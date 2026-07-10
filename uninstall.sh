#!/system/bin/sh
# Maodie Launcher - Uninstall Script

MOD_DIR="/data/adb/modules/Maodie-Launcher"
CORE_SCRIPT="$MOD_DIR/maodie/scripts/core.sh"

# 1. 停止内核进程并清理 iptables 规则
if [ -x "$CORE_SCRIPT" ]; then
    sh "$CORE_SCRIPT" stop 2>/dev/null
else
    pkill -15 -f "$MOD_DIR/maodie/kernel/Mihomo" 2>/dev/null
    sleep 1
    pkill -9 -f "$MOD_DIR/maodie/kernel/Mihomo" 2>/dev/null
fi

# 2. 停止看门狗与去广告服务
pkill -f "$MOD_DIR/maodie/scripts/monitor.sh" 2>/dev/null
pkill -f "$MOD_DIR/maodie/scripts/NoAdsService.sh" 2>/dev/null

# 3. 仅恢复本模块实际修改过的路径，不依赖当前版本清单。
ADBLOCK_STATE="$MOD_DIR/maodie/config/adblock.state"
if [ -f "$ADBLOCK_STATE" ]; then
    while IFS= read -r target || [ -n "$target" ]; do
        [ -n "$target" ] || continue
        chattr -i "$target" 2>/dev/null
    done < "$ADBLOCK_STATE"
fi

# 4. 移除模块目录
rm -rf "$MOD_DIR"
