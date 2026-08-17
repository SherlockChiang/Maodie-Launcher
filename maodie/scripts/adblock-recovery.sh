#!/system/bin/sh
# Standalone recovery helper copied outside the module before uninstall.

umask 077

SCRIPT_DIR="${0%/*}"
[ "$SCRIPT_DIR" = "$0" ] && SCRIPT_DIR="."
STATE_FILE="${MAODIE_ADBLOCK_STATE:-$SCRIPT_DIR/adblock.state}"
LOCK_DIR="$SCRIPT_DIR/recovery.lock"
SERVICE_ENTRY="/data/adb/service.d/maodie-adblock-recovery.sh"
RECOVERY_POLL_INTERVAL="${MAODIE_RECOVERY_POLL_INTERVAL:-30}"
case "$RECOVERY_POLL_INTERVAL" in ''|*[!0-9]*|0) RECOVERY_POLL_INTERVAL=30 ;; esac

RECOVERY_INPUT=""
RECOVERY_REMAINING=""

cleanup() {
    lock_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null)
    [ "$lock_pid" = "$$" ] && rm -rf "$LOCK_DIR" 2>/dev/null
    [ -n "$RECOVERY_INPUT" ] && rm -f "$RECOVERY_INPUT" 2>/dev/null
    [ -n "$RECOVERY_REMAINING" ] && rm -f "$RECOVERY_REMAINING" 2>/dev/null
}

acquire_lock() {
    attempts=0
    while ! mkdir "$LOCK_DIR" 2>/dev/null; do
        [ -e "$LOCK_DIR" ] || return 1
        old_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null)
        if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null \
            && [ -r "/proc/$old_pid/cmdline" ] \
            && grep -aFq "$SCRIPT_DIR/recover.sh" "/proc/$old_pid/cmdline" 2>/dev/null; then
            return 2
        fi
        if [ -z "$old_pid" ] && [ "$attempts" -lt 2 ]; then
            attempts=$((attempts + 1))
            sleep 1
            continue
        fi
        rm -rf "$LOCK_DIR" 2>/dev/null || return 1
    done
    printf '%s\n' $$ > "$LOCK_DIR/pid" || {
        # Do not leave an ownerless lock behind when the filesystem rejects
        # the pid write (for example after a transient storage failure).
        rm -rf "$LOCK_DIR" 2>/dev/null
        return 1
    }
}

normalize_target() {
    normalized_target="$1"
    while [ "$normalized_target" != "/" ] && [ "${normalized_target%/}" != "$normalized_target" ]; do
        normalized_target=${normalized_target%/}
    done
    printf '%s' "$normalized_target"
}

safe_recovery_target() {
    recovery_target=$(normalize_target "$1")
    case "$recovery_target" in
        ''|/|*'//'*|*'/../'*|*/..|*'/./'*|*/.|*[[:space:]]) return 1 ;;
        /data/data/*/*)
            relative_target=${recovery_target#/data/data/}
            expected_resolved="/data/user/0/$relative_target"
            ;;
        /data/media/0/Android/data/*/*) expected_resolved="$recovery_target" ;;
        *) return 1 ;;
    esac
    [ ! -L "$recovery_target" ] || return 1
    command -v readlink >/dev/null 2>&1 || return 1
    resolved_target=$(readlink -f "$recovery_target" 2>/dev/null) || return 1
    [ "$resolved_target" = "$recovery_target" ] || [ "$resolved_target" = "$expected_resolved" ]
}

immutable_status() {
    attr_line=$(lsattr -d "$1" 2>/dev/null) || return 2
    attr_flags=${attr_line%% *}
    case "$attr_flags" in *i*) return 0 ;; *) return 1 ;; esac
}

user_storage_ready() {
    [ "${MAODIE_ASSUME_USER_UNLOCKED:-0}" = "1" ] && return 0
    if command -v am >/dev/null 2>&1; then
        unlock_state=$(am get-started-user-state 0 2>/dev/null)
        printf '%s\n' "$unlock_state" | grep -q 'RUNNING_UNLOCKED' && return 0
    fi
    if command -v cmd >/dev/null 2>&1; then
        unlock_state=$(cmd activity get-started-user-state 0 2>/dev/null)
        printf '%s\n' "$unlock_state" | grep -q 'RUNNING_UNLOCKED' && return 0
    fi
    return 1
}

restore_target() {
    target="$1"
    if [ ! -e "$target" ] && [ ! -L "$target" ]; then
        case "$target" in
            /data/media/0/Android/data/*) [ -d /data/media/0/Android/data ] || return 1 ;;
        esac
        return 0
    fi
    safe_recovery_target "$target" || return 1
    immutable_status "$target"
    status=$?
    case "$status" in
        1) return 0 ;;
        0)
            chattr -i "$target" 2>/dev/null || return 1
            immutable_status "$target"
            [ "$?" -eq 1 ]
            return
            ;;
        *) return 1 ;;
    esac
}

recover_once() {
    [ -f "$STATE_FILE" ] || return 0
    [ ! -L "$STATE_FILE" ] || return 1

    RECOVERY_INPUT="$STATE_FILE.input.$$"
    RECOVERY_REMAINING="$STATE_FILE.failed.$$"
    rm -f "$RECOVERY_INPUT" "$RECOVERY_REMAINING"
    cp -f "$STATE_FILE" "$RECOVERY_INPUT" 2>/dev/null || return 1
    : > "$RECOVERY_REMAINING" 2>/dev/null || return 1

    ledger_write_failed=0
    while IFS= read -r target || [ -n "$target" ]; do
        [ -n "$target" ] || continue
        target=$(normalize_target "$target")
        if ! restore_target "$target"; then
            printf '%s\n' "$target" >> "$RECOVERY_REMAINING" || ledger_write_failed=1
        fi
    done < "$RECOVERY_INPUT"

    if [ "$ledger_write_failed" -ne 0 ]; then
        rm -f "$RECOVERY_INPUT" "$RECOVERY_REMAINING"
        RECOVERY_INPUT=""
        RECOVERY_REMAINING=""
        return 1
    fi
    if [ -s "$RECOVERY_REMAINING" ]; then
        chmod 600 "$RECOVERY_REMAINING" 2>/dev/null || return 1
        mv -f "$RECOVERY_REMAINING" "$STATE_FILE" 2>/dev/null || return 1
        RECOVERY_REMAINING=""
        rm -f "$RECOVERY_INPUT"
        RECOVERY_INPUT=""
        return 1
    fi

    rm -f "$STATE_FILE" 2>/dev/null || return 1
    rm -f "$RECOVERY_INPUT" "$RECOVERY_REMAINING"
    RECOVERY_INPUT=""
    RECOVERY_REMAINING=""
    return 0
}

acquire_lock
lock_status=$?
case "$lock_status" in 0) ;; 2) exit 75 ;; *) exit 1 ;; esac
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

if [ "$1" = "--wait" ]; then
    while [ -f "$STATE_FILE" ]; do
        if user_storage_ready && recover_once; then
            break
        fi
        sleep "$RECOVERY_POLL_INTERVAL"
    done
else
    user_storage_ready || {
        echo "User 0 storage is locked; recovery ledger was preserved for a later retry." >&2
        exit 1
    }
    recover_once || {
        echo "Recovery is incomplete. Remaining paths are recorded in $STATE_FILE" >&2
        exit 1
    }
fi

if [ "$SCRIPT_DIR" = "/data/adb/maodie-launcher-recovery" ] && [ ! -s "$STATE_FILE" ]; then
    rm -f "$SERVICE_ENTRY" 2>/dev/null
fi
echo "All recorded Maodie AdBlock attributes were restored."
exit 0
