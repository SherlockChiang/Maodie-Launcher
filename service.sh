#!/system/bin/sh
# Maodie Launcher - Service Script

# 获取当前脚本所在的确切物理路径
MODDIR="$(dirname "$0")"
SCRIPT_DIR="$MODDIR/maodie/scripts"
LOG_FILE="$MODDIR/maodie/run/service.log"

# 初始化运行环境
mkdir -p "$MODDIR/maodie/run"
echo "--- Service Started at $(date) ---" > "$LOG_FILE"

# 1. 等待系统启动完成标志 (兼容旧标准)
# Magisk/KSU 的 late_start 阶段通常系统已启动，但加个保险是好习惯
echo "Waiting for boot_completed..." >> "$LOG_FILE"
until [ "$(getprop sys.boot_completed)" = "1" ]; do
  sleep 2
done

# 2. 网络栈检测 (通用)
echo "Checking loopback network..." >> "$LOG_FILE"
wait_count=0
while ! ping -c 1 -W 1 127.0.0.1 >/dev/null 2>&1; do
    sleep 1
    wait_count=$((wait_count+1))
    # 增加超时时间到 90秒，照顾老旧卡顿机型
    if [ $wait_count -gt 90 ]; then 
        echo "Warning: Network stack timeout! Forcing start anyway." >> "$LOG_FILE"
        break
    fi 
done

echo "System ready. Starting core and monitor..." >> "$LOG_FILE"

# 3. 权限上险，确保脚本可执行
chmod +x "$SCRIPT_DIR/core.sh" 2>/dev/null
chmod +x "$SCRIPT_DIR/monitor.sh" 2>/dev/null

# 4. 启动脚本
# 使用双引号包裹路径，后台静默执行
nohup "$SCRIPT_DIR/core.sh" start > /dev/null 2>&1 &
nohup "$SCRIPT_DIR/monitor.sh" > /dev/null 2>&1 &

echo "Service script finished successfully." >> "$LOG_FILE"