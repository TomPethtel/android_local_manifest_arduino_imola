#!/bin/bash
# Package the native arm64 build (OUT_DIR=out-arm64) into the EDL image set the Arduino flasher expects.
# device/arduino/imola/tools/package_qdl.py hardcodes out/ and out/host/linux-x86, so give it a shim top dir
# and the arm64 simg2img on PATH. Needs mtools (mcopy) and zstd in the VM.
set -e
cd ~/lineage-24
shim=$(mktemp -d)
ln -s "$PWD/out-arm64" "$shim/out"
ln -s "$PWD/vendor" "$shim/vendor"
ln -s "$PWD/device" "$shim/device"
export PATH=$PWD/out-arm64/host/linux-arm64/bin:$PATH
python3 device/arduino/imola/tools/package_qdl.py --top "$shim" --out-dir "$PWD/out-arm64/target/product/imola/arduino-images"
rm -rf "$shim"
ls -la out-arm64/target/product/imola/LineageOS-24.0-imola-*.tar.zst
