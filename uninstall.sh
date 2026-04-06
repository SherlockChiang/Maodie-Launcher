#!/system/bin/sh
# Maodie Launcher - Uninstall Script

MOD_DIR="/data/adb/modules/Maodie-Launcher"
CORE_SCRIPT="$MOD_DIR/maodie/scripts/core.sh"

# 1. 停止内核进程并清理 iptables 规则
if [ -x "$CORE_SCRIPT" ]; then
    sh "$CORE_SCRIPT" stop 2>/dev/null
else
    killall -15 Mihomo 2>/dev/null
    sleep 1
    killall -9 Mihomo 2>/dev/null
fi

# 2. 停止监控和去广告服务
pkill -f "inotifyd - $MOD_DIR" 2>/dev/null
pkill -f "NoAdsService.sh" 2>/dev/null

# 3. 移除模块目录
rm -rf "$MOD_DIR"