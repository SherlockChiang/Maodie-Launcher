#!/system/bin/sh

MODDIR="$(dirname "$0")"
CONFIG_FILE="$MODDIR/maodie/config/config.yaml"
CORE_SCRIPT="$MODDIR/maodie/scripts/core.sh"
WEBUI_DIR="$MODDIR/maodie/config/webui"
AUTOLOGIN_FILE="$WEBUI_DIR/maodie-autologin.html"
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
        sed -i "/^external-controller:/a secret: \"$escaped_secret\"  # action.sh 自动生成；请勿泄露给其他 App|" "$CONFIG_FILE"
    else
        printf '\nsecret: "%s"  # action.sh 自动生成；请勿泄露给其他 App\n' "$secret_value" >> "$CONFIG_FILE"
    fi
}

ensure_autologin_page() {
    mkdir -p "$WEBUI_DIR"
    cat > "$AUTOLOGIN_FILE" <<'EOF'
<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>Maodie Launcher</title>
  <style>
    body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;background:#101318;color:#eef1f6;font-family:system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}
    main{max-width:28rem;padding:1.5rem;text-align:center}
    h1{font-size:1.1rem;margin:0 0 .5rem}
    p{margin:.25rem 0;color:#aab2bf;line-height:1.5}
  </style>
</head>
<body>
  <main>
    <h1>正在打开 Maodie 面板</h1>
    <p>正在写入本地授权信息，请稍候...</p>
  </main>
  <script>
    (function () {
      var raw = window.location.hash ? window.location.hash.slice(1) : "";
      if (!raw) {
        document.querySelector("p").textContent = "缺少授权信息，请重新从 KernelSU 模块按钮打开。";
        return;
      }

      var secret = decodeURIComponent(escape(window.atob(raw)));
      var endpointId = "maodie-local";
      var endpointUrl = "http://127.0.0.1:9090";
      var endpoints = [];

      try {
        endpoints = JSON.parse(window.localStorage.getItem("endpointList") || "[]");
        if (!Array.isArray(endpoints)) endpoints = [];
      } catch (_) {
        endpoints = [];
      }

      var found = false;
      endpoints = endpoints.map(function (endpoint) {
        if (endpoint && (endpoint.id === endpointId || endpoint.url === endpointUrl)) {
          found = true;
          return { id: endpointId, url: endpointUrl, secret: secret };
        }
        return endpoint;
      }).filter(Boolean);

      if (!found) {
        endpoints.unshift({ id: endpointId, url: endpointUrl, secret: secret });
      }

      window.localStorage.setItem("endpointList", JSON.stringify(endpoints));
      window.localStorage.setItem("selectedEndpoint", endpointId);
      window.location.replace("/ui");
    })();
  </script>
</body>
</html>
EOF
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

ensure_autologin_page

secret_b64=$(printf '%s' "$secret" | base64 2>/dev/null | tr -d '\n\r')
URL="$CONTROLLER_URL/ui/maodie-autologin.html#${secret_b64}"

am start -a android.intent.action.VIEW -d "$URL" --user 0 >/dev/null 2>&1 \
    || am start -a android.intent.action.VIEW -d "$URL" >/dev/null 2>&1

exit 0
