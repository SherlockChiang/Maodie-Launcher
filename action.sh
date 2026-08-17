#!/system/bin/sh

MODDIR="${MAODIE_MOD_DIR:-$(dirname "$0")}"
CORE_SCRIPT="$MODDIR/maodie/scripts/core.sh"
CONFIG_SCRIPT="$MODDIR/maodie/scripts/configctl.sh"
CONTROLLER_URL="http://127.0.0.1:9090"

url_encode() {
    printf '%s' "$1" | sed \
        -e 's/%/%25/g' \
        -e 's/ /%20/g' \
        -e 's/#/%23/g' \
        -e 's/&/%26/g' \
        -e 's/+/%2B/g' \
        -e 's/?/%3F/g' \
        -e 's/=/%3D/g' \
        -e 's|/|%2F|g'
}

if [ ! -f "$CONFIG_SCRIPT" ]; then
    echo "找不到配置控制脚本。" >&2
    exit 1
fi

secret=$(sh "$CONFIG_SCRIPT" ensure-secret --changed-exit-code)
secret_status=$?
case "$secret_status" in
    0) secret_changed=0 ;;
    10) secret_changed=1 ;;
    *)
        echo "无法读取或生成 API secret。" >&2
        exit "$secret_status"
        ;;
esac

case "$secret" in
    ''|*[!A-Za-z0-9._~-]*)
        echo "配置控制脚本返回了无效的 API secret。" >&2
        exit 1
        ;;
esac

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

# MetaCubeXD 的 setup 路由会保存首次连接信息；直接打开 /ui/ 无法稳定补录 secret。
secret_query=$(url_encode "$secret")
URL="$CONTROLLER_URL/ui/#/setup?hostname=127.0.0.1&port=9090&http=1&secret=${secret_query}"

if ! am start -a android.intent.action.VIEW -d "$URL" --user 0 >/dev/null 2>&1 \
    && ! am start -a android.intent.action.VIEW -d "$URL" >/dev/null 2>&1; then
    echo "无法打开浏览器，请手动访问 $URL" >&2
    exit 1
fi

exit 0
