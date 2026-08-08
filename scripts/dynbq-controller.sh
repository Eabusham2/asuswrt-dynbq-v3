#!/bin/sh

BASE=/jffs/dynbq
PID=/tmp/dynbq.pid
LOG=/tmp/dynbq.log
FEATURES=/tmp/dynbq.features
LOG_MAX_BYTES=32768
LOG_KEEP_LINES=120

LOW=64
MID=128
HIGH=192
INTERVAL=2

# Keep MID=128 sticky.
LOW_PRESS_SAMPLES=4
LOW_CLEAR_SAMPLES=3
FULL_SAMPLE_MIN=512

# HIGH=192 requires sustained, clean hardware-offloaded traffic.
HIGH_POST_PPS=30000
HIGH_SAMPLES=6
HIGH_OUT_MAX=64
HIGH_EXIT_SAMPLES=3

# Dynamic aggregation envelope.  Never increase above the firmware's
# existing baseline; only cap very large AMPDU depth during LOW pressure.
LOW_MPDU_CAP=64

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

ensure_module()
{
    [ -e /proc/dynbq ] && return 0

    busybox insmod "$BASE/dynbq.ko" 2>/dev/null ||
        insmod "$BASE/dynbq.ko" 2>/dev/null ||
        return 1

    [ -e /proc/dynbq ]
}

new_bdmf()
{
    OUT="$(/jffs/bin/bdmf_shell -c init 2>/dev/null)"
    SID="$(
        printf '%s\n' "$OUT" |
        awk '
        /Session/ {
            for (i=1; i<=NF; i++)
                if ($i ~ /^[0-9]+$/)
                    id=$i
        }
        END {
            if (id != "")
                print id
        }'
    )"

    [ -n "$SID" ] || return 1
    echo "$SID" >/var/bdmf_sh_id
}

ensure_bdmf()
{
    if [ -s /var/bdmf_sh_id ]; then
        SID="$(cat /var/bdmf_sh_id)"
        /jffs/bin/bdmf_shell -c "$SID" -cmd "/Bdmf/types" >/dev/null 2>&1 &&
            return 0
    fi

    rm -f /var/bdmf_sh_id
    new_bdmf
}

bs()
{
    ensure_bdmf || return 1

    SID="$(cat /var/bdmf_sh_id)"
    /jffs/bin/bdmf_shell -c "$SID" -cmd "$@" &&
        return 0

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

    printf '%s\n' "$STATS" |
    awk -v R="$R" '
    index($0,"dhd_helper/radio_idx=" R) {
        hit=1
        next
    }

    hit && /doorbell_ctx=/ {
        x=$0
        sub(/^.*doorbell_ctx=/,"",x)
        sub(/,.*/,"",x)
        gsub(/[[:space:]]/,"",x)
        print x
        exit
    }

    hit && /dhd_helper\/radio_idx=/ {
        exit
    }'
}

statval()
{
    R="$1"
    K="$2"

    printf '%s\n' "$STATS" |
    awk -v R="$R" -v K="$K" '
    index($0,"dhd_helper/radio_idx=" R) {
        hit=1
        next
    }

    hit && index($0,K "=") {
        x=$0
        sub("^.*" K "=","",x)
        sub(/,.*/,"",x)
        gsub(/[^0-9]/,"",x)

        if (x == "")
            x="0"

        print x
        exit
    }

    hit && /dhd_helper\/radio_idx=/ {
        exit
    }'
}

flows()
{
    R="$1"

    dhd -i "wl$R" flowring_ids_dump 2>/dev/null |
    awk '
    $2 ~ /^[0-9]+$/ &&
    ($3 == 0 || $3 == 3) &&
    $4 !~ /^33:33:/ {
        print $2
    }'
}

set_radio()
{
    R="$1"
    Q="$2"
    CTX="$3"

    [ -n "$CTX" ] || return 0

    for F in $(flows "$R"); do
        echo "$CTX $F $Q" >/proc/dynbq || return 1
    done

    return 0
}

delta32()
{
    N="$1"
    O="$2"

    if [ "$N" -ge "$O" ]; then
        echo $((N-O))
    else
        echo $((4294967296-O+N))
    fi
}

outstanding()
{
    P="$1"
    C="$2"

    if [ "$P" -ge "$C" ]; then
        X=$((P-C))
    else
        X=$((4294967296-C+P))
    fi

    [ "$X" -gt 4096 ] && X=4096
    echo "$X"
}

# Return a value only if the wl command succeeds and its output contains
# exactly one signed decimal token.  This prevents the old "NA but pretend
# supported" bug.
wl_single_int()
{
    R="$1"
    shift

    OUT="$(wl -i "wl$R" "$@" 2>/dev/null)" || return 1

    printf '%s\n' "$OUT" |
    awk '
    {
        for (i=1; i<=NF; i++) {
            if ($i ~ /^-?[0-9]+$/) {
                n++
                v=$i
            }
        }
    }
    END {
        if (n == 1)
            print v
        else
            exit 1
    }'
}

same_value_set_test()
{
    R="$1"
    CMD="$2"
    VALUE="$3"

    wl -i "wl$R" "$CMD" "$VALUE" >/dev/null 2>&1 || return 1
    RB="$(wl_single_int "$R" "$CMD" 2>/dev/null)" || return 1
    [ "$RB" = "$VALUE" ]
}

same_tid_set_test()
{
    R="$1"
    CMD="$2"
    TID="$3"
    VALUE="$4"

    wl -i "wl$R" "$CMD" "$TID" "$VALUE" >/dev/null 2>&1 || return 1
    RB="$(wl_single_int "$R" "$CMD" "$TID" 2>/dev/null)" || return 1
    [ "$RB" = "$VALUE" ]
}

capture_wifi_features()
{
    : >"$FEATURES"

    for R in 1 2; do
        BA="$(wl_single_int "$R" ampdu_ba_wsize 2>/dev/null || true)"
        MPDU="$(wl_single_int "$R" ampdu_mpdu 2>/dev/null || true)"

        eval BA$R=\"\$BA\"
        eval MPDU$R=\"\$MPDU\"

        BA_SET=0
        MPDU_SET=0

        case "$BA" in
            ''|*[!0-9-]*)
                ;;
            *)
                if same_value_set_test "$R" ampdu_ba_wsize "$BA"; then
                    BA_SET=1
                fi
                ;;
        esac

        case "$MPDU" in
            ''|*[!0-9-]*)
                ;;
            *)
                if [ "$MPDU" -gt 0 ] 2>/dev/null &&
                   same_value_set_test "$R" ampdu_mpdu "$MPDU"; then
                    MPDU_SET=1
                fi
                ;;
        esac

        eval BAW$R=$BA_SET
        eval MPDUW$R=$MPDU_SET

        for T in 0 3; do
            RR="$(wl_single_int "$R" ampdu_rr_retry_limit_tid "$T" 2>/dev/null || true)"
            RW=0

            case "$RR" in
                ''|*[!0-9-]*)
                    ;;
                *)
                    if [ "$RR" -ge 1 ] 2>/dev/null &&
                       same_tid_set_test "$R" ampdu_rr_retry_limit_tid "$T" "$RR"; then
                        RW=1
                    fi
                    ;;
            esac

            eval RR${R}_${T}=\"\$RR\"
            eval RRW${R}_${T}=$RW
        done

        {
            echo "wl$R.ba_wsize=${BA:-unsupported}"
            echo "wl$R.ba_wsize_writable=$BA_SET"
            echo "wl$R.ampdu_mpdu=${MPDU:-unsupported}"
            echo "wl$R.ampdu_mpdu_writable=$MPDU_SET"

            eval X=\$RR${R}_0
            eval W=\$RRW${R}_0
            echo "wl$R.rr_tid0=${X:-unsupported}"
            echo "wl$R.rr_tid0_writable=$W"

            eval X=\$RR${R}_3
            eval W=\$RRW${R}_3
            echo "wl$R.rr_tid3=${X:-unsupported}"
            echo "wl$R.rr_tid3_writable=$W"
        } >>"$FEATURES"

        # Keep BA256 when the live setter is actually supported.
        if [ "$BA_SET" -eq 1 ] && [ "$BA" != "256" ]; then
            if wl -i "wl$R" ampdu_ba_wsize 256 >/dev/null 2>&1; then
                RB="$(wl_single_int "$R" ampdu_ba_wsize 2>/dev/null || true)"
                if [ "$RB" = "256" ]; then
                    eval BA$R=256
                    log "wl$R BA window ${BA}->256"
                else
                    wl -i "wl$R" ampdu_ba_wsize "$BA" >/dev/null 2>&1 || true
                fi
            fi
        fi
    done

    log "feature probe complete"
}

apply_wifi_policy()
{
    R="$1"
    Q="$2"

    eval MPDU=\$MPDU$R
    eval MPDUW=\$MPDUW$R

    if [ "$MPDUW" -eq 1 ] && [ -n "$MPDU" ]; then
        TARGET="$MPDU"

        if [ "$Q" -eq "$LOW" ] && [ "$MPDU" -gt "$LOW_MPDU_CAP" ]; then
            TARGET="$LOW_MPDU_CAP"
        fi

        wl -i "wl$R" ampdu_mpdu "$TARGET" >/dev/null 2>&1 || true
    fi

    for T in 0 3; do
        eval BASE=\$RR${R}_$T
        eval WR=\$RRW${R}_$T

        [ "$WR" -eq 1 ] || continue

        TARGET="$BASE"

        # Pressure-aware fallback envelope: at LOW, spend one fewer retry at
        # the regular rate before native ratesel falls back.  Native MCS/NSS/
        # bandwidth selection remains fully automatic.
        if [ "$Q" -eq "$LOW" ] && [ "$BASE" -gt 1 ]; then
            TARGET=$((BASE-1))
        fi

        wl -i "wl$R" ampdu_rr_retry_limit_tid "$T" "$TARGET" \
            >/dev/null 2>&1 || true
    done
}

restore()
{
    # Called from the running controller process, where the feature baselines
    # captured at startup are available.
    refresh_stats >/dev/null 2>&1 || true

    for R in 1 2; do
        CTX="$(ctx "$R" 2>/dev/null || true)"
        set_radio "$R" "$MID" "$CTX" >/dev/null 2>&1 || true
        apply_wifi_policy "$R" "$MID" >/dev/null 2>&1 || true
    done
}

restore_bq_only()
{
    # Safe for a fresh CLI shell where MPDU/RR baseline variables were not
    # captured.  Never calls apply_wifi_policy().
    refresh_stats >/dev/null 2>&1 || true

    for R in 1 2; do
        CTX="$(ctx "$R" 2>/dev/null || true)"
        set_radio "$R" "$MID" "$CTX" >/dev/null 2>&1 || true
    done
}

cleanup_signal()
{
    trap - INT TERM HUP
    log "controller-v3 received stop signal"
    restore
    rm -f "$PID"
    exit 0
}

run()
{
    ensure_module || {
        log "ERROR module load failed"
        rm -f "$PID"
        exit 1
    }

    echo $$ >"$PID"
    trap cleanup_signal INT TERM HUP

    S1=$MID
    S2=$MID

    PR1=0
    PR2=0
    CL1=0
    CL2=0
    HC1=0
    HC2=0
    HX1=0
    HX2=0

    INIT1=0
    INIT2=0

    PF1=0
    PF2=0
    PD1=0
    PD2=0
    PP1=0
    PP2=0
    PC1=0
    PC2=0

    capture_wifi_features
    apply_wifi_policy 1 "$MID"
    apply_wifi_policy 2 "$MID"

    log "controller-v3 started PID=$$ sticky MID=128 LOW=64 HIGH=192"

    while :; do
        sleep "$INTERVAL"

        if ! refresh_stats; then
            log "BDMF unavailable; retrying"
            continue
        fi

        CTX1="$(ctx 1)"
        CTX2="$(ctx 2)"

        for R in 1 2; do
            eval CTX=\$CTX$R
            [ -n "$CTX" ] || continue

            NF="$(statval "$R" dhd_tx_fr_ac_be_full)"
            ND="$(statval "$R" dhd_bq_tx_drop_packets)"
            NP="$(statval "$R" dhd_tx_post_packets)"
            NC="$(statval "$R" dhd_tx_complete_packets)"

            [ -n "$NF" ] || NF=0
            [ -n "$ND" ] || ND=0
            [ -n "$NP" ] || NP=0
            [ -n "$NC" ] || NC=0

            eval INIT=\$INIT$R

            if [ "$INIT" -eq 0 ]; then
                eval PF$R="$NF"
                eval PD$R="$ND"
                eval PP$R="$NP"
                eval PC$R="$NC"
                eval INIT$R=1

                set_radio "$R" "$MID" "$CTX" || true
                continue
            fi

            eval OF=\$PF$R
            eval OD=\$PD$R
            eval OP=\$PP$R
            eval OC=\$PC$R

            DF="$(delta32 "$NF" "$OF")"
            DD="$(delta32 "$ND" "$OD")"
            DP="$(delta32 "$NP" "$OP")"
            DC="$(delta32 "$NC" "$OC")"

            eval PF$R="$NF"
            eval PD$R="$ND"
            eval PP$R="$NP"
            eval PC$R="$NC"

            PPS=$((DP/INTERVAL))
            OUT="$(outstanding "$NP" "$NC")"

            eval CUR=\$S$R
            eval PR=\$PR$R
            eval CL=\$CL$R
            eval HC=\$HC$R
            eval HX=\$HX$R

            NEW="$CUR"

            PRESS_NOW=0
            [ "$DF" -ge "$FULL_SAMPLE_MIN" ] && PRESS_NOW=1

            HIGH_OK=0
            if [ "$PPS" -ge "$HIGH_POST_PPS" ] &&
               [ "$OUT" -le "$HIGH_OUT_MAX" ] &&
               [ "$DF" -eq 0 ] &&
               [ "$DD" -eq 0 ] &&
               [ "$DP" -gt 0 ] &&
               [ $((DC*100)) -ge $((DP*95)) ]; then
                HIGH_OK=1
            fi

            case "$CUR" in

            "$MID")
                CL=0
                HX=0

                # Actual Runner BQ drops are severe enough for immediate LOW.
                if [ "$DD" -gt 0 ]; then
                    NEW=$LOW
                    PR=0
                    HC=0
                else
                    if [ "$PRESS_NOW" -eq 1 ]; then
                        PR=$((PR+1))
                    else
                        PR=0
                    fi

                    if [ "$PR" -ge "$LOW_PRESS_SAMPLES" ]; then
                        NEW=$LOW
                        PR=0
                        HC=0
                    else
                        if [ "$HIGH_OK" -eq 1 ]; then
                            HC=$((HC+1))
                        else
                            HC=0
                        fi

                        if [ "$HC" -ge "$HIGH_SAMPLES" ]; then
                            NEW=$HIGH
                            HC=0
                        fi
                    fi
                fi
                ;;

            "$LOW")
                PR=0
                HC=0
                HX=0

                if [ "$DD" -gt 0 ] || [ "$PRESS_NOW" -eq 1 ]; then
                    CL=0
                else
                    CL=$((CL+1))

                    if [ "$CL" -ge "$LOW_CLEAR_SAMPLES" ]; then
                        NEW=$MID
                        CL=0
                    fi
                fi
                ;;

            "$HIGH")
                PR=0
                CL=0
                HC=0

                if [ "$DD" -gt 0 ]; then
                    NEW=$LOW
                    HX=0
                elif [ "$PRESS_NOW" -eq 1 ]; then
                    NEW=$MID
                    HX=0
                elif [ "$HIGH_OK" -eq 1 ]; then
                    HX=0
                else
                    HX=$((HX+1))

                    if [ "$HX" -ge "$HIGH_EXIT_SAMPLES" ]; then
                        NEW=$MID
                        HX=0
                    fi
                fi
                ;;

            *)
                NEW=$MID
                PR=0
                CL=0
                HC=0
                HX=0
                ;;

            esac

            eval S$R="$NEW"
            eval PR$R="$PR"
            eval CL$R="$CL"
            eval HC$R="$HC"
            eval HX$R="$HX"

            if ! set_radio "$R" "$NEW" "$CTX"; then
                log "ERROR wl$R set BQ=$NEW failed"
                continue
            fi

            if [ "$NEW" != "$CUR" ]; then
                apply_wifi_policy "$R" "$NEW"

                log "wl$R postpps=${PPS} full+${DF} bqdrop+${DD} outstanding=${OUT} BQ ${CUR}->${NEW}"
            fi

            echo "pps=$PPS full_delta=$DF bqdrop_delta=$DD outstanding=$OUT high_ok=$HIGH_OK target=$NEW" \
                >"/tmp/dynbq.wl$R.stats"
        done

        echo "$S1" >/tmp/dynbq.wl1
        echo "$S2" >/tmp/dynbq.wl2
    done
}

case "$1" in

run)
    run
    ;;

start)
    if [ -f "$PID" ] &&
       kill -0 "$(cat "$PID")" 2>/dev/null; then
        echo "DynBQ V3 already running PID $(cat "$PID")"
        exit 0
    fi

    rm -f "$PID"
    : >"$LOG"
    rm -f "$FEATURES" /tmp/dynbq.wl1 /tmp/dynbq.wl2 \
          /tmp/dynbq.wl1.stats /tmp/dynbq.wl2.stats

    ensure_module || {
        echo "ERROR: could not load dynbq.ko"
        exit 1
    }

    nohup "$0" run </dev/null >>"$LOG" 2>&1 &
    sleep 10

    if [ -f "$PID" ] &&
       kill -0 "$(cat "$PID")" 2>/dev/null; then
        echo "DynBQ V3 RUNNING PID $(cat "$PID")"
    else
        echo "ERROR: DynBQ V3 failed runtime health"
        tail -60 "$LOG" 2>/dev/null || true
        exit 1
    fi
    ;;

stop)
    if [ -f "$PID" ] &&
       kill -0 "$(cat "$PID")" 2>/dev/null; then
        # The live controller handles SIGTERM and restores both BQ and its
        # captured Wi-Fi policy baselines before exiting.
        kill "$(cat "$PID")" 2>/dev/null || true
        sleep 3
    else
        # No live process means no captured Wi-Fi baselines in this shell.
        # Restore only the BQ safely.
        restore_bq_only
    fi

    rm -f "$PID" "$LOG" "$FEATURES" \
          /tmp/dynbq.wl1 /tmp/dynbq.wl2 \
          /tmp/dynbq.wl1.stats /tmp/dynbq.wl2.stats
    echo "DynBQ stopped; BQ restored and ephemeral runtime files removed"
    ;;

status)
    if [ -f "$PID" ] &&
       kill -0 "$(cat "$PID")" 2>/dev/null; then
        echo "DynBQ V3 RUNNING PID $(cat "$PID")"
    else
        echo "DynBQ V3 STOPPED"
    fi

    echo "wl1 target=$(cat /tmp/dynbq.wl1 2>/dev/null || echo 128)"
    echo "wl2 target=$(cat /tmp/dynbq.wl2 2>/dev/null || echo 128)"

    echo "--- live hardware signals ---"
    echo "wl1: $(cat /tmp/dynbq.wl1.stats 2>/dev/null || echo pending)"
    echo "wl2: $(cat /tmp/dynbq.wl2.stats 2>/dev/null || echo pending)"

    echo "--- BA/rate capabilities actually enabled ---"
    cat "$FEATURES" 2>/dev/null || echo pending

    echo "--- recent log ---"
    tail -20 "$LOG" 2>/dev/null || true
    ;;

*)
    echo "Usage: $0 start|stop|status"
    exit 1
    ;;

esac
