#!/system/bin/sh

MOD_DIR="${MAODIE_MOD_DIR:-/data/adb/modules/Maodie-Launcher}"
CONFIG_DIR="$MOD_DIR/maodie/config"
CONFIG_FILE="$CONFIG_DIR/config.yaml"
KERNEL_BIN="$MOD_DIR/maodie/kernel/Mihomo"
RUN_DIR="$MOD_DIR/maodie/run"
LOCK_FILE="$RUN_DIR/config.lock.fd"
FALLBACK_LOCK_DIR="$RUN_DIR/config.lock.d"
CONFIG_TMP="$CONFIG_FILE.tmp.$$"
LAST_GOOD_TMP="$CONFIG_FILE.last-good.tmp.$$"
CHECK_LOG="$RUN_DIR/config-check.log"
CHECK_LOG_TMP="$CHECK_LOG.tmp.$$"

umask 077
mkdir -p "$RUN_DIR"
chmod 700 "$RUN_DIR" 2>/dev/null

LOCK_METHOD=""
LOCK_FD=0

fallback_owner_alive() {
    check_pid="$1"
    case "$check_pid" in
        ''|*[!0-9]*) return 1 ;;
    esac
    kill -0 "$check_pid" 2>/dev/null || return 1
    [ -r "/proc/$check_pid/cmdline" ] \
        && grep -aq "configctl.sh" "/proc/$check_pid/cmdline" 2>/dev/null
}

acquire_fallback_lock() {
    attempts=0
    while ! mkdir "$FALLBACK_LOCK_DIR" 2>/dev/null; do
        old_pid=$(cat "$FALLBACK_LOCK_DIR/pid" 2>/dev/null)
        if fallback_owner_alive "$old_pid"; then
            echo "Another configuration update is in progress." >&2
            return 1
        fi

        # A freshly-created directory may not have its pid file yet. Wait before
        # considering it stale so another process cannot delete a new lock.
        attempts=$((attempts + 1))
        if [ "$attempts" -lt 3 ]; then
            sleep 1
            continue
        fi

        confirmed_pid=$(cat "$FALLBACK_LOCK_DIR/pid" 2>/dev/null)
        if [ "$confirmed_pid" != "$old_pid" ] || fallback_owner_alive "$confirmed_pid"; then
            attempts=0
            continue
        fi
        rm -rf "$FALLBACK_LOCK_DIR" 2>/dev/null || return 1
        attempts=0
    done

    if ! printf '%s\n' "$$" > "$FALLBACK_LOCK_DIR/pid"; then
        rm -rf "$FALLBACK_LOCK_DIR" 2>/dev/null
        return 1
    fi
    LOCK_METHOD="mkdir"
}

acquire_lock() {
    if command -v flock >/dev/null 2>&1; then
        # Android mksh marks high-numbered descriptors close-on-exec, so the
        # Toybox flock process cannot see an `exec 9>...` descriptor.  FD 0 is
        # inherited reliably; this script never consumes its caller's stdin.
        : >> "$LOCK_FILE" || return 1
        exec 0<"$LOCK_FILE" || return 1
        if ! flock -n 0; then
            echo "Another configuration update is in progress." >&2
            exec 0<&-
            return 1
        fi
        LOCK_METHOD="flock"
        return 0
    fi

    acquire_fallback_lock
}

cleanup() {
    exit_status=$?
    trap - 0 HUP INT TERM
    rm -f "$CONFIG_TMP" "$LAST_GOOD_TMP" "$CHECK_LOG_TMP"
    case "$LOCK_METHOD" in
        flock)
            flock -u "$LOCK_FD" 2>/dev/null
            exec 0<&-
            ;;
        mkdir)
            lock_pid=$(cat "$FALLBACK_LOCK_DIR/pid" 2>/dev/null)
            [ "$lock_pid" = "$$" ] && rm -rf "$FALLBACK_LOCK_DIR"
            ;;
    esac
    exit "$exit_status"
}

on_signal() {
    signal_status="$1"
    trap - HUP INT TERM
    exit "$signal_status"
}

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
    generated_secret=""
    if [ -r /proc/sys/kernel/random/uuid ]; then
        generated_secret=$(tr -d '-' < /proc/sys/kernel/random/uuid 2>/dev/null)
    fi
    if [ -z "$generated_secret" ]; then
        generated_secret=$(tr -dc 'A-Za-z0-9' < /dev/urandom 2>/dev/null | head -c 32)
    fi
    if [ -z "$generated_secret" ]; then
        generated_secret="$(date +%s)$$"
    fi
    printf '%s' "$generated_secret"
}

write_config_secret() {
    secret_value="$1"
    is_safe_secret "$secret_value" || return 1

    awk -v secret="$secret_value" '
        BEGIN {
            replacement = "secret: \"" secret "\"  # generated by configctl.sh; keep private"
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
    ' "$CONFIG_FILE" > "$CONFIG_TMP" || return 1

    chmod 600 "$CONFIG_TMP" 2>/dev/null || return 1
    if ! validate_config "$CONFIG_TMP"; then
        rm -f "$CONFIG_TMP"
        return 1
    fi
    mv -f "$CONFIG_TMP" "$CONFIG_FILE"
}

ensure_secret() {
    [ -f "$CONFIG_FILE" ] || {
        echo "Configuration file not found: $CONFIG_FILE" >&2
        return 1
    }

    if has_unsupported_secret_syntax "$CONFIG_FILE"; then
        echo "Unsupported top-level secret YAML syntax; use: secret: \"value\"" >&2
        return 1
    fi

    existing_secret=$(get_config_secret "$CONFIG_FILE")
    secret_count=$(count_top_level_secrets "$CONFIG_FILE")
    if [ "$secret_count" = "1" ] && is_safe_secret "$existing_secret"; then
        ENSURED_SECRET="$existing_secret"
        SECRET_CHANGED=0
        return 0
    fi

    # Empty, unsafe and duplicate top-level values are replaced with one fresh,
    # URL/YAML-safe value. Nested `secret:` keys are intentionally untouched.
    ENSURED_SECRET=$(generate_api_secret)
    is_safe_secret "$ENSURED_SECRET" || {
        echo "Unable to generate a safe API secret." >&2
        return 1
    }
    write_config_secret "$ENSURED_SECRET" || {
        echo "Unable to save API secret." >&2
        return 1
    }
    SECRET_CHANGED=1
}

validate_config() {
    candidate="$1"
    validation_status=0
    "$KERNEL_BIN" -t -d "$CONFIG_DIR" -f "$candidate" \
        0<&- 9>&- >/dev/null 2>"$CHECK_LOG_TMP" || validation_status=$?

    chmod 600 "$CHECK_LOG_TMP" 2>/dev/null
    mv -f "$CHECK_LOG_TMP" "$CHECK_LOG" 2>/dev/null || true
    return "$validation_status"
}

save_last_good() {
    cp -f "$CONFIG_FILE" "$LAST_GOOD_TMP" || return 1
    chmod 600 "$LAST_GOOD_TMP" 2>/dev/null || return 1
    mv -f "$LAST_GOOD_TMP" "$CONFIG_FILE.last-good"
}

if ! acquire_lock; then
    exit 1
fi
trap cleanup 0
trap 'on_signal 129' HUP
trap 'on_signal 130' INT
trap 'on_signal 143' TERM

case "$1" in
    apply-base64)
        encoded="$2"
        [ -n "$encoded" ] || { echo "Configuration payload is empty." >&2; exit 1; }
        printf '%s' "$encoded" | base64 -d > "$CONFIG_TMP" 2>/dev/null || {
            echo "Unable to decode configuration payload." >&2
            exit 1
        }
        [ -s "$CONFIG_TMP" ] || { echo "Decoded configuration is empty." >&2; exit 1; }
        if ! validate_config "$CONFIG_TMP"; then
            echo "Mihomo rejected the new configuration." >&2
            tail -n 20 "$CHECK_LOG" >&2
            exit 1
        fi
        save_last_good || {
            echo "Unable to save the last-known-good configuration." >&2
            exit 1
        }
        chmod 600 "$CONFIG_TMP" 2>/dev/null || exit 1
        mv -f "$CONFIG_TMP" "$CONFIG_FILE" || exit 1
        ;;
    restore)
        [ -s "$CONFIG_FILE.last-good" ] || {
            echo "No last-known-good configuration exists." >&2
            exit 1
        }
        cp -f "$CONFIG_FILE.last-good" "$CONFIG_TMP" || exit 1
        if ! validate_config "$CONFIG_TMP"; then
            echo "Mihomo rejected the last-known-good configuration." >&2
            tail -n 20 "$CHECK_LOG" >&2
            exit 1
        fi
        chmod 600 "$CONFIG_TMP" 2>/dev/null || exit 1
        mv -f "$CONFIG_TMP" "$CONFIG_FILE" || exit 1
        ;;
    ensure-secret)
        case "$2" in
            ''|--changed-exit-code) ;;
            *) echo "Unknown ensure-secret option: $2" >&2; exit 1 ;;
        esac
        ensure_secret || exit 1
        printf '%s\n' "$ENSURED_SECRET"
        if [ "$2" = "--changed-exit-code" ] && [ "$SECRET_CHANGED" -eq 1 ]; then
            exit 10
        fi
        ;;
    *)
        echo "Usage: $0 {apply-base64 <payload>|restore|ensure-secret [--changed-exit-code]}" >&2
        exit 1
        ;;
esac
