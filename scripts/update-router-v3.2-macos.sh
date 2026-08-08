#!/bin/bash
set -euo pipefail

ROUTER="${ROUTER:-192.168.50.1}"
RUSER="${RUSER:-Eabusham2}"
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/dynbq-controller.sh"
SOCK="/tmp/dynbq-v32-update-ssh-$$"

cleanup() {
  ssh -S "$SOCK" -O exit "$RUSER@$ROUTER" >/dev/null 2>&1 || true
  rm -f "$SOCK"
}
trap cleanup EXIT

[ -s "$SRC" ] || { echo "ERROR: $SRC missing"; exit 2; }
sh -n "$SRC"

ssh -M -S "$SOCK" -o ControlPersist=120 -fnNT "$RUSER@$ROUTER"
scp -o ControlPath="$SOCK" "$SRC" "$RUSER@$ROUTER:/tmp/dynbq-controller.v32.new" >/dev/null

ssh -S "$SOCK" "$RUSER@$ROUTER" 'sh -s' <<'ROUTER_SH'
set -eu

C=/jffs/dynbq/dynbq-controller.sh
N=/tmp/dynbq-controller.v32.new
B=/tmp/dynbq-controller.pre-v32

healthy_runner()
{
    for R in 1 2; do
        L="$(dhd -i "wl$R" dump 2>/dev/null | grep 'dol_cap Hlp:' | tail -1)"
        echo "wl$R: $L"
        echo "$L" | grep -q 'txoffl:1' || return 1
        echo "$L" | grep -q 'rxoffl:1' || return 1
        echo "$L" | grep -q 'bkupq:1' || return 1
        echo "$L" | grep -q 'hbqd:1' || return 1
        echo "$L" | grep -q 'dynbkupq:1' || return 1
        echo "$L" | grep -q 'codel:0' || return 1
        echo "$L" | grep -q 'ba256cfg:1' || return 1
    done
}

count_run()
{
    NPROC=0
    for D in /proc/[0-9]*; do
        [ -r "$D/cmdline" ] || continue
        CMD="$(tr '\000' ' ' <"$D/cmdline" 2>/dev/null || true)"
        case "$CMD" in
            *"/jffs/dynbq/dynbq-controller.sh run"*) NPROC=$((NPROC+1)) ;;
        esac
    done
    echo "$NPROC"
}

echo "=== PRECHECK RUNNER ==="
healthy_runner || { echo "ERROR: Runner baseline unhealthy; refusing update"; exit 10; }

busybox ash -n "$N" || { echo "ERROR: new controller failed BusyBox ash syntax"; exit 11; }

grep -q '^VERSION=3.2.0$' "$N" || { echo "ERROR: V3.2 controller missing"; exit 12; }
grep -q '^LOW_IDLE_PPS=1000$' "$N" || { echo "ERROR: V3.2 low-idle policy missing"; exit 13; }
grep -q '^HIGH_POST_PPS=30000$' "$N" || { echo "ERROR: V3.2 high-entry policy missing"; exit 14; }
grep -q '^HIGH_HOLD_PPS=20000$' "$N" || { echo "ERROR: V3.2 high-hold policy missing"; exit 15; }

cp -p "$C" "$B"

"$C" stop >/dev/null 2>&1 || true
cp "$N" "$C"
chmod 755 "$C"
rm -f "$N"

if ! "$C" start; then
    echo "ERROR: V3.2 failed to start; rolling controller back"
    cp "$B" "$C"
    chmod 755 "$C"
    "$C" start >/dev/null 2>&1 || true
    exit 20
fi

sleep 4

NPROC="$(count_run)"
if [ "$NPROC" -ne 1 ] || [ ! -e /proc/dynbq ]; then
    echo "ERROR: V3.2 runtime health failed; rolling controller back"
    "$C" stop >/dev/null 2>&1 || true
    cp "$B" "$C"
    chmod 755 "$C"
    "$C" start >/dev/null 2>&1 || true
    exit 21
fi

echo
echo "=== POSTCHECK RUNNER ==="
healthy_runner || {
    echo "ERROR: Runner changed unexpectedly; rolling controller back"
    "$C" stop >/dev/null 2>&1 || true
    cp "$B" "$C"
    chmod 755 "$C"
    "$C" start >/dev/null 2>&1 || true
    exit 22
}

rm -f "$B"

echo
echo "=== PERSISTENT FILES ==="
find /jffs/dynbq -maxdepth 1 -type f -printf '%f\n' 2>/dev/null | sort
COUNT="$(find /jffs/dynbq -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')"
[ "$COUNT" -eq 2 ] || { echo "WARN: expected exactly 2 persistent DynBQ files; found $COUNT"; }

echo
echo "=== V3.2 STATUS ==="
"$C" status

echo
echo "PASS: V3.2 installed without reboot; rollback copy removed"
ROUTER_SH
