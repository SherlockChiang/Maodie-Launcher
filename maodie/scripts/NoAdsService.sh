#!/system/bin/sh
# Maodie Launcher - 物理级去广告防线 (Physical AdBlocker)
# inspired by https://github.com/liuzq2002/Adguard-Home-For-Magisk-Mod
# 广告路径清单见 maodie/config/adblock.list（单一数据源，uninstall.sh 共用）

MOD_DIR="/data/adb/modules/Maodie-Launcher"
ADBLOCK_LIST="$MOD_DIR/maodie/config/adblock.list"
LOG_FILE="$MOD_DIR/maodie/run/adblock.log"
LOCK_DIR="$MOD_DIR/maodie/run/adblock.lock"

mkdir -p "$MOD_DIR/maodie/run"

service_alive() {
    check_pid="$1"
    [ -n "$check_pid" ] || return 1
    kill -0 "$check_pid" 2>/dev/null || return 1
    [ -r "/proc/$check_pid/cmdline" ] && grep -aq "NoAdsService.sh" "/proc/$check_pid/cmdline" 2>/dev/null
}

read_lock_pid() {
    if [ -d "$LOCK_DIR" ]; then
        cat "$LOCK_DIR/pid" 2>/dev/null
    elif [ -f "$LOCK_DIR" ]; then
        cat "$LOCK_DIR" 2>/dev/null
    fi
}

cleanup_lock() {
    lock_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null)
    [ "$lock_pid" = "$$" ] && rm -rf "$LOCK_DIR"
}

# 防止重复启动（原子目录锁 + 存活校验）
while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    old_pid=$(read_lock_pid)
    if service_alive "$old_pid"; then
        exit 0
    fi
    if [ -d "$LOCK_DIR" ]; then
        rm -rf "$LOCK_DIR"
    else
        rm -f "$LOCK_DIR"
    fi
done
echo $$ > "$LOCK_DIR/pid"
trap cleanup_lock EXIT
trap 'exit 0' INT TERM

echo "$(date): NoAdsService started (PID: $$)." > "$LOG_FILE"

if [ ! -f "$ADBLOCK_LIST" ]; then
    echo "$(date): adblock.list not found, nothing to do." >> "$LOG_FILE"
    exit 0
fi

blocked_count=0
skipped_count=0

# 目标是否已带 immutable(i) 属性（lsattr 首列含小写 i）
is_immutable() {
    lsattr -d "$1" 2>/dev/null | awk '{print $1}' | grep -q 'i'
}

is_state_file() {
    case "$1" in
        *.db|*.db-*|*.sqlite|*.sqlite3|*.xml) return 0 ;;
        *) return 1 ;;
    esac
}

# 广告屏蔽核心：清空目标并加 immutable，使 App 无法再写入
block_ad() {
    target="$1"
    [ ! -e "$target" ] && return
    if [ -f "$target" ] && is_state_file "$target"; then
        if is_immutable "$target"; then
            chattr -i "$target" 2>/dev/null
        fi
        skipped_count=$((skipped_count + 1))
        return
    fi
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
    skipped_count=0

    # 读清单：跳过空行与 # 注释行；兼容末行无换行
    while IFS= read -r target || [ -n "$target" ]; do
        case "$target" in
            ''|\#*) continue ;;
        esac
        block_ad "$target"
    done < "$ADBLOCK_LIST"

    [ "$blocked_count" -gt 0 ] && echo "$(date): Patrol done, $blocked_count path(s) blocked." >> "$LOG_FILE"
    [ "$skipped_count" -gt 0 ] && echo "$(date): Patrol skipped $skipped_count state file(s)." >> "$LOG_FILE"

    # 巡检间隔：1 小时
    sleep 3600
done
