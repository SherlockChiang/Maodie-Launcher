#!/system/bin/sh
# Maodie Launcher - optional physical AdBlock service

umask 077

MOD_DIR="${MAODIE_MOD_DIR:-/data/adb/modules/Maodie-Launcher}"
RUN_DIR="$MOD_DIR/maodie/run"
ADBLOCK_LIST="$MOD_DIR/maodie/config/adblock.list"
LOG_FILE="$RUN_DIR/adblock.log"
LOG_MAX_SIZE=262144
LOCK_DIR="$RUN_DIR/adblock.lock"
STATE_FILE="$MOD_DIR/maodie/config/adblock.state"
ENABLE_FILE="$MOD_DIR/maodie/config/adblock.enabled"
DISABLE_FILE="$MOD_DIR/disable"
REMOVE_FILE="$MOD_DIR/remove"
MAINTENANCE_FILE="$RUN_DIR/maintenance"
PROBE_FILE="$RUN_DIR/adblock.chattr.probe"
PROBE_MARKER="$RUN_DIR/adblock.chattr.probe.pending"
RESTORE_INPUT=""
RESTORE_REMAINING=""
INITIAL_DELAY="${MAODIE_ADBLOCK_INITIAL_DELAY:-30}"
PATROL_INTERVAL="${MAODIE_ADBLOCK_INTERVAL:-3600}"
POLL_INTERVAL="${MAODIE_ADBLOCK_POLL_INTERVAL:-30}"

case "$INITIAL_DELAY" in
    ''|*[!0-9]*) INITIAL_DELAY=30 ;;
esac
case "$PATROL_INTERVAL" in
    ''|*[!0-9]*|0) PATROL_INTERVAL=3600 ;;
esac
case "$POLL_INTERVAL" in
    ''|*[!0-9]*|0) POLL_INTERVAL=30 ;;
esac
if [ "$POLL_INTERVAL" -gt "$PATROL_INTERVAL" ]; then
    POLL_INTERVAL="$PATROL_INTERVAL"
fi

mkdir -p "$RUN_DIR" || exit 1
chmod 700 "$RUN_DIR" 2>/dev/null

rotate_log() {
    if [ -f "$LOG_FILE" ] && [ "$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)" -gt "$LOG_MAX_SIZE" ]; then
        mv -f "$LOG_FILE" "$LOG_FILE.old" 2>/dev/null
    fi
}

log() {
    rotate_log
    echo "$(date '+%m-%d %H:%M:%S'): $1" >> "$LOG_FILE"
    chmod 600 "$LOG_FILE" 2>/dev/null
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

normalize_target() {
    normalized_target="$1"
    while [ "$normalized_target" != "/" ] && [ "${normalized_target%/}" != "$normalized_target" ]; do
        normalized_target=${normalized_target%/}
    done
    printf '%s' "$normalized_target"
}

# Return 0 for immutable, 1 for non-immutable, and 2 when attributes cannot be read.
immutable_status() {
    attr_line=$(lsattr -d "$1" 2>/dev/null) || return 2
    attr_flags=${attr_line%% *}
    case "$attr_flags" in
        *i*) return 0 ;;
        *) return 1 ;;
    esac
}

is_safe_target() {
    safe_target=$(normalize_target "$1")
    case "$safe_target" in
        ''|/|*'//'*|*'/../'*|*/..|*'/./'*|*/.|*[[:space:]]*) return 1 ;;
    esac

    case "$safe_target" in
        /data/data/*/*)
            relative_target=${safe_target#/data/data/}
            target_package=${relative_target%%/*}
            expected_resolved="/data/user/0/$relative_target"
            ;;
        /data/media/0/Android/data/*/*)
            relative_target=${safe_target#/data/media/0/Android/data/}
            target_package=${relative_target%%/*}
            expected_resolved="$safe_target"
            ;;
        *) return 1 ;;
    esac

    case "$target_package" in
        ''|*[!A-Za-z0-9._-]*) return 1 ;;
    esac
    [ ! -L "$safe_target" ] || return 1
    command -v readlink >/dev/null 2>&1 || return 1
    resolved_target=$(readlink -f "$safe_target" 2>/dev/null) || return 1
    [ "$resolved_target" = "$safe_target" ] || [ "$resolved_target" = "$expected_resolved" ]
}

state_contains() {
    grep -Fxq "$1" "$STATE_FILE" 2>/dev/null
}

# Write-ahead ledger: record ownership before changing attributes or contents.
record_change() {
    recorded_target="$1"
    if ! state_contains "$recorded_target"; then
        printf '%s\n' "$recorded_target" >> "$STATE_FILE" || return 1
    fi
    chmod 600 "$STATE_FILE" 2>/dev/null
    return 0
}

cleanup_probe() {
    [ -L "$PROBE_FILE" ] && return 1
    if [ -e "$PROBE_FILE" ]; then
        immutable_status "$PROBE_FILE"
        probe_status=$?
        case "$probe_status" in
            0) chattr -i "$PROBE_FILE" 2>/dev/null || return 1 ;;
            1) ;;
            *) return 1 ;;
        esac
        rm -f "$PROBE_FILE" 2>/dev/null || return 1
    fi
    rm -f "$PROBE_MARKER" 2>/dev/null
    return 0
}

# Non-destructive capability probe. The pending marker makes a crash between +i/-i recoverable.
probe_chattr_support() {
    for required_command in chattr lsattr readlink find; do
        if ! command -v "$required_command" >/dev/null 2>&1; then
            log "AdBlock unavailable: required command missing: $required_command"
            return 1
        fi
    done

    cleanup_probe || {
        log "AdBlock unavailable: an old chattr probe could not be restored."
        return 1
    }
    printf '%s\n' "$$" > "$PROBE_MARKER" || return 1
    : > "$PROBE_FILE" || {
        rm -f "$PROBE_MARKER"
        return 1
    }

    if ! chattr +i "$PROBE_FILE" 2>/dev/null; then
        cleanup_probe
        log "AdBlock unavailable: filesystem rejected immutable attributes."
        return 1
    fi
    immutable_status "$PROBE_FILE"
    probe_status=$?
    if [ "$probe_status" -ne 0 ]; then
        cleanup_probe
        log "AdBlock unavailable: immutable probe verification failed."
        return 1
    fi
    if ! chattr -i "$PROBE_FILE" 2>/dev/null; then
        log "AdBlock unavailable: immutable probe could not be reverted."
        return 1
    fi
    immutable_status "$PROBE_FILE"
    probe_status=$?
    if [ "$probe_status" -ne 1 ]; then
        log "AdBlock unavailable: immutable probe remained active."
        return 1
    fi

    rm -f "$PROBE_FILE" "$PROBE_MARKER" 2>/dev/null || return 1
    return 0
}

restore_one() {
    restore_target=$(normalize_target "$1")
    [ -n "$restore_target" ] || return 0

    # Missing emulated-storage paths remain pending until that storage root is
    # visible; otherwise direct-boot could erase the only recovery record.
    if [ ! -e "$restore_target" ] && [ ! -L "$restore_target" ]; then
        case "$restore_target" in
            /data/media/0/Android/data/*)
                [ -d /data/media/0/Android/data ] || return 1
                ;;
        esac
        return 0
    fi
    [ ! -L "$restore_target" ] || return 1
    is_safe_target "$restore_target" || return 1

    immutable_status "$restore_target"
    restore_status=$?
    case "$restore_status" in
        1) return 0 ;;
        0)
            chattr -i "$restore_target" 2>/dev/null || return 1
            immutable_status "$restore_target"
            [ "$?" -eq 1 ]
            return
            ;;
        *) return 1 ;;
    esac
}

restore_changes() {
    restore_failed=0
    cleanup_probe || restore_failed=1

    [ -f "$STATE_FILE" ] || return "$restore_failed"
    if ! user_storage_ready; then
        log "User 0 credential-encrypted storage is still locked; recovery remains pending."
        return 1
    fi

    RESTORE_INPUT="$STATE_FILE.input.$$"
    RESTORE_REMAINING="$STATE_FILE.failed.$$"
    rm -f "$RESTORE_INPUT" "$RESTORE_REMAINING"
    cp -f "$STATE_FILE" "$RESTORE_INPUT" 2>/dev/null || return 1
    : > "$RESTORE_REMAINING" 2>/dev/null || {
        rm -f "$RESTORE_INPUT"
        RESTORE_INPUT=""
        return 1
    }

    ledger_write_failed=0
    while IFS= read -r changed || [ -n "$changed" ]; do
        [ -n "$changed" ] || continue
        normalized_changed=$(normalize_target "$changed")
        if ! restore_one "$normalized_changed"; then
            if ! printf '%s\n' "$normalized_changed" >> "$RESTORE_REMAINING"; then
                ledger_write_failed=1
            fi
            restore_failed=1
            log "Restore failed and remains recorded: $normalized_changed"
        fi
    done < "$RESTORE_INPUT"

    if [ "$ledger_write_failed" -ne 0 ]; then
        # Some targets may already be restored, but the original superset is
        # still a safe retry ledger. Never replace it with a partial file.
        rm -f "$RESTORE_INPUT" "$RESTORE_REMAINING"
        RESTORE_INPUT=""
        RESTORE_REMAINING=""
        return 1
    fi

    if [ -s "$RESTORE_REMAINING" ]; then
        chmod 600 "$RESTORE_REMAINING" 2>/dev/null || restore_failed=1
        if ! mv -f "$RESTORE_REMAINING" "$STATE_FILE" 2>/dev/null; then
            restore_failed=1
            rm -f "$RESTORE_REMAINING"
        fi
    elif [ "$restore_failed" -eq 0 ]; then
        rm -f "$STATE_FILE" 2>/dev/null || restore_failed=1
        rm -f "$RESTORE_REMAINING"
    else
        # Probe or transaction cleanup failed; retain the original ledger.
        rm -f "$RESTORE_REMAINING"
    fi
    rm -f "$RESTORE_INPUT"
    RESTORE_INPUT=""
    RESTORE_REMAINING=""
    [ "$restore_failed" -eq 0 ]
}

# Verify +i and -i on the actual target before any destructive operation.
probe_target_chattr() {
    probe_target="$1"
    record_change "$probe_target" || return 1

    chattr +i "$probe_target" 2>/dev/null || return 1
    immutable_status "$probe_target"
    target_probe_status=$?
    if [ "$target_probe_status" -ne 0 ]; then
        chattr -i "$probe_target" 2>/dev/null
        return 1
    fi
    chattr -i "$probe_target" 2>/dev/null || return 1
    immutable_status "$probe_target"
    [ "$?" -eq 1 ]
}

empty_directory() {
    empty_target="$1"
    # Delete children only; keep the root inode, owner, mode and SELinux label intact.
    find "$empty_target" -mindepth 1 -maxdepth 1 -exec rm -rf {} \; >/dev/null 2>&1 || return 1
    remaining_entry=$(find "$empty_target" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)
    [ -z "$remaining_entry" ]
}

block_ad() {
    target=$(normalize_target "$1")
    [ -e "$target" ] || return
    if ! is_safe_target "$target"; then
        log "Unsafe target skipped: $target"
        skipped_count=$((skipped_count + 1))
        return
    fi

    # A shell redirection follows a symlink swapped in after validation. Without
    # openat(O_NOFOLLOW), regular files cannot be truncated safely in an
    # App-controlled directory, so this implementation only handles directories.
    if [ -f "$target" ]; then
        log "Regular-file target skipped (no race-safe open primitive): $target"
        skipped_count=$((skipped_count + 1))
        return
    fi
    if [ -d "$target" ]; then
        :
    else
        log "Unsupported target type skipped: $target"
        skipped_count=$((skipped_count + 1))
        return
    fi

    immutable_status "$target"
    target_status=$?
    case "$target_status" in
        0)
            # Only claim an immutable target when it is already in this module's ledger.
            if ! state_contains "$target"; then
                log "Pre-existing immutable target left untouched: $target"
                skipped_count=$((skipped_count + 1))
                return
            fi
            if remaining_entry=$(find "$target" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null); then
                [ -z "$remaining_entry" ] && return
            fi
            if ! chattr -i "$target" 2>/dev/null; then
                log "Owned immutable directory is non-empty and could not be reopened: $target"
                skipped_count=$((skipped_count + 1))
                return
            fi
            ;;
        1) ;;
        *)
            log "Unable to read target attributes; skipped: $target"
            skipped_count=$((skipped_count + 1))
            return
            ;;
    esac

    if ! probe_target_chattr "$target"; then
        log "Target failed the immutable capability probe; skipped: $target"
        skipped_count=$((skipped_count + 1))
        return
    fi

    # Revalidate immediately before changing contents.
    if ! is_safe_target "$target"; then
        log "Target changed during validation; skipped: $target"
        skipped_count=$((skipped_count + 1))
        return
    fi
    [ -d "$target" ] && empty_directory "$target" || {
        log "Unable to empty directory safely: $target"
        skipped_count=$((skipped_count + 1))
        return
    }

    if ! is_safe_target "$target"; then
        log "Target changed before immutable commit: $target"
        skipped_count=$((skipped_count + 1))
        return
    fi
    if chattr +i "$target" 2>/dev/null; then
        immutable_status "$target"
        if [ "$?" -eq 0 ]; then
            remaining_entry="__find_failed__"
            if found_entry=$(find "$target" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null); then
                remaining_entry="$found_entry"
            fi
            if [ -z "$remaining_entry" ]; then
                blocked_count=$((blocked_count + 1))
                return
            fi
            chattr -i "$target" 2>/dev/null
            log "Directory changed during immutable commit; it will be retried: $target"
            skipped_count=$((skipped_count + 1))
            return
        fi
    fi

    # The write-ahead entry is deliberately retained so disable/uninstall can retry restoration.
    log "Failed to commit immutable attribute; target remains recorded: $target"
    skipped_count=$((skipped_count + 1))
}

service_alive() {
    check_pid="$1"
    case "$check_pid" in ''|*[!0-9]*) return 1 ;; esac
    kill -0 "$check_pid" 2>/dev/null || return 1
    [ -r "/proc/$check_pid/cmdline" ] \
        && grep -aFq "$MOD_DIR/maodie/scripts/NoAdsService.sh" "/proc/$check_pid/cmdline" 2>/dev/null
}

read_lock_pid() {
    if [ -d "$LOCK_DIR" ]; then
        cat "$LOCK_DIR/pid" 2>/dev/null
    elif [ -f "$LOCK_DIR" ]; then
        cat "$LOCK_DIR" 2>/dev/null
    fi
}

cleanup_lock() {
    lock_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null)
    [ "$lock_pid" = "$$" ] && rm -rf "$LOCK_DIR"
    [ -n "$RESTORE_INPUT" ] && rm -f "$RESTORE_INPUT" 2>/dev/null
    [ -n "$RESTORE_REMAINING" ] && rm -f "$RESTORE_REMAINING" 2>/dev/null
}

acquire_lock() {
    lock_mode="$1"
    lock_attempts=0
    while ! mkdir "$LOCK_DIR" 2>/dev/null; do
        old_pid=$(read_lock_pid)
        if service_alive "$old_pid"; then
            if [ "$lock_mode" != "restore" ]; then
                return 2
            fi
            kill -15 "$old_pid" 2>/dev/null
            lock_wait=0
            while service_alive "$old_pid" && [ "$lock_wait" -lt 10 ]; do
                sleep 1
                lock_wait=$((lock_wait + 1))
            done
            if service_alive "$old_pid"; then
                kill -9 "$old_pid" 2>/dev/null
                sleep 1
            fi
            service_alive "$old_pid" && return 1
        elif [ -d "$LOCK_DIR" ] && [ -z "$old_pid" ] && [ "$lock_attempts" -lt 2 ]; then
            lock_attempts=$((lock_attempts + 1))
            sleep 1
            continue
        fi

        if [ -d "$LOCK_DIR" ]; then
            rm -rf "$LOCK_DIR"
        else
            rm -f "$LOCK_DIR"
        fi
    done

    echo $$ > "$LOCK_DIR/pid" || {
        rm -rf "$LOCK_DIR"
        return 1
    }
    return 0
}

mode="$1"
if [ "$mode" = "restore" ]; then
    acquire_lock restore
    lock_result=$?
    [ "$lock_result" -eq 0 ] || exit 1
    trap cleanup_lock EXIT
    trap 'exit 1' INT TERM
    if restore_changes; then
        log "Recorded AdBlock changes restored."
        exit 0
    fi
    log "Some AdBlock changes could not be restored."
    exit 1
fi

if [ "$mode" = "restore-loop" ]; then
    acquire_lock restore
    lock_result=$?
    [ "$lock_result" -eq 0 ] || exit 1
    trap cleanup_lock EXIT
    trap 'exit 1' INT TERM
    while ! restore_changes; do
        sleep "$POLL_INTERVAL"
    done
    log "Recorded AdBlock changes restored after user storage became available."
    exit 0
fi

if [ -f "$MAINTENANCE_FILE" ] || [ -f "$REMOVE_FILE" ] || [ ! -f "$ENABLE_FILE" ]; then
    acquire_lock restore
    lock_result=$?
    [ "$lock_result" -eq 0 ] || exit 1
    trap cleanup_lock EXIT
    trap 'exit 1' INT TERM
    restore_changes
    exit $?
fi

acquire_lock daemon
lock_result=$?
case "$lock_result" in
    0) ;;
    2) exit 0 ;;
    *) exit 1 ;;
esac
trap cleanup_lock EXIT
trap 'exit 0' INT TERM

log "NoAdsService started (PID $$)."
if [ ! -f "$ADBLOCK_LIST" ]; then
    log "adblock.list not found; nothing to do."
    exit 0
fi

next_patrol="$INITIAL_DELAY"
paused=0
chattr_ready=0
storage_wait_logged=0

while :; do
    if [ -f "$MAINTENANCE_FILE" ]; then
        log "Maintenance requested; restoring and stopping AdBlock."
        restore_changes
        exit $?
    fi
    if [ -f "$REMOVE_FILE" ]; then
        log "Module removal requested; restoring and stopping AdBlock."
        restore_changes
        exit $?
    fi
    if [ ! -f "$ENABLE_FILE" ]; then
        log "AdBlock opt-in marker removed; restoring and stopping."
        restore_changes
        exit $?
    fi
    if [ -f "$DISABLE_FILE" ]; then
        if [ "$paused" -eq 0 ] || [ -f "$STATE_FILE" ] || [ -f "$PROBE_MARKER" ]; then
            if restore_changes; then
                log "Module disabled; AdBlock restored and paused."
            else
                log "Module disabled; AdBlock restoration will be retried."
            fi
        fi
        paused=1
        sleep "$POLL_INTERVAL"
        continue
    fi

    if ! user_storage_ready; then
        if [ "$storage_wait_logged" -eq 0 ]; then
            log "User 0 storage is locked; AdBlock patrol is waiting."
            storage_wait_logged=1
        fi
        sleep "$POLL_INTERVAL"
        continue
    fi
    storage_wait_logged=0

    if [ "$paused" -eq 1 ]; then
        log "Module re-enabled; AdBlock patrol resumed."
        paused=0
        next_patrol=0
        chattr_ready=0
    fi

    if [ "$next_patrol" -le 0 ]; then
        if [ "$chattr_ready" -eq 0 ]; then
            if probe_chattr_support; then
                chattr_ready=1
            else
                retry_delay="$PATROL_INTERVAL"
                [ "$retry_delay" -gt 300 ] && retry_delay=300
                next_patrol="$retry_delay"
            fi
        fi

        if [ "$chattr_ready" -eq 1 ]; then
            blocked_count=0
            skipped_count=0
            patrol_interrupted=0
            while IFS= read -r target || [ -n "$target" ]; do
                case "$target" in
                    ''|\#*) continue ;;
                esac
                if [ -f "$MAINTENANCE_FILE" ] || [ -f "$REMOVE_FILE" ] || [ -f "$DISABLE_FILE" ] || [ ! -f "$ENABLE_FILE" ]; then
                    patrol_interrupted=1
                    break
                fi
                block_ad "$target"
            done < "$ADBLOCK_LIST"

            [ "$blocked_count" -gt 0 ] && log "Patrol blocked $blocked_count path(s)."
            [ "$skipped_count" -gt 0 ] && log "Patrol skipped $skipped_count path(s)."
            if [ "$patrol_interrupted" -eq 1 ]; then
                next_patrol=0
                continue
            fi
            next_patrol="$PATROL_INTERVAL"
        fi
    fi

    sleep_for="$POLL_INTERVAL"
    if [ "$next_patrol" -gt 0 ] && [ "$next_patrol" -lt "$sleep_for" ]; then
        sleep_for="$next_patrol"
    fi
    [ "$sleep_for" -gt 0 ] || sleep_for=1
    sleep "$sleep_for"
    next_patrol=$((next_patrol - sleep_for))
done
