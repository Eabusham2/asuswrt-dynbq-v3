#!/bin/bash
set -euo pipefail

ROUTER="${ROUTER:-192.168.50.1}"
RUSER="${RUSER:-Eabusham2}"
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/dynbq-controller.sh"
SOCK="/tmp/dynbq-v32-update-ssh-$$"
REMOTE_NEW="/tmp/dynbq-controller.v32.new"

cleanup() {
  ssh -S "$SOCK" -O exit "$RUSER@$ROUTER" >/dev/null 2>&1 || true
  rm -f "$SOCK"
}
trap cleanup EXIT

[ -s "$SRC" ] || { echo "ERROR: $SRC missing"; exit 2; }
sh -n "$SRC"

ssh -M -S "$SOCK" -o ControlPersist=120 -fnNT "$RUSER@$ROUTER"

LOCAL_SIZE="$(wc -c < "$SRC" | tr -d ' ')"
REMOTE_SIZE="$(
  ssh -S "$SOCK" "$RUSER@$ROUTER" \
    "umask 077; cat > '$REMOTE_NEW'; wc -c < '$REMOTE_NEW' | tr -d ' '" \
    < "$SRC"
)" || {
  echo "ERROR: SSH stream transfer failed"
  exit 3
}

[ "$REMOTE_SIZE" = "$LOCAL_SIZE" ] || {
  echo "ERROR: transfer size mismatch: local=$LOCAL_SIZE remote=${REMOTE_SIZE:-missing}"
  ssh -S "$SOCK" "$RUSER@$ROUTER" "rm -f '$REMOTE_NEW'" >/dev/null 2>&1 || true
  exit 4
}

echo "PASS: controller transferred over plain SSH; exact byte count verified ($LOCAL_SIZE bytes)"

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
healthy_runner || { echo "ERROR: Runner baseline unhealthy; refusing update"; rm -f "$N"; exit 10; }

busybox ash -n "$N" || { echo "ERROR: new controller failed BusyBox ash syntax"; rm -f "$N"; exit 11; }

grep -q '^VERSION=3.2.2$' "$N" || { echo "ERROR: V3.2.2 controller missing"; rm -f "$N"; exit 12; }
grep -q '^LOW_IDLE_PPS=2000$' "$N" || { echo "ERROR: V3.2.2 low-idle threshold missing"; rm -f "$N"; exit 13; }
grep -q '^LOW_IDLE_SAMPLES=3$' "$N" || { echo "ERROR: V3.2.2 low-idle timing missing"; rm -f "$N"; exit 14; }
grep -q '^LOW_EXIT_PPS=4000$' "$N" || { echo "ERROR: V3.2.2 low-exit threshold missing"; rm -f "$N"; exit 15; }
grep -q '^HIGH_POST_PPS=30000$' "$N" || { echo "ERROR: V3.2.2 high-entry PPS missing"; rm -f "$N"; exit 16; }
grep -q '^HIGH_SAMPLES=4$' "$N" || { echo "ERROR: V3.2.2 high-entry timing missing"; rm -f "$N"; exit 17; }
grep -q '^HIGH_OUT_MAX=2048$' "$N" || { echo "ERROR: V3.2.2 high outstanding ceiling missing"; rm -f "$N"; exit 18; }
grep -q '^HIGH_HOLD_PPS=20000$' "$N" || { echo "ERROR: V3.2.2 high-hold policy missing"; rm -f "$N"; exit 19; }

cp -p "$C" "$B"
"$C" stop >/dev/null 2>&1 || true
cp "$N" "$C"
chmod 755 "$C"
rm -f "$N"

if ! "$C" start; then
    echo "ERROR: V3.2.2 failed to start; rolling controller back"
    cp "$B" "$C"
    chmod 755 "$C"
    "$C" start >/dev/null 2>&1 || true
    exit 20
fi

sleep 4
NPROC="$(count_run)"
if [ "$NPROC" -ne 1 ] || [ ! -e /proc/dynbq ]; then
    echo "ERROR: V3.2.2 runtime health failed; rolling controller back"
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
COUNT=0
EXTRA=0
for F in /jffs/dynbq/*; do
    [ -e "$F" ] || continue
    [ -f "$F" ] || continue
    NAME="${F##*/}"
    echo "$NAME"
    COUNT=$((COUNT+1))
    case "$NAME" in
        dynbq.ko|dynbq-controller.sh) ;;
        *) EXTRA=1 ;;
    esac
done

if [ -f /jffs/dynbq/dynbq.ko ] &&
   [ -f /jffs/dynbq/dynbq-controller.sh ] &&
   [ "$COUNT" -eq 2 ] &&
   [ "$EXTRA" -eq 0 ]; then
    echo "PASS: exactly two persistent DynBQ files"
else
    echo "WARN: persistent DynBQ layout unexpected (count=$COUNT extra=$EXTRA)"
    ls -la /jffs/dynbq 2>/dev/null || true
fi

echo
echo "=== V3.2.2 STATUS ==="
"$C" status

echo
echo "PASS: V3.2.2 installed without reboot; rollback copy removed"
ROUTER_SH
