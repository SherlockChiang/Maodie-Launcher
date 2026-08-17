#!/system/bin/sh
# Maodie Launcher - Uninstall Script

umask 077

MOD_DIR="${MAODIE_MOD_DIR:-/data/adb/modules/Maodie-Launcher}"
RUN_DIR="$MOD_DIR/maodie/run"
MAINTENANCE_FILE="$RUN_DIR/maintenance"
CORE_SCRIPT="$MOD_DIR/maodie/scripts/core.sh"
SERVICE_SCRIPT="$MOD_DIR/service.sh"
MONITOR_SCRIPT="$MOD_DIR/maodie/scripts/monitor.sh"
ADBLOCK_SCRIPT="$MOD_DIR/maodie/scripts/NoAdsService.sh"
KERNEL_BIN="$MOD_DIR/maodie/kernel/Mihomo"
ADBLOCK_STATE="$MOD_DIR/maodie/config/adblock.state"
RECOVERY_SOURCE="$MOD_DIR/maodie/scripts/adblock-recovery.sh"
RECOVERY_SERVICE_SOURCE="$MOD_DIR/maodie/scripts/adblock-recovery-service.sh"
RECOVERY_DIR="/data/adb/maodie-launcher-recovery"
RECOVERY_STATE="$RECOVERY_DIR/adblock.state"
RECOVERY_SCRIPT="$RECOVERY_DIR/recover.sh"
RECOVERY_SERVICE="/data/adb/service.d/maodie-adblock-recovery.sh"

mkdir -p "$RUN_DIR" 2>/dev/null || {
    echo "Maodie uninstall: unable to create maintenance state." >&2
    exit 1
}
chmod 700 "$RUN_DIR" 2>/dev/null
if ! printf '%s\n' "uninstall:$$" > "$MAINTENANCE_FILE"; then
    echo "Maodie uninstall: unable to enter maintenance mode." >&2
    exit 1
fi
chmod 600 "$MAINTENANCE_FILE" 2>/dev/null

process_running() {
    process_match="$1"
    for process_dir in /proc/[0-9]*; do
        [ -r "$process_dir/cmdline" ] || continue
        process_pid=${process_dir#/proc/}
        [ "$process_pid" = "$$" ] && continue
        if grep -aFq "$process_match" "$process_dir/cmdline" 2>/dev/null; then
            return 0
        fi
    done
    return 1
}

signal_processes() {
    signal_name="$1"
    process_match="$2"
    for process_dir in /proc/[0-9]*; do
        [ -r "$process_dir/cmdline" ] || continue
        process_pid=${process_dir#/proc/}
        [ "$process_pid" = "$$" ] && continue
        grep -aFq "$process_match" "$process_dir/cmdline" 2>/dev/null || continue
        case "$signal_name" in
            TERM) kill -15 "$process_pid" 2>/dev/null ;;
            KILL) kill -9 "$process_pid" 2>/dev/null ;;
        esac
    done
}

stop_and_wait() {
    process_match="$1"
    process_label="$2"
    process_timeout="$3"

    signal_processes TERM "$process_match"
    process_waited=0
    while process_running "$process_match" && [ "$process_waited" -lt "$process_timeout" ]; do
        sleep 1
        process_waited=$((process_waited + 1))
    done

    if process_running "$process_match"; then
        echo "Maodie uninstall: $process_label did not stop gracefully; force killing." >&2
        signal_processes KILL "$process_match"
        sleep 1
    fi

    if process_running "$process_match"; then
        echo "Maodie uninstall: unable to stop $process_label." >&2
        return 1
    fi
    return 0
}

persist_adblock_recovery() {
    [ -s "$ADBLOCK_STATE" ] || [ -s "$RECOVERY_STATE" ] || return 0
    [ -f "$RECOVERY_SOURCE" ] && [ -f "$RECOVERY_SERVICE_SOURCE" ] || return 1

    mkdir -p "$RECOVERY_DIR" 2>/dev/null || return 1
    chmod 700 "$RECOVERY_DIR" 2>/dev/null || return 1

    # Install the standalone helper first. A crash can then leave an old ledger
    # with a usable helper, never a new ledger without recovery code.
    recovery_tmp="$RECOVERY_SCRIPT.tmp.$$"
    cp -f "$RECOVERY_SOURCE" "$recovery_tmp" 2>/dev/null || return 1
    chmod 700 "$recovery_tmp" 2>/dev/null || {
        rm -f "$recovery_tmp"
        return 1
    }
    mv -f "$recovery_tmp" "$RECOVERY_SCRIPT" || return 1

    if [ -s "$ADBLOCK_STATE" ]; then
        merged_state="$RECOVERY_DIR/adblock.state.tmp.$$"
        if [ -s "$RECOVERY_STATE" ]; then
            awk 'NF && !seen[$0]++ { print }' "$RECOVERY_STATE" "$ADBLOCK_STATE" > "$merged_state"
        else
            awk 'NF && !seen[$0]++ { print }' "$ADBLOCK_STATE" > "$merged_state"
        fi
        if [ "$?" -ne 0 ]; then
            rm -f "$merged_state"
            return 1
        fi
        chmod 600 "$merged_state" 2>/dev/null || {
            rm -f "$merged_state"
            return 1
        }
        mv -f "$merged_state" "$RECOVERY_STATE" || return 1
    fi

    mkdir -p /data/adb/service.d 2>/dev/null || return 1
    service_tmp="$RECOVERY_SERVICE.tmp.$$"
    cp -f "$RECOVERY_SERVICE_SOURCE" "$service_tmp" 2>/dev/null || return 1
    chmod 700 "$service_tmp" 2>/dev/null || {
        rm -f "$service_tmp"
        return 1
    }
    mv -f "$service_tmp" "$RECOVERY_SERVICE"
}

failed=0

# Stop restart-capable/background services before touching the core.
stop_and_wait "$SERVICE_SCRIPT" "boot service" 10 || failed=1
stop_and_wait "$MONITOR_SCRIPT" "watchdog" 10 || failed=1
stop_and_wait "$ADBLOCK_SCRIPT" "AdBlock service" 10 || failed=1
stop_and_wait "$RECOVERY_SERVICE" "old recovery launcher" 5 || failed=1
stop_and_wait "$RECOVERY_SCRIPT" "old recovery worker" 10 || failed=1
if ! process_running "$RECOVERY_SCRIPT"; then
    rm -rf "$RECOVERY_DIR/recovery.lock" 2>/dev/null
fi

# Let core.sh perform its normal process, firewall and sysctl cleanup first.
core_stop_status=1
if [ -f "$CORE_SCRIPT" ]; then
    core_attempt=0
    while [ "$core_attempt" -lt 3 ]; do
        if MAODIE_MOD_DIR="$MOD_DIR" sh "$CORE_SCRIPT" stop >/dev/null 2>&1; then
            core_stop_status=0
            break
        fi
        core_attempt=$((core_attempt + 1))
        sleep 1
    done
else
    echo "Maodie uninstall: core controller is missing; using process fallback." >&2
fi

# A failed/stale PID file or lock must not leave the deleted binary running.
if process_running "$KERNEL_BIN"; then
    stop_and_wait "$KERNEL_BIN" "Mihomo core" 5 || failed=1
fi

# Retry the controller after process fallback so network rules/sysctl are still cleared.
if [ -f "$CORE_SCRIPT" ]; then
    if MAODIE_MOD_DIR="$MOD_DIR" sh "$CORE_SCRIPT" stop >/dev/null 2>&1; then
        core_stop_status=0
    fi
fi
if process_running "$KERNEL_BIN"; then
    echo "Maodie uninstall: Mihomo is still running." >&2
    failed=1
fi
if [ "$core_stop_status" -ne 0 ]; then
    echo "Maodie uninstall: core/network cleanup did not complete successfully." >&2
    failed=1
fi

# Restore only paths owned by NoAdsService's write-ahead ledger. Persist a
# standalone copy first because root managers may delete this module regardless
# of uninstall.sh's exit status.
recovery_persist_failed=0
adblock_restore_failed=0
if ! persist_adblock_recovery; then
    echo "Maodie uninstall: unable to persist the external AdBlock recovery kit." >&2
    recovery_persist_failed=1
fi
if [ -f "$ADBLOCK_SCRIPT" ]; then
    if ! MAODIE_MOD_DIR="$MOD_DIR" sh "$ADBLOCK_SCRIPT" restore; then
        echo "Maodie uninstall: some AdBlock paths could not be restored; state was preserved." >&2
        adblock_restore_failed=1
        persist_adblock_recovery || recovery_persist_failed=1
    fi
else
    echo "Maodie uninstall: AdBlock restore controller is missing." >&2
    adblock_restore_failed=1
fi

# Also retry any ledger left by an earlier uninstall. A successful independent
# recovery proves that no immutable targets remain, even if the in-module pass failed.
if [ -s "$RECOVERY_STATE" ] && [ -x "$RECOVERY_SCRIPT" ]; then
    if sh "$RECOVERY_SCRIPT" && [ ! -s "$RECOVERY_STATE" ]; then
        adblock_restore_failed=0
        recovery_persist_failed=0
        rm -f "$RECOVERY_SCRIPT" 2>/dev/null
        rmdir "$RECOVERY_DIR" 2>/dev/null || true
    else
        adblock_restore_failed=1
        nohup sh "$RECOVERY_SCRIPT" --wait >> "$RECOVERY_DIR/recovery.log" 2>&1 &
    fi
fi
if [ "$adblock_restore_failed" -ne 0 ]; then
    failed=1
fi
# If a ledger remains, persistence is independently required even when the
# in-module pass happened to succeed. Otherwise the module can be deleted with
# no executable/boot entry capable of restoring the external ledger.
if [ "$recovery_persist_failed" -ne 0 ] && [ -s "$RECOVERY_STATE" ]; then
    echo "Maodie uninstall: recovery data could not be made persistent." >&2
    failed=1
fi

# Remove a stale launcher only after persistence/recovery decisions are done.
# Keeping the old entry through the write window preserves a cross-boot retry
# if uninstall is interrupted after the ledger is merged but before the new
# entry is atomically installed.
if [ ! -s "$RECOVERY_STATE" ]; then
    rm -f "$RECOVERY_SERVICE" 2>/dev/null
fi

# Close any last check-to-spawn window before returning to a manager that may
# immediately remove the module directory.
for final_process in "$SERVICE_SCRIPT" "$MONITOR_SCRIPT" "$ADBLOCK_SCRIPT" "$KERNEL_BIN"; do
    if process_running "$final_process"; then
        echo "Maodie uninstall: process survived final verification: $final_process" >&2
        failed=1
    fi
done

if [ "$failed" -ne 0 ]; then
    # Root managers may delete the module regardless of this exit status. The
    # independent recovery kit therefore lives outside the module directory.
    if [ -s "$RECOVERY_STATE" ] && [ -x "$RECOVERY_SCRIPT" ]; then
        echo "Maodie uninstall: recovery kit preserved at $RECOVERY_DIR" >&2
        echo "Run as root: sh $RECOVERY_SCRIPT" >&2
    fi
    echo "Maodie uninstall completed with recoverable errors." >&2
    exit 1
fi

# The module manager owns final deletion. Keeping maintenance set closes the race
# between this script returning and that unconditional deletion.
echo "Maodie services stopped and recorded AdBlock changes restored."
exit 0
