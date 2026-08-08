#!/bin/bash
set -euo pipefail

ROUTER="${ROUTER:-192.168.50.1}"
RUSER="${RUSER:-Eabusham2}"
SOCK="/tmp/dynbq-v32-ssh-$$"
WATCH="/tmp/dynbq-v32-watch-$$.log"
NEWLOG="/tmp/dynbq-v32-newlog-$$.log"

cleanup() {
  ssh -S "$SOCK" -O exit "$RUSER@$ROUTER" >/dev/null 2>&1 || true
  rm -f "$SOCK" "$WATCH" "$NEWLOG"
}
trap cleanup EXIT

command -v networkQuality >/dev/null 2>&1 || {
  echo "ERROR: macOS networkQuality command not found"
  exit 2
}

echo "=== DYNBQ V3.2 THREE-BAND REAL-LOAD TEST ==="
echo "Run this Mac over Wi-Fi, not Ethernet."
echo "Expected policy: very-low -> 64, normal -> 128, very-high clean -> 192."
echo

ssh -M -S "$SOCK" -o ControlPersist=180 -fnNT "$RUSER@$ROUTER"

PRE="$(ssh -S "$SOCK" "$RUSER@$ROUTER" '
  /jffs/dynbq/dynbq-controller.sh status
  echo __LINES__
  wc -l < /tmp/dynbq.log 2>/dev/null || echo 0
')"
printf '%s\n' "$PRE"

START="$(printf '%s\n' "$PRE" | awk '/__LINES__/{getline; print; exit}')"
case "$START" in ''|*[!0-9]*) START=0 ;; esac

echo
echo "=== WATCHING CONTROLLER SAMPLES ==="
ssh -S "$SOCK" "$RUSER@$ROUTER" '
  i=0
  while [ "$i" -lt 70 ]; do
    date "+ts=%H:%M:%S"
    printf "wl1 "; cat /tmp/dynbq.wl1.stats 2>/dev/null || echo pending
    printf "wl2 "; cat /tmp/dynbq.wl2.stats 2>/dev/null || echo pending
    sleep 1
    i=$((i+1))
  done
' >"$WATCH" 2>&1 &
WATCHPID=$!

sleep 2

echo
echo "=== VERY-HIGH LOAD PHASE ==="
networkQuality -s -v || true

echo
echo "=== COOLDOWN / VERY-LOW OPPORTUNITY ==="
echo "No generated load for 22 seconds. HIGH must drop; if a radio stays <=1000 pps long enough it should reach 64."
sleep 22

kill "$WATCHPID" >/dev/null 2>&1 || true
wait "$WATCHPID" 2>/dev/null || true

NEXT=$((START+1))
ssh -S "$SOCK" "$RUSER@$ROUTER" "tail -n +$NEXT /tmp/dynbq.log 2>/dev/null || true" >"$NEWLOG"

echo
echo "=== NEW TRANSITIONS ==="
cat "$NEWLOG"

echo
echo "=== FINAL STATUS ==="
FINAL="$(ssh -S "$SOCK" "$RUSER@$ROUTER" '/jffs/dynbq/dynbq-controller.sh status')"
printf '%s\n' "$FINAL"

echo
echo "=== DEDUPED SAMPLE DIAGNOSTICS ==="
awk '
function val(k,  i,a) {
  for (i=1;i<=NF;i++) {
    split($i,a,"=")
    if (a[1]==k) return a[2]+0
  }
  return -1
}
/^wl[12] / {
  r=$1
  seq=val("seq")
  if (seq < 0 || seq==lastseq[r]) next
  lastseq[r]=seq

  p=val("pps"); o=val("outstanding"); h=val("high_ok"); hh=val("high_hold_ok"); li=val("low_idle")
  fd=val("full_delta"); bd=val("bqdrop_delta"); t=val("target")

  samples[r]++
  if (p>maxpps[r]) maxpps[r]=p
  if (o>maxout[r]) maxout[r]=o
  if (fd>0) fullsamples[r]++
  if (bd>0) dropsamples[r]++
  if (t==192) highsamples[r]++
  if (t==64) lowsamples[r]++

  if (h==1) { hs[r]++; if (hs[r]>maxhs[r]) maxhs[r]=hs[r] } else hs[r]=0
  if (hh==1) { hhs[r]++; if (hhs[r]>maxhhs[r]) maxhhs[r]=hhs[r] } else hhs[r]=0
  if (li==1) { ls[r]++; if (ls[r]>maxls[r]) maxls[r]=ls[r] } else ls[r]=0
}
END {
  for (n=1;n<=2;n++) {
    r="wl" n
    printf "%s: samples=%d max_pps=%d max_outstanding=%d max_high_ok_streak=%d max_high_hold_streak=%d max_low_idle_streak=%d target192_samples=%d target64_samples=%d full_samples=%d bqdrop_samples=%d\n", r,samples[r]+0,maxpps[r]+0,maxout[r]+0,maxhs[r]+0,maxhhs[r]+0,maxls[r]+0,highsamples[r]+0,lowsamples[r]+0,fullsamples[r]+0,dropsamples[r]+0
  }
}
' "$WATCH"

UP=0
EXIT=0
LOW=0

grep -Eq 'BQ (64|128)->192' "$NEWLOG" && UP=1
grep -Eq 'BQ 192->(128|64)' "$NEWLOG" && EXIT=1
grep -Eq 'reason=very_low BQ (128|192)->64' "$NEWLOG" && LOW=1

F1="$(printf '%s\n' "$FINAL" | awk -F= '/^wl1 target=/{print $2; exit}')"
F2="$(printf '%s\n' "$FINAL" | awk -F= '/^wl2 target=/{print $2; exit}')"

echo
echo "=== RESULT ==="
if [ "$UP" -eq 1 ]; then
  echo "PASS: automatic very-high entry to 192 observed"
else
  echo "NOT YET PROVEN: no automatic entry to 192 observed"
fi

if [ "$EXIT" -eq 1 ]; then
  echo "PASS: HIGH automatically dropped after very-high load ended"
else
  echo "NOT OBSERVED: no 192 exit transition was available to verify"
fi

if [ "$LOW" -eq 1 ]; then
  echo "PASS: sustained very-low traffic automatically selected 64"
else
  echo "INFO: no logged very_low -> 64 transition during this run (the sample diagnostics show whether the <=1000 pps streak occurred)"
fi

echo "Final targets: wl1=${F1:-unknown} wl2=${F2:-unknown}"

echo
if [ "$UP" -eq 1 ] && [ "$EXIT" -eq 1 ]; then
  echo "OVERALL HIGH CYCLE: PASS"
else
  echo "OVERALL HIGH CYCLE: INCOMPLETE"
fi
