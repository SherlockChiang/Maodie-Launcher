#!/system/bin/sh
# Maodie Launcher - Post-fs-data Script
# 注意：此阶段有严格超时限制（KernelSU ~30-40s），必须快速执行完毕

MODDIR="$(dirname "$0")"
PID_FILE="$MODDIR/maodie/run/kernel.pid"
ADB_LOCK="$MODDIR/maodie/run/adblock.lock"
MONITOR_LOCK="$MODDIR/maodie/run/monitor.lock"

read_lock_pid() {
    lock_path="$1"
    if [ -d "$lock_path" ]; then
        cat "$lock_path/pid" 2>/dev/null
    elif [ -f "$lock_path" ]; then
        cat "$lock_path" 2>/dev/null
    fi
}

remove_lock() {
    lock_path="$1"
    if [ -d "$lock_path" ]; then
        rm -rf "$lock_path"
    else
        rm -f "$lock_path"
    fi
}

script_alive() {
    check_pid="$1"
    script_name="$2"
    [ -n "$check_pid" ] || return 1
    kill -0 "$check_pid" 2>/dev/null || return 1
    [ -r "/proc/$check_pid/cmdline" ] && grep -aq "$script_name" "/proc/$check_pid/cmdline" 2>/dev/null
}

# 1. 通过 PID 文件停止上次残留的内核进程
if [ -f "$PID_FILE" ]; then
    pid=$(cat "$PID_FILE" 2>/dev/null)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        kill -9 "$pid" 2>/dev/null
    fi
    rm -f "$PID_FILE"
fi

# 2. 兜底：用 pkill 清理所有 Mihomo 进程（替代耗时的 /proc 遍历）
pkill -9 -f "Mihomo" 2>/dev/null || true

# 3. 清理上次残留的监控看门狗进程及其 lock
pkill -f "$MODDIR/maodie/scripts/monitor.sh" 2>/dev/null
remove_lock "$MONITOR_LOCK"

# 4. 清理去广告服务锁文件
if [ -d "$ADB_LOCK" ] || [ -f "$ADB_LOCK" ]; then
    pid=$(read_lock_pid "$ADB_LOCK")
    if script_alive "$pid" "NoAdsService.sh"; then
        kill -9 "$pid" 2>/dev/null
    fi
    remove_lock "$ADB_LOCK"
fi

# 5. iptables 清理放到后台执行，避免阻塞 post-fs-data 阶段
{
    iptables -w 1 -D FORWARD -i "utun+" -j ACCEPT 2>/dev/null
    iptables -w 1 -D FORWARD -o "utun+" -j ACCEPT 2>/dev/null
    iptables -w 1 -t mangle -D PREROUTING -m mark --mark 2022 -j RETURN 2>/dev/null
    ip6tables -w 1 -D FORWARD -i "utun+" -j ACCEPT 2>/dev/null
    ip6tables -w 1 -D FORWARD -o "utun+" -j ACCEPT 2>/dev/null
} &
