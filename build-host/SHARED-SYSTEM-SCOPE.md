# One system build for the UNO Q and the IQ-9075 (scope, 2026-11-21)

Question (Tom, 2026-11-21): "Shouldn't a lot of stuff be able to be shared since its all one OS, we just need
variation per board for the hardware?"

**Answer: yes.** The two products' system side is already nearly identical. AOSP's `merge_target_files` was built
for exactly this ("group sizes ... may vary for each board that uses a shared system image"). Recommended:
one generic system build plus a vendor-only build per board, merged per board. Rough effort is **3–4 days**,
about 1.5 of them waiting on builds and boards. The siso action cache doesn't help: it can't produce a hit across
two out dirs at all (section 3).

Evidence comes from `~/lineage-24` in the `aosp` VM, read only (an imola build was running in `out-imola`).
I compared `out-arm64/target/product/{imola,iq9075}` (imola userdebug from 11-09, iq9075 user from 11-21 11:26),
both device trees, and `build/make/tools/releasetools/merge/`.

## 1. What differs on the system side

Both products inherit the same `core_64_bit_only` + `full_base` + `common_full_tablet_wifionly`, with the same
arch/CPU (armv8-a, cortex-a53), shipping API 36, erofs and Virtual A/B. Everything that's left:

| Item | imola | iq9075 | Shared-system fix |
|---|---|---|---|
| Identity props: `ro.product.{system,system_ext,product}.*`, `ro.build.fingerprint`, `ro.lineage.device`/`version` | Arduino / imola | Qualcomm / iq9075 | Give the shared system a generic identity and set `ro.product.property_source_order=odm,vendor,product,system_ext,system` in it. Then `ro.product.model` etc. come from vendor (`ro.product.vendor.model` is already `Uno Q` / `IQ-9075 EVK`). `ro.build.fingerprint` becomes the system's; `ro.vendor.build.fingerprint` stays per board. Only Lineage's Updater reads `ro.lineage.device`, and OTAs here go through `ota-install.sh`. |
| `WiringUno` (`/system/app`, `platform_apis` + platform cert) | yes | no | Can't move to vendor: vendor apps may not use platform APIs. Ship it on both, and have imola's vendor install a feature XML that the app checks before showing its launcher. Or accept it showing on the 9075. |
| `AnnexService` (system_ext priv-app), `AnnexDemo` (product) | yes | no | Ship them on both. Annex is coming to the 9075 anyway (annex `docs/PORT-IQ9075.md`). Still to check that the service is inert with no Greybus. The `unoq-*` tools and `arduino-router` are already vendor. |
| `adb_keys` (`/product/etc/security`) | no | yes | Ship on both (both trust the build Mac's key). |
| `ro.adb.secure=0`, `persist.sys.usb.config=adb` | every variant (device.mk + product.prop) | userdebug/eng only | One policy for both. **Decision:** with the iq9075 policy, imola user builds would need the Mac's key. |
| `update_engine_client` | debug only | every variant | Ship on every variant. |
| system_ext sepolicy (`SYSTEM_EXT_{PUBLIC,PRIVATE}_SEPOLICY_DIRS`) | sepolicy-local + Annex: 8 files | sepolicy-local: 5 files | One common directory with the union. `gpio.te`, `memfd_class.te` and `isolated_app.te` are byte-identical. The rest (openocd port, greybus types, `mod_service`, storaged/fsck on `sysfs_devices_block`, `ro.vendor_dlkm.*` contexts) don't collide. |
| `ro.com.google.clientidbase` | android-arduino | android-google | Drop it, or use one value. |

Already identical or already vendor-side:
- The framework-res and SettingsProvider overlays (`DEVICE_PACKAGE_OVERLAYS`, compiled into `/system`) are
  byte-identical on both boards.
- Dalvik heap, `dalvik.vm.isa.*`, `ro.soc.*`, every HAL, Mesa, firmware, both boot HALs, fstabs and init rc files
  are already vendor-side.
- No system-side module uses the board kernel's headers: `generated_kernel_headers` users are all
  `hardware/qcom-caf` vendor modules.

The ~65 extra `/system` files on imola are variant noise (userdebug vs user), not a product difference.

Trade-off: system native code stays on the common CPU target. It is cortex-a53 on both boards today, so nothing is
lost. A later A78C tuning would reach only the 9075's vendor code.

## 2. How the mixed build would work

The setup needs three lunch targets and three out dirs, so only one board-independent tree:

1. **`lineage_lumina_sys`** (new, e.g. `device/lumina/common`). It is GSI-shaped like `generic_system_arm64.mk`:
   `TARGET_NO_KERNEL`, no vendor/odm/ramdisk images, and system + system_ext + product with the superset from
   section 1. Build it once per variant with `m target-files-package`.
2. **`lineage_imola_vendor`, `lineage_iq9075_vendor`.** Each inherits today's product, in the same way as
   cuttlefish's `aosp_cf_vendor.mk`. They set `PRODUCT_BUILD_{SYSTEM,SYSTEM_EXT,PRODUCT}_IMAGE := false`,
   `PRODUCT_BUILD_SUPER_PARTITION := false` and `TARGET_SKIP_OTA_PACKAGE := true`, then run
   `m target-files-package`.
   - The target-files rule pulls in `FULL_SYSTEMIMAGE_DEPS` only `ifdef BUILDING_SYSTEM_IMAGE`
     (`core/Makefile:6557`), so system modules aren't compiled.
   - Output: vendor, vendor_dlkm, system_dlkm, BOOT (the board ramdisk with its fstab), and RADIO/linux.img.
3. **Merge per board.** Run `merge_target_files --framework-target-files sys.zip --vendor-target-files
   <board>.zip --rebuild-sepolicy --output-target-files <board>-merged.zip`. Then `ota_from_target_files` gives the
   board's OTA, and `img_from_target_files` gives images for `package_qdl.py` / `install-android.sh`.

What the merge does, from the source:
- **Framework side:** system, system_ext, product, root, vbmeta_system. **Board side:** everything else,
  including BOOT and RADIO. Both boards already ship `linux.img` as a RADIO image, so imola's `linux_a/b` and the
  9075's GRUB `linux_a/b` pass through untouched.
- **Super:** `MergeDynamicPartitionInfoDicts` takes the super groups and sizes from the vendor side and unions
  the partition lists. Both BoardConfigs already list system/system_ext/product in their group, so imola's 4 GiB
  super and the 9075's 11.5 GiB super both work. Today's super images are ~1.36 GB.
- `ab_partitions.txt` is the union. Neither board uses AVB, so there is no vbmeta to reconcile. Both run VAB
  without compression.

**A/B OTA per board.** Each board gets its own OTA zip from its own merged target-files; the system bytes inside
are identical. update_engine, the two boot HALs (imola: GPT attributes via bootctrl-qti; 9075: GRUB env in misc)
and both `linux_a/b` layouts are board-side, so nothing in them changes. Incrementals work between two merged
target-files of the same board.

Gotchas:
- **Sepolicy hash.** Vendor's `precompiled_sepolicy` is keyed to the platform policy's hash. A newer system with
  an old vendor makes init compile policy on every boot, which hurts most on the QRB2210. Use `--rebuild-sepolicy`
  at merge time.
- **When to rebuild a vendor target-files.** Only when board inputs change, or after a sync that touches
  first-stage init or fs_mgr (the board ramdisk carries first-stage init).
- **Soong analysis.** It is still per tree, at about 26 GB peak for whole-tree analysis. A sync that touches any
  Android.bp costs three sequential analyses instead of two.
- **Packaging scripts.** `package-arm64.sh`/`package_qdl.py`, `install-android.sh` and `ota-install.sh` must read
  the merged images instead of `$OUT`.

| Change | Today (out-imola + out-arm64) | Mixed |
|---|---|---|
| Framework/system change or sync | system side built twice | built once, plus 2 merges |
| Board-only change | 1 incremental | 1 vendor-only incremental + 1 merge (about the same) |
| Disk | 2 full out dirs | 1 full + 2 vendor-only (kernel obj + vendor modules; guess 20–30 GB each) |

The system side is what made product switches expensive. In the killed imola-after-iq9075 run in `out-arm64`
(today 15:23, 95,977 steps queued, killed at ~20k), 63% of rebuilt outputs were Java (`android_common`), 15%
system native, and under 1% vendor. That run also flipped user to userdebug, so a pure product switch is
smaller; that number isn't measured.

## 3. The siso action cache

- **It can't share across out dirs.** An action's cache key covers its command, inputs and output paths. AOSP
  runs every action from the source root with out-dir paths in the arguments (`out-imola/soong/.intermediates/…`
  vs `out-arm64/…`), so the two trees never produce the same key: zero cross-board hits. siso's `canonicalize_dir`
  rewrites only the working directory (Chromium's layout), which is the same here anyway.
- **It only helps inside one shared out dir**, which means going back to product switches. There, only actions
  byte-identical to a cached one hit. The Java bulk of a switch depends on product config, so the hit rate is
  unknown and probably far from 100%.
- **It doesn't fit as measured.**
  - siso alone reached 24 of 27 GB at ~1M entries. A -j8 build needs ~15–19 GB for its own JVMs and clang, so
    siso would have to stay under ~8–10 GB, roughly a 3× cut.
  - Unmeasured routes:
    - siso's built-in `-local_cache_enable` (disk cache in `~/.cache/siso`, no bazel-remote), caching only the
      Java/R8/D8/metalava/APEX rule families to cut the entry count (C++ already has ccache).
    - `GOMEMLIMIT` passed to siso through the same ninja-env patch as `GODEBUG`. That only helps if the live heap
      is smaller than the limit, which wasn't true for soong_build.
    - A bigger machine.
- **Verdict:** not cheaper. Even if it fit, it would speed up the shared-out-dir model that the mixed build makes
  unnecessary.
- **Side note:** ccache also hashes `-I` paths, so generated-header include dirs under `out-imola/` vs
  `out-arm64/` likely give misses too. The split probably lost some ccache hits; `ccache -s` after the current
  out-imola build would show it.

## Effort and order

| Step | Effort |
|---|---|
| Common system product, union system_ext sepolicy, WiringUno feature gate, adb policy | 1 day |
| Two `_vendor` products, with the system-side packages and system_ext dirs moved out | 0.5 day |
| `merge-board.sh` (merge, OTA, images) and the packaging/install script changes | 1 day |
| First cycle: cold system build, 2 vendor builds, merges, flash + A→B OTA on both boards | 1–1.5 days, mostly waiting |

Start after the running out-imola build finishes (only one build fits in the VM). `out-arm64` can become the
system tree, which saves part of the cold build at the cost of a product-switch-sized rerun.

Decisions for Tom:
1. **adb policy on imola user builds:** key-checked like the 9075, or open.
2. **WiringUno:** gate it on an imola-only feature, or let it show on the 9075.
3. **Optional disk reclaim:** about 100 GB is reclaimable: `out/` (74 GB, the Oct 27 Rosetta tree) and
   `out-arm64/target/product/imola` (27 GB, stale since imola moved to out-imola). Nothing deleted.
