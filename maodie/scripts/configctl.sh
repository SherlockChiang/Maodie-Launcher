#!/system/bin/sh

MOD_DIR="/data/adb/modules/Maodie-Launcher"
CONFIG_DIR="$MOD_DIR/maodie/config"
CONFIG_FILE="$CONFIG_DIR/config.yaml"
KERNEL_BIN="$MOD_DIR/maodie/kernel/Mihomo"
RUN_DIR="$MOD_DIR/maodie/run"
LOCK_DIR="$RUN_DIR/config.lock"

umask 077
mkdir -p "$RUN_DIR"

cleanup() {
    rm -f "$CONFIG_FILE.tmp.$$"
    [ "$(cat "$LOCK_DIR/pid" 2>/dev/null)" = "$$" ] && rm -rf "$LOCK_DIR"
}

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    echo "Another configuration update is in progress." >&2
    exit 1
fi
echo $$ > "$LOCK_DIR/pid"
trap cleanup EXIT INT TERM

case "$1" in
    apply-base64)
        encoded="$2"
        [ -n "$encoded" ] || { echo "Configuration payload is empty." >&2; exit 1; }
        printf '%s' "$encoded" | base64 -d > "$CONFIG_FILE.tmp.$$" 2>/dev/null || {
            echo "Unable to decode configuration payload." >&2
            exit 1
        }
        [ -s "$CONFIG_FILE.tmp.$$" ] || { echo "Decoded configuration is empty." >&2; exit 1; }
        "$KERNEL_BIN" -t -d "$CONFIG_DIR" -f "$CONFIG_FILE.tmp.$$" >/dev/null 2>"$RUN_DIR/config-check.log" || {
            echo "Mihomo rejected the new configuration." >&2
            tail -n 20 "$RUN_DIR/config-check.log" >&2
            exit 1
        }
        chmod 600 "$RUN_DIR/config-check.log" 2>/dev/null
        cp -f "$CONFIG_FILE" "$CONFIG_FILE.last-good" || exit 1
        chmod 600 "$CONFIG_FILE.last-good" 2>/dev/null
        mv -f "$CONFIG_FILE.tmp.$$" "$CONFIG_FILE" || exit 1
        chmod 600 "$CONFIG_FILE" 2>/dev/null
        ;;
    restore)
        [ -s "$CONFIG_FILE.last-good" ] || { echo "No last-known-good configuration exists." >&2; exit 1; }
        cp -f "$CONFIG_FILE.last-good" "$CONFIG_FILE.tmp.$$" || exit 1
        "$KERNEL_BIN" -t -d "$CONFIG_DIR" -f "$CONFIG_FILE.tmp.$$" >/dev/null 2>"$RUN_DIR/config-check.log" || exit 1
        mv -f "$CONFIG_FILE.tmp.$$" "$CONFIG_FILE" || exit 1
        chmod 600 "$CONFIG_FILE" 2>/dev/null
        ;;
    *)
        echo "Usage: $0 {apply-base64 <payload>|restore}" >&2
        exit 1
        ;;
esac
