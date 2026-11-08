#!/bin/bash
# UNO Q Mods in the image: the STM32 sketch enumerates over Greybus (gb-unoq), the kernel binds the stock
# Greybus class drivers, and ModService (priv-app, system uid) exposes mods to apps. The project lives in a
# separate repo (unoq-mods); its aosp/sync-to-vm.sh puts what the build needs at vendor/unoq-mods.
#
#   1. gb-unoq into drivers/greybus (CONFIG_GREYBUS_UNOQ) and the staging Greybus class drivers into
#      imola_defconfig, all as modules
#   2. load them at boot (vendor_dlkm modules.load)
#   3. arduino-router and imola-bridge become disabled: vendor/unoq-mods' init rc starts either gb-unoq's
#      line discipline or the router on /dev/ttyHS1 (persist.vendor.unoq.mcu_mode, default greybus)
#   4. ueventd gives the Greybus device nodes to group system
#   5. the product inherits vendor/unoq-mods/aosp/product.mk; its sepolicy dir is added
# Idempotent. Revert with `git checkout` in kernel/arduino/imola and device/arduino/imola.
set -euo pipefail
cd ~/lineage-24
SRC=vendor/unoq-mods
[ -f $SRC/Android.bp ] || { echo "missing $SRC: run unoq-mods/aosp/sync-to-vm.sh on the Mac first" >&2; exit 1; }

K=kernel/arduino/imola
D=device/arduino/imola

# 1. Kernel driver and config.
install -m 644 $SRC/kernel/gb-unoq/gb-unoq.c $K/drivers/greybus/gb-unoq.c
grep -q 'config GREYBUS_UNOQ' $K/drivers/greybus/Kconfig || python3 - $K/drivers/greybus/Kconfig <<'EOF'
import sys
p = sys.argv[1]
s = open(p).read()
entry = '''config GREYBUS_UNOQ
	tristate "Greybus host for the Arduino UNO Q's STM32"
	depends on SERIAL_DEV_BUS && TTY
	select CRC_CCITT
	help
	  Select this option for the Arduino UNO Q, whose STM32 sketch speaks
	  HDLC-framed Greybus on the QRB2210's uart2. The SVC is emulated in the
	  driver, so the sketch only implements Control and its bundles.

	  To compile this code as a module, chose M here: the module
	  will be called gb-unoq.ko

'''
s = s.replace('config GREYBUS_ES2\n', entry + 'config GREYBUS_ES2\n', 1)
open(p, 'w').write(s)
print('patched: ' + p)
EOF
grep -q 'CONFIG_GREYBUS_UNOQ' $K/drivers/greybus/Makefile || {
  sed -i '/^obj-\$(CONFIG_GREYBUS_BEAGLEPLAY)/a obj-$(CONFIG_GREYBUS_UNOQ)	+= gb-unoq.o' $K/drivers/greybus/Makefile
  echo "patched: $K/drivers/greybus/Makefile"; }

defconfig=$K/arch/arm64/configs/imola_defconfig
# GREYBUS_LIGHT depends on LEDS_CLASS_FLASH, which imola_defconfig leaves off; without it olddefconfig
# silently drops gb-light and the module load list then names a module that was never built.
for c in LEDS_CLASS_FLASH GREYBUS_LOOPBACK GREYBUS_LOG GREYBUS_RAW GREYBUS_HID GREYBUS_POWER GREYBUS_LIGHT \
         GREYBUS_UART GREYBUS_SPI GREYBUS_PWM GREYBUS_I2C GREYBUS_GPIO GREYBUS_BRIDGED_PHY GREYBUS_UNOQ; do
  grep -q "^CONFIG_$c=" $defconfig || { sed -i "/^CONFIG_GREYBUS_BEAGLEPLAY=m/a CONFIG_$c=m" $defconfig; echo "patched: $defconfig ($c)"; }
done

# 2. Load at boot. modprobe pulls in greybus.ko and crc-ccitt.ko from modules.dep.
mods=$D/shared/utils/dlkm_loader/vendor.modules.list.mk
grep -q 'UNO Q Mods' $mods || { cat >> $mods <<'EOF'

# UNO Q Mods (build-host/unoq-mods.sh): Greybus host for the STM32 and the class drivers it binds
VENDOR_DLKM_KERNEL_MODULES_LIST += \
    greybus.ko \
    gb-unoq.ko \
    gb-gbphy.ko \
    gb-gpio.ko \
    gb-i2c.ko \
    gb-pwm.ko \
    gb-spilib.ko \
    gb-spi.ko \
    gb-uart.ko \
    gb-light.ko \
    gb-power-supply.ko \
    gb-hid.ko \
    gb-raw.ko \
    gb-log.ko \
    gb-loopback.ko
EOF
  echo "patched: $mods"; }

# 3. Only vendor/unoq-mods' rc starts the router now (imola-bridge follows the router via init.imola.rc).
rc=$D/init.imola.rc
python3 - $rc <<'EOF'
import re, sys
p = sys.argv[1]
s = open(p).read()
for svc in ('arduino-router', 'imola-bridge'):
    m = re.search(r'^service %s .*\n(?:    .*\n)*' % re.escape(svc), s, re.M)
    block = m.group(0)
    if '    disabled\n' not in block:
        s = s.replace(block, block.replace('    class main\n', '    class main\n    disabled\n', 1))
        print('patched: %s (%s disabled)' % (p, svc))
open(p, 'w').write(s)
EOF

# The device resets the MCU (dropping the loader's ready line, TLMM 70) whenever init.svc.arduino-router
# becomes "stopped". In greybus mode the router never runs, but unoq-mods.rc's `stop arduino-router` still
# sets that property, and the reset landed 2 s after unoq-greybus.sh had raised the line: the loader never
# started the sketch. Keep the reset for bridge mode only, where it is Arduino's behaviour.
python3 - $rc <<'EOF'
import sys
p = sys.argv[1]
s = open(p).read()
old = ('on property:init.svc.arduino-router=stopped\n'
       '    stop imola-bridge\n'
       '    exec_background - root system -- /vendor/bin/imola-gpio reset\n')
new = ('on property:init.svc.arduino-router=stopped\n'
       '    stop imola-bridge\n'
       '\n'
       '# Local (build-host/unoq-mods.sh): MCU reset only when bridge mode gives up the UART\n'
       'on property:init.svc.arduino-router=stopped && property:vendor.unoq.mcu_mode=bridge\n'
       '    exec_background - root system -- /vendor/bin/imola-gpio reset\n')
if old in s:
    s = s.replace(old, new)
    open(p, 'w').write(s)
    print('patched: %s (MCU reset in bridge mode only)' % p)
elif new not in s:
    sys.exit('init.imola.rc: router-stopped trigger not found')
EOF

# 4. Device nodes for ModService.
ue=$D/ueventd.imola.rc
grep -q 'UNO Q Mods' $ue || { cat $SRC/aosp/ueventd.unoq-mods.rc >> $ue; echo "patched: $ue"; }

# 5. Product and sepolicy.
grep -q 'vendor/unoq-mods/aosp/product.mk' $D/device.mk || {
  printf '\n# UNO Q Mods (build-host/unoq-mods.sh)\n$(call inherit-product, vendor/unoq-mods/aosp/product.mk)\n' >> $D/device.mk
  echo "patched: $D/device.mk"; }
# Mods policy: vendor (unoq_mods, Greybus sysfs labels) and system_ext (sysfs_greybus, ModService).
sed -i 's#^BOARD_SEPOLICY_DIRS += vendor/unoq-mods/aosp/sepolicy$#BOARD_SEPOLICY_DIRS += vendor/unoq-mods/aosp/sepolicy/vendor#' $D/BoardConfig.mk
grep -q 'vendor/unoq-mods/aosp/sepolicy/vendor' $D/BoardConfig.mk || {
  printf '\n# UNO Q Mods (build-host/unoq-mods.sh)\nBOARD_SEPOLICY_DIRS += vendor/unoq-mods/aosp/sepolicy/vendor\n' >> $D/BoardConfig.mk
  echo "patched: $D/BoardConfig.mk"; }
grep -q 'vendor/unoq-mods/aosp/sepolicy/system_ext_public' $D/BoardConfig.mk || {
  printf 'SYSTEM_EXT_PUBLIC_SEPOLICY_DIRS += vendor/unoq-mods/aosp/sepolicy/system_ext_public\nSYSTEM_EXT_PRIVATE_SEPOLICY_DIRS += vendor/unoq-mods/aosp/sepolicy/system_ext_private\n' >> $D/BoardConfig.mk
  echo "patched: $D/BoardConfig.mk (unoq-mods system_ext sepolicy)"; }

# Check.
grep -n 'GREYBUS_UNOQ' $K/drivers/greybus/Kconfig $K/drivers/greybus/Makefile
grep -c '^CONFIG_GREYBUS' $defconfig
grep -A3 -E '^service (arduino-router|imola-bridge) ' $rc | grep -E 'service|disabled'
grep -n 'arduino-router=stopped' $rc
grep -n 'gpiochip' $ue
grep -n 'unoq-mods' $D/device.mk $D/BoardConfig.mk
echo "UNOQ MODS OK"
