#!/bin/bash
set -euo pipefail

: "${ROUTER:?Set ROUTER to the router hostname or IP address}"
: "${RUSER:?Set RUSER to the router SSH administrator username}"
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/dynbq-controller.sh"
VERSION="$(sed -n 's/^VERSION=//p' "$SRC")"
case "$VERSION" in
  [0-9]*.[0-9]*.[0-9]*) ;;
  *) echo "ERROR: invalid controller version"; exit 2 ;;
esac
case "$VERSION" in *[!0-9.]* ) echo "ERROR: invalid controller version"; exit 2 ;; esac
SOCK="/tmp/dynbq-update-ssh-$$"
REMOTE_NEW="/tmp/dynbq-controller.new"

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

ssh -S "$SOCK" "$RUSER@$ROUTER" "sh -s -- '$VERSION'" <<'ROUTER_SH'
set -eu
EXPECTED_VERSION="$1"

C=/jffs/dynbq/dynbq-controller.sh
N=/tmp/dynbq-controller.new
B=/tmp/dynbq-controller.pre-update

healthy_runner()
{
    for R in 0 1 2; do
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

grep -Fxq "VERSION=$EXPECTED_VERSION" "$N" || {
    echo "ERROR: controller version mismatch"; rm -f "$N"; exit 12;
}
[ -s "$C" ] && [ -s /jffs/dynbq/dynbq.ko ] || {
    echo "ERROR: an existing controller and firmware-matched module are required"
    rm -f "$N"
    exit 13
}

cp -p "$C" "$B"
"$C" stop >/dev/null 2>&1 || true
cp "$N" "$C"
chmod 755 "$C"
rm -f "$N"

if ! "$C" start; then
    echo "ERROR: V$EXPECTED_VERSION failed to start; rolling controller back"
    cp "$B" "$C"
    chmod 755 "$C"
    "$C" start >/dev/null 2>&1 || true
    exit 20
fi

sleep 4
NPROC="$(count_run)"
if [ "$NPROC" -ne 1 ] || [ ! -e /proc/dynbq ]; then
    echo "ERROR: V$EXPECTED_VERSION runtime health failed; rolling controller back"
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
echo "=== V$EXPECTED_VERSION STATUS ==="
"$C" status

echo
echo "PASS: V$EXPECTED_VERSION installed without reboot; rollback copy removed"
ROUTER_SH
