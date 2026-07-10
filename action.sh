#!/system/bin/sh

MODDIR="$(dirname "$0")"
CONFIG_FILE="$MODDIR/maodie/config/config.yaml"
CORE_SCRIPT="$MODDIR/maodie/scripts/core.sh"
CONTROLLER_URL="http://127.0.0.1:9090"

get_config_secret() {
    config_path="$1"
    [ -f "$config_path" ] || return
    awk '
        /^[[:space:]]*secret:[[:space:]]*/ {
            sub(/^[[:space:]]*secret:[[:space:]]*/, "")
            sub(/[[:space:]]*#.*/, "")
            gsub(/^[[:space:]]+|[[:space:]]+$/, "")
            gsub(/^"/, "")
            gsub(/"$/, "")
            gsub(/^'\''/, "")
            gsub(/'\''$/, "")
            print
            exit
        }
    ' "$config_path"
}

generate_api_secret() {
    secret=""
    if [ -r /proc/sys/kernel/random/uuid ]; then
        secret=$(cat /proc/sys/kernel/random/uuid 2>/dev/null | tr -d '-')
    fi
    if [ -z "$secret" ]; then
        secret=$(tr -dc 'A-Za-z0-9' < /dev/urandom 2>/dev/null | head -c 32)
    fi
    if [ -z "$secret" ]; then
        secret="$(date +%s)$$"
    fi
    printf '%s' "$secret"
}

set_config_secret() {
    secret_value="$1"
    escaped_secret=$(printf '%s' "$secret_value" | sed 's/[|&]/\\&/g')
    if grep -q '^[[:space:]]*secret:' "$CONFIG_FILE"; then
        sed -i "s|^[[:space:]]*secret:.*|secret: \"$escaped_secret\"  # action.sh 自动生成；请勿泄露给其他 App|" "$CONFIG_FILE"
    elif grep -q '^external-controller:' "$CONFIG_FILE"; then
        sed -i "/^external-controller:/a secret: \"$escaped_secret\"  # action.sh 自动生成；请勿泄露给其他 App" "$CONFIG_FILE"
    else
        printf '\nsecret: "%s"  # action.sh 自动生成；请勿泄露给其他 App\n' "$secret_value" >> "$CONFIG_FILE"
    fi
}

secret=$(get_config_secret "$CONFIG_FILE")
secret_changed=0
if [ -z "$secret" ]; then
    secret=$(generate_api_secret)
    set_config_secret "$secret"
    secret_changed=1
fi

if [ -x "$CORE_SCRIPT" ]; then
    if [ "$secret_changed" -eq 1 ]; then
        core_action=restart
    else
        core_action=start
    fi
    if ! sh "$CORE_SCRIPT" "$core_action"; then
        echo "Maodie 核心启动失败，最近日志：" >&2
        tail -n 20 "$MODDIR/maodie/run/kernel.log" 2>/dev/null >&2
        exit 1
    fi
else
    echo "找不到核心控制脚本。" >&2
    exit 1
fi

# 不把 API secret 放进 ACTION_VIEW URI，避免浏览器/URL handler 获取管理凭据。
URL="$CONTROLLER_URL/ui/"

if ! am start -a android.intent.action.VIEW -d "$URL" --user 0 >/dev/null 2>&1 \
    && ! am start -a android.intent.action.VIEW -d "$URL" >/dev/null 2>&1; then
    echo "无法打开浏览器，请手动访问 $URL" >&2
    exit 1
fi

exit 0
