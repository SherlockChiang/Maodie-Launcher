#!/system/bin/sh
SKIPUNZIP=1
umask 077

EXISTING_DIR="/data/adb/modules/Maodie-Launcher"
OLD_CONFIG="$EXISTING_DIR/maodie/config/config.yaml"

OLD_PROVIDERS_DIR="$EXISTING_DIR/maodie/config/proxy_providers"
NEW_PROVIDERS_DIR="$MODPATH/maodie/config/proxy_providers"

OLD_CACHE_DB="$EXISTING_DIR/maodie/config/cache.db"
NEW_CACHE_DB="$MODPATH/maodie/config/cache.db"

NEW_CONFIG="$MODPATH/maodie/config/config.yaml"
TEMP_PROVIDERS="$MODPATH/user_providers.yaml"
FINAL_CONFIG="$MODPATH/maodie/config/config.yaml.final"

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
  if grep -q '^[[:space:]]*secret:' "$NEW_CONFIG"; then
    sed -i "s|^[[:space:]]*secret:.*|secret: \"$escaped_secret\"  # 安装时自动生成；请勿泄露给其他 App|" "$NEW_CONFIG"
  elif grep -q '^external-controller:' "$NEW_CONFIG"; then
    sed -i "/^external-controller:/a secret: \"$escaped_secret\"  # 安装时自动生成；请勿泄露给其他 App" "$NEW_CONFIG"
  else
    printf '\nsecret: "%s"  # 安装时自动生成；请勿泄露给其他 App\n' "$secret_value" >> "$NEW_CONFIG"
  fi
}

ensure_api_secret() {
  current_secret=$(get_config_secret "$NEW_CONFIG")
  if [ -z "$current_secret" ] && [ -f "$OLD_CONFIG" ]; then
    old_secret=$(get_config_secret "$OLD_CONFIG")
    if [ -n "$old_secret" ]; then
      set_config_secret "$old_secret"
      ui_print "  ✅ 已沿用旧配置 API secret"
      return
    fi
  fi

  if [ -z "$current_secret" ]; then
    new_secret=$(generate_api_secret)
    set_config_secret "$new_secret"
    ui_print "  ✅ 已生成随机 API secret"
  fi
}

ui_print "- 正在哈气..."

DEVICE_ABI=$(getprop ro.product.cpu.abi 2>/dev/null)
case "$DEVICE_ABI" in
  arm64-v8a|arm64*) ;;
  *) abort "不支持的设备架构：$DEVICE_ABI（仅支持 ARM64）" ;;
esac

ui_print "- 解压核心文件..."
unzip -o "$ZIPFILE" -x 'META-INF/*' -d "$MODPATH" >&2 || abort "解压模块失败"
[ -f "$MODPATH/maodie/kernel/Mihomo" ] || abort "模块缺少 Mihomo 核心"
[ -f "$NEW_CONFIG" ] || abort "模块缺少默认配置"

ui_print "- 设置执行权限..."
chmod +x "$MODPATH/service.sh"
chmod +x "$MODPATH/post-fs-data.sh"
chmod +x "$MODPATH/uninstall.sh"
chmod -R +x "$MODPATH/maodie/scripts/"
chmod 755 "$MODPATH/maodie/kernel/Mihomo"
chmod 700 "$MODPATH/maodie/config"
chmod 600 "$MODPATH/maodie/config/config.yaml"
chmod -R 600 "$MODPATH/maodie/config/proxy_providers" 2>/dev/null
find "$MODPATH/maodie/config/webui" -type d -exec chmod 755 {} \;
find "$MODPATH/maodie/config/webui" -type f -exec chmod 644 {} \;

ui_print "- 开始配置迁移..."

if [ -d "$EXISTING_DIR" ]; then

  if [ -d "$OLD_PROVIDERS_DIR" ]; then
    ui_print "  发现旧版 proxy_providers 文件夹，正在保留..."
    mkdir -p "$NEW_PROVIDERS_DIR"
    cp -rf "$OLD_PROVIDERS_DIR/." "$NEW_PROVIDERS_DIR/" 2>/dev/null || abort "proxy_providers 迁移失败"
    chmod -R 600 "$NEW_PROVIDERS_DIR"
    ui_print "  ✅ proxy_providers 文件夹迁移完成"
  else
    ui_print "  未发现旧版 proxy_providers 文件夹，跳过..."
  fi

  if [ -f "$OLD_CACHE_DB" ]; then
    ui_print "  发现旧版 cache.db，正在保留..."
    cp -f "$OLD_CACHE_DB" "$NEW_CACHE_DB" 2>/dev/null || abort "cache.db 迁移失败"
    chmod 600 "$NEW_CACHE_DB"
    ui_print "  ✅ cache.db 迁移完成"
  else
    ui_print "  未发现旧版 cache.db，跳过..."
  fi

  if [ -f "$OLD_CONFIG" ]; then
    ui_print "  发现旧版本配置，正在提取订阅信息..."

    # 备份旧配置，万一迁移失败可手动恢复
    cp -f "$OLD_CONFIG" "$MODPATH/config.yaml.backup" 2>/dev/null || abort "旧配置备份失败"

    sed -n '/^proxy-providers:/,/^proxy-groups:/ { /^proxy-groups:/d; p; }' "$OLD_CONFIG" > "$TEMP_PROVIDERS" 2>/dev/null || true
    sed -i '/^[ \t]*$/d' "$TEMP_PROVIDERS" 2>/dev/null || true

    if [ -s "$TEMP_PROVIDERS" ]; then
      ui_print "  成功提取旧订阅 (proxy-providers)！"

      START_LINE=$(grep -m 1 -n "^proxy-providers:" "$NEW_CONFIG" | cut -d: -f1)
      END_LINE=$(grep -m 1 -n "^proxy-groups:" "$NEW_CONFIG" | cut -d: -f1)

      if [ -n "$START_LINE" ] && [ -n "$END_LINE" ] && [ "$START_LINE" -lt "$END_LINE" ]; then
        head -n $(($START_LINE - 1)) "$NEW_CONFIG" > "$FINAL_CONFIG"
        cat "$TEMP_PROVIDERS" >> "$FINAL_CONFIG"
        echo "" >> "$FINAL_CONFIG"
        tail -n +$END_LINE "$NEW_CONFIG" >> "$FINAL_CONFIG"

        # 标题完整且 Mihomo 能实际加载时才接受合并结果。
        if grep -q "^proxy-providers:" "$FINAL_CONFIG" && grep -q "^proxy-groups:" "$FINAL_CONFIG" && grep -q "^rules:" "$FINAL_CONFIG" \
            && "$MODPATH/maodie/kernel/Mihomo" -t -d "$MODPATH/maodie/config" -f "$FINAL_CONFIG" >/dev/null 2>&1; then
          mv -f "$FINAL_CONFIG" "$NEW_CONFIG" || abort "无法保存迁移后的配置"
          ui_print "  ✅ 配置文件合并完成：新规则 + 旧订阅"
        else
          ui_print "  ⚠️ 警告：合并后的配置缺少关键段落，回退旧配置。"
          rm -f "$FINAL_CONFIG"
          cp -f "$OLD_CONFIG" "$NEW_CONFIG" 2>/dev/null || abort "无法恢复旧配置"
        fi
      else
        ui_print "  ⚠️ 警告：新配置结构异常，无法定位锚点。"
        ui_print "  -> 保留旧版完整配置以防丢失订阅。"
        cp -f "$OLD_CONFIG" "$NEW_CONFIG" 2>/dev/null || abort "无法保留旧配置"
      fi
    else
      ui_print "  ⚠️ 警告：无法从旧配置提取 providers。"
      ui_print "  -> 可能是格式不标准，已保留旧版完整配置。"
      cp -f "$OLD_CONFIG" "$NEW_CONFIG" 2>/dev/null || abort "无法保留旧配置"
    fi

    rm -f "$TEMP_PROVIDERS"
  fi
else
  ui_print "  首次安装，无需迁移。"
fi

ensure_api_secret
chmod 700 "$MODPATH/maodie/config" 2>/dev/null
chmod 600 "$NEW_CONFIG" "$MODPATH/config.yaml.backup" 2>/dev/null
