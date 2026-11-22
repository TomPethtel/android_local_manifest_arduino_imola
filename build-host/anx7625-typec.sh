#!/bin/bash
# Type-C support for the ANX7625 on the UNO Q, so its USB-C port picks its own role the way a handset does:
# a device (adb) when plugged into a computer, a host when a hub or accessory is plugged in. The ANX7625's PD
# firmware negotiates the role; the patched driver passes it to dwc3's usb-role-switch. Needs the dts at
# dr_mode = "otg" (usb-adb-debug.sh). Details in anx7625-typec.patch and README section 11.
# Idempotent. Revert with `git checkout -- drivers/gpu/drm/bridge/analogix` in kernel/arduino/imola.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
K=~/lineage-24/kernel/arduino/imola
git -C $K apply --reverse --check "$here/anx7625-typec.patch" 2>/dev/null ||
  { git -C $K apply "$here/anx7625-typec.patch"; echo "patched: $K (anx7625-typec.patch)"; }
grep -q 'depends on USB_ROLE_SWITCH' $K/drivers/gpu/drm/bridge/analogix/Kconfig
grep -q 'dr_mode = "otg"' $K/arch/arm64/boot/dts/qcom/qrb2210-arduino-imola.dts ||
  echo "WARNING: dts is not dr_mode = \"otg\"; run usb-adb-debug.sh or the ANX7625 probe will defer" >&2
echo "ANX7625 TYPE-C OK"
