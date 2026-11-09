#!/bin/bash
# Annex in the image: on the Arduino UNO Q, the STM32 sketch enumerates over Greybus (gb-unoq), the kernel
# binds the stock Greybus class drivers, and ModService (priv-app, system uid) exposes mods to apps. The
# project lives in a separate repo (Annex); its aosp/sync-to-vm.sh puts what the build needs at vendor/annex.
#
#   0. a tree wired in by this script's earlier version (unoq-mods.sh, vendor/unoq-mods) is renamed in
#      place
#   1. gb-unoq into drivers/greybus (CONFIG_GREYBUS_UNOQ) and the staging Greybus class drivers into
#      imola_defconfig, all as modules
#   2. load them at boot (vendor_dlkm modules.load)
#   3. arduino-router and imola-bridge become disabled: vendor/annex's init rc starts either gb-unoq's
#      line discipline or the router on /dev/ttyHS1 (persist.vendor.unoq.mcu_mode, default greybus)
#   4. ueventd gives the Greybus device nodes to group system
#   5. the product inherits vendor/annex/aosp/product.mk; its sepolicy dirs are added
# Idempotent. Revert with `git checkout` in kernel/arduino/imola and device/arduino/imola.
set -euo pipefail
cd ~/lineage-24
SRC=vendor/annex
[ -f $SRC/Android.bp ] || { echo "missing $SRC: run the Annex repo's aosp/sync-to-vm.sh on the Mac first" >&2; exit 1; }

K=kernel/arduino/imola
D=device/arduino/imola

# 0. The old name. Arduino's trademark policy keeps its marks out of third-party product names, so the
#    project is Annex now; rename what earlier versions of this script wrote.
python3 - $D/device.mk $D/BoardConfig.mk $D/shared/utils/dlkm_loader/vendor.modules.list.mk $D/ueventd.imola.rc <<'EOF'
import sys
for p in sys.argv[1:]:
    s = open(p).read()
    n = (s.replace('vendor/unoq-mods/', 'vendor/annex/')
          .replace('# UNO Q Mods (build-host/unoq-mods.sh)', '# Annex (build-host/annex.sh)')
          .replace('# UNO Q Mods: Greybus device nodes', '# Annex: Greybus device nodes'))
    if n != s:
        open(p, 'w').write(n)
        print('patched: %s (renamed to Annex)' % p)
EOF

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
grep -q 'Annex (build-host/annex.sh)' $mods || { cat >> $mods <<'EOF'

# Annex (build-host/annex.sh): Greybus host for the STM32 and the class drivers it binds
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

# 3. Only vendor/annex's rc starts the router now (imola-bridge follows the router via init.imola.rc).
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

# The device starts imola-bridge and resets the MCU from `on property:init.svc.arduino-router=...` triggers.
# vendor_init may not read init.svc.* once SELinux enforces (init drops such vendor triggers), and in greybus
# mode the reset dropped the loader's ready line under gb-unoq. vendor/annex's rc does both jobs in its
# mode switch instead, so remove the triggers (including the bridge-only form earlier versions left).
python3 - $rc <<'EOF'
import re, sys
p = sys.argv[1]
s = open(p).read()
n = re.sub(r'\n# Local \(build-host/unoq-mods\.sh\): MCU reset only when bridge mode gives up the UART\n', '\n', s)
n = re.sub(r'\non property:init\.svc\.arduino-router=[^\n]*\n(?:    [^\n]*\n)*', '\n', n)
n = re.sub(r'\n{3,}', '\n\n', n)
if n != s:
    open(p, 'w').write(n)
    print('patched: %s (init.svc.arduino-router triggers removed)' % p)
EOF

# 4. Device nodes for ModService.
ue=$D/ueventd.imola.rc
grep -q '# Annex: Greybus device nodes' $ue || { cat $SRC/aosp/ueventd.annex.rc >> $ue; echo "patched: $ue"; }

# 5. Product and sepolicy.
grep -q 'vendor/annex/aosp/product.mk' $D/device.mk || {
  printf '\n# Annex (build-host/annex.sh)\n$(call inherit-product, vendor/annex/aosp/product.mk)\n' >> $D/device.mk
  echo "patched: $D/device.mk"; }
# Annex policy: vendor (unoq_mods, Greybus sysfs labels) and system_ext (sysfs_greybus, ModService).
sed -i 's#^BOARD_SEPOLICY_DIRS += vendor/annex/aosp/sepolicy$#BOARD_SEPOLICY_DIRS += vendor/annex/aosp/sepolicy/vendor#' $D/BoardConfig.mk
grep -q 'vendor/annex/aosp/sepolicy/vendor' $D/BoardConfig.mk || {
  printf '\n# Annex (build-host/annex.sh)\nBOARD_SEPOLICY_DIRS += vendor/annex/aosp/sepolicy/vendor\n' >> $D/BoardConfig.mk
  echo "patched: $D/BoardConfig.mk"; }
grep -q 'vendor/annex/aosp/sepolicy/system_ext_public' $D/BoardConfig.mk || {
  printf 'SYSTEM_EXT_PUBLIC_SEPOLICY_DIRS += vendor/annex/aosp/sepolicy/system_ext_public\nSYSTEM_EXT_PRIVATE_SEPOLICY_DIRS += vendor/annex/aosp/sepolicy/system_ext_private\n' >> $D/BoardConfig.mk
  echo "patched: $D/BoardConfig.mk (Annex system_ext sepolicy)"; }

# Check.
grep -n 'GREYBUS_UNOQ' $K/drivers/greybus/Kconfig $K/drivers/greybus/Makefile
grep -c '^CONFIG_GREYBUS' $defconfig
grep -A3 -E '^service (arduino-router|imola-bridge) ' $rc | grep -E 'service|disabled'
! grep -n 'init.svc.arduino-router' $rc
grep -n 'gpiochip' $ue
grep -n 'vendor/annex' $D/device.mk $D/BoardConfig.mk
! grep -n -E 'unoq-mods|UNO Q Mods' $D/device.mk $D/BoardConfig.mk $mods $ue
echo "ANNEX OK"
