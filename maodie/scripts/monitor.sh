#!/system/bin/sh
# monitor.sh - 修正版 inotifyd (管道模式)

# --- 变量定义 ---
MOD_DIR="/data/adb/modules/Maodie-Launcher"
CORE_SCRIPT="$MOD_DIR/maodie/scripts/core.sh"
CONTROL_FILE="disable"
# 添加一个简易日志，用于调试（确认监控是否生效）
DEBUG_LOG="$MOD_DIR/maodie/run/monitor.log"

# --- 清理旧进程 ---
# 防止重复运行导致冲突
pkill -f "inotifyd - $MOD_DIR" 2>/dev/null

# --- 启动监控 (Pipeline 模式) ---
# 解释: inotifyd - DIR 监听目录，将变动输出到标准输出
#       | while read ... 读取这些输出并执行逻辑
#       & 放入后台运行

inotifyd - "$MOD_DIR" | while read events dir file; do
    # 调试日志: 记录所有捕捉到的事件 (确认生效后可注释掉)
    # echo "$(date) Event:[$events] File:[$file]" >> "$DEBUG_LOG"

    # 只关心 disable 文件
    if [ "$file" = "$CONTROL_FILE" ]; then
        
        # 事件处理
        case "$events" in
            "n"|"w") 
                # n = Create (创建), w = Write Close (写入完成)
                # KSU 创建文件通常是 'n'，但也可能是 'w'，写在一起更稳健
                sh "$CORE_SCRIPT" stop
                ;;
            "d") 
                # d = Delete (删除)
                sh "$CORE_SCRIPT" start
                ;;
        esac
    fi
done &