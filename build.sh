#!/usr/bin/env bash
# Maodie Launcher - 一键打包脚本 (Bash)
# 用法: bash build.sh [--clean]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MODULE_PROP="$SCRIPT_DIR/module.prop"
ZIP_NAME=""

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; MAGENTA='\033[0;35m'; YELLOW='\033[0;33m'; NC='\033[0m'

step()  { echo -e "${CYAN}>> $1${NC}"; }
ok()    { echo -e "${GREEN}   $1${NC}"; }
warn()  { echo -e "${YELLOW}   $1${NC}"; }
err()   { echo -e "${RED}   $1${NC}"; }

# ─── 参数解析 ─────────────────────────────────────────────────
CLEAN_ONLY=false
for arg in "$@"; do
    case "$arg" in
        --clean)     CLEAN_ONLY=true ;;
        -h|--help)
            echo "用法: bash build.sh [--clean]"
            echo "  --clean     仅清理构建产物"
            exit 0
            ;;
    esac
done

# ─── 清理 ─────────────────────────────────────────────────────
clean() {
    step "清理构建产物..."
    count=0
    for f in "$SCRIPT_DIR"/Maodie-Launcher-*.zip; do
        [ -f "$f" ] || continue
        rm -f "$f"
        ok "已删除: $(basename "$f")"
        count=$((count + 1))
    done
    [ $count -eq 0 ] && ok "没有需要清理的文件"
    echo -e "\n${GREEN}清理完成。${NC}"
}
if $CLEAN_ONLY; then clean; exit 0; fi

# ─── 函数 ─────────────────────────────────────────────────────
get_version() {
    if [ ! -f "$MODULE_PROP" ]; then
        err "module.prop 不存在"; exit 1
    fi
    local ver
    ver=$(grep '^version=' "$MODULE_PROP" | head -1 | cut -d= -f2 | tr -d '[:space:]')
    if [ -z "$ver" ]; then
        err "无法从 module.prop 读取版本号"; exit 1
    fi
    echo "$ver"
}

get_git_hash() {
    if command -v git &>/dev/null && git rev-parse --short HEAD &>/dev/null; then
        git rev-parse --short HEAD
    else
        echo "local"
    fi
}

# ─── 主流程 ───────────────────────────────────────────────────
echo ""
echo -e "${MAGENTA}========================================${NC}"
echo -e "${MAGENTA}   Maodie Launcher - 一键打包${NC}"
echo -e "${MAGENTA}========================================${NC}"
echo ""

VERSION=$(get_version)
GIT_HASH=$(get_git_hash)
step "版本: $VERSION"
step "Commit: $GIT_HASH"

# 检查文件
INCLUDE=(META-INF maodie webroot customize.sh module.prop service.sh post-fs-data.sh uninstall.sh action.sh)
step "检查打包文件..."
missing=()
for item in "${INCLUDE[@]}"; do
    [ -e "$SCRIPT_DIR/$item" ] || missing+=("$item")
done
if [ ${#missing[@]} -gt 0 ]; then
    err "缺少必要文件: ${missing[*]}"
    exit 1
fi
ok "所有必要文件就绪"

# 确保 run 目录
mkdir -p "$SCRIPT_DIR/maodie/run"
touch "$SCRIPT_DIR/maodie/run/.gitkeep"

# 打包
step "正在打包..."
ZIP_NAME="Maodie-Launcher-${VERSION}.zip"
ZIP_PATH="$SCRIPT_DIR/$ZIP_NAME"
rm -f "$ZIP_PATH"

(
    cd "$SCRIPT_DIR"
    zip -r "$ZIP_NAME" "${INCLUDE[@]}" -x "*.DS_Store" "*/__MACOSX/*" >/dev/null 2>&1
)

if [ -f "$ZIP_PATH" ]; then
    SIZE=$(du -h "$ZIP_PATH" | cut -f1)
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}   打包成功!${NC}"
    echo -e "${GREEN}========================================${NC}"
    ok "文件: $ZIP_NAME"
    ok "大小: $SIZE"
    ok "路径: $ZIP_PATH"
    echo ""
else
    err "打包失败: zip 文件未生成"
    exit 1
fi
