#!/system/bin/sh
# monitor.sh - 修正版 inotifyd (实时热重载守护)

MOD_DIR="/data/adb/modules/Maodie-Launcher"
CORE_SCRIPT="$MOD_DIR/maodie/scripts/core.sh"
CONTROL_FILE="disable"
DEBUG_LOG="$MOD_DIR/maodie/run/monitor.log"

# 确保日志目录存在
mkdir -p "$MOD_DIR/maodie/run"

echo "$(date): Monitor started." >> "$DEBUG_LOG"

# 检查 busybox inotifyd 是否可用
if ! busybox inotifyd --help >/dev/null 2>&1; then
    echo "$(date): Error: busybox inotifyd not available. Monitor exiting." >> "$DEBUG_LOG"
    exit 1
fi

# 清理旧的 inotifyd 进程（仅匹配本模块路径）
pkill -f "inotifyd - $MOD_DIR" 2>/dev/null
sleep 1

busybox inotifyd - "$MOD_DIR" | while read -r events dir file; do
    if [ "$file" = "$CONTROL_FILE" ]; then
        case "$events" in
            *n*|*w*|*c*)
                echo "$(date): Module disabled by user. Stopping core..." >> "$DEBUG_LOG"
                sh "$CORE_SCRIPT" stop
                ;;
            *d*)
                echo "$(date): Module enabled by user. Starting core..." >> "$DEBUG_LOG"
                sh "$CORE_SCRIPT" start
                ;;
        esac
    fi
done &

echo "$(date): inotifyd watcher launched (PID: $!)." >> "$DEBUG_LOG"