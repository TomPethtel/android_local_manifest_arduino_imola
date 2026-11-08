#!/usr/bin/env bash
# Flash an imola EDL package (package-arm64.sh output, copied to the Mac) with qdl, never with
# arduino-flasher-cli (it rewrites the GPT and drops userdata; see README section 5).
#
#   qdl-flash.sh <arduino-images dir>              full flash: firmware, GPT, efi, rootfs; zeroes the heads of
#                                                  userdata and metadata, so Android formats them (settings,
#                                                  Developer options and Rooted debugging are lost)
#   qdl-flash.sh --keep-data <arduino-images dir>  efi (kernel, ramdisk, dtb) and rootfs (super) only; the
#                                                  GPT, firmware, userdata and metadata stay as they are.
#                                                  Use when the board already runs this package's layout.
#
# Board in EDL first: JCTL jumper across GND/USB_BOOT, then power-cycle (05c6:9008). Start this before
# replugging if qdl has hung on a board left in EDL (README). Remove the jumper and power-cycle after.
set -euo pipefail
keep=0
[ "${1:-}" = "--keep-data" ] && { keep=1; shift; }
dir=${1:?usage: qdl-flash.sh [--keep-data] <arduino-images dir>}
cd "$dir/flash"

if [ $keep = 0 ]; then
  exec qdl --storage emmc prog_firehose_ddr.elf rawprogram0.xml patch0.xml
fi

python3 - <<'EOF'
import xml.etree.ElementTree as ET
tree = ET.parse('rawprogram0.xml')
root = tree.getroot()
for e in list(root):
    if e.get('label') not in ('efi', 'rootfs'):
        root.remove(e)
assert sorted(e.get('label') for e in root) == ['efi', 'rootfs'], 'efi/rootfs entries not found'
tree.write('rawprogram0.keepdata.xml')
for e in root:
    print('will write', e.get('label'), '<-', e.get('filename'))
EOF
exec qdl --storage emmc prog_firehose_ddr.elf rawprogram0.keepdata.xml
