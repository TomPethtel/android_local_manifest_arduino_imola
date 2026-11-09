# Building on an Apple Silicon Mac

AOSP does not build on macOS, and its host toolchain ships only as x86_64 Linux binaries.
This directory holds everything used to build LineageOS 24 for the Uno Q (`imola`) on an
M-series Mac, two ways:

1. **Rosetta path (proven):** an arm64 Ubuntu VM running the stock x86_64 prebuilts under
   Rosetta 2. Slow (a full build is 8–12 h of compile) and the translated tools crash now
   and then, but every part of the build has been exercised.
2. **Native arm64 path (experimental):** the same tree with arm64 host prebuilts and a set of
   build-system patches, after <https://actinis.io/blog/building-aosp-on-arm64>. Builds in its
   own `OUT_DIR`, so both can live in one tree.

Tested on an M5 Max, 36 GB RAM, macOS 26, Lima 2.2.

## 1. The VM

```bash
softwareupdate --install-rosetta --agree-to-license     # once, on the Mac
limactl create --name=aosp --vm-type=vz --rosetta --cpus=18 --memory=28 --disk=600 \
  --mount-type=virtiofs --tty=false template:ubuntu-24.04
limactl start aosp
```

* 28 GiB is the ceiling on a 36 GB Mac. 32 GiB made macOS swap 20 GB and Rosetta began failing
  with `Failed to map AOT header: 12`.
* Give the guest a 64 GB swap file. Soong's analysis of this tree peaks above 26 GB:
  `sudo fallocate -l 64G /swapfile && sudo chmod 600 /swapfile && sudo mkswap /swapfile && sudo swapon /swapfile`
  (add `/swapfile none swap sw 0 0` to `/etc/fstab`).
* Install build dependencies with `vm-setup-deps.sh` (run inside the VM). It enables amd64
  multiarch and installs the x86_64 glibc that the AOSP prebuilts link against.

## 2. Source

Follow the top-level README (`repo init` on `lineage-24.0`, add this manifest, `repo sync`,
`patches.sh`). The manifest here names its remote `gh_imola`; the upstream copy calls it
`github`, which collides with LineageOS's default manifest and makes `repo sync` fail with
"remote github already exists".

## 3. Rosetta build

```bash
mkdir -p ~/bin && cp uname-shim.sh ~/bin/uname && cp uname-shim.sh ~/bin/arch && chmod +x ~/bin/*
cd ~/lineage-24/build/soong && git apply ~/rosetta-soong_ui.patch
cp build-imola.sh ~/ && nohup ~/build-imola.sh > ~/build-wrapper.log 2>&1 < /dev/null &
```

What the pieces do, and why:

| Piece | Why |
|---|---|
| `uname`/`arch` shims on `PATH` | Native scripts see `aarch64` and look for `prebuilts/go/linux-arm64`; translated binaries already report `x86_64`. |
| `rosetta-soong_ui.patch` | `soong_ui` runs `soong_build` with `env -i` and filters ninja's environment. The patch passes through `SOONG_BUILD_GOMEMLIMIT`, `SOONG_BUILD_GOGC` and `GODEBUG`. |
| `SOONG_BUILD_GOGC=30` | Without it the Go heap of `soong_build` grows to ~50 GB and thrashes swap. A hard `GOMEMLIMIT` below the live heap (~26 GB) puts the GC in a death spiral instead; do not use one. |
| `SOONG_INCREMENTAL_ANALYSIS=false` | Lineage's release config turns incremental analysis on; its in-memory cache made the heap grow run over run. |
| `GODEBUG=asyncpreemptoff=1` | Go's async-preemption signals crash translated Go tools (`siso`, `build_license_metadata`, …). |
| `m -k` in a retry loop | Rosetta also hangs or segfaults the odd `clang`, `python` or `java` step. Keep going, then retry only the failures. |
| `-j8`, `NINJA_HIGHMEM_NUM_JOBS=2` | At `-j12` the Java/R8 phase ran 8+ JVMs and OOM-killed steps. |

Other things learned the hard way:

* Any interruption of the build (crash or kill) re-runs the full Soong analysis, 20–50 min.
* Protect the driver once it is running:
  `echo -1000 | sudo tee /proc/$(pgrep -x siso)/oom_score_adj`.
* nsjail sandboxing is disabled under Rosetta; harmless.
* `/usr/bin/repo` from apt is read-only and nags about updating; harmless.

## 4. Native arm64 build (experimental)

Prebuilts to add to the tree (AOSP has arm64 clang and Go; JDK 21 and Rust come from upstream):

```bash
cd ~/lineage-24
git clone --filter=blob:none --depth=1 --sparse -b mirror-goog-main-prebuilts \
  https://android.googlesource.com/platform/prebuilts/clang/host/linux-arm64 prebuilts/clang/host/linux-arm64
(cd prebuilts/clang/host/linux-arm64 && git sparse-checkout set clang-r584948b clang-r596125)
git clone --filter=blob:none --depth=1 -b mirror-goog-llvm-r596125-release \
  https://android.googlesource.com/platform/prebuilts/go/linux-arm64 prebuilts/go/linux-arm64   # go1.25.4
# JDK 21: Temurin aarch64 tarball extracted to prebuilts/jdk/jdk21/linux-arm64
# Rust 1.93.1: the aarch64-unknown-linux-MUSL host toolchain (rust-1.93.1-aarch64-unknown-linux-musl.tar.xz,
#   install.sh --prefix=prebuilts/rust-toolchain/linux-arm64/1.93.1) with rust-std for aarch64-linux-android
#   and armv7-linux-androideabi added, plus linux-musl-x86's Android.bp copied next to it. It must be the musl
#   build: rustc only loads proc-macro dylibs built for its own host triple, and Soong builds host crates for
#   aarch64-unknown-linux-musl. arm64-patches.sh drops Alpine's musl libgcc_s.so.1 into its lib/ and wraps
#   rustc with RUSTC_BOOTSTRAP=1.
sudo apt-get install musl       # loader for the musl-linked arm64 build-tools (bison, m4, ckati, …)
```

Then `bash arm64-patches.sh` (idempotent) and `build-imola-arm64.sh`. The patch script covers:

* `build/make`: `HOST_ARCH`/`HOST_PREBUILT_ARCH` on aarch64, host prebuilt prefix, clang paths via `HOST_PREBUILT_TAG`, `HOST_arm64.mk`.
* `build/soong`: install into `out/host/linux-arm64`, stage `libc_musl.so` for built tools on a forced-musl host, Rust host prebuilts from `linux-arm64` with the `linux_musl_arm64` target, nsjail from the arm64 dir.
* `prebuilts/build-tools` and `prebuilts/jdk/jdk21`: enable bison/flex/m4/make/javap on arm64.
* `system/sepolicy`: `getopt` results into `int` (plain `char` is unsigned on aarch64).
* `prebuilts/rust-toolchain/linux-x86`: no from-source sysroot on musl_arm64; `vendor/lineage`: kernel host tools from the distro.
* `bionic`: the kernel-header cleaner behind `generated_kernel_headers` loads libclang from the arm64 clang.

Then `package-arm64.sh` wraps the device tree's `package_qdl.py` for the `out-arm64` layout and produces
`arduino-images/` (512 MB boot partition, 4 GB root partition with the super image, Qualcomm firmware and
EDL XMLs) plus a `.tar.zst` of it.

## 5. Flashing and what the board needs to boot (2026-11-07)

**Flash with qdl, not with `arduino-flasher-cli`.** The Arduino flasher re-sizes the root partition to fill the
eMMC and silently drops the `userdata` entry from the GPT. Android then waits 40 s for `/data`, apexd cannot
activate the tethering module, the `bpfloader` service stays at its platform stub `/system/bin/false`, and init
reboots with reason `netbpfload-missing` at 61 s, forever (the red QRB status LED is the kernel's panic-indicator
trigger firing during that reboot). `brew install qdl`, put the JCTL jumper on, power-cycle, then:

```bash
cd arduino-images/flash && qdl --storage emmc prog_firehose_ddr.elf rawprogram0.xml patch0.xml
```

`qdl-flash.sh <arduino-images dir>` does the same from the Mac. `qdl-flash.sh --keep-data <dir>` writes only
`efi` (kernel, ramdisk, dtb) and `rootfs` (super), so `userdata` survives, including Developer options and Rooted
debugging. Use it to update a board already on this layout (about 2 min). The full flash zeroes the heads of
`userdata` and `metadata`. There is no jumper-free path: ABL never sees the kernel's `bootloader` reboot reason
(`BootReason:0`), and the Armbian U-Boot has no USB controller for fastboot.

Two device-tree fixes on top of the upstream port, applied by `imola-fixes.sh` (host-independent):

* `sys.use_memfd=true`: the 6.18 kernel has no `/dev/ashmem`, and libcutils only switches to memfd from vendor
  API level 202604; the tree ships shipping API level 36, so system_server died at startup with
  "Failed to create ashmem" and zygote restarted it every 5 s.

Optional debug variant, `usb-adb-debug.sh`: puts the USB-C port in device mode with adb on it (the stock port
keeps the port as a USB host with adb on TCP 5555), fixes the vendor usb rc resetting `sys.usb.config` to
`none` after boot, and mirrors logcat errors into dmesg so they reach the serial console.

Serial console: JCTL pin 4 (TX), 6 (RX), 7 (GND), 1.8 V logic, 115200 8N1; an FTDI TTL232RG-VREG1V8 works
directly. On macOS hold the port open or the baud rate resets: `exec 3<>$dev; stty -f $dev raw 115200; cat <&3`.

Status: LineageOS 24 boots to `sys.boot_completed=1` on the UNO Q from the native arm64 build.

## 6. UNO Q Mods (2026-11-08)

`unoq-mods.sh` builds the STM32 into the image as a Moto-Mods-style Greybus accessory. The project is a
separate repo (unoq-mods). Its `aosp/build-prebuilts.sh` and `aosp/sync-to-vm.sh` put what the build needs at
`vendor/unoq-mods`, and then this script wires it in:

* the `gb-unoq` Greybus host (in-kernel SVC) as `CONFIG_GREYBUS_UNOQ`, plus the staging Greybus class drivers,
  all loaded at boot from `vendor_dlkm`. `LEDS_CLASS_FLASH` is needed too, or olddefconfig silently drops
  gb-light.
* `persist.vendor.unoq.mcu_mode` (default `greybus`) decides who owns `/dev/ttyHS1`: gb-unoq's line
  discipline, or Arduino's `arduino-router` for stock Bridge sketches. `arduino-router` and `imola-bridge`
  become `disabled`, and the device's MCU reset on router stop only runs in bridge mode. Otherwise it drops
  the loader's ready line right after gb-unoq raised it, and the sketch never starts.
* ModService preloaded as a priv-app on the system uid. Android 17 refuses a sideloaded platform-signed app
  that joins `android.uid.system`. The Mods Demo app ships alongside it.
* ueventd gives the Greybus gpiochips, `/dev/gb/raw*` and `/dev/ttyGB*` to group `system`.

Verified 2026-11-08 on board 2, after a keep-data flash and a cold boot: the sketch enumerates, ModService
(uid 1000) attaches it within a second of starting, and the demo app drives the LEDs. unoq-mods'
`tools/image-check.sh` runs the checks.

## 7. Performance and SELinux enforcing (2026-11-08)

The port now boots **SELinux enforcing** with no denials in boot, Mods, sketch uploads, bridge mode, the
browser or Settings. `selinux-audit.sh` lists what a board has denied since boot (`--enforce` runs a smoke
test), and `m-target.sh <target>` builds single targets, such as `selinux_policy`, with the arm64 build's
environment. The image is `IMOLA_SELINUX=enforcing` by default. `IMOLA_SELINUX=permissive bash package-arm64.sh`
packages a permissive one for debugging: the kernel command line comes from `package_qdl.py` (boot.scr), not
BoardConfig.

* **Memfd** (`imola-fixes.sh`). The 6.18 kernel has no `/dev/ashmem`, so `sys.use_memfd` (now set from the
  product build.prop) backs shared memory with memfd. Two follow-on costs:
  * The policy never enabled `memfd_class`, because it keys off vendor API 202604, so every memfd crossing
    binder was denied. `sepolicy/system_ext/private` enables it, and Android 17's `memfd_file` rules take over.
  * libcutils recognised memfds by `readlink(/proc/self/fd/N)`, which Chromium's renderer sandbox refuses. The
    renderer fell back to ashmem on every allocation, about half a core while a page renders.
    `libcutils-memfd-sandbox.patch` checks the seals instead.
* **Labels for the QCM2290** (`selinux-fixes.sh`, `sepolicy/vendor`). The device policy came from db845c, so its
  sysfs labels pointed at sdm845 addresses. This adds the real display, remoteproc (including the modem at
  6080000), rmtfs memory, wakeup and eMMC-queue nodes, plus `gralloc.minigbm.so` (in-process for every graphics
  client), Mesa's `vendor.mesa.*` options and the Android 17 build-info props.
* **vendor_init may not set platform props.** `sys.use_memfd`, the ADB and timezone props and
  `persist.demo.rotationlock` moved to the product build.prop. `usb-adb-debug.sh` deletes the vendor rc's
  `sys.usb.config` override; AOSP's init.usb.rc already applies the persist value.
* **Treble.** `gpio_chip_device` moved to system_ext public so system-side ModService can be granted it.
  `unoq-mods.sh` folds the device's `init.svc.arduino-router` triggers into the Mods mode switch, since
  vendor_init can't read `init.svc.*`.
* **Sketch uploads** stage in `/data/vendor/openocd`. AOSP's shell.te neverallows keep every vendor domain out of
  `/data/local/tmp`.
* **OpenOCD** starts with `poll off` (it bit-banged SWD every 100 ms), and the `logcat_kmsg` debug mirror is gone.

## 8. A/B slot state: Qualcomm's boot control HAL (2026-11-08)

**The trap.** ABL keeps each slot's state in the attribute bits of its `boot_a`/`boot_b` GPT entry: priority,
active, retry count, successful, unbootable. On every boot of a slot that isn't marked successful it lowers the
retry count, and at 0 it marks the slot unbootable and parks in fastboot. The port shipped AOSP's default boot
HAL (`com.android.hardware.boot`), which records success only in `misc`, where ABL never looks. Seven boots after
`fastboot set_active a`, the board sat in fastboot looking dead.

**The fix.** `bootctrl-qti.sh` swaps in `hardware/qcom-caf/bootctrl`, which writes those bits on both GPT copies,
and installs its policy from `sepolicy/bootctrl`. `/dev/block/mmcblk0` is labelled `root_block_device` and
`hal_bootctl_default` may write it. The QCM2290 needs nothing else. `ro.boot.bootdevice` is unset, so gpt-utils
takes its eMMC path, and the Arduino GPT has `_a`/`_b` copies of `boot` and the firmware partitions in the HAL's
list. Don't set `ro.vendor.bootctrl.enable=true`: that is the HAL's GVM mode, which records success only in misc.

`slot-status.sh` prints the bits from a running board over adb root, read-only. Verified on board 2 after a
keep-data flash: the first boot marked `boot_a` successful (retry 5 → 4), and six reboots later it is still
retry 4, successful 1. No denials, and image-check is 13/13.

How it behaves:

* vold marks the slot from `cp_commitChanges` once boot completes. If that call fails, ActivityManager reboots
  ("Checkpoint commit failed") until the retries run out, so a change to the HAL or its policy must leave
  `selinux-audit.sh` clean.
* The first boot of an unmarked slot mounts `/data` with an f2fs checkpoint, because vold treats it like the
  first boot after an OTA. The checkpoint is committed at boot complete, and later boots skip it. That first
  boot comes after this image replaces the default HAL, and again after any `fastboot set_active`.
* `fastboot set_active a; fastboot reboot` still re-arms a slot (retry 7, successful 0), and the next completed
  boot marks it again.
* `ddr` and `uefi_dtb` aren't in Qualcomm's list, so `slot-status.sh` counts 16 of 18 other `_a` entries
  marked successful.

## 9. A/B OTA (2026-11-08)

**Why it didn't work.** The board had A/B dynamic partitions and, since section 8, a boot HAL ABL listens to,
but an OTA could not have worked:

* `update_engine` wasn't on the image, so nothing could apply a payload (the Lineage Updater app was there).
* The kernel, ramdisk and dtb were files in the single, unslotted `efi` FAT partition, and `boot.scr`
  hard-coded `androidboot.slot_suffix=_a`. A slot switch would have booted the old kernel against `_a`.
* U-Boot can't see the slot: ABL hands it no `androidboot.slot_suffix`.
* Virtual A/B (`libsnapshot`) CHECKs that the dynamic partitions live in a partition named `super`. The port
  kept Arduino's name, `rootfs`, so `update_engine` aborted at the start of every update.
* The build offers `otapackage` only to devices with a recovery fstab, and this one has no recovery.

**The layout now** (`ota-ab.sh`, `package-qdl-ab.patch`). The old 512 MB `efi` space is split, and nothing
after it moves, so a keep-data flash converts a board and userdata survives:

| GPT | Size | Holds |
|---|---|---|
| `efi` (p67) | 128 MB | `boot.scr` only. U-Boot's `do_boot` always loads it from `mmc 0:43`. |
| `linux_a`, `linux_b` (p71, p72) | 192 MB each | The slot's `boot.img`: kernel, ramdisk, dtb, `BOARD_KERNEL_CMDLINE` |
| `super` (p69, was `rootfs`) | 4 GB | The dynamic partitions |
| `boot_a`, `boot_b` | 4 MB | U-Boot, with `uboot.slot=_a` / `_b` added to the image header's command line |

**Boot path.** ABL picks `boot_a` or `boot_b` from the GPT slot bits and passes that image's header command
line on in `/chosen/bootargs`. `boot.scr` reads `uboot.slot=` from there (`fdt get value`, `setexpr sub`),
reads `linux_<slot>` sized from the boot image header, and `bootm`s it with
`androidboot.slot_suffix=<slot> androidboot.selinux=<mode>` in front of the image's own command line. On
failure it resets, so ABL counts the attempt.

**U-Boot traps.**

* This U-Boot ignores the load addresses in the boot image header and runs the kernel where it sits in the
  image. An arm64 kernel must start on a 2 MB boundary, so `boot.scr` reads the image to `0x10a600000` minus
  one page. Unaligned, the kernel panics at 0.008 s ("kernel stack overflow").
* A panic that early comes before `qcom_scm` clears the download cookie, so the board drops into Qualcomm's
  RAM-dump mode (`QUSB_BULK`, 05c6:900e) and waits for a power cycle.
* Commands typed over the serial console lose characters on long lines (no flow control). Type about 4 ms
  per character.

**Build and install.**

```bash
bash ~/build-host/ota-ab.sh                      # once, after selinux-fixes.sh and bootctrl-qti.sh
bash ~/build-host/m-target.sh droid otapackage   # -> out-arm64/target/product/imola/lineage_imola-ota.zip
```

The zip is a full OTA (about 1 GB). `linux.img` (a copy of `boot.img`) reaches target-files as a radio image:
the build's custom-image route only records images when AVB is on, which this port doesn't use. On the Mac,
`ota-install.sh <zip>` pushes it to `/data/ota_package` and hands the payload to `update_engine` over adb root,
as the Updater app would; reboot to switch slots.

**Verified on board 2** (keep-data flash of the new layout, then the OTA from the same build):

* The install took 2 min 49 s and staged snapshots of the six dynamic partitions, writing `linux_b` directly.
  `boot_b` went active with retry 7, and there were no denials.
* On reboot: ABL `Booting from slot (_b)`, U-Boot `Android slot _b`, kernel `androidboot.slot_suffix=_b`.
  The merge finished about 15 s after boot completed, and `boot_b` was marked successful.
* A plain reboot of the merged slot passes `image-check.sh` 13/13.
* `ota-install.sh` then installed the same zip back to `_a`, and the board switched, merged and marked `_a`
  successful the same way, again with no denials.
* After the merge, `boot_a` is marked unbootable. That's normal Virtual A/B: the old slot's dynamic
  partitions are gone.

**Not done.** No update server: the Updater app's `lineage.updater.uri` is unset, so OTAs go in with
`ota-install.sh`. No incremental OTAs yet. Once, the board hard-reset during a 1 GB `adb push`, with the
kernel log cut off mid-line at `arm-smmu c600`; a retry went through.
