#!/system/bin/sh
# Persistent cross-boot entrypoint for an uninstall recovery ledger.

umask 077

RECOVERY_DIR="/data/adb/maodie-launcher-recovery"
RECOVERY_SCRIPT="$RECOVERY_DIR/recover.sh"
RECOVERY_STATE="$RECOVERY_DIR/adblock.state"

if [ ! -s "$RECOVERY_STATE" ] || [ ! -x "$RECOVERY_SCRIPT" ]; then
    rm -f "$0" 2>/dev/null
    exit 0
fi

nohup sh "$RECOVERY_SCRIPT" --wait >> "$RECOVERY_DIR/recovery.log" 2>&1 &
exit 0
