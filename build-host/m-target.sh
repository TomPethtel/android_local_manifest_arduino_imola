#!/bin/bash
# Build specific targets with the same environment as build-imola-arm64.sh, e.g. `m-target.sh selinux_policy`.
export PATH=$(printf "%s" "$PATH" | tr ":" "\n" | grep -vx "$HOME/bin" | paste -sd:)
cd ~/lineage-24 || exit 1
export OUT_DIR=out-arm64 USE_CCACHE=1 CCACHE_EXEC=/usr/bin/ccache CCACHE_DIR=$HOME/.ccache-arm64
export SOONG_INCREMENTAL_ANALYSIS=false SOONG_BUILD_GOGC=30
export ALLOW_MISSING_DEPENDENCIES=true SKIP_ABI_CHECKS=true THINLTO_USE_MLGO=false
source build/envsetup.sh >/dev/null
lunch lineage_imola-cp2a-userdebug >/dev/null || exit 1
m -j8 "$@"
