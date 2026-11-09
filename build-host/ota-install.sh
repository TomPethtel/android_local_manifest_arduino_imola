#!/usr/bin/env bash
# Install an A/B OTA zip (lineage_imola-ota.zip from `m-target.sh droid otapackage`) on a running board over
# adb root: push it to /data/ota_package and hand its payload to update_engine, as the Updater app would. The
# board keeps running on its current slot; reboot to switch. Needs Rooted debugging.
#
#   ota-install.sh <ota.zip> [adb serial]        (default imola0001)
set -euo pipefail
zip=${1:?usage: ota-install.sh <ota.zip> [adb serial]}
S=${2:-imola0001}
A=(adb -s "$S")

# payload.bin is stored uncompressed in the zip; update_engine reads it in place from its data offset.
read -r off size < <(python3 - "$zip" <<'EOF'
import sys, zipfile
z = zipfile.ZipFile(sys.argv[1])
i = z.getinfo('payload.bin')
assert i.compress_type == zipfile.ZIP_STORED, 'payload.bin is compressed'
with open(sys.argv[1], 'rb') as f:
    f.seek(i.header_offset)
    h = f.read(30)
name_len, extra_len = int.from_bytes(h[26:28], 'little'), int.from_bytes(h[28:30], 'little')
print(i.header_offset + 30 + name_len + extra_len, i.file_size)
EOF
)
headers=$(unzip -p "$zip" payload_properties.txt | tr -d '\r')

"${A[@]}" root >/dev/null 2>&1 || true
sleep 2
"${A[@]}" wait-for-device
"${A[@]}" push "$zip" /data/ota_package/update.zip
"${A[@]}" shell 'restorecon /data/ota_package/update.zip >/dev/null 2>&1; chmod 644 /data/ota_package/update.zip'
log=$("${A[@]}" shell "update_engine_client --update --follow --payload=file:///data/ota_package/update.zip \
  --offset=$off --size=$size --headers=\"$headers\" 2>&1" | tr '\r' '\n' || true)
grep -v -E 'DOWNLOADING|VERIFYING' <<<"$log" || true
"${A[@]}" shell rm -f /data/ota_package/update.zip
if grep -q 'onPayloadApplicationComplete(ErrorCode::kSuccess' <<<"$log"; then
  echo "Installed to the other slot. Reboot to switch: adb -s $S reboot"
else
  echo "Install did not finish; see: adb -s $S logcat -d -s update_engine" >&2
  exit 1
fi
