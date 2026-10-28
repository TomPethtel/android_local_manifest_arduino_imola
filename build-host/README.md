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

Then `package-arm64.sh` wraps the device tree's `package_qdl.py` for the `out-arm64` layout and produces
`arduino-images/` (512 MB boot partition, 4 GB root partition with the super image, Qualcomm firmware and
EDL XMLs) plus a `.tar.zst` of it, flashable with `arduino-flasher-cli flash --board ventunoq <dir>` or `qdl`.

Build `droid`, not `bacon`: Lineage disables the OTA zip for imola (no recovery image), so `bacon` always
fails on its final `ln`. The device has no boot.img, recovery or A/B slots at all; U-Boot loads the kernel,
ramdisk and dtb from the FAT boot partition, and updates mean reflashing (the `nouser` XML keeps userdata).

Status (2026-10-27): the native arm64 build COMPLETES. First full run: 45 min analysis + ~4 h compile at -j8
(the kernel ran at -j2 that time, see step 22) + packaging, with every fix above applied up front. The
LFI-verifier non-fatal change from the blog was never needed.
