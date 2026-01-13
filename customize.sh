#!/system/bin/sh
SKIPUNZIP=1

# 定义模块安装后的路径 (用于查找旧配置)
EXISTING_DIR="/data/adb/modules/Maodie-Launcher"

ui_print "- 正在哈气..."

# 1. 解压文件到临时目录
ui_print "- 解压核心文件..."
unzip -o "$ZIPFILE" -x 'META-INF/*' -d $MODPATH >&2

# 2. 赋予权限 (至关重要)
ui_print "- 设置执行权限..."
chmod +x $MODPATH/service.sh
chmod +x $MODPATH/uninstall.sh
chmod -R +x $MODPATH/maodie/scripts/
chmod 755 $MODPATH/maodie/kernel/Mihomo
chmod -R 755 "$MODPATH/maodie/config/webui"

# 3. 内部配置迁移 (Upgrade Strategy)
# 如果系统中已经存在旧版本的模块，尝试保留其配置
if [ -f "$EXISTING_DIR/maodie/config/config.yaml" ]; then
  ui_print "- 检测到上一版本的配置，正在迁移..."
  cp -f "$EXISTING_DIR/maodie/config/config.yaml" "$MODPATH/maodie/config/config.yaml"
  
  # 如果你有 dashboard 或者 providers 文件夹，也可以在这里加 cp 命令保留
  # cp -rf "$EXISTING_DIR/maodie/providers" "$MODPATH/maodie/"
else
  ui_print "- 首次安装，使用默认配置..."
fi

# 4. 环境提示
ui_print "- 配置路径: /data/adb/modules/Maodie-Launcher/maodie/config/"
