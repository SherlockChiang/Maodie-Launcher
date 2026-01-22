#!/system/bin/sh
SKIPUNZIP=1

# === 变量定义 ===
EXISTING_DIR="/data/adb/modules/Maodie-Launcher"
OLD_CONFIG="$EXISTING_DIR/maodie/config/config.yaml"

# 旧的 providers 文件夹路径
OLD_PROVIDERS_DIR="$EXISTING_DIR/maodie/config/proxy_providers"
# 新的 providers 文件夹路径
NEW_PROVIDERS_DIR="$MODPATH/maodie/config/proxy_providers"

# === 变量定义：新增 cache.db ===
OLD_CACHE_DB="$EXISTING_DIR/maodie/config/cache.db"
NEW_CACHE_DB="$MODPATH/maodie/config/cache.db"

NEW_CONFIG="$MODPATH/maodie/config/config.yaml"
TEMP_PROVIDERS="$MODPATH/user_providers.yaml"
FINAL_CONFIG="$MODPATH/maodie/config/config.yaml.final"

ui_print "- 正在哈气..."

# 1. 解压文件
ui_print "- 解压核心文件..."
unzip -o "$ZIPFILE" -x 'META-INF/*' -d $MODPATH >&2

# 2. 赋予权限
ui_print "- 设置执行权限..."
chmod +x $MODPATH/service.sh
chmod +x $MODPATH/uninstall.sh
chmod -R +x $MODPATH/maodie/scripts/
chmod 755 $MODPATH/maodie/kernel/Mihomo
chmod -R 755 "$MODPATH/maodie/config/webui"

# 3. 智能配置迁移 (Smart Merge Strategy)
ui_print "- 开始配置迁移..."

if [ -d "$EXISTING_DIR" ]; then

  # === 逻辑 A: 保留 proxy_providers 文件夹 ===
  if [ -d "$OLD_PROVIDERS_DIR" ]; then
    ui_print "  发现旧版 proxy_providers 文件夹，正在保留..."
    mkdir -p "$NEW_PROVIDERS_DIR"
    cp -rf "$OLD_PROVIDERS_DIR/"* "$NEW_PROVIDERS_DIR/"
    chmod -R 755 "$NEW_PROVIDERS_DIR"
    ui_print "  ✅ proxy_providers 文件夹迁移完成"
  else
    ui_print "  未发现旧版 proxy_providers 文件夹，跳过..."
  fi

  # === 逻辑 B: 保留 cache.db (新增功能) ===
  if [ -f "$OLD_CACHE_DB" ]; then
    ui_print "  发现旧版 cache.db，正在保留..."
    # 强制覆盖新包里可能自带的空 cache.db
    cp -f "$OLD_CACHE_DB" "$NEW_CACHE_DB"
    # 赋予读写权限 (644: Owner读写, Group/Others读)
    chmod 644 "$NEW_CACHE_DB"
    ui_print "  ✅ cache.db 迁移完成"
  else
    ui_print "  未发现旧版 cache.db，跳过..."
  fi

  # === 逻辑 C: 保留 config.yaml 中的订阅配置 ===
  if [ -f "$OLD_CONFIG" ]; then
    ui_print "  发现旧版本配置，正在提取订阅信息..."

    # 逻辑：提取从 "proxy-providers:" 开始，到 "proxy-groups:" (不包含) 结束的内容
    sed -n '/^proxy-providers:/,/^proxy-groups:/ { /^proxy-groups:/d; p; }' "$OLD_CONFIG" > "$TEMP_PROVIDERS"

    # 检查是否成功提取到内容
    if [ -s "$TEMP_PROVIDERS" ]; then
      ui_print "  成功提取旧订阅 (proxy-providers)！"
      
      START_LINE=$(grep -n "^proxy-providers:" "$NEW_CONFIG" | cut -d: -f1)
      END_LINE=$(grep -n "^proxy-groups:" "$NEW_CONFIG" | cut -d: -f1)

      if [ -n "$START_LINE" ] && [ -n "$END_LINE" ]; then
        # 生成头部
        head -n $(($START_LINE - 1)) "$NEW_CONFIG" > "$FINAL_CONFIG"
        
        # 插入用户的旧订阅
        cat "$TEMP_PROVIDERS" >> "$FINAL_CONFIG"
        
        # 插入换行符
        echo "" >> "$FINAL_CONFIG"
        
        # 生成尾部
        tail -n +$END_LINE "$NEW_CONFIG" >> "$FINAL_CONFIG"

        # 替换生效
        mv -f "$FINAL_CONFIG" "$NEW_CONFIG"
        ui_print "  ✅ 配置文件合并完成：新规则 + 旧订阅"
      else
        ui_print "  ⚠️ 警告：新配置结构异常，无法定位锚点。"
        ui_print "  -> 保留旧版完整配置以防丢失订阅。"
        cp -f "$OLD_CONFIG" "$NEW_CONFIG"
      fi
    else
      ui_print "  ⚠️ 警告：无法从旧配置提取 providers。"
      ui_print "  -> 可能是格式不标准，已保留旧版完整配置。"
      cp -f "$OLD_CONFIG" "$NEW_CONFIG"
    fi

    # 清理临时文件
    rm -f "$TEMP_PROVIDERS"
  fi

else
  ui_print "  首次安装，使用默认配置..."
fi

# 4. 环境提示
ui_print "- 配置路径: /data/adb/modules/Maodie-Launcher/maodie/config/"