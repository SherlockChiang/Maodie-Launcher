#!/system/bin/sh
# Maodie Launcher - Service Script

# 获取当前脚本所在的确切物理路径
MODDIR="$(dirname "$0")"
SCRIPT_DIR="$MODDIR/maodie/scripts"
LOG_FILE="$MODDIR/maodie/run/service.log"
LOG_MAX_SIZE=262144
KERNEL_BIN="$MODDIR/maodie/kernel/Mihomo"

# 初始化运行环境
mkdir -p "$MODDIR/maodie/run"
chmod 700 "$MODDIR/maodie/run" 2>/dev/null

if [ -f "$LOG_FILE" ] && [ "$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)" -gt "$LOG_MAX_SIZE" ]; then
    mv -f "$LOG_FILE" "$LOG_FILE.old"
fi
echo "--- Service Started at $(date) ---" >> "$LOG_FILE"
chmod 600 "$LOG_FILE" 2>/dev/null

# 清理上次关机前残留的 PID 文件（重启后 PID 可能被其它进程复用，避免误判"已运行"）
rm -f "$MODDIR/maodie/run/kernel.pid"

# 0. 前置检查：核心二进制和配置文件是否存在
if [ ! -f "$KERNEL_BIN" ]; then
    echo "FATAL: Kernel binary missing: $KERNEL_BIN" >> "$LOG_FILE"
    exit 1
fi
if [ ! -f "$MODDIR/maodie/config/config.yaml" ]; then
    echo "FATAL: Config file missing." >> "$LOG_FILE"
    exit 1
fi

# 1. 等待系统启动完成标志 (兼容旧标准)
echo "Waiting for boot_completed..." >> "$LOG_FILE"
until [ "$(getprop sys.boot_completed)" = "1" ]; do
  sleep 2
done
echo "Boot completed." >> "$LOG_FILE"

# 1.5 等待系统服务完全稳定（避免 TUN 接口创建干扰 WifiNative 等系统组件）
sleep 10
echo "Post-boot delay done." >> "$LOG_FILE"

# 2. 网络栈检测 (通用)
echo "Checking loopback network..." >> "$LOG_FILE"
wait_count=0
while ! ping -c 1 -W 1 127.0.0.1 >/dev/null 2>&1; do
    sleep 1
    wait_count=$((wait_count+1))
    if [ $wait_count -gt 30 ]; then
        echo "Warning: Network stack timeout! Forcing start anyway." >> "$LOG_FILE"
        break
    fi
done

echo "System ready. Starting core and monitor..." >> "$LOG_FILE"

# 3. 确保脚本可执行
chmod +x "$SCRIPT_DIR/core.sh" 2>/dev/null
chmod +x "$SCRIPT_DIR/monitor.sh" 2>/dev/null
chmod +x "$SCRIPT_DIR/NoAdsService.sh" 2>/dev/null

# 3.5 SELinux 兼容处理
if command -v getenforce >/dev/null 2>&1; then
    SELINUX_STATUS=$(getenforce 2>/dev/null)
    echo "SELinux status: $SELINUX_STATUS" >> "$LOG_FILE"
    if [ "$SELINUX_STATUS" = "Enforcing" ]; then
        # 为 Mihomo 二进制设置可执行上下文
        chcon u:object_r:system_file:s0 "$KERNEL_BIN" 2>/dev/null
        for script in "$SCRIPT_DIR/core.sh" "$SCRIPT_DIR/monitor.sh" "$SCRIPT_DIR/NoAdsService.sh"; do
            chcon u:object_r:system_file:s0 "$script" 2>/dev/null
        done
        echo "SELinux contexts applied." >> "$LOG_FILE"
    fi
fi

# 4. 启动核心（后台执行，避免阻塞 service 阶段）
nohup sh "$SCRIPT_DIR/core.sh" start >> "$LOG_FILE" 2>&1 &

# 5. 启动监控和去广告服务（后台）
nohup sh "$SCRIPT_DIR/monitor.sh" >> "$LOG_FILE" 2>&1 &
nohup sh "$SCRIPT_DIR/NoAdsService.sh" >> "$LOG_FILE" 2>&1 &

echo "--- Service script finished at $(date) ---" >> "$LOG_FILE"
