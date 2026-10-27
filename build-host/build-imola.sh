#!/bin/bash
# Build LineageOS 24 for the Arduino UNO Q (imola) inside the Lima "aosp" VM.
set -o pipefail
export PATH=$HOME/bin:$PATH
cd ~/lineage-24 || exit 1
./device/arduino/imola/patches.sh
export SOONG_INCREMENTAL_ANALYSIS=false
export SOONG_BUILD_GOGC=30
export GODEBUG=asyncpreemptoff=1
export NINJA_HIGHMEM_NUM_JOBS=2
export USE_CCACHE=1 CCACHE_EXEC=/usr/bin/ccache CCACHE_DIR=$HOME/.ccache
ccache -M 50G >/dev/null
source build/envsetup.sh
lunch lineage_imola-cp2a-userdebug || exit 1
rc=1
for attempt in 1 2 3 4 5; do
  echo "=== build attempt $attempt ==="
  m -k -j8 bacon 2>&1 | tee ~/build.log; rc=${PIPESTATUS[0]}
  [ $rc -eq 0 ] && break
done
echo BUILD_EXIT=$rc
