#!/bin/bash
set -euo pipefail

ROUTER="${ROUTER:-192.168.50.1}"
RUSER="${RUSER:-Eabusham2}"
SOCK="/tmp/dynbq-high-ssh-$$"
WATCH="/tmp/dynbq-high-watch-$$.log"
NEWLOG="/tmp/dynbq-high-newlog-$$.log"

cleanup() {
  ssh -S "$SOCK" -O exit "$RUSER@$ROUTER" >/dev/null 2>&1 || true
  rm -f "$SOCK" "$WATCH" "$NEWLOG"
}
trap cleanup EXIT

command -v networkQuality >/dev/null 2>&1 || {
  echo "ERROR: macOS networkQuality command not found"
  exit 2
}

echo "=== DYNBQ V3.1 HIGH=192 REAL-LOAD TEST ==="
echo "Run this Mac over Wi-Fi, not Ethernet."
echo
echo "Opening one SSH control connection..."
ssh -M -S "$SOCK" -o ControlPersist=120 -fnNT "$RUSER@$ROUTER"

echo
echo "=== PRECHECK ==="
PRE="$(ssh -S "$SOCK" "$RUSER@$ROUTER" '
  /jffs/dynbq/dynbq-controller.sh status
  echo __LINES__
  wc -l < /tmp/dynbq.log 2>/dev/null || echo 0
')"
printf '%s\n' "$PRE"

START="$(printf '%s\n' "$PRE" | awk '/__LINES__/{getline; print; exit}')"
case "$START" in
  ''|*[!0-9]*) START=0 ;;
esac

echo
echo "=== LIVE WATCH START ==="
ssh -S "$SOCK" "$RUSER@$ROUTER" '
  i=0
  while [ "$i" -lt 40 ]; do
    date "+%H:%M:%S"
    printf "wl1 "; cat /tmp/dynbq.wl1.stats 2>/dev/null || echo pending
    printf "wl2 "; cat /tmp/dynbq.wl2.stats 2>/dev/null || echo pending
    sleep 1
    i=$((i+1))
  done
' >"$WATCH" 2>&1 &
WATCHPID=$!

echo
echo "=== REAL WIFI LOAD ==="
echo "Running macOS networkQuality sequential test..."
networkQuality -s -v || true

echo
echo "Load finished. Checking cooldown/return to MID..."
sleep 10

kill "$WATCHPID" >/dev/null 2>&1 || true
wait "$WATCHPID" 2>/dev/null || true

NEXT=$((START+1))
ssh -S "$SOCK" "$RUSER@$ROUTER" "tail -n +$NEXT /tmp/dynbq.log 2>/dev/null || true" >"$NEWLOG"

echo
echo "=== NEW DYNBQ TRANSITIONS ==="
cat "$NEWLOG"

echo
echo "=== FINAL STATUS ==="
ssh -S "$SOCK" "$RUSER@$ROUTER" '/jffs/dynbq/dynbq-controller.sh status'

echo
echo "=== MAX OBSERVED PPS ==="
awk '
/^wl[12] / {
  for (i=1; i<=NF; i++) {
    if ($i ~ /^pps=/) {
      split($i,a,"=")
      if (a[2]+0 > max) max=a[2]+0
    }
  }
}
END { print max+0 }
' "$WATCH"

UP=0
DOWN=0

grep -Eq 'BQ 128->192' "$NEWLOG" && UP=1
grep -Eq 'BQ 192->128' "$NEWLOG" && DOWN=1

echo
if [ "$UP" -eq 1 ] && [ "$DOWN" -eq 1 ]; then
  echo "PASS: automatic HIGH path empirically proven: 128 -> 192 -> 128"
elif [ "$UP" -eq 1 ]; then
  echo "PARTIAL: HIGH triggered (128 -> 192), but cooldown return was not observed yet"
else
  MAXPPS="$(awk '
  /^wl[12] / {
    for (i=1; i<=NF; i++) {
      if ($i ~ /^pps=/) {
        split($i,a,"=")
        if (a[2]+0 > max) max=a[2]+0
      }
    }
  }
  END { print max+0 }
  ' "$WATCH")"

  echo "NOT TRIGGERED: no 128 -> 192 transition observed"
  echo "Max observed DHD TX post rate: ${MAXPPS} pps"
  echo "V3.1 requires >=30000 pps for 6 consecutive 2-second samples with clean completion/queue state."
fi
