#!/usr/bin/env bash
# List the SELinux denials a running board has logged since boot, grouped by source domain, target type and
# class, with the permissions and one sample path/name each. Run on the Mac with the board on adb.
#
#   selinux-audit.sh [serial]             denials so far (board stays as it is)
#   selinux-audit.sh --enforce [serial]   run a smoke test of the main features enforcing (switching to enforcing
#                                         first if the board booted permissive, and back afterwards), then report
#                                         what was denied
#
# Needs adb root (Rooted debugging). The smoke test opens Settings, the browser and Annex Demo, toggles an Annex
# Demo LED, and lists Greybus devices; add to it as features are covered.
set -uo pipefail
enforce=0
[ "${1:-}" = "--enforce" ] && { enforce=1; shift; }
S=${1:-imola0001}
A=(adb -s "$S")

"${A[@]}" root >/dev/null 2>&1; sleep 2; "${A[@]}" wait-for-device
[ "$("${A[@]}" shell id -u | tr -d '\r')" = 0 ] || { echo "adb is not root" >&2; exit 1; }

if [ $enforce = 1 ]; then
  was=$("${A[@]}" shell getenforce | tr -d '\r')
  "${A[@]}" shell 'dmesg -c >/dev/null; setenforce 1; getenforce'
  "${A[@]}" shell '
    am start -W -a android.settings.SETTINGS >/dev/null 2>&1; sleep 3
    am start -W -n org.lineageos.jelly/.MainActivity >/dev/null 2>&1; sleep 8
    am start -W -n com.trustlumina.annex.sample/.MainActivity >/dev/null 2>&1; sleep 4
    input tap 230 254; sleep 2; input tap 500 254; sleep 2
    ls /sys/bus/greybus/devices/ >/dev/null; input keyevent KEYCODE_HOME; sleep 2
  '
  [ "$was" = Permissive ] && "${A[@]}" shell 'setenforce 0'
  "${A[@]}" shell getenforce
fi

"${A[@]}" shell 'dmesg' | tr -d '\r' | grep -o 'avc:  denied.*' | python3 -c '
import re, sys, collections
groups = collections.OrderedDict()
for line in sys.stdin:
    m = re.search(r"\{ ([^}]*) \}.*scontext=u:r:([a-z0-9_]+):s0\S*.*tcontext=u:(?:object_r|r):([a-z0-9_]+):s0\S* tclass=(\S+)", line)
    if not m:
        continue
    perms, src, tgt, cls = m.groups()
    where = re.search(r"(?:path|name|property)=(\"[^\"]*\"|\S+)", line)
    key = (src, tgt, cls)
    g = groups.setdefault(key, [set(), where.group(1) if where else ""])
    g[0].update(perms.split())
if not groups:
    print("no denials")
for (src, tgt, cls), (perms, where) in sorted(groups.items()):
    print("%-30s %-34s %-16s { %s }  %s" % (src, tgt, cls, " ".join(sorted(perms)), where[:90]))
'
