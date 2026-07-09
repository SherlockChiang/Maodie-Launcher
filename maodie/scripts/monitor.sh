#!/system/bin/sh
# monitor.sh - 看门狗：disable 监听 + 健康自愈
# 周期巡检，应对：
#   - Mihomo 内核被 OOM / 异常杀死           -> 重启内核
#   - system_server 运行时重启后 netd 冲掉    -> 检测 TUN 路由入口并重启核心
#     auto-route / ip rule，避免"核心存活但不走流量"
#   - 用户在管理器里 禁用/启用 模块            -> 跟随 disable 文件启停

MOD_DIR="/data/adb/modules/Maodie-Launcher"
CORE_SCRIPT="$MOD_DIR/maodie/scripts/core.sh"
RUN_DIR="$MOD_DIR/maodie/run"
PID_FILE="$RUN_DIR/kernel.pid"
DISABLE_FILE="$MOD_DIR/disable"
LOCK_DIR="$RUN_DIR/monitor.lock"
LOG="$RUN_DIR/monitor.log"
LOG_MAX=262144          # 256KB
CHECK_INTERVAL=30       # 巡检间隔（秒）
SYSTEM_SERVER_STATE="$RUN_DIR/system_server.start_count"
TUN_IFACE="utun"
TUN_TABLE="2022"

mkdir -p "$RUN_DIR"

script_alive() {
    check_pid="$1"
    [ -n "$check_pid" ] || return 1
    kill -0 "$check_pid" 2>/dev/null || return 1
    [ -r "/proc/$check_pid/cmdline" ] && grep -aq "monitor.sh" "/proc/$check_pid/cmdline" 2>/dev/null
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

while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    old_pid=$(read_lock_pid)
    if script_alive "$old_pid"; then
        exit 0
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
}

# Mihomo 是否存活（PID 文件 + cmdline 校验，防重启后 PID 被复用误判）
mihomo_alive() {
    [ -f "$PID_FILE" ] || return 1
    pid=$(cat "$PID_FILE" 2>/dev/null)
    [ -n "$pid" ] || return 1
    [ -r "/proc/$pid/cmdline" ] && grep -aq "Mihomo" "/proc/$pid/cmdline" 2>/dev/null
}

read_system_server_start_count() {
    getprop sys.system_server.start_count 2>/dev/null
}

system_server_restarted() {
    current_count=$(read_system_server_start_count)
    [ -n "$current_count" ] || return 1

    if [ ! -f "$SYSTEM_SERVER_STATE" ]; then
        echo "$current_count" > "$SYSTEM_SERVER_STATE" 2>/dev/null
        return 1
    fi

    last_count=$(cat "$SYSTEM_SERVER_STATE" 2>/dev/null)
    if [ "$current_count" != "$last_count" ]; then
        echo "$current_count" > "$SYSTEM_SERVER_STATE" 2>/dev/null
        return 0
    fi

    return 1
}

tun_route_healthy() {
    [ -d "/sys/class/net/$TUN_IFACE" ] || return 1

    ip route show table "$TUN_TABLE" 2>/dev/null | grep -q "default dev $TUN_IFACE" || return 1
    ip rule show 2>/dev/null | grep -q "lookup $TUN_TABLE" || return 1

    if [ -f /proc/net/if_inet6 ] && ip -6 rule show 2>/dev/null | grep -q "lookup $TUN_TABLE"; then
        ip -6 route show table "$TUN_TABLE" 2>/dev/null | grep -q "default dev $TUN_IFACE" || return 1
    fi

    return 0
}

log "Watchdog started (PID $$), interval ${CHECK_INTERVAL}s."

while :; do
    if [ -f "$DISABLE_FILE" ]; then
        # 用户已在管理器禁用：确保内核停止
        if mihomo_alive; then
            log "Module disabled by user, stopping core."
            sh "$CORE_SCRIPT" stop
        fi
    elif ! mihomo_alive; then
        # 进程不在（异常退出 / 被杀）：重启（core.sh start 会一并铺好规则）
        log "Mihomo not running, (re)starting core."
        sh "$CORE_SCRIPT" start
    elif system_server_restarted; then
        # framework 软重启会让 netd/connectivity 重建网络状态，Mihomo 进程可能还活着但 auto-route 入口丢失。
        log "system_server restart detected, restarting core to restore TUN routing."
        sh "$CORE_SCRIPT" restart
    elif ! tun_route_healthy; then
        # 进程和 utun 残留不代表流量仍被接管；缺 ip rule/table 入口时需要重启核心重建 auto-route。
        log "TUN routing unhealthy, restarting core to rebuild auto-route."
        sh "$CORE_SCRIPT" restart
    else
        # 进程健在：幂等重铺路由/规则。规则被 netd 冲掉时自动恢复，在位时是空操作。
        sh "$CORE_SCRIPT" reapply
    fi
    sleep "$CHECK_INTERVAL"
done
