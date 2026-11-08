#!/bin/bash
# SELinux for the UNO Q port, so it can run enforcing. Everything here was found running permissive (the
# board boots with androidboot.selinux=permissive) and is applied on top of the YAJATapps device tree:
#
#   1. policy in build-host/sepolicy/ (vendor, system_ext public, system_ext private) copied into
#      device/arduino/imola/sepolicy-local/ and registered in BoardConfig.mk
#   2. gpio_chip_device moves from the device's vendor policy to system_ext public (sepolicy/system_ext/public),
#      so system-side ModService can be granted it under Treble
#   3. platform properties that the vendor build.prop sets (vendor_init may not) move to the product
#      build.prop: the ADB and timezone blocks of device.mk and mesa's persist.demo.rotationlock.
#      sys.use_memfd is handled by imola-fixes.sh.
#   4. sketch uploads stage in /data/vendor/openocd (init.imola.rc creates it): OpenOCD may not read /data/local/tmp
#      under enforcing (shell.te neverallow)
#
# Run from a copy of build-host/ in the VM (needs the sepolicy/ directory next to this script). Idempotent.
# Revert with `git checkout` in device/arduino/imola and removing device/arduino/imola/sepolicy-local.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
cd ~/lineage-24
D=device/arduino/imola
L=$D/sepolicy-local

# 1. Policy files.
rm -rf $L
mkdir -p $L
cp -r "$HERE/sepolicy/vendor" $L/vendor
cp -r "$HERE/sepolicy/system_ext/public" $L/system_ext_public
cp -r "$HERE/sepolicy/system_ext/private" $L/system_ext_private
grep -q 'sepolicy-local/vendor' $D/BoardConfig.mk || {
  cat >> $D/BoardConfig.mk <<'EOF'

# SELinux fixes for enforcing (build-host/selinux-fixes.sh)
BOARD_SEPOLICY_DIRS += $(DEVICE_PATH)/sepolicy-local/vendor
SYSTEM_EXT_PUBLIC_SEPOLICY_DIRS += $(DEVICE_PATH)/sepolicy-local/system_ext_public
SYSTEM_EXT_PRIVATE_SEPOLICY_DIRS += $(DEVICE_PATH)/sepolicy-local/system_ext_private
EOF
  echo "patched: $D/BoardConfig.mk (sepolicy-local)"; }

# 2. gpio_chip_device now comes from system_ext public policy.
grep -q '^type gpio_chip_device, dev_type;' $D/sepolicy/file.te && {
  sed -i 's/^type gpio_chip_device, dev_type;/# gpio_chip_device: system_ext public policy (build-host\/selinux-fixes.sh)/' $D/sepolicy/file.te
  echo "patched: $D/sepolicy/file.te (gpio_chip_device moved)"; }

# 3. Platform props out of the vendor build.prop.
python3 - $D/device.mk $D/shared/graphics/mesa/device.mk <<'EOF'
import sys
dev, mesa = sys.argv[1], sys.argv[2]

s = open(dev).read()
n = s
for header in ('# ADB configuration', '# Default timezone and locale'):
    i = n.find(header)
    if i < 0:
        continue
    j = n.find('PRODUCT_PROPERTY_OVERRIDES +=', i)
    if j >= 0 and n[i:j].count('\n') <= 1:
        n = n[:j] + 'PRODUCT_PRODUCT_PROPERTIES +=' + n[j + len('PRODUCT_PROPERTY_OVERRIDES +='):]
if n != s:
    open(dev, 'w').write(n)
    print('patched: %s (ADB and timezone props to the product build.prop)' % dev)

s = open(mesa).read()
old = '    ro.opengles.version=196609 \\\n    persist.demo.rotationlock=1\n'
new = ('    ro.opengles.version=196609\n\n'
       '# Local (build-host/selinux-fixes.sh): a platform prop, so the product build.prop sets it\n'
       'PRODUCT_PRODUCT_PROPERTIES += \\\n    persist.demo.rotationlock=1\n')
if old in s:
    open(mesa, 'w').write(s.replace(old, new))
    print('patched: %s (persist.demo.rotationlock to product)' % mesa)
EOF

# 4. Staging directory for sketch uploads.
grep -q '/data/vendor/openocd' $D/init.imola.rc || {
  printf '\n# Local (build-host/selinux-fixes.sh): sketch uploads; adb root pushes images here, OpenOCD flashes them\non post-fs-data\n    mkdir /data/vendor/openocd 0770 root system\n' >> $D/init.imola.rc
  echo "patched: $D/init.imola.rc (/data/vendor/openocd)"; }

ls $L/*
grep -n 'sepolicy-local' $D/BoardConfig.mk
grep -n 'gpio_chip_device' $D/sepolicy/file.te
grep -n -B1 'persist.sys.usb.config\|persist.sys.timezone=' $D/device.mk | grep PRODUCT_
grep -n -A1 'PRODUCT_PRODUCT_PROPERTIES' $D/shared/graphics/mesa/device.mk
echo "SELINUX FIXES OK"
