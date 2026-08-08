#!/bin/bash
set -euo pipefail

ROUTER="${ROUTER:-192.168.50.1}"
RUSER="${RUSER:-Eabusham2}"
SOCK="/tmp/dynbq-high-ssh-$$"
WATCH="/tmp/dynbq-high-watch-$$.log"
NEWLOG="/tmp/dynbq-high-newlog-$$.log"

HIGH_POST_PPS="${HIGH_POST_PPS:-30000}"
HIGH_OUT_MAX="${HIGH_OUT_MAX:-64}"
HIGH_SAMPLES="${HIGH_SAMPLES:-6}"

cleanup() {
  ssh -S "$SOCK" -O exit "$RUSER@$ROUTER" >/dev/null 2>&1 || true
  rm -f "$SOCK" "$WATCH" "$NEWLOG"
}
trap cleanup EXIT

command -v networkQuality >/dev/null 2>&1 || {
  echo "ERROR: macOS networkQuality command not found"
  exit 2
}

echo "=== DYNBQ V3.1 HIGH=192 DIAGNOSTIC ==="
echo "Run this Mac over Wi-Fi, not Ethernet."
echo "Policy: >=${HIGH_POST_PPS} pps, outstanding<=${HIGH_OUT_MAX}, clean queue,"
echo "        completion gate passes, for ${HIGH_SAMPLES} consecutive controller samples."
echo

echo "Opening one SSH control connection..."
ssh -M -S "$SOCK" -o ControlPersist=180 -fnNT "$RUSER@$ROUTER"

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
echo "=== SAMPLE WATCH ==="
# V3 updates its stats every 2 seconds. Sampling every 2.2 seconds avoids
# counting the same controller sample twice in normal operation.
ssh -S "$SOCK" "$RUSER@$ROUTER" '
  i=0
  while [ "$i" -lt 24 ]; do
    ts="$(date "+%H:%M:%S")"
    for r in 1 2; do
      s="$(cat "/tmp/dynbq.wl$r.stats" 2>/dev/null || true)"
      [ -n "$s" ] && echo "$ts wl$r $s"
    done
    sleep 2.2
    i=$((i+1))
  done
' >"$WATCH" 2>&1 &
WATCHPID=$!

echo
echo "=== REAL WIFI LOAD ==="
echo "Running macOS networkQuality sequential test..."
networkQuality -s -v || true

echo
echo "Load finished. Watching cooldown..."
sleep 12

kill "$WATCHPID" >/dev/null 2>&1 || true
wait "$WATCHPID" 2>/dev/null || true

NEXT=$((START+1))
ssh -S "$SOCK" "$RUSER@$ROUTER" "tail -n +$NEXT /tmp/dynbq.log 2>/dev/null || true" >"$NEWLOG"

echo
echo "=== CONTROLLER SAMPLES ==="
cat "$WATCH"

echo
echo "=== NEW DYNBQ TRANSITIONS ==="
cat "$NEWLOG"

echo
echo "=== DIAGNOSIS ==="
awk -v ppsmin="$HIGH_POST_PPS" -v outmax="$HIGH_OUT_MAX" '
function val(prefix,    i,a) {
  for (i=3; i<=NF; i++) {
    split($i,a,"=")
    if (a[1] == prefix) return a[2]+0
  }
  return 0
}
function radio_idx(r) { return (r=="wl1" ? 1 : 2) }

$2=="wl1" || $2=="wl2" {
  r=radio_idx($2)
  p=val("pps")
  f=val("full_delta")
  d=val("bqdrop_delta")
  o=val("outstanding")
  h=val("high_ok")
  t=val("target")

  samples[r]++
  if (p > maxpps[r]) maxpps[r]=p
  if (o > maxout[r]) maxout[r]=o
  if (p >= ppsmin) above[r]++

  reason=""
  if (p < ppsmin) reason="pps"
  else if (d > 0) reason="bqdrop"
  else if (f > 0) reason="feeder_full"
  else if (o > outmax) reason="outstanding"
  else if (h != 1) reason="completion_gate"
  else reason="HIGH_OK"

  fail[r,reason]++

  if (h == 1) {
    streak[r]++
    if (streak[r] > maxstreak[r]) maxstreak[r]=streak[r]
  } else {
    streak[r]=0
  }

  if (t == 192) saw192[r]=1
}
END {
  for (r=1; r<=2; r++) {
    printf "wl%d: samples=%d max_pps=%d max_outstanding=%d pps>=threshold=%d max_HIGH_OK_streak=%d saw_target_192=%s\n",
      r, samples[r]+0, maxpps[r]+0, maxout[r]+0, above[r]+0, maxstreak[r]+0,
      (saw192[r] ? "yes" : "no")
    printf "     below_pps=%d outstanding_fail=%d feeder_full=%d bqdrop=%d completion_gate_fail=%d HIGH_OK=%d\n",
      fail[r,"pps"]+0, fail[r,"outstanding"]+0, fail[r,"feeder_full"]+0,
      fail[r,"bqdrop"]+0, fail[r,"completion_gate"]+0, fail[r,"HIGH_OK"]+0
  }
}
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
  echo "NOT TRIGGERED: diagnosis above shows which guard prevented HIGH."
fi

echo
echo "=== FINAL STATUS ==="
ssh -S "$SOCK" "$RUSER@$ROUTER" '/jffs/dynbq/dynbq-controller.sh status'
