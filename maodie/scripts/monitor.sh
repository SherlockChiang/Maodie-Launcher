#!/system/bin/sh
# monitor.sh - 看门狗：disable 监听 + 健康自愈
# 周期巡检，应对：
#   - Mihomo 内核被 OOM / 异常杀死           -> 重启内核
#   - system_server 运行时重启后 netd 冲掉    -> 检测 TUN 路由入口并重启核心
#     auto-route / ip rule，避免"核心存活但不走流量"
#   - 用户在管理器里 禁用/启用 模块            -> 跟随 disable 文件启停

umask 077

MOD_DIR="${MAODIE_MOD_DIR:-/data/adb/modules/Maodie-Launcher}"
export MAODIE_MOD_DIR="$MOD_DIR"
CORE_SCRIPT="$MOD_DIR/maodie/scripts/core.sh"
NETWORK_SCRIPT="$MOD_DIR/maodie/scripts/network.sh"
KERNEL_BIN="$MOD_DIR/maodie/kernel/Mihomo"
RUN_DIR="$MOD_DIR/maodie/run"
PID_FILE="$RUN_DIR/kernel.pid"
DISABLE_FILE="$MOD_DIR/disable"
REMOVE_FILE="$MOD_DIR/remove"
MAINTENANCE_FILE="$RUN_DIR/maintenance"
LOCK_DIR="$RUN_DIR/monitor.lock"
LOG="$RUN_DIR/monitor.log"
LOG_MAX=262144          # 256KB
KERNEL_LOG="$RUN_DIR/kernel.log"
KERNEL_LOG_MAX=${MAODIE_KERNEL_LOG_MAX:-524288}
CHECK_INTERVAL=${MAODIE_CHECK_INTERVAL:-60}
MAX_BACKOFF=${MAODIE_MAX_BACKOFF:-900}
SYSTEM_SERVER_STATE="$RUN_DIR/system_server.start_count"

case "$CHECK_INTERVAL" in *[!0-9]*|'') CHECK_INTERVAL=60 ;; esac
case "$MAX_BACKOFF" in *[!0-9]*|'') MAX_BACKOFF=900 ;; esac
case "$KERNEL_LOG_MAX" in *[!0-9]*|'') KERNEL_LOG_MAX=524288 ;; esac
[ "$CHECK_INTERVAL" -gt 0 ] 2>/dev/null || CHECK_INTERVAL=1
[ "$MAX_BACKOFF" -gt 0 ] 2>/dev/null || MAX_BACKOFF="$CHECK_INTERVAL"
[ "$KERNEL_LOG_MAX" -gt 0 ] 2>/dev/null || KERNEL_LOG_MAX=524288

mkdir -p "$RUN_DIR"
chmod 700 "$RUN_DIR" 2>/dev/null
chmod 600 "$LOG" "$LOG.old" "$KERNEL_LOG" "$KERNEL_LOG.old" \
    "$SYSTEM_SERVER_STATE" 2>/dev/null || true

proc_has_arg() {
    check_pid="$1"
    expected_arg="$2"
    [ -r "/proc/$check_pid/cmdline" ] || return 1
    tr '\000' '\n' < "/proc/$check_pid/cmdline" 2>/dev/null | grep -Fxq -- "$expected_arg"
}

script_alive() {
    check_pid="$1"
    [ -n "$check_pid" ] || return 1
    kill -0 "$check_pid" 2>/dev/null || return 1
    proc_has_arg "$check_pid" "$MOD_DIR/maodie/scripts/monitor.sh"
}

read_lock_pid() {
    if [ -d "$LOCK_DIR" ]; then
        cat "$LOCK_DIR/pid" 2>/dev/null
    elif [ -f "$LOCK_DIR" ]; then
        cat "$LOCK_DIR" 2>/dev/null
    fi
}

cleanup_lock() {
    lock_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null)
    [ "$lock_pid" = "$$" ] && rm -rf "$LOCK_DIR"
}

lock_attempts=0
while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    old_pid=$(read_lock_pid)
    if script_alive "$old_pid"; then
        exit 0
    fi

    # Do not steal the lock while another instance is between mkdir and
    # writing its owner PID.
    if [ -d "$LOCK_DIR" ] && [ -z "$old_pid" ] && [ "$lock_attempts" -lt 2 ]; then
        lock_attempts=$((lock_attempts + 1))
        sleep 1
        continue
    fi
    if [ -d "$LOCK_DIR" ]; then
        rm -rf "$LOCK_DIR"
    else
        rm -f "$LOCK_DIR"
    fi
done
echo $$ > "$LOCK_DIR/pid"
trap cleanup_lock EXIT
trap 'exit 0' INT TERM

log() {
    if [ -f "$LOG" ] && [ "$(wc -c < "$LOG" 2>/dev/null || echo 0)" -gt "$LOG_MAX" ]; then
        mv -f "$LOG" "$LOG.old"
    fi
    echo "$(date '+%m-%d %H:%M:%S'): $1" >> "$LOG"
    chmod 600 "$LOG" 2>/dev/null
}

trim_kernel_log() {
    [ -f "$KERNEL_LOG" ] || return 0
    kernel_log_size=$(wc -c < "$KERNEL_LOG" 2>/dev/null || echo 0)
    [ "$kernel_log_size" -gt "$KERNEL_LOG_MAX" ] 2>/dev/null || return 0

    kernel_log_tmp="$RUN_DIR/.kernel.log.tail"
    if ! tail -c "$KERNEL_LOG_MAX" "$KERNEL_LOG" > "$kernel_log_tmp" 2>/dev/null; then
        rm -f "$kernel_log_tmp" 2>/dev/null
        return 1
    fi
    chmod 600 "$kernel_log_tmp" 2>/dev/null

    # Mihomo opens stdout with O_APPEND. Truncate the same inode, then append
    # the retained tail so the long-running writer follows the new size.
    if : > "$KERNEL_LOG" 2>/dev/null; then
        cat "$kernel_log_tmp" >> "$KERNEL_LOG" 2>/dev/null
        chmod 600 "$KERNEL_LOG" 2>/dev/null
    fi
    rm -f "$kernel_log_tmp" 2>/dev/null
}

# Mihomo 是否存活（PID 文件 + cmdline 校验，防重启后 PID 被复用误判）
mihomo_alive() {
    [ -f "$PID_FILE" ] || return 1
    pid=$(cat "$PID_FILE" 2>/dev/null)
    [ -n "$pid" ] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    proc_has_arg "$pid" "$KERNEL_BIN" || return 1
    ! proc_has_arg "$pid" '-t'
}

read_system_server_start_count() {
    getprop sys.system_server.start_count 2>/dev/null
}

current_boot_id() {
    if [ -r /proc/sys/kernel/random/boot_id ]; then
        cat /proc/sys/kernel/random/boot_id 2>/dev/null
        return
    fi
    stat -c '%Y' /proc/1 2>/dev/null
}

system_server_restarted() {
    current_count=$(read_system_server_start_count)
    current_boot=$(current_boot_id)
    [ -n "$current_count" ] || return 1

    if [ ! -f "$SYSTEM_SERVER_STATE" ]; then
        printf '%s|%s\n' "$current_boot" "$current_count" > "$SYSTEM_SERVER_STATE" 2>/dev/null
        return 1
    fi

    state=$(cat "$SYSTEM_SERVER_STATE" 2>/dev/null)
    # Android's mksh treats `|` as an extended-pattern operator inside
    # ${value%%pattern}; split the persisted pair explicitly instead.
    saved_ifs=$IFS
    IFS='|'
    read -r last_boot last_count <<EOF
$state
EOF
    IFS=$saved_ifs
    if [ "$last_boot" != "$current_boot" ]; then
        printf '%s|%s\n' "$current_boot" "$current_count" > "$SYSTEM_SERVER_STATE" 2>/dev/null
        return 1
    fi

    if [ "$current_count" != "$last_count" ]; then
        printf '%s|%s\n' "$current_boot" "$current_count" > "$SYSTEM_SERVER_STATE" 2>/dev/null
        return 0
    fi

    return 1
}

network_route_healthy() {
    [ -r "$NETWORK_SCRIPT" ] || return 1
    sh "$NETWORK_SCRIPT" route-check >/dev/null 2>&1
}

network_rules_healthy() {
    [ -r "$NETWORK_SCRIPT" ] || return 1
    sh "$NETWORK_SCRIPT" check >/dev/null 2>&1
}

log "Watchdog started (PID $$), interval ${CHECK_INTERVAL}s."
route_failures=0
start_failures=0
inactive_cleaned=0

while :; do
    next_sleep=$CHECK_INTERVAL
    trim_kernel_log
    if [ -f "$DISABLE_FILE" ] || [ -f "$REMOVE_FILE" ] || [ -f "$MAINTENANCE_FILE" ]; then
        # stop is intentionally idempotent: even with a stale/missing PID it
        # clears this module's process, network rules and sysctl snapshot.
        terminal_inactive=0
        if [ -f "$MAINTENANCE_FILE" ]; then
            inactive_reason="maintenance"
            terminal_inactive=1
        elif [ -f "$REMOVE_FILE" ]; then
            inactive_reason="scheduled removal"
            terminal_inactive=1
        else
            inactive_reason="module disabled"
        fi

        if [ "$terminal_inactive" -eq 1 ] || [ "$inactive_cleaned" -ne 1 ] || mihomo_alive; then
            log "Inactive state detected ($inactive_reason), enforcing stop."
            if sh "$CORE_SCRIPT" stop >> "$LOG" 2>&1; then
                inactive_cleaned=1
            else
                inactive_cleaned=0
                if [ "$terminal_inactive" -eq 1 ]; then
                    log "Stop reported incomplete cleanup; terminal lifecycle will continue."
                else
                    log "Stop did not complete; will retry."
                fi
            fi
            if [ "$terminal_inactive" -eq 1 ]; then
                # Removal is terminal for this watchdog. Do not remain alive
                # after the module directory disappears, even when cleanup
                # reported a best-effort firewall failure.
                log "Terminal inactive state handled; watchdog exiting."
                exit 0
            fi
        fi
        route_failures=0
        start_failures=0
    else
        inactive_cleaned=0
        if ! mihomo_alive; then
        # 进程不在（异常退出 / 被杀）：重启（core.sh start 会一并铺好规则）
            log "Mihomo not running, (re)starting core."
            if sh "$CORE_SCRIPT" start >> "$LOG" 2>&1; then
                start_failures=0
            else
                [ "$start_failures" -lt 4 ] && start_failures=$((start_failures + 1))
                next_sleep=$((CHECK_INTERVAL * (1 << start_failures)))
                [ "$next_sleep" -gt "$MAX_BACKOFF" ] && next_sleep=$MAX_BACKOFF
                log "Core start failed (${start_failures}), retrying in ${next_sleep}s."
            fi
            route_failures=0
        elif system_server_restarted; then
            # netd may rebuild routing/firewall state while Mihomo remains
            # alive. Restart only if auto-route health is actually lost.
            if ! network_route_healthy; then
                log "system_server restart removed TUN routing; restarting core."
                sh "$CORE_SCRIPT" restart >> "$LOG" 2>&1
            elif ! sh "$CORE_SCRIPT" reapply >> "$LOG" 2>&1; then
                log "Network reapply failed after system_server restart; restarting core."
                sh "$CORE_SCRIPT" restart >> "$LOG" 2>&1
            else
                log "system_server restart detected; module rules reapplied."
            fi
            route_failures=0
        elif ! network_route_healthy; then
            route_failures=$((route_failures + 1))
            if [ "$route_failures" -ge 3 ]; then
                log "TUN routing unhealthy for ${route_failures} checks, restarting core."
                sh "$CORE_SCRIPT" restart >> "$LOG" 2>&1
                route_failures=0
            fi
        elif ! network_rules_healthy; then
            log "Module firewall rules missing, reapplying."
            if ! sh "$CORE_SCRIPT" reapply >> "$LOG" 2>&1; then
                log "Network reapply failed; restarting core."
                sh "$CORE_SCRIPT" restart >> "$LOG" 2>&1
            fi
            route_failures=0
        else
            route_failures=0
            start_failures=0
        fi
    fi
    sleep "$next_sleep"
done
