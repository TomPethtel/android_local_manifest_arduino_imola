#!/bin/bash
# OPTIONAL debug variant: put the UNO Q's USB-C port in device mode with adb on it, instead of the port's
# normal USB host role (device.mk: "TCP 5555 for network ADB; USB operates in host mode"). Three pieces:
#   1. the dts overrides the SoC's dr_mode="otg" with "host"       -> "peripheral"
#   2. vendor persist.sys.usb.config=none                          -> adb
#   3. nothing sets vendor.usb.controller, so init never binds the gadget to a UDC -> set it to the dwc3
#      core (usb@4e00000 in qcm2290.dtsi) at boot
# Idempotent. Revert with `git checkout` in kernel/arduino/imola and device/arduino/imola.
set -euo pipefail
cd ~/lineage-24
dts=kernel/arduino/imola/arch/arm64/boot/dts/qcom/qrb2210-arduino-imola.dts
grep -q 'dr_mode = "peripheral"' "$dts" || { sed -i 's/dr_mode = "host";/dr_mode = "peripheral"; \/* Local: adb over USB for debugging *\//' "$dts" && echo "patched: $dts"; }
mk=device/arduino/imola/device.mk
grep -q 'persist.sys.usb.config=adb' "$mk" || { sed -i 's/persist.sys.usb.config=none \\/persist.sys.usb.config=adb \\/' "$mk" && echo "patched: $mk"; }
rc=device/arduino/imola/init.imola.usb.rc
grep -q 'vendor.usb.controller 4e00000.usb' "$rc" || { sed -i '0,/^    mount configfs none \/config$/s//    mount configfs none \/config\n    setprop vendor.usb.controller 4e00000.usb/' "$rc" && echo "patched: $rc"; }
grep -n 'dr_mode' "$dts"; grep -n 'persist.sys.usb.config' "$mk"; sed -n 1,4p "$rc"
echo "USB ADB DEBUG OK"
