#!/bin/bash
# Native arm64 build of LineageOS 24 for imola. Separate OUT_DIR so the Rosetta/x86 build in out/ is untouched.
# NOTE: do not put ~/bin (the uname->x86_64 shim) on PATH here.
set -o pipefail
cd ~/lineage-24 || exit 1
export OUT_DIR=out-arm64
export USE_CCACHE=1 CCACHE_EXEC=/usr/bin/ccache CCACHE_DIR=$HOME/.ccache-arm64
export SOONG_INCREMENTAL_ANALYSIS=false SOONG_BUILD_GOGC=30
export ALLOW_MISSING_DEPENDENCIES=true SKIP_ABI_CHECKS=true THINLTO_USE_MLGO=false
echo "host: $(uname -m), prebuilt prefix should be linux-arm64"
ccache -M 50G >/dev/null
source build/envsetup.sh
lunch lineage_imola-cp2a-userdebug || exit 1
[ "$1" = "--lunch-only" ] && { echo LUNCH_OK; exit 0; }
rc=1
for attempt in 1 2 3; do
  echo "=== arm64 build attempt $attempt ==="
  m -k -j8 bacon 2>&1 | tee ~/build-arm64.log; rc=${PIPESTATUS[0]}
  [ $rc -eq 0 ] && break
done
echo BUILD_EXIT=$rc
