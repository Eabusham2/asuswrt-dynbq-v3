#!/bin/sh
set -eu

DIR=/jffs/dynbq
SERV=/jffs/scripts/services-start
C=$DIR/dynbq-controller.sh

echo "=== DynBQ final cleanup ==="

# Remove only DynBQ/AQM experimental NVRAM keys. Keep unrelated router config.
CHANGED=0
for K in \
    dol1_cap_hbqd_override \
    dol2_cap_hbqd_override \
    dhd1_rnr_codel \
    dhd2_rnr_codel
do
    if [ -n "$(nvram get "$K")" ]; then
        nvram unset "$K"
        CHANGED=1
    fi
done
[ "$CHANGED" -eq 0 ] || nvram commit

# Remove every temporary/failed DynBQ boot block while preserving unrelated hooks.
if [ -f "$SERV" ]; then
    sed -i '/# DYNBQ AQM VERIFY BEGIN/,/# DYNBQ AQM VERIFY END/d' "$SERV" 2>/dev/null || true
    sed -i '/# DYNBQ AQM BDMF VERIFY BEGIN/,/# DYNBQ AQM BDMF VERIFY END/d' "$SERV" 2>/dev/null || true
    sed -i '/# DYNBQ RESTORE VERIFY BEGIN/,/# DYNBQ RESTORE VERIFY END/d' "$SERV" 2>/dev/null || true

    # Normalize the production block to one copy and no extra syslog chatter.
    sed -i '/# DYNBQ BEGIN/,/# DYNBQ END/d' "$SERV" 2>/dev/null || true
    cat >>"$SERV" <<'BOOT'
# DYNBQ BEGIN
(sleep 25; /jffs/dynbq/dynbq-controller.sh start) &
# DYNBQ END
BOOT
    chmod 755 "$SERV"
    sh -n "$SERV"
fi

# Persistent DynBQ storage must contain exactly the module + controller.
for F in "$DIR"/* "$DIR"/.[!.]*; do
    [ -e "$F" ] || continue
    case "$F" in
        "$DIR/dynbq.ko"|"$DIR/dynbq-controller.sh") ;;
        *) rm -rf "$F" ;;
    esac
done

# Remove stale tmpfs status/verifier outputs from development. Runtime files used
# by the active controller are kept, but its log is truncated now and bounded by
# the controller thereafter. /tmp is RAM-backed and is cleared on reboot.
rm -f \
    /tmp/dynbq-aqm-* \
    /tmp/dynbq-final-* \
    /tmp/dynbq-runner-restore-status \
    /tmp/dynbq-controller.pre-* \
    /tmp/dynbq.log.tmp

[ -f /tmp/dynbq.log ] && : >/tmp/dynbq.log || true

echo "Persistent DynBQ files:"
ls -lah "$DIR"
echo
echo "Persistent size:"
du -sh "$DIR" 2>/dev/null || true
echo
echo "Runtime tmpfs files:"
ls -lh /tmp/dynbq* 2>/dev/null || true
echo
echo "PASS: cleanup complete"
