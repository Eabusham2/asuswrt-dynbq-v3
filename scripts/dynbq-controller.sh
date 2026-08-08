#!/bin/sh

VERSION=3.2.1
BASE=/jffs/dynbq
PID=/tmp/dynbq.pid
LOG=/tmp/dynbq.log
LOG_MAX_BYTES=32768
LOG_KEEP_LINES=120

LOW=64
MID=128
HIGH=192
INTERVAL=2

# LOW should be easy to reach at genuinely light load, but still use
# hysteresis so ordinary background traffic does not flap the queue.
LOW_IDLE_PPS=1500
LOW_IDLE_SAMPLES=4
LOW_EXIT_PPS=3000
LOW_EXIT_SAMPLES=1
LOW_PRESS_SAMPLES=4
FULL_SAMPLE_MIN=512

# HIGH is still reserved for sustained very-high traffic.  Real hardware
# testing showed outstanding can legitimately rise well above 64 while
# completions are healthy, so use a generous safety ceiling and only treat
# feeder-full as pressure when it reaches FULL_SAMPLE_MIN.
HIGH_POST_PPS=30000
HIGH_SAMPLES=4
HIGH_OUT_MAX=2048
HIGH_HOLD_PPS=20000
HIGH_EXIT_SAMPLES=2
HIGH_TO_LOW_SAMPLES=2

trim_log()
{
    [ -f "$LOG" ] || return 0
    SIZE="$(wc -c <"$LOG" 2>/dev/null | tr -d ' ')"
    [ -n "$SIZE" ] || SIZE=0
    if [ "$SIZE" -gt "$LOG_MAX_BYTES" ]; then
        tail -n "$LOG_KEEP_LINES" "$LOG" >"$LOG.tmp" 2>/dev/null || : >"$LOG.tmp"
        mv "$LOG.tmp" "$LOG"
    fi
}

log()
{
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >>"$LOG"
    trim_log
}

run_pids()
{
    for D in /proc/[0-9]*; do
        [ -r "$D/cmdline" ] || continue
        CMD="$(tr '\000' ' ' <"$D/cmdline" 2>/dev/null || true)"
        case "$CMD" in
            *"/jffs/dynbq/dynbq-controller.sh run"*) echo "${D#/proc/}" ;;
        esac
    done
}

ensure_module()
{
    [ -e /proc/dynbq ] && return 0
    busybox insmod "$BASE/dynbq.ko" 2>/dev/null ||
        insmod "$BASE/dynbq.ko" 2>/dev/null ||
        return 1
    [ -e /proc/dynbq ]
}

runner_cap_line()
{
    R="$1"
    dhd -i "wl$R" dump 2>/dev/null | grep 'dol_cap Hlp:' | tail -1
}

runner_healthy()
{
    for R in 1 2; do
        L="$(runner_cap_line "$R")"
        [ -n "$L" ] || return 1
        echo "$L" | grep -q 'txoffl:1' || return 1
        echo "$L" | grep -q 'rxoffl:1' || return 1
        echo "$L" | grep -q 'bkupq:1' || return 1
        echo "$L" | grep -q 'hbqd:1' || return 1
        echo "$L" | grep -q 'dynbkupq:1' || return 1
        echo "$L" | grep -q 'codel:0' || return 1
        echo "$L" | grep -q 'ba256cfg:1' || return 1
    done
    return 0
}

wait_runner()
{
    N=0
    while [ "$N" -lt 15 ]; do
        runner_healthy && return 0
        sleep 2
        N=$((N+1))
    done
    return 1
}

new_bdmf()
{
    OUT="$(/jffs/bin/bdmf_shell -c init 2>/dev/null || true)"
    SID="$(printf '%s\n' "$OUT" | awk '
        /Session/ {
            for (i=1; i<=NF; i++) if ($i ~ /^[0-9]+$/) id=$i
        }
        END { if (id != "") print id }')"
    [ -n "$SID" ] || return 1
    echo "$SID" >/var/bdmf_sh_id
}

ensure_bdmf()
{
    if [ -s /var/bdmf_sh_id ]; then
        SID="$(cat /var/bdmf_sh_id)"
        /jffs/bin/bdmf_shell -c "$SID" -cmd "/Bdmf/types" >/dev/null 2>&1 && return 0
    fi
    rm -f /var/bdmf_sh_id
    new_bdmf
}

bs()
{
    ensure_bdmf || return 1
    SID="$(cat /var/bdmf_sh_id)"
    /jffs/bin/bdmf_shell -c "$SID" -cmd "$@" && return 0
    rm -f /var/bdmf_sh_id
    new_bdmf || return 1
    /jffs/bin/bdmf_shell -c "$(cat /var/bdmf_sh_id)" -cmd "$@"
}

refresh_stats()
{
    STATS="$(bs /Bdmf/e dhd_helper max_prints:-1 2>/dev/null)" || return 1
    [ -n "$STATS" ]
}

ctx()
{
    R="$1"
    printf '%s\n' "$STATS" | awk -v R="$R" '
        index($0,"dhd_helper/radio_idx=" R) { hit=1; next }
        hit && /doorbell_ctx=/ {
            x=$0; sub(/^.*doorbell_ctx=/,"",x); sub(/,.*/,"",x)
            gsub(/[[:space:]]/,"",x); print x; exit
        }
        hit && /dhd_helper\/radio_idx=/ { exit }'
}

statval()
{
    R="$1"; K="$2"
    printf '%s\n' "$STATS" | awk -v R="$R" -v K="$K" '
        index($0,"dhd_helper/radio_idx=" R) { hit=1; next }
        hit && index($0,K "=") {
            x=$0; sub("^.*" K "=","",x); sub(/,.*/,"",x)
            gsub(/[^0-9]/,"",x); if (x=="") x="0"; print x; exit
        }
        hit && /dhd_helper\/radio_idx=/ { exit }'
}

flows()
{
    R="$1"
    dhd -i "wl$R" flowring_ids_dump 2>/dev/null | awk '
        $2 ~ /^[0-9]+$/ && ($3 == 0 || $3 == 3) && $4 !~ /^33:33:/ { print $2 }'
}

set_radio()
{
    R="$1"; Q="$2"; CTX="$3"
    [ -n "$CTX" ] || return 0
    for F in $(flows "$R"); do
        echo "$CTX $F $Q" >/proc/dynbq || return 1
    done
}

delta32()
{
    N="$1"; O="$2"
    if [ "$N" -ge "$O" ]; then echo $((N-O)); else echo $((4294967296-O+N)); fi
}

outstanding()
{
    P="$1"; C="$2"
    if [ "$P" -ge "$C" ]; then X=$((P-C)); else X=$((4294967296-C+P)); fi
    [ "$X" -gt 4096 ] && X=4096
    echo "$X"
}

restore_mid()
{
    refresh_stats >/dev/null 2>&1 || return 0
    for R in 1 2; do
        CTX="$(ctx "$R" 2>/dev/null || true)"
        set_radio "$R" "$MID" "$CTX" >/dev/null 2>&1 || true
    done
}

cleanup_signal()
{
    trap - INT TERM HUP
    log "controller-v${VERSION} received stop signal; restoring MID=128"
    restore_mid
    rm -f "$PID"
    exit 0
}

run()
{
    ensure_module || { log "ERROR module load failed"; exit 1; }
    echo $$ >"$PID"
    trap cleanup_signal INT TERM HUP

    if ! wait_runner; then
        log "ERROR Runner offload/HBQD baseline unavailable"
        rm -f "$PID"
        exit 1
    fi

    S1=$MID; S2=$MID
    PR1=0; PR2=0
    CL1=0; CL2=0
    HC1=0; HC2=0
    HX1=0; HX2=0
    INIT1=0; INIT2=0
    PF1=0; PF2=0
    PD1=0; PD2=0
    PP1=0; PP2=0
    PC1=0; PC2=0
    SQ1=0; SQ2=0

    log "controller-v${VERSION} started PID=$$ LOW=64 MID=128 HIGH=192"

    while :; do
        sleep "$INTERVAL"
        if ! refresh_stats; then log "BDMF unavailable; retrying"; continue; fi

        CTX1="$(ctx 1)"; CTX2="$(ctx 2)"

        for R in 1 2; do
            eval CTX=\$CTX$R
            [ -n "$CTX" ] || continue

            NF="$(statval "$R" dhd_tx_fr_ac_be_full)"
            ND="$(statval "$R" dhd_bq_tx_drop_packets)"
            NP="$(statval "$R" dhd_tx_post_packets)"
            NC="$(statval "$R" dhd_tx_complete_packets)"
            [ -n "$NF" ] || NF=0; [ -n "$ND" ] || ND=0
            [ -n "$NP" ] || NP=0; [ -n "$NC" ] || NC=0

            eval INIT=\$INIT$R
            if [ "$INIT" -eq 0 ]; then
                eval PF$R="$NF"; eval PD$R="$ND"; eval PP$R="$NP"; eval PC$R="$NC"
                eval INIT$R=1
                set_radio "$R" "$MID" "$CTX" || true
                continue
            fi

            eval OF=\$PF$R; eval OD=\$PD$R; eval OP=\$PP$R; eval OC=\$PC$R
            DF="$(delta32 "$NF" "$OF")"; DD="$(delta32 "$ND" "$OD")"
            DP="$(delta32 "$NP" "$OP")"; DC="$(delta32 "$NC" "$OC")"
            eval PF$R="$NF"; eval PD$R="$ND"; eval PP$R="$NP"; eval PC$R="$NC"

            PPS=$((DP/INTERVAL)); OUT="$(outstanding "$NP" "$NC")"
            eval CUR=\$S$R; eval PR=\$PR$R; eval CL=\$CL$R; eval HC=\$HC$R; eval HX=\$HX$R
            eval SQ=\$SQ$R; SQ=$((SQ+1)); eval SQ$R="$SQ"
            NEW="$CUR"; REASON=hold

            PRESS_NOW=0; [ "$DF" -ge "$FULL_SAMPLE_MIN" ] && PRESS_NOW=1
            LOW_IDLE_NOW=0
            [ "$PPS" -le "$LOW_IDLE_PPS" ] && [ "$PRESS_NOW" -eq 0 ] && [ "$DD" -eq 0 ] && LOW_IDLE_NOW=1

            HIGH_OK=0
            [ "$PPS" -ge "$HIGH_POST_PPS" ] && [ "$OUT" -le "$HIGH_OUT_MAX" ] && \
                [ "$PRESS_NOW" -eq 0 ] && [ "$DD" -eq 0 ] && [ "$DP" -gt 0 ] && HIGH_OK=1

            HIGH_HOLD_OK=0
            [ "$PPS" -ge "$HIGH_HOLD_PPS" ] && [ "$OUT" -le "$HIGH_OUT_MAX" ] && \
                [ "$PRESS_NOW" -eq 0 ] && [ "$DD" -eq 0 ] && HIGH_HOLD_OK=1

            case "$CUR" in
            "$MID")
                HX=0
                if [ "$DD" -gt 0 ]; then
                    NEW=$LOW; REASON=bqdrop; PR=0; CL=0; HC=0
                else
                    if [ "$PRESS_NOW" -eq 1 ]; then PR=$((PR+1)); CL=0; HC=0
                    else
                        PR=0
                        if [ "$LOW_IDLE_NOW" -eq 1 ]; then CL=$((CL+1)); else CL=0; fi
                        if [ "$HIGH_OK" -eq 1 ]; then HC=$((HC+1)); else HC=0; fi
                    fi
                    if [ "$PR" -ge "$LOW_PRESS_SAMPLES" ]; then
                        NEW=$LOW; REASON=pressure; PR=0; CL=0; HC=0
                    elif [ "$CL" -ge "$LOW_IDLE_SAMPLES" ]; then
                        NEW=$LOW; REASON=very_low; PR=0; CL=0; HC=0
                    elif [ "$HC" -ge "$HIGH_SAMPLES" ]; then
                        NEW=$HIGH; REASON=very_high; PR=0; CL=0; HC=0
                    fi
                fi
                ;;
            "$LOW")
                PR=0; HC=0; HX=0
                if [ "$DD" -gt 0 ] || [ "$PRESS_NOW" -eq 1 ]; then CL=0
                elif [ "$PPS" -ge "$LOW_EXIT_PPS" ]; then
                    CL=$((CL+1))
                    if [ "$CL" -ge "$LOW_EXIT_SAMPLES" ]; then NEW=$MID; REASON=low_cleared; CL=0; fi
                else CL=0
                fi
                ;;
            "$HIGH")
                PR=0; HC=0
                if [ "$DD" -gt 0 ]; then NEW=$LOW; REASON=bqdrop; CL=0; HX=0
                elif [ "$PRESS_NOW" -eq 1 ]; then NEW=$MID; REASON=pressure; CL=0; HX=0
                else
                    if [ "$LOW_IDLE_NOW" -eq 1 ]; then CL=$((CL+1)); else CL=0; fi
                    if [ "$HIGH_HOLD_OK" -eq 1 ]; then HX=0; else HX=$((HX+1)); fi
                    if [ "$CL" -ge "$HIGH_TO_LOW_SAMPLES" ]; then
                        NEW=$LOW; REASON=very_low; CL=0; HX=0
                    elif [ "$HX" -ge "$HIGH_EXIT_SAMPLES" ]; then
                        NEW=$MID; REASON=high_cleared; CL=0; HX=0
                    fi
                fi
                ;;
            *) NEW=$MID; REASON=invalid_state; PR=0; CL=0; HC=0; HX=0 ;;
            esac

            eval S$R="$NEW"; eval PR$R="$PR"; eval CL$R="$CL"; eval HC$R="$HC"; eval HX$R="$HX"

            if ! set_radio "$R" "$NEW" "$CTX"; then log "ERROR wl$R set BQ=$NEW failed"; continue; fi
            if [ "$NEW" != "$CUR" ]; then
                log "wl$R postpps=${PPS} full+${DF} bqdrop+${DD} outstanding=${OUT} reason=${REASON} BQ ${CUR}->${NEW}"
            fi

            echo "seq=$SQ pps=$PPS post_delta=$DP complete_delta=$DC full_delta=$DF bqdrop_delta=$DD outstanding=$OUT pressure=$PRESS_NOW low_idle=$LOW_IDLE_NOW high_ok=$HIGH_OK high_hold_ok=$HIGH_HOLD_OK target=$NEW" >"/tmp/dynbq.wl$R.stats"
        done

        echo "$S1" >/tmp/dynbq.wl1; echo "$S2" >/tmp/dynbq.wl2
    done
}

case "${1:-}" in
run)
    run
    ;;
start)
    PIDS="$(run_pids)"
    if [ -n "$PIDS" ]; then
        COUNT="$(printf '%s\n' "$PIDS" | wc -l | tr -d ' ')"
        if [ "$COUNT" -eq 1 ]; then
            P="$(printf '%s\n' "$PIDS" | head -1)"; echo "$P" >"$PID"
            echo "DynBQ V${VERSION} already running PID $P"; exit 0
        fi
        for P in $PIDS; do kill "$P" 2>/dev/null || true; done
        sleep 2
    fi
    rm -f "$PID" /tmp/dynbq.wl1 /tmp/dynbq.wl2 /tmp/dynbq.wl1.stats /tmp/dynbq.wl2.stats
    : >"$LOG"
    ensure_module || { echo "ERROR: could not load dynbq.ko"; exit 1; }
    nohup "$0" run </dev/null >>"$LOG" 2>&1 &
    sleep 6
    if [ -f "$PID" ] && kill -0 "$(cat "$PID")" 2>/dev/null; then
        echo "DynBQ V${VERSION} RUNNING PID $(cat "$PID")"
    else
        echo "ERROR: DynBQ V${VERSION} failed runtime health"; tail -60 "$LOG" 2>/dev/null || true; exit 1
    fi
    ;;
stop)
    PIDS="$(run_pids)"
    for P in $PIDS; do kill "$P" 2>/dev/null || true; done
    sleep 3
    [ -n "$(run_pids)" ] && { for P in $(run_pids); do kill -9 "$P" 2>/dev/null || true; done; }
    restore_mid
    rm -f "$PID" "$LOG" /tmp/dynbq.wl1 /tmp/dynbq.wl2 /tmp/dynbq.wl1.stats /tmp/dynbq.wl2.stats
    echo "DynBQ stopped; MID=128 restored and runtime files removed"
    ;;
status)
    PIDS="$(run_pids)"
    if [ -n "$PIDS" ]; then echo "DynBQ V${VERSION} RUNNING PID(s) $(printf '%s' "$PIDS" | tr '\n' ' ')"
    else echo "DynBQ V${VERSION} STOPPED"
    fi
    echo "wl1 target=$(cat /tmp/dynbq.wl1 2>/dev/null || echo 128)"
    echo "wl2 target=$(cat /tmp/dynbq.wl2 2>/dev/null || echo 128)"
    echo "--- live hardware signals ---"
    echo "wl1: $(cat /tmp/dynbq.wl1.stats 2>/dev/null || echo pending)"
    echo "wl2: $(cat /tmp/dynbq.wl2.stats 2>/dev/null || echo pending)"
    echo "--- Runner capabilities ---"
    echo "wl1: $(runner_cap_line 1)"
    echo "wl2: $(runner_cap_line 2)"
    echo "--- recent log ---"
    tail -20 "$LOG" 2>/dev/null || true
    ;;
*)
    echo "Usage: $0 start|stop|status"
    exit 1
    ;;
esac
