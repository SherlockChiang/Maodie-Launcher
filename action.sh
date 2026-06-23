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

secret=$(get_config_secret "$CONFIG_FILE")
secret_changed=0
if [ -z "$secret" ]; then
    secret=$(generate_api_secret)
    set_config_secret "$secret"
    secret_changed=1
fi

if [ -x "$CORE_SCRIPT" ]; then
    if [ "$secret_changed" -eq 1 ]; then
        sh "$CORE_SCRIPT" restart >/dev/null 2>&1
    else
        sh "$CORE_SCRIPT" start >/dev/null 2>&1
    fi
fi

secret_query=$(url_encode "$secret")
URL="$CONTROLLER_URL/ui/#/setup?hostname=127.0.0.1&port=9090&http=1&secret=${secret_query}"

am start -a android.intent.action.VIEW -d "$URL" --user 0 >/dev/null 2>&1 \
    || am start -a android.intent.action.VIEW -d "$URL" >/dev/null 2>&1

exit 0
