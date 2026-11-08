#!/bin/bash
# Qualcomm's boot control HAL for the UNO Q, so that a successful boot is recorded where ABL looks.
#
# ABL picks the slot from the GPT attribute bits of the boot_a/boot_b entries (priority, active, retry count,
# successful, unbootable). On every boot of a slot not yet marked successful it lowers the retry count, and at
# zero it marks the slot unbootable and parks in fastboot. The port shipped AOSP's default boot HAL
# (com.android.hardware.boot), which records success only in misc, so ABL never saw it: after `fastboot
# set_active a` the board booted seven times and then sat in fastboot looking dead.
# hardware/qcom-caf/bootctrl (already in the tree) writes those bits on both GPT copies. On this Android vold
# calls markBootSuccessful from cp_commitChanges once boot completes (update_verifier no longer runs), and a
# failure there makes ActivityManager reboot ("Checkpoint commit failed"), so the HAL has to work under
# enforcing from the first boot:
#
#   1. device.mk: android.hardware.boot-service.qti (+ .recovery) replace com.android.hardware.boot and
#      android.hardware.boot-service.default_recovery; hardware/qcom-caf/bootctrl joins PRODUCT_SOONG_NAMESPACES
#      (its Android.bp is a soong_namespace)
#   2. policy in build-host/sepolicy/bootctrl/ copied into device/arduino/imola/sepolicy-bootctrl/ and
#      registered in BoardConfig.mk: the binary's exec label, /dev/block/mmcblk0 as root_block_device (Qualcomm's
#      label for the eMMC whole-disk node), rw on it, getattr on the A/B partition nodes
#
# Nothing else is needed on the QCM2290: ro.boot.bootdevice is unset, so gpt-utils takes its eMMC path and
# edits /dev/block/mmcblk0; /dev/block/bootdevice/by-name exists (two boot_* entries = two slots); and the
# Arduino GPT carries _a/_b copies of xbl, abl, tz, rpm, hyp, boot and the rest of the HAL's list. Leave
# ro.vendor.bootctrl.enable unset: "true" switches the HAL to its misc-only GVM mode, the same problem again.
#
# Run from a copy of build-host/ in the VM (needs sepolicy/bootctrl next to this script). Idempotent.
# Revert with `git checkout device.mk BoardConfig.mk` in device/arduino/imola (after re-running the other
# scripts that edit them) and removing device/arduino/imola/sepolicy-bootctrl.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
cd ~/lineage-24
D=device/arduino/imola
test -f hardware/qcom-caf/bootctrl/aidl/Android.bp || { echo "hardware/qcom-caf/bootctrl is missing"; exit 1; }

# 1. Packages and namespace.
python3 - $D/device.mk <<'EOF'
import sys
mk = sys.argv[1]
s = open(mk).read()
n = s
n = n.replace('    com.android.hardware.boot \\\n', '    android.hardware.boot-service.qti \\\n')
n = n.replace('    android.hardware.boot-service.default_recovery \\\n',
              '    android.hardware.boot-service.qti.recovery \\\n')
anchor = '# BootControl HAL & VINTF\n'
ns = ('# Local (build-host/bootctrl-qti.sh): Qualcomm boot control HAL, which keeps the slot state in the GPT\n'
      '# attributes ABL reads\n'
      'PRODUCT_SOONG_NAMESPACES += hardware/qcom-caf/bootctrl\n\n')
if ns not in n:
    if anchor not in n:
        sys.exit('device.mk: no "%s" block' % anchor.strip())
    n = n.replace(anchor, ns + anchor)
if n != s:
    open(mk, 'w').write(n)
    print('patched: %s (qti boot control HAL)' % mk)
EOF

# 2. Policy.
rm -rf $D/sepolicy-bootctrl
cp -r "$HERE/sepolicy/bootctrl" $D/sepolicy-bootctrl
grep -q 'sepolicy-bootctrl' $D/BoardConfig.mk || {
  printf '\n# Qualcomm boot control HAL (build-host/bootctrl-qti.sh)\nBOARD_SEPOLICY_DIRS += $(DEVICE_PATH)/sepolicy-bootctrl\n' >> $D/BoardConfig.mk
  echo "patched: $D/BoardConfig.mk (sepolicy-bootctrl)"; }

grep -n -A4 'qcom-caf/bootctrl' $D/device.mk
if grep -qE 'com\.android\.hardware\.boot( |$)|boot-service\.default' $D/device.mk; then
  echo "device.mk still names the default boot HAL"; exit 1
fi
ls $D/sepolicy-bootctrl
grep -n 'sepolicy-bootctrl' $D/BoardConfig.mk
echo "BOOTCTRL QTI OK"
