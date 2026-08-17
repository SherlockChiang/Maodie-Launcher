#!/system/bin/sh
SKIPUNZIP=1
umask 077

EXISTING_DIR="/data/adb/modules/Maodie-Launcher"
OLD_CONFIG="$EXISTING_DIR/maodie/config/config.yaml"

OLD_PROVIDERS_DIR="$EXISTING_DIR/maodie/config/proxy_providers"
NEW_PROVIDERS_DIR="$MODPATH/maodie/config/proxy_providers"

OLD_CACHE_DB="$EXISTING_DIR/maodie/config/cache.db"
NEW_CACHE_DB="$MODPATH/maodie/config/cache.db"
OLD_ADBLOCK_STATE="$EXISTING_DIR/maodie/config/adblock.state"
NEW_ADBLOCK_STATE="$MODPATH/maodie/config/adblock.state"
OLD_ADBLOCK_ENABLE="$EXISTING_DIR/maodie/config/adblock.enabled"
OLD_ADBLOCK_LIST="$EXISTING_DIR/maodie/config/adblock.list"
NEW_ADBLOCK_LIST="$MODPATH/maodie/config/adblock.list"

NEW_CONFIG="$MODPATH/maodie/config/config.yaml"
TEMP_PROVIDERS="$MODPATH/user_providers.yaml"
FILTERED_PROVIDERS="$MODPATH/user_providers.filtered.yaml"
FINAL_CONFIG="$MODPATH/maodie/config/config.yaml.final"

get_config_secret() {
  config_path="$1"
  [ -f "$config_path" ] || return
  awk '
    /^secret:[[:space:]]*/ {
      value = $0
      sub(/^secret:[[:space:]]*/, "", value)
      sub(/[[:space:]][[:space:]]*#.*/, "", value)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      first = substr(value, 1, 1)
      last = substr(value, length(value), 1)
      single_quote = sprintf("%c", 39)
      if ((first == "\"" && last == "\"") ||
          (first == single_quote && last == single_quote)) {
        value = substr(value, 2, length(value) - 2)
      }
      print value
      exit
    }
  ' "$config_path"
}

count_top_level_secrets() {
  awk '/^secret:[[:space:]]*/ { count++ } END { print count + 0 }' "$1" 2>/dev/null
}

has_unsupported_secret_syntax() {
  awk '
    /^[^[:space:]#]/ {
      line = $0
      if (line ~ /^secret[[:space:]]+:/ ||
          line ~ /^secret:[^[:space:]#]/ ||
          line ~ /^"secret"[[:space:]]*:/ ||
          (substr(line, 1, 8) == "\047secret\047" && substr(line, 9) ~ /^[[:space:]]*:/) ||
          line ~ /^secret:[[:space:]]*[>|]/) {
        found = 1
      }
    }
    END { exit(found ? 0 : 1) }
  ' "$1" 2>/dev/null
}

is_safe_secret() {
  secret_value="$1"
  [ -n "$secret_value" ] || return 1
  [ "${#secret_value}" -le 256 ] || return 1
  case "$secret_value" in
    *[!A-Za-z0-9._~-]*) return 1 ;;
  esac
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
  secret_tmp="$NEW_CONFIG.secret.$$"
  is_safe_secret "$secret_value" || return 1

  awk -v secret="$secret_value" '
    BEGIN {
      replacement = "secret: \"" secret "\"  # 安装时自动生成；请勿泄露给其他 App"
      written = 0
    }
    /^secret:[[:space:]]*/ {
      if (!written) {
        print replacement
        written = 1
      }
      next
    }
    /^external-controller:/ && !written {
      print
      print replacement
      written = 1
      next
    }
    { print }
    END {
      if (!written) {
        if (NR > 0) print ""
        print replacement
      }
    }
  ' "$NEW_CONFIG" > "$secret_tmp" || {
    rm -f "$secret_tmp"
    return 1
  }
  chmod 600 "$secret_tmp" 2>/dev/null || {
    rm -f "$secret_tmp"
    return 1
  }
  mv -f "$secret_tmp" "$NEW_CONFIG"
}

atomic_replace_config() {
  source_config="$1"
  replace_tmp="$NEW_CONFIG.replace.$$"
  cp -f "$source_config" "$replace_tmp" 2>/dev/null || {
    rm -f "$replace_tmp"
    return 1
  }
  chmod 600 "$replace_tmp" 2>/dev/null || {
    rm -f "$replace_tmp"
    return 1
  }
  mv -f "$replace_tmp" "$NEW_CONFIG"
}

ensure_api_secret() {
  if has_unsupported_secret_syntax "$NEW_CONFIG"; then
    abort "配置使用了不支持的顶层 secret YAML 写法；请改为 secret: \"value\""
  fi

  current_secret=$(get_config_secret "$NEW_CONFIG")
  current_secret_count=$(count_top_level_secrets "$NEW_CONFIG")
  if [ "$current_secret_count" = "1" ] && is_safe_secret "$current_secret"; then
    return
  fi

  if [ -f "$OLD_CONFIG" ]; then
    old_secret=$(get_config_secret "$OLD_CONFIG")
    old_secret_count=$(count_top_level_secrets "$OLD_CONFIG")
    if [ "$old_secret_count" = "1" ] && is_safe_secret "$old_secret"; then
      set_config_secret "$old_secret" || abort "无法保存旧配置 API secret"
      ui_print "  ✅ 已沿用旧配置 API secret"
      return
    fi
  fi

  new_secret=$(generate_api_secret)
  is_safe_secret "$new_secret" || abort "无法生成安全的 API secret"
  set_config_secret "$new_secret" || abort "无法保存随机 API secret"
  ui_print "  ✅ 已生成随机 API secret"
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
chmod +x "$MODPATH/action.sh"
chmod -R +x "$MODPATH/maodie/scripts/"
chmod 755 "$MODPATH/maodie/kernel/Mihomo"
chmod 700 "$MODPATH/maodie/config"
chmod 600 "$MODPATH/maodie/config/config.yaml"
find "$MODPATH/maodie/config/proxy_providers" -type d -exec chmod 700 {} \; 2>/dev/null
find "$MODPATH/maodie/config/proxy_providers" -type f -exec chmod 600 {} \; 2>/dev/null
find "$MODPATH/maodie/config/webui" -type d -exec chmod 755 {} \;
find "$MODPATH/maodie/config/webui" -type f -exec chmod 644 {} \;

ui_print "- 开始配置迁移..."

if [ -d "$EXISTING_DIR" ]; then

  if [ -f "$OLD_ADBLOCK_STATE" ]; then
    state_tmp="$NEW_ADBLOCK_STATE.tmp.$$"
    cp -f "$OLD_ADBLOCK_STATE" "$state_tmp" || abort "去广告恢复账本迁移失败"
    chmod 600 "$state_tmp" || abort "无法设置去广告恢复账本权限"
    mv -f "$state_tmp" "$NEW_ADBLOCK_STATE" || abort "无法提交去广告恢复账本"
  else
    # 安装期可能早于 user 0 CE 解锁，不能在这里把 missing/chattr 失败
    # 当作已恢复。将旧清单迁成待恢复账本，由运行期解锁后处理。
    if [ -f "$OLD_ADBLOCK_LIST" ]; then
      state_tmp="$NEW_ADBLOCK_STATE.tmp.$$"
      rm -f "$state_tmp"
      while IFS= read -r target || [ -n "$target" ]; do
        case "$target" in ''|\#*) continue ;; esac
        while [ "${target%/}" != "$target" ]; do target=${target%/}; done
        case "$target" in
          /data/data/*/*|/data/media/0/Android/data/*/*)
            case "$target" in *'//'*|*'/../'*|*/..|*'/./'*|*/.|*[[:space:]]) continue ;; esac
            printf '%s\n' "$target" >> "$state_tmp" || abort "无法创建旧版去广告待恢复账本"
            ;;
        esac
      done < "$OLD_ADBLOCK_LIST"
      if [ -s "$state_tmp" ]; then
        chmod 600 "$state_tmp" || abort "无法设置旧版去广告待恢复账本权限"
        mv -f "$state_tmp" "$NEW_ADBLOCK_STATE" || abort "无法提交旧版去广告待恢复账本"
        ui_print "  ⚠️ 旧版去广告路径将在用户解锁后恢复"
      else
        rm -f "$state_tmp"
      fi
    fi
  fi

  if [ -f "$OLD_ADBLOCK_ENABLE" ]; then
    if command -v cmp >/dev/null 2>&1 \
        && [ -f "$OLD_ADBLOCK_LIST" ] \
        && [ -f "$NEW_ADBLOCK_LIST" ] \
        && cmp -s "$OLD_ADBLOCK_LIST" "$NEW_ADBLOCK_LIST"; then
      cp -f "$OLD_ADBLOCK_ENABLE" "$MODPATH/maodie/config/adblock.enabled" \
        || abort "无法迁移去广告启用状态"
    else
      ui_print "  ⚠️ 去广告清单已变化；本次升级后需重新确认并启用"
    fi
  fi

  if [ -d "$OLD_PROVIDERS_DIR" ]; then
    ui_print "  发现旧版 proxy_providers 文件夹，正在保留..."
    mkdir -p "$NEW_PROVIDERS_DIR"
    cp -rf "$OLD_PROVIDERS_DIR/." "$NEW_PROVIDERS_DIR/" 2>/dev/null || abort "proxy_providers 迁移失败"
    find "$NEW_PROVIDERS_DIR" -type d -exec chmod 700 {} \; 2>/dev/null
    find "$NEW_PROVIDERS_DIR" -type f -exec chmod 600 {} \; 2>/dev/null
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

    # 丢弃从未配置过的默认占位 provider；真实的一个或多个 provider 均原样保留。
    awk '
      function flush_provider() {
        if (provider_block != "" && provider_block !~ /请填写您自己的代理地址/) {
          printf "%s", provider_block
        }
        provider_block = ""
      }
      NR == 1 { print; next }
      /^  [^[:space:]][^:]*:[[:space:]]*$/ {
        flush_provider()
        provider_block = $0 ORS
        next
      }
      { provider_block = provider_block $0 ORS }
      END { flush_provider() }
    ' "$TEMP_PROVIDERS" > "$FILTERED_PROVIDERS" 2>/dev/null || true
    NO_CONFIGURED_PROVIDER=0
    if grep -q '^  [^[:space:]][^:]*:[[:space:]]*$' "$FILTERED_PROVIDERS" 2>/dev/null; then
      mv -f "$FILTERED_PROVIDERS" "$TEMP_PROVIDERS"
    else
      rm -f "$FILTERED_PROVIDERS" "$TEMP_PROVIDERS"
      NO_CONFIGURED_PROVIDER=1
    fi

    if [ -s "$TEMP_PROVIDERS" ]; then
      ui_print "  成功提取旧订阅 (proxy-providers)！"

      START_LINE=$(grep -m 1 -n "^proxy-providers:" "$NEW_CONFIG" | cut -d: -f1)
      END_LINE=$(grep -m 1 -n "^proxy-groups:" "$NEW_CONFIG" | cut -d: -f1)

      if [ -n "$START_LINE" ] && [ -n "$END_LINE" ] && [ "$START_LINE" -lt "$END_LINE" ]; then
        head -n $(($START_LINE - 1)) "$NEW_CONFIG" > "$FINAL_CONFIG"
        cat "$TEMP_PROVIDERS" >> "$FINAL_CONFIG"
        echo "" >> "$FINAL_CONFIG"
        tail -n +$END_LINE "$NEW_CONFIG" >> "$FINAL_CONFIG"

        # 安装阶段的临时模块目录可能尚无可执行 SELinux 上下文，不在此运行 Mihomo。
        # 运行期 WebUI 配置更新仍由 configctl.sh 调用 Mihomo 做完整校验。
        if grep -q "^proxy-providers:" "$FINAL_CONFIG" \
            && grep -q "^proxy-groups:" "$FINAL_CONFIG" \
            && grep -q "^rules:" "$FINAL_CONFIG"; then
          mv -f "$FINAL_CONFIG" "$NEW_CONFIG" || abort "无法保存迁移后的配置"
          ui_print "  ✅ 配置文件合并完成：新规则 + 旧订阅"
        else
          ui_print "  ⚠️ 警告：合并后的配置确实缺少关键段落，回退旧配置。"
          rm -f "$FINAL_CONFIG"
          atomic_replace_config "$OLD_CONFIG" || abort "无法恢复旧配置"
        fi
      else
        ui_print "  ⚠️ 警告：新配置结构异常，无法定位锚点。"
        ui_print "  -> 保留旧版完整配置以防丢失订阅。"
        atomic_replace_config "$OLD_CONFIG" || abort "无法保留旧配置"
      fi
    else
      if [ "$NO_CONFIGURED_PROVIDER" -eq 1 ]; then
        ui_print "  未发现已配置的订阅，保留新版单 provider 模板。"
      else
        ui_print "  ⚠️ 警告：无法从旧配置提取 providers。"
        ui_print "  -> 可能是格式不标准，已保留旧版完整配置。"
        atomic_replace_config "$OLD_CONFIG" || abort "无法保留旧配置"
      fi
    fi

    rm -f "$TEMP_PROVIDERS" "$FILTERED_PROVIDERS"
  fi
else
  ui_print "  首次安装，无需迁移。"
fi

ensure_api_secret
chmod 700 "$MODPATH/maodie/config" 2>/dev/null
chmod 600 "$NEW_CONFIG" "$MODPATH/config.yaml.backup" 2>/dev/null
