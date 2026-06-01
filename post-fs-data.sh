#!/system/bin/sh
# Maodie Launcher - Post-fs-data Script
# 注意：此阶段有严格超时限制（KernelSU ~30-40s），必须快速执行完毕

MODDIR="$(dirname "$0")"
PID_FILE="$MODDIR/maodie/run/kernel.pid"
LOCK_FILE="$MODDIR/maodie/run/adblock.lock"

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
rm -f "$MODDIR/maodie/run/monitor.lock"

# 4. 清理去广告服务锁文件
if [ -f "$LOCK_FILE" ]; then
    pid=$(cat "$LOCK_FILE" 2>/dev/null)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        kill -9 "$pid" 2>/dev/null
    fi
    rm -f "$LOCK_FILE"
fi

# 5. iptables 清理放到后台执行，避免阻塞 post-fs-data 阶段
{
    iptables -w 1 -D FORWARD -i "utun+" -j ACCEPT 2>/dev/null
    iptables -w 1 -D FORWARD -o "utun+" -j ACCEPT 2>/dev/null
    iptables -w 1 -t mangle -D PREROUTING -m mark --mark 2022 -j RETURN 2>/dev/null
    ip6tables -w 1 -D FORWARD -i "utun+" -j ACCEPT 2>/dev/null
    ip6tables -w 1 -D FORWARD -o "utun+" -j ACCEPT 2>/dev/null
} &
