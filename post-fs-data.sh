#!/system/bin/sh
# Maodie Launcher - Post-fs-data Script
# 注意：此阶段有严格超时限制（KernelSU ~30-40s），必须快速执行完毕

umask 077

MODDIR="${MAODIE_MOD_DIR:-$(dirname "$0")}"
export MAODIE_MOD_DIR="$MODDIR"
KERNEL_BIN="$MODDIR/maodie/kernel/Mihomo"
PID_FILE="$MODDIR/maodie/run/kernel.pid"
ADB_LOCK="$MODDIR/maodie/run/adblock.lock"
MONITOR_LOCK="$MODDIR/maodie/run/monitor.lock"
NETWORK_SCRIPT="$MODDIR/maodie/scripts/network.sh"

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
    [ -r "/proc/$check_pid/cmdline" ] && grep -aFq "$script_name" "/proc/$check_pid/cmdline" 2>/dev/null
}

kernel_alive() {
    check_pid="$1"
    [ -n "$check_pid" ] || return 1
    kill -0 "$check_pid" 2>/dev/null || return 1
    [ -r "/proc/$check_pid/cmdline" ] && grep -aFq "$KERNEL_BIN" "/proc/$check_pid/cmdline" 2>/dev/null
}

# 1. 通过 PID 文件停止上次残留的内核进程
if [ -f "$PID_FILE" ]; then
    pid=$(cat "$PID_FILE" 2>/dev/null)
    if kernel_alive "$pid"; then
        kill -9 "$pid" 2>/dev/null
    fi
    rm -f "$PID_FILE"
fi

# 2. 兜底：仅清理本模块核心，避免误伤其它 Mihomo 实例
pkill -9 -f "$KERNEL_BIN" 2>/dev/null || true

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

# 5. 网络清理由单一控制器负责；后台执行以满足 post-fs-data 时限。
if [ -r "$NETWORK_SCRIPT" ]; then
    sh "$NETWORK_SCRIPT" clear >/dev/null 2>&1 &
fi
