#!/bin/bash
# Print the A/B slot state ABL boots from: the attribute bits of the boot_a/boot_b GPT entries, read from both
# GPT copies of a running board over adb root. Read-only.
#   usage: slot-status.sh [adb serial]        (default imola0001)
# ABL lowers `retry` on each boot of a slot that is not `successful`, and at 0 marks it `unbootable` and stops in
# fastboot. With Qualcomm's boot control HAL (bootctrl-qti.sh) the slot is marked successful once boot completes.
set -euo pipefail
S=${1:-imola0001}
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
adb -s "$S" root >/dev/null
adb -s "$S" wait-for-device
sectors=$(adb -s "$S" shell cat /sys/block/mmcblk0/size | tr -d '\r')
adb -s "$S" exec-out 'dd if=/dev/block/mmcblk0 bs=512 count=34 2>/dev/null' > "$T/primary"
adb -s "$S" exec-out "dd if=/dev/block/mmcblk0 bs=512 skip=$((sectors - 33)) count=33 2>/dev/null" > "$T/backup"
echo "slot: $(adb -s "$S" shell getprop ro.boot.slot_suffix | tr -d '\r')"
python3 -I - "$T/primary" 0 "$T/backup" $((sectors - 33)) <<'EOF'
import struct, sys, zlib

def gpt(path, base_lba):
    buf = open(path, 'rb').read()
    hdr_lba = 1 if base_lba == 0 else base_lba + len(buf) // 512 - 1
    h = buf[(hdr_lba - base_lba) * 512:][:512]
    if h[:8] != b'EFI PART':
        sys.exit('%s: no GPT header at LBA %d' % (path, hdr_lba))
    hsize, hcrc = struct.unpack_from('<II', h, 12)
    ent_lba, n, esz, ecrc = struct.unpack_from('<QIII', h, 72)
    hh = bytearray(h[:hsize])
    hh[16:20] = bytes(4)
    ents = buf[(ent_lba - base_lba) * 512:][:n * esz]
    ok = zlib.crc32(bytes(hh)) == hcrc and zlib.crc32(ents) == ecrc
    parts = {}
    for i in range(n):
        e = ents[i * esz:(i + 1) * esz]
        if e[:16] != bytes(16):
            parts[e[56:128].decode('utf-16le').rstrip('\0')] = struct.unpack_from('<Q', e, 48)[0]
    return ok, parts

def bits(attr):
    b = attr >> 48 & 0xff
    return 'active=%d priority=%d retry=%d successful=%d unbootable=%d' % (
        b >> 2 & 1, b & 3, b >> 3 & 7, b >> 6 & 1, b >> 7 & 1)

pok, p = gpt(sys.argv[1], int(sys.argv[2]))
bok, b = gpt(sys.argv[3], int(sys.argv[4]))
print('GPT: primary %s, backup %s, attributes %s' % ('valid' if pok else 'BAD CRC', 'valid' if bok else 'BAD CRC',
      'identical' if p == b else 'DIFFER'))
for name in ('boot_a', 'boot_b'):
    print('%-7s %s' % (name, bits(p.get(name, 0))))
for slot in ('a', 'b'):
    ab = [k for k in p if k.endswith('_' + slot) and k[:-2] + ('_b' if slot == 'a' else '_a') in p and k != 'boot_' + slot]
    ok = [k for k in ab if p[k] >> 54 & 1]
    print('other _%s entries marked successful: %d/%d' % (slot, len(ok), len(ab)))
EOF
