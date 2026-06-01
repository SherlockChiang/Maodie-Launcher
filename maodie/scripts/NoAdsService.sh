#!/system/bin/sh
# Maodie Launcher - 物理级去广告防线 (Physical AdBlocker)
# inspired by https://github.com/liuzq2002/Adguard-Home-For-Magisk-Mod
# 广告路径清单见 maodie/config/adblock.list（单一数据源，uninstall.sh 共用）

MOD_DIR="/data/adb/modules/Maodie-Launcher"
ADBLOCK_LIST="$MOD_DIR/maodie/config/adblock.list"
LOG_FILE="$MOD_DIR/maodie/run/adblock.log"
LOCK_FILE="$MOD_DIR/maodie/run/adblock.lock"

mkdir -p "$MOD_DIR/maodie/run"

# 防止重复启动（lock 文件 + 存活校验）
if [ -f "$LOCK_FILE" ]; then
    old_pid=$(cat "$LOCK_FILE" 2>/dev/null)
    if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
        exit 0
    fi
fi
echo $$ > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"; exit 0' INT TERM

echo "$(date): NoAdsService started (PID: $$)." > "$LOG_FILE"

if [ ! -f "$ADBLOCK_LIST" ]; then
    echo "$(date): adblock.list not found, nothing to do." >> "$LOG_FILE"
    exit 0
fi

blocked_count=0

# 目标是否已带 immutable(i) 属性（lsattr 首列含小写 i）
is_immutable() {
    lsattr -d "$1" 2>/dev/null | awk '{print $1}' | grep -q 'i'
}

# 广告屏蔽核心：清空目标并加 immutable，使 App 无法再写入
block_ad() {
    target="$1"
    [ ! -e "$target" ] && return
    is_immutable "$target" && return
    if [ -d "$target" ]; then
        rm -rf "$target" 2>/dev/null
        mkdir -p "$target" 2>/dev/null
    else
        : > "$target" 2>/dev/null
    fi
    if chattr +i "$target" 2>/dev/null; then
        blocked_count=$((blocked_count + 1))
    fi
}

# 延迟 30 秒，把开机算力让给 Mihomo 和其他系统组件
sleep 30

while :; do
    blocked_count=0

    # 读清单：跳过空行与 # 注释行；兼容末行无换行
    while IFS= read -r target || [ -n "$target" ]; do
        case "$target" in
            ''|\#*) continue ;;
        esac
        block_ad "$target"
    done < "$ADBLOCK_LIST"

    [ "$blocked_count" -gt 0 ] && echo "$(date): Patrol done, $blocked_count path(s) blocked." >> "$LOG_FILE"

    # 巡检间隔：1 小时
    sleep 3600
done
