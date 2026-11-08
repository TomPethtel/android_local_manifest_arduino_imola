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
# 2. The memfd workaround's cost: apps still send ashmem ioctls (Chromium's renderer: ASHMEM_SET_PROT_MASK,
#    0x7705) to what are now memfd files labelled appdomain_tmpfs. No policy covers that, so with SELinux
#    permissive every one is a logged denial: thousands per second while a page renders, about half the
#    renderer's CPU in the kernel plus a third of a core in logd. The ioctls fail with ENOTTY on memfd either
#    way, so don't audit them.
te=device/arduino/imola/sepolicy/memfd_ashmem.te
[ -f "$te" ] || { cat > "$te" <<'EOF'
# Local (build-host/imola-fixes.sh): no /dev/ashmem on 6.18, so sys.use_memfd backs app shared memory with
# memfd (appdomain_tmpfs). Apps still issue ashmem ioctls on it; they fail with ENOTTY, so don't log them.
dontaudit appdomain appdomain_tmpfs:file ioctl;
dontauditxperm appdomain appdomain_tmpfs:file ioctl { 0x7700-0x77ff };
EOF
  echo "patched: $te"; }

# 3. OpenOCD (vendor blob, started at boot for sketch uploads) polls the STM32 over bit-banged SWD every 100 ms,
#    about 4% of a core forever. Uploads and `reset` poll explicitly, so turn background polling off.
ocd=vendor/arduino/imola/proprietary/vendor/bin/openocd-launcher
grep -q 'init; poll off' "$ocd" || { sed -i 's/-c "telnet_port 4444; gdb_port disabled; init"/-c "telnet_port 4444; gdb_port disabled; init; poll off"/' "$ocd" && echo "patched: $ocd (poll off)"; }

grep -q 'sys.use_memfd=true' "$mk" && [ -f "$te" ] && grep -q 'poll off' "$ocd" && echo "IMOLA FIXES OK"
