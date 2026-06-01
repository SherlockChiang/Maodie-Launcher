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

# 2. 停止看门狗与去广告服务
pkill -f "$MOD_DIR/maodie/scripts/monitor.sh" 2>/dev/null
pkill -f "NoAdsService.sh" 2>/dev/null

# 3. 恢复去广告服务设置过的 immutable 标记，避免卸载后影响 App 写入
#    与 NoAdsService 共用同一份清单 adblock.list
ADBLOCK_LIST="$MOD_DIR/maodie/config/adblock.list"
if [ -f "$ADBLOCK_LIST" ]; then
    while IFS= read -r target || [ -n "$target" ]; do
        case "$target" in
            ''|\#*) continue ;;
        esac
        chattr -i "$target" 2>/dev/null
    done < "$ADBLOCK_LIST"
fi

# 4. 移除模块目录
rm -rf "$MOD_DIR"
