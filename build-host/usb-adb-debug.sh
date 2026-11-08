#!/bin/bash
# OPTIONAL debug variant: put the UNO Q's USB-C port in device mode with adb on it, instead of the port's
# normal USB host role (device.mk: "TCP 5555 for network ADB; USB operates in host mode"). Three pieces:
#   1. the dts overrides the SoC's dr_mode="otg" with "host"       -> "peripheral"
#   2. vendor persist.sys.usb.config=none                          -> adb
#   3. nothing sets vendor.usb.controller, so init never binds the gadget to a UDC -> set it to the dwc3
#      core (usb@4e00000 in qcm2290.dtsi) at boot
#   4. the vendor usb rc's `on boot` ends with `setprop sys.usb.config none`, which runs AFTER init.usb.rc copied
#      persist.sys.usb.config into sys.usb.config and so overrides adb with none -> delete it (init.usb.rc already
#      applies persist.sys.usb.config). Earlier versions rewrote it to ${persist.sys.usb.config}, but vendor_init
#      may not read that property once SELinux enforces.
#   5. removes the logcat_kmsg mirror earlier versions added: once the board booted it only crash-looped
#      (logcat -f /dev/kmsg keeps exiting), restarting every minute and tripping flags_health_check
# Idempotent. Revert with `git checkout` in kernel/arduino/imola and device/arduino/imola.
set -euo pipefail
cd ~/lineage-24
dts=kernel/arduino/imola/arch/arm64/boot/dts/qcom/qrb2210-arduino-imola.dts
grep -q 'dr_mode = "peripheral"' "$dts" || { sed -i 's/dr_mode = "host";/dr_mode = "peripheral"; \/* Local: adb over USB for debugging *\//' "$dts" && echo "patched: $dts"; }
mk=device/arduino/imola/device.mk
grep -q 'persist.sys.usb.config=adb' "$mk" || { sed -i 's/persist.sys.usb.config=none \\/persist.sys.usb.config=adb \\/' "$mk" && echo "patched: $mk"; }
rc=device/arduino/imola/init.imola.usb.rc
grep -q 'vendor.usb.controller 4e00000.usb' "$rc" || { sed -i '0,/^    mount configfs none \/config$/s//    mount configfs none \/config\n    setprop vendor.usb.controller 4e00000.usb/' "$rc" && echo "patched: $rc"; }
grep -qE '^    setprop sys.usb.config (none|\$\{persist.sys.usb.config\})$' "$rc" && { sed -i -E '/^    setprop sys.usb.config (none|\$\{persist.sys.usb.config\})$/d' "$rc" && echo "patched: $rc (vendor sys.usb.config override removed)"; }
main=device/arduino/imola/init.imola.rc
python3 - "$main" <<'EOF'
import re, sys
p = sys.argv[1]
s = open(p).read()
n = re.sub(r'\n# Local debug: mirror logcat errors into dmesg so they reach the serial console\nservice logcat_kmsg .*?\n\non post-fs-data\n    start logcat_kmsg\n', '\n', s, flags=re.S)
if n != s:
    open(p, 'w').write(n)
    print('patched: %s (removed logcat_kmsg)' % p)
EOF
grep -n 'dr_mode' "$dts"; grep -n 'persist.sys.usb.config' "$mk"; sed -n 1,4p "$rc"; ! grep -nE '^    setprop sys.usb.config (none|\$)' "$rc"; ! grep -n 'logcat_kmsg' "$main"
echo "USB ADB DEBUG OK"
