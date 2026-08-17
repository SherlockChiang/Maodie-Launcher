#!/system/bin/sh
# Maodie Launcher - Service Script

umask 077

MODDIR="${MAODIE_MOD_DIR:-$(dirname "$0")}"
SCRIPT_DIR="$MODDIR/maodie/scripts"
RUN_DIR="$MODDIR/maodie/run"
LOG_FILE="$RUN_DIR/service.log"
LOG_MAX_SIZE=262144
KERNEL_BIN="$MODDIR/maodie/kernel/Mihomo"
CONFIG_FILE="$MODDIR/maodie/config/config.yaml"
MAINTENANCE_FILE="$RUN_DIR/maintenance"
DISABLE_FILE="$MODDIR/disable"
SERVICE_LOCK="$RUN_DIR/service.lock"
BOOT_ID_FILE="$RUN_DIR/boot.id"
BOOT_TIMEOUT="${MAODIE_BOOT_TIMEOUT:-180}"
POST_BOOT_DELAY="${MAODIE_POST_BOOT_DELAY:-10}"

case "$BOOT_TIMEOUT" in
    ''|*[!0-9]*) BOOT_TIMEOUT=180 ;;
esac
case "$POST_BOOT_DELAY" in
    ''|*[!0-9]*) POST_BOOT_DELAY=10 ;;
esac

mkdir -p "$RUN_DIR" || exit 1
chmod 700 "$RUN_DIR" 2>/dev/null

rotate_log() {
    if [ -f "$LOG_FILE" ] && [ "$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)" -gt "$LOG_MAX_SIZE" ]; then
        mv -f "$LOG_FILE" "$LOG_FILE.old" 2>/dev/null
    fi
}

log() {
    rotate_log
    echo "$(date '+%m-%d %H:%M:%S'): $1" >> "$LOG_FILE"
    chmod 600 "$LOG_FILE" 2>/dev/null
}

service_pid_alive() {
    check_pid="$1"
    [ -n "$check_pid" ] || return 1
    kill -0 "$check_pid" 2>/dev/null || return 1
    [ -r "/proc/$check_pid/cmdline" ] \
        && grep -aFq "$MODDIR/service.sh" "/proc/$check_pid/cmdline" 2>/dev/null
}

cleanup_service_lock() {
    lock_pid=$(cat "$SERVICE_LOCK/pid" 2>/dev/null)
    [ "$lock_pid" = "$$" ] && rm -rf "$SERVICE_LOCK"
}

acquire_service_lock() {
    attempts=0
    while ! mkdir "$SERVICE_LOCK" 2>/dev/null; do
        old_pid=$(cat "$SERVICE_LOCK/pid" 2>/dev/null)
        if service_pid_alive "$old_pid"; then
            return 1
        fi

        # mkdir 与 pid 写入之间有一个很短的窗口，先给可能的创建者一次机会。
        if [ -d "$SERVICE_LOCK" ] && [ -z "$old_pid" ] && [ "$attempts" -lt 2 ]; then
            attempts=$((attempts + 1))
            sleep 1
            continue
        fi

        rm -rf "$SERVICE_LOCK" 2>/dev/null
    done
    echo $$ > "$SERVICE_LOCK/pid" || {
        rm -rf "$SERVICE_LOCK"
        return 1
    }
    return 0
}

read_boot_id() {
    if [ -r /proc/sys/kernel/random/boot_id ]; then
        IFS= read -r boot_id < /proc/sys/kernel/random/boot_id
        printf '%s' "$boot_id"
        return
    fi

    # 极旧内核的保守回退；Android/Linux 正常均提供 boot_id。
    awk '$1 == "btime" { print "btime:" $2; exit }' /proc/stat 2>/dev/null
}

if ! acquire_service_lock; then
    # 同一 boot 的重复 service 调用不应再次拉起核心或看门狗。
    exit 0
fi
trap cleanup_service_lock EXIT
trap 'exit 0' INT TERM

log "Service invocation started (PID $$)."

if [ -f "$MAINTENANCE_FILE" ]; then
    log "Maintenance marker present; startup skipped."
    exit 0
fi

current_boot_id=$(read_boot_id)
previous_boot_id=$(cat "$BOOT_ID_FILE" 2>/dev/null)
if [ -n "$current_boot_id" ]; then
    if [ "$current_boot_id" != "$previous_boot_id" ]; then
        log "New boot detected; clearing cross-boot runtime state."
        rm -f "$RUN_DIR/kernel.pid" \
            "$RUN_DIR/sysctl.state" \
            "$RUN_DIR/system_server.start_count" \
            "$RUN_DIR/iptables_wait.mode" 2>/dev/null
    else
        log "Same boot detected; preserving PID and sysctl state."
    fi

    boot_tmp="$BOOT_ID_FILE.tmp.$$"
    if printf '%s\n' "$current_boot_id" > "$boot_tmp"; then
        mv -f "$boot_tmp" "$BOOT_ID_FILE"
        chmod 600 "$BOOT_ID_FILE" 2>/dev/null
    else
        rm -f "$boot_tmp"
        log "Warning: unable to persist boot identity."
    fi
else
    log "Warning: boot identity unavailable; preserving runtime state."
fi

if [ ! -f "$KERNEL_BIN" ]; then
    log "FATAL: Kernel binary missing: $KERNEL_BIN"
    exit 1
fi
if [ ! -f "$CONFIG_FILE" ]; then
    log "FATAL: Config file missing: $CONFIG_FILE"
    exit 1
fi

log "Waiting for boot_completed (timeout ${BOOT_TIMEOUT}s)."
waited=0
while [ "$(getprop sys.boot_completed 2>/dev/null)" != "1" ]; do
    if [ -f "$MAINTENANCE_FILE" ]; then
        log "Maintenance requested while waiting for boot; startup skipped."
        exit 0
    fi
    if [ "$waited" -ge "$BOOT_TIMEOUT" ]; then
        log "Warning: boot_completed timeout; continuing cautiously after the bounded wait."
        break
    fi
    sleep 2
    waited=$((waited + 2))
done
if [ "$(getprop sys.boot_completed 2>/dev/null)" = "1" ]; then
    log "Boot completed."
else
    log "Boot completion was not observed; proceeding in compatibility mode."
fi

if [ "$POST_BOOT_DELAY" -gt 0 ]; then
    sleep "$POST_BOOT_DELAY"
fi

if [ -f "$MAINTENANCE_FILE" ]; then
    log "Maintenance requested during post-boot delay; startup skipped."
    exit 0
fi

chmod +x "$SCRIPT_DIR/core.sh" 2>/dev/null
chmod +x "$SCRIPT_DIR/monitor.sh" 2>/dev/null
chmod +x "$SCRIPT_DIR/NoAdsService.sh" 2>/dev/null
chmod +x "$SCRIPT_DIR/configctl.sh" 2>/dev/null
chmod +x "$SCRIPT_DIR/network.sh" 2>/dev/null

if command -v getenforce >/dev/null 2>&1; then
    SELINUX_STATUS=$(getenforce 2>/dev/null)
    log "SELinux status: $SELINUX_STATUS"
    if [ "$SELINUX_STATUS" = "Enforcing" ]; then
        chcon u:object_r:system_file:s0 "$KERNEL_BIN" 2>/dev/null
        for script in "$SCRIPT_DIR/core.sh" "$SCRIPT_DIR/monitor.sh" "$SCRIPT_DIR/NoAdsService.sh" "$SCRIPT_DIR/configctl.sh" "$SCRIPT_DIR/network.sh"; do
            chcon u:object_r:system_file:s0 "$script" 2>/dev/null
        done
    fi
fi

if [ -f "$DISABLE_FILE" ]; then
    log "Module is disabled; core startup skipped."
else
    if ! sh "$SCRIPT_DIR/core.sh" start >> "$LOG_FILE" 2>&1; then
        log "Core failed to start; watchdog will retry with backoff."
    fi
fi

# monitor/NoAdsService use their own locks. Starting them again is harmless,
# while keeping them alive permits KernelSU-style disable/enable transitions.
if [ ! -f "$MAINTENANCE_FILE" ]; then
    nohup sh "$SCRIPT_DIR/monitor.sh" >> "$LOG_FILE" 2>&1 &
    if [ -f "$MODDIR/maodie/config/adblock.enabled" ]; then
        nohup sh "$SCRIPT_DIR/NoAdsService.sh" >> "$LOG_FILE" 2>&1 &
    else
        log "AdBlock disabled (opt-in marker not found); restoring recorded changes."
        if ! sh "$SCRIPT_DIR/NoAdsService.sh" restore >> "$LOG_FILE" 2>&1; then
            log "AdBlock recovery is pending user unlock; starting a retry worker."
            nohup sh "$SCRIPT_DIR/NoAdsService.sh" restore-loop >> "$LOG_FILE" 2>&1 &
        fi
    fi
fi

log "Service invocation finished."
