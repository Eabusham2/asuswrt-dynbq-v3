#!/bin/bash
set -euo pipefail

ROUTER="${ROUTER:-192.168.50.1}"
RUSER="${RUSER:-Eabusham2}"
SOCK="/tmp/dynbq-56ghz-audit-ssh-$$"
OUT="${OUT:-$PWD/56ghz-audit-$(date +%Y%m%d-%H%M%S).txt}"

cleanup() {
  ssh -S "$SOCK" -O exit "$RUSER@$ROUTER" >/dev/null 2>&1 || true
  rm -f "$SOCK"
}
trap cleanup EXIT

ssh -M -S "$SOCK" -o ControlPersist=120 -fnNT "$RUSER@$ROUTER"

ssh -S "$SOCK" "$RUSER@$ROUTER" 'sh -s' <<'ROUTER_SH' | tee "$OUT"
set +e

echo "=== 5/6-GHZ READ-ONLY BASELINE ==="
date
uname -a
printf 'productid='; nvram get productid
printf 'firmver='; nvram get firmver
printf 'buildno='; nvram get buildno
printf 'extendno='; nvram get extendno

echo
echo "=== TOOL AVAILABILITY ==="
for C in dhd wl wlctl; do
    P="$(command -v "$C" 2>/dev/null)"
    [ -n "$P" ] && echo "$C=$P" || echo "$C=NOT_FOUND"
done

echo
echo "=== CURRENT DYNBQ ==="
/jffs/dynbq/dynbq-controller.sh status 2>/dev/null || echo "DynBQ status unavailable"

echo
echo "=== RELEVANT NVRAM: WL1/WL2 ==="
nvram show 2>/dev/null \
  | grep -E '^wl[12]_' \
  | grep -Ei 'ampdu|amsdu|aggr|ba_|ba256|wme|edca|ofdma|mu_|mumimo|multi.?user|twt|taf|atf|airtime|frameburst|dtim|mlo|emlsr|chanspec|channel|bw|nmode|he_|eht_|txbf|beam|retry|rate|mcs|nss|sched|ife|sbf|lbr' \
  | sort

echo
echo "=== DHD MODULE PARAMETERS ==="
for F in /sys/module/dhd/parameters/*; do
    [ -f "$F" ] || continue
    N="${F##*/}"
    echo "$N" | grep -Eiq 'ampdu|amsdu|aggr|ba|lbr|ife|sbf|taf|sched|rate|retry|txbound|rxbound|thresh|flow|queue|wme|twt' || continue
    V="$(cat "$F" 2>/dev/null)"
    echo "$N=$V"
done

for R in 1 2; do
    IF="wl$R"
    echo
    echo "################################################################"
    echo "=== $IF RUNNER CAPABILITIES ==="
    dhd -i "$IF" dump 2>/dev/null | grep 'dol_cap Hlp:' | tail -1

    echo
    echo "=== $IF DHD AGG/BA/SCHED/RATE/AIRTIME LINES ==="
    dhd -i "$IF" dump 2>/dev/null \
      | grep -Ei 'ampdu|amsdu|block.?ack|ba256|(^|[^a-z])ba([^a-z]|$)|aggr|lbr|rate|ratesel|mcs|nss|retry|retries|taf|ife|sbf|sched|airtime|fair|ofdma|mu[-_ ]|mumimo|twt|emlsr|txbound|rxbound|txp_thresh|wme|edca|flowring|queue|bkupq|hbqd|codel' \
      | head -n 700

    echo
    echo "=== $IF FLOWRINGS (FIRST 300 LINES) ==="
    dhd -i "$IF" flowring_ids_dump 2>/dev/null | head -n 300

done

echo
echo "=== PROCESS CLUES ==="
ps 2>/dev/null | grep -Ei 'dhd|wl|taf|ife|sbf|sched|airtime' | grep -v grep || true

echo
echo "=== END READ-ONLY BASELINE ==="
ROUTER_SH

echo
echo "Saved audit: $OUT"
