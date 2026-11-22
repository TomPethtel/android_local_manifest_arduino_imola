#!/bin/bash
# OPTIONAL debug variant: make the UNO Q's USB-C port dual role with adb on it when it is a device, instead of
# the port's fixed USB host role (device.mk: "TCP 5555 for network ADB; USB operates in host mode"). Pieces:
#   1. the dts overrides the SoC's dr_mode="otg" with "host"       -> back to "otg", so dwc3 registers its
#      usb-role-switch (it starts as a device). The ANX7625 driver switches it once it has Type-C support
#      (anx7625-typec.sh); until then the port stays a device.
#   2. vendor persist.sys.usb.config=none                          -> adb
#   3. nothing sets vendor.usb.controller, so init never binds the gadget to a UDC -> set it to the dwc3
#      core (usb@4e00000 in qcm2290.dtsi) at boot
#   4. the vendor usb rc's `on boot` ends with `setprop sys.usb.config none`, which runs AFTER init.usb.rc copied
#      persist.sys.usb.config into sys.usb.config and so overrides adb with none -> delete it (init.usb.rc already
#      applies persist.sys.usb.config). Earlier versions rewrote it to ${persist.sys.usb.config}, but vendor_init
#      may not read that property once SELinux enforces.
#   5. removes the logcat_kmsg mirror earlier versions added: once the board booted it only crash-looped
#      (logcat -f /dev/kmsg keeps exiting), restarting every minute and tripping flags_health_check
#   6. configfs gadgets bind only to a UDC that exists when init writes it (match_existing_only), and dwc3
#      has no UDC while the port is a host. Booted with a hub attached, the boot-time write fails and adb
#      never comes back on USB when the board is moved to a computer -> let the gadget wait for its UDC
#   7. r8152 (Realtek USB Ethernet, common in USB-C docks) is built as a module but not in the load list,
#      so a dock's Ethernet enumerates and nothing binds -> load it. r8152 then registers a wakeup source
#      under the dwc3 host that nothing labels, and system_suspend is denied reading its stats (10 denials)
#      -> label wakeup sources of USB devices on that host sysfs_wakeup
# Idempotent. Revert with `git checkout` in kernel/arduino/imola and device/arduino/imola.
set -euo pipefail
cd ~/lineage-24
dts=kernel/arduino/imola/arch/arm64/boot/dts/qcom/qrb2210-arduino-imola.dts
grep -q 'dr_mode = "otg"' "$dts" || { sed -i -E 's/dr_mode = "(host|peripheral)";.*$/dr_mode = "otg"; \/* Local: dual role, the ANX7625 picks host or device *\//' "$dts" && echo "patched: $dts"; }
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
cfs=kernel/arduino/imola/drivers/usb/gadget/configfs.c
grep -q '^	\.match_existing_only = 1,$' "$cfs" && { sed -i 's|^\t\.match_existing_only = 1,$|\t.match_existing_only = 0, /* Local: dual role, the UDC only exists in device mode; wait for it */|' "$cfs" && echo "patched: $cfs"; }
mods=device/arduino/imola/shared/utils/dlkm_loader/vendor.modules.list.mk
grep -q '^    r8152.ko' "$mods" || { sed -i 's/^    cdc_ncm.ko \\$/&\n    r8152.ko \\/' "$mods" && echo "patched: $mods (r8152)"; }
fc=device/arduino/imola/sepolicy/file_contexts
grep -q 'xhci-hcd' "$fc" || { printf '%s\n' '' '# Local (usb-adb-debug.sh): wakeup sources of USB devices on the dwc3 host, e.g. r8152 Ethernet' \
  '/sys/devices/platform/soc@0/4ef8800\.usb/4e00000\.usb/xhci-hcd\.[0-9]+\.auto/usb[0-9]+(/[0-9]+-[0-9.]+(:[0-9]+\.[0-9]+)?)*/wakeup(/.*)?	u:object_r:sysfs_wakeup:s0' >> "$fc" && echo "patched: $fc (USB wakeup sources)"; }
grep -n 'dr_mode' "$dts"; grep -n 'persist.sys.usb.config' "$mk"; sed -n 1,4p "$rc"; ! grep -nE '^    setprop sys.usb.config (none|\$)' "$rc"; ! grep -n 'logcat_kmsg' "$main"
grep -n 'match_existing_only = 0' "$cfs"; grep -n '^    r8152.ko' "$mods"; grep -n 'xhci-hcd' "$fc"
echo "USB ADB DEBUG OK"
