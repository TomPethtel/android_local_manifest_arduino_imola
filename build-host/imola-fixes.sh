#!/bin/bash
# Device-tree fixes needed to boot the YAJATapps imola port, independent of the build host. Idempotent.
set -euo pipefail
cd ~/lineage-24

# 1. system_server dies at startup with "Failed to create ashmem: No such file or directory": the 6.18 kernel
#    has no /dev/ashmem, and libcutils only switches to memfd when ro.vendor.api_level >= 202604. The tree ships
#    PRODUCT_SHIPPING_API_LEVEL := 36 (-> vendor API level 202504), so ashmem is chosen and zygote restarts every
#    5 s forever. Force memfd (libcutils honours sys.use_memfd) rather than bumping the shipping API level, which
#    would pull in other VSR requirements.
mk=device/arduino/imola/device.mk
grep -q 'sys.use_memfd=true' "$mk" || { printf '\n# Local: no /dev/ashmem on 6.18; make libcutils use memfd (see build-host/imola-fixes.sh)\nPRODUCT_PROPERTY_OVERRIDES += sys.use_memfd=true\n' >> "$mk" && echo "patched: $mk (sys.use_memfd)"; }
grep -q 'sys.use_memfd=true' "$mk" && echo "IMOLA FIXES OK"
