#!/bin/bash
# Package a native arm64 build into the EDL image set the Arduino flasher expects.
#   package-arm64.sh                imola's whole-image build in OUT_DIR=out-imola
#   package-arm64.sh <result dir>   a shared-system build merged for imola (lineage-iq9075's build-lumina.sh,
#                                   ~/lumina-builds/imola-<variant>-<date>, relative to the VM home or absolute):
#                                   its super.img and linux.img (the boot image), plus kernel, ramdisk and dtb
# device/arduino/imola/tools/package_qdl.py hardcodes out/ and out/host/linux-x86, so give it a shim top dir
# and the arm64 simg2img on PATH. Needs mtools (mcopy) and zstd in the VM.
set -e
cd ~/lineage-24
shim=$(mktemp -d)
if [ -n "${1:-}" ]; then
  R=$(cd ~ && cd "$1" && pwd)
  P=$shim/out/target/product/imola
  mkdir -p "$P"
  for f in kernel ramdisk.img dtb.img super.img; do ln -s "$R/$f" "$P/$f"; done
  ln -s "$R/linux.img" "$P/boot.img"
  out=$R/arduino-images
  host=$(ls -d "$PWD"/out-system-*/host/linux-arm64 | head -1)
else
  ln -s "$PWD/out-imola" "$shim/out"
  out=$PWD/out-imola/target/product/imola/arduino-images
  host=$PWD/out-imola/host/linux-arm64
fi
ln -s "$PWD/vendor" "$shim/vendor"
ln -s "$PWD/device" "$shim/device"
export PATH=$host/bin:$PATH
python3 device/arduino/imola/tools/package_qdl.py --top "$shim" --out-dir "$out"
rm -rf "$shim"
ls -la "$(dirname "$out")"/LineageOS-24.0-imola-*.tar.zst
