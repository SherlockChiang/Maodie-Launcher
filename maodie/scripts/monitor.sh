#!/system/bin/sh
# monitor.sh - 看门狗：disable 监听 + 健康自愈
# 周期巡检，应对：
#   - Mihomo 内核被 OOM / 异常杀死           -> 重启内核
#   - system_server 运行时重启后 netd 冲掉    -> 幂等重铺 iptables/sysctl 规则
#     iptables 规则导致"模块失效"
#   - 用户在管理器里 禁用/启用 模块            -> 跟随 disable 文件启停

MOD_DIR="/data/adb/modules/Maodie-Launcher"
CORE_SCRIPT="$MOD_DIR/maodie/scripts/core.sh"
RUN_DIR="$MOD_DIR/maodie/run"
PID_FILE="$RUN_DIR/kernel.pid"
DISABLE_FILE="$MOD_DIR/disable"
LOCK_FILE="$RUN_DIR/monitor.lock"
LOG="$RUN_DIR/monitor.log"
LOG_MAX=262144          # 256KB
CHECK_INTERVAL=30       # 巡检间隔（秒）

mkdir -p "$RUN_DIR"

# 单实例保护（与 NoAdsService 一致的 lock 文件方式）
if [ -f "$LOCK_FILE" ]; then
    old_pid=$(cat "$LOCK_FILE" 2>/dev/null)
    if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
        exit 0
    fi
fi
echo $$ > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"; exit 0' INT TERM

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
    else
        # 进程健在：幂等重铺路由/规则。规则被 netd 冲掉时自动恢复，在位时是空操作。
        sh "$CORE_SCRIPT" reapply
    fi
    sleep "$CHECK_INTERVAL"
done
