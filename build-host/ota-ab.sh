#!/bin/bash
# A/B OTA for the UNO Q port. The board already had A/B dynamic partitions (Virtual A/B) and, since
# bootctrl-qti.sh, a boot HAL that ABL listens to, but an OTA could not have worked:
#
#   - The kernel, ramdisk and dtb lived as files in the single, unslotted efi FAT partition, and U-Boot's
#     boot.scr hard-coded androidboot.slot_suffix=_a. A slot switch would have kept booting the old kernel
#     against _a's system. Now each slot has its own partition, linux_a and linux_b, holding the build's
#     boot.img (kernel, ramdisk, dtb and BOARD_KERNEL_CMDLINE).
#   - U-Boot had no way to know the slot: ABL passes no androidboot.slot_suffix. ABL does pass the header
#     command line of the boot image it starts, so boot_a and boot_b now hold copies of U-Boot whose header
#     says uboot.slot=_a or _b. efi shrinks to 128 MB and holds only boot.scr, which reads that token, loads
#     linux_<slot> and bootm's it with androidboot.slot_suffix=<slot> in front of the image's command line.
#   - Virtual A/B (libsnapshot) CHECKs that the dynamic partitions live in a partition named super; this port
#     kept Arduino's name, rootfs, and update_engine aborted at the start of every update. The partition is
#     renamed super (same place, so data survives).
#
# Changes (all in device/arduino/imola):
#   1. BoardConfig.mk: no hard-coded slot in BOARD_KERNEL_CMDLINE; BOARD_SUPER_PARTITION_METADATA_DEVICE
#      super instead of rootfs; sepolicy-ota
#   2. policy in build-host/sepolicy/ota/ copied to sepolicy-ota/: linux_a/linux_b are boot_block_device
#      (update_engine may write them), super is super_block_device
#   3. tools/package_qdl.py (package-qdl-ab.patch, on top of selinux-fixes.sh): GPT with efi 128 MB +
#      linux_a/linux_b 192 MB each in the old efi space and rootfs renamed super (metadata, super and userdata
#      do not move), per-slot U-Boot copies, the slot-picking boot.scr, linux.img for both slots
#
# The new GPT needs one qdl flash (qdl-flash.sh --keep-data writes the GPT,
# boot_a/b, efi, linux_a/b and super; userdata survives because it does not move). Run after selinux-fixes.sh
# and bootctrl-qti.sh, from a copy of build-host/ in the VM. Idempotent. Revert with `git checkout` of the
# files above in device/arduino/imola (then re-run the scripts that edit them) and removing
# device/arduino/imola/sepolicy-ota.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
cd ~/lineage-24
D=device/arduino/imola

# 1. BoardConfig.mk
python3 - $D/BoardConfig.mk <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
n = s.replace('BOARD_KERNEL_CMDLINE += androidboot.slot_suffix=_a\n', '')
n = n.replace('BOARD_SUPER_PARTITION_METADATA_DEVICE := rootfs\n',
              '# Local (build-host/ota-ab.sh): Virtual A/B requires the name super (Arduino\'s layout says rootfs)\n'
              'BOARD_SUPER_PARTITION_METADATA_DEVICE := super\n')
if 'sepolicy-ota' not in n:
    n += ('\n# A/B OTA (build-host/ota-ab.sh): block-device labels for linux_a/linux_b and super\n'
          'BOARD_SEPOLICY_DIRS += $(DEVICE_PATH)/sepolicy-ota\n')
for need in ('BOARD_SUPER_PARTITION_METADATA_DEVICE := super', 'sepolicy-ota'):
    if need not in n:
        sys.exit('BoardConfig.mk: could not apply ' + need)
if n != s:
    open(p, 'w').write(n)
    print('patched: %s (slot-free cmdline, super, sepolicy-ota)' % p)
PY

# 2. Policy.
rm -rf $D/sepolicy-ota
cp -r "$HERE/sepolicy/ota" $D/sepolicy-ota

# 3. Packager.
if git -C $D apply --reverse --check "$HERE/package-qdl-ab.patch" 2>/dev/null; then :
else git -C $D apply "$HERE/package-qdl-ab.patch" && echo "patched: $D/tools/package_qdl.py (A/B layout)"; fi

grep -n -E 'slot_suffix|SUPER_PARTITION_METADATA_DEVICE|sepolicy-ota' $D/BoardConfig.mk
! grep -n -E 'androidboot.slot_suffix=_a|METADATA_DEVICE := rootfs' $D/BoardConfig.mk
ls $D/sepolicy-ota
git -C $D apply --reverse --check "$HERE/package-qdl-ab.patch"
echo "OTA AB OK"
