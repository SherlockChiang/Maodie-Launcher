#!/system/bin/sh
# Maodie Core - 兼容版 (Android 7.0 - Android 16)

umask 077

MOD_DIR="${MAODIE_MOD_DIR:-/data/adb/modules/Maodie-Launcher}"
export MAODIE_MOD_DIR="$MOD_DIR"
KERNEL_BIN="$MOD_DIR/maodie/kernel/Mihomo"
CONFIG_DIR="$MOD_DIR/maodie/config"
CONFIG_FILE="$CONFIG_DIR/config.yaml"
RUN_DIR="$MOD_DIR/maodie/run"
PID_FILE="$RUN_DIR/kernel.pid"
LOG_FILE="$RUN_DIR/kernel.log"
CONFIG_CHECK_LOG="$RUN_DIR/config-start-check.log"
LOG_MAX_SIZE=524288  # 512KB
OOM_SCORE_ADJ=${MAODIE_OOM_SCORE_ADJ:--200}
LOCK_DIR="$RUN_DIR/core.lock"
SYSCTL_STATE="$RUN_DIR/sysctl.state"
NETWORK_SCRIPT="$MOD_DIR/maodie/scripts/network.sh"
DISABLE_FILE="$MOD_DIR/disable"
REMOVE_FILE="$MOD_DIR/remove"
MAINTENANCE_FILE="$RUN_DIR/maintenance"

API_LEVEL=$(getprop ro.build.version.sdk 2>/dev/null)

mkdir -p "$RUN_DIR"
chmod 700 "$RUN_DIR" 2>/dev/null
chmod 600 "$LOG_FILE" "$LOG_FILE.old" "$CONFIG_CHECK_LOG" \
    "$PID_FILE" "$SYSCTL_STATE" 2>/dev/null || true

proc_has_arg() {
    local pid="$1" expected="$2"
    [ -r "/proc/$pid/cmdline" ] || return 1
    tr '\000' '\n' < "/proc/$pid/cmdline" 2>/dev/null | grep -Fxq -- "$expected"
}

kernel_pid_alive() {
    local pid="$1"
    [ -n "$pid" ] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    proc_has_arg "$pid" "$KERNEL_BIN" || return 1
    ! kernel_pid_is_validation "$pid"
}

kernel_pid_is_validation() {
    local pid="$1"
    proc_has_arg "$pid" '-t'
}

signal_module_cores() {
    local signal_name="$1"
    local proc_dir proc_pid found=1
    for proc_dir in /proc/[0-9]*; do
        [ -r "$proc_dir/cmdline" ] || continue
        grep -aFq "$KERNEL_BIN" "$proc_dir/cmdline" 2>/dev/null || continue
        proc_pid=${proc_dir##*/}
        proc_has_arg "$proc_pid" "$KERNEL_BIN" || continue
        kernel_pid_is_validation "$proc_pid" && continue
        kill "$signal_name" "$proc_pid" 2>/dev/null && found=0
    done
    return "$found"
}

find_module_core_pid() {
    local proc_dir proc_pid
    for proc_dir in /proc/[0-9]*; do
        [ -r "$proc_dir/cmdline" ] || continue
        grep -aFq "$KERNEL_BIN" "$proc_dir/cmdline" 2>/dev/null || continue
        proc_pid=${proc_dir##*/}
        proc_has_arg "$proc_pid" "$KERNEL_BIN" || continue
        # A concurrent `Mihomo -t` validation is not the long-running core.
        kernel_pid_is_validation "$proc_pid" && continue
        kernel_pid_alive "$proc_pid" || continue
        printf '%s\n' "$proc_pid"
        return 0
    done
    return 1
}

core_lock_owner_alive() {
    local owner_pid="$1"
    [ -n "$owner_pid" ] || return 1
    kill -0 "$owner_pid" 2>/dev/null || return 1
    proc_has_arg "$owner_pid" "$MOD_DIR/maodie/scripts/core.sh"
}

acquire_lock() {
    local attempts=0 old_pid
    while ! mkdir "$LOCK_DIR" 2>/dev/null; do
        old_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null)
        if core_lock_owner_alive "$old_pid"; then
            attempts=$((attempts + 1))
            [ "$attempts" -ge 15 ] && return 1
            sleep 1
            continue
        fi

        # Avoid stealing a valid lock during its short mkdir -> pid window.
        if [ -z "$old_pid" ] && [ "$attempts" -lt 2 ]; then
            attempts=$((attempts + 1))
            sleep 1
            continue
        fi
        rm -rf "$LOCK_DIR"
    done
    echo $$ > "$LOCK_DIR/pid"
}

release_lock() {
    [ "$(cat "$LOCK_DIR/pid" 2>/dev/null)" = "$$" ] && rm -rf "$LOCK_DIR"
}

copy_log_tail() {
    local source_file="$1" destination_file="$2"
    local tail_tmp="$RUN_DIR/.kernel.log.tail.$$"
    if ! tail -c "$LOG_MAX_SIZE" "$source_file" > "$tail_tmp" 2>/dev/null; then
        rm -f "$tail_tmp" 2>/dev/null
        return 1
    fi
    chmod 600 "$tail_tmp" 2>/dev/null
    mv -f "$tail_tmp" "$destination_file"
}

rotate_log() {
    local size old_size
    if [ -f "$LOG_FILE" ]; then
        size=$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)
        if [ "$size" -gt "$LOG_MAX_SIZE" ]; then
            if copy_log_tail "$LOG_FILE" "${LOG_FILE}.old"; then
                : > "$LOG_FILE"
            else
                mv -f "$LOG_FILE" "${LOG_FILE}.old"
            fi
        fi
    fi

    # Older versions could leave a multi-megabyte rotated log indefinitely.
    if [ -f "${LOG_FILE}.old" ]; then
        old_size=$(wc -c < "${LOG_FILE}.old" 2>/dev/null || echo 0)
        if [ "$old_size" -gt "$LOG_MAX_SIZE" ]; then
            copy_log_tail "${LOG_FILE}.old" "${LOG_FILE}.old" || true
        fi
    fi
    chmod 600 "$LOG_FILE" "${LOG_FILE}.old" 2>/dev/null || true
}

safe_sysctl() {
    local val=$1
    local file=$2
    local current
    [ -f "$file" ] || return
    current=$(cat "$file" 2>/dev/null) || return
    [ "$current" = "$val" ] && return
    if ! grep -Fq "$file|" "$SYSCTL_STATE" 2>/dev/null; then
        printf '%s|%s|%s\n' "$file" "$current" "$val" >> "$SYSCTL_STATE"
        chmod 600 "$SYSCTL_STATE" 2>/dev/null
    fi
    echo "$val" > "$file" 2>/dev/null
}

safe_sysctl_min() {
    local minimum="$1"
    local file="$2"
    local current
    [ -f "$file" ] || return
    current=$(cat "$file" 2>/dev/null) || return
    case "$current:$minimum" in
        *[!0-9:]*) return ;;
    esac
    [ "$current" -ge "$minimum" ] 2>/dev/null && return
    safe_sysctl "$minimum" "$file"
}

restore_tuning() {
    local file original applied current
    [ -f "$SYSCTL_STATE" ] || return
    while IFS='|' read -r file original applied; do
        [ -f "$file" ] || continue
        current=$(cat "$file" 2>/dev/null) || continue
        [ "$current" = "$applied" ] && echo "$original" > "$file" 2>/dev/null
    done < "$SYSCTL_STATE"
    rm -f "$SYSCTL_STATE"
}

apply_tuning() {
    echo "--- System Tuning (SDK: $API_LEVEL) ---" >> "$LOG_FILE"

    safe_sysctl 1 /proc/sys/net/ipv4/ip_forward
    safe_sysctl 1 /proc/sys/net/ipv6/conf/all/forwarding

    for file in /proc/sys/net/ipv4/conf/*/rp_filter; do
        safe_sysctl 0 "$file"
    done

    # Capacity knobs are lower bounds only. Never reduce a larger OEM value.
    safe_sysctl_min 65536 /proc/sys/net/netfilter/nf_conntrack_max
    safe_sysctl_min 8388608 /proc/sys/net/core/wmem_max
    safe_sysctl_min 8388608 /proc/sys/net/core/rmem_max
}

network_apply() {
    [ -r "$NETWORK_SCRIPT" ] || {
        echo "Error: Network controller missing: $NETWORK_SCRIPT" >> "$LOG_FILE"
        return 1
    }
    sh "$NETWORK_SCRIPT" apply >> "$LOG_FILE" 2>&1
}

network_clear() {
    [ -r "$NETWORK_SCRIPT" ] || return 1
    sh "$NETWORK_SCRIPT" clear >> "$LOG_FILE" 2>&1
}

validate_config() {
    if "$KERNEL_BIN" -t -d "$CONFIG_DIR" -f "$CONFIG_FILE" > "$CONFIG_CHECK_LOG" 2>&1; then
        chmod 600 "$CONFIG_CHECK_LOG" 2>/dev/null
        return 0
    fi

    chmod 600 "$CONFIG_CHECK_LOG" 2>/dev/null
    echo "Error: Mihomo rejected the active configuration." >> "$LOG_FILE"
    tail -n 20 "$CONFIG_CHECK_LOG" >> "$LOG_FILE" 2>/dev/null
    return 1
}

inactive_reason() {
    if [ -f "$MAINTENANCE_FILE" ]; then
        printf 'maintenance\n'
    elif [ -f "$REMOVE_FILE" ]; then
        printf 'scheduled removal\n'
    elif [ -f "$DISABLE_FILE" ]; then
        printf 'module disabled\n'
    else
        return 1
    fi
}

is_running() {
    local pid pid_tmp
    if [ -f "$PID_FILE" ]; then
        pid=$(cat "$PID_FILE" 2>/dev/null)
        kernel_pid_alive "$pid" && return 0
        # PID 文件存在但进程已死或 PID 被复用，清理残留
        rm -f "$PID_FILE"
    fi

    # Recover from a lost PID file before starting another core instance.
    pid=$(find_module_core_pid) || return 1
    pid_tmp="$PID_FILE.tmp.$$"
    if printf '%s\n' "$pid" > "$pid_tmp" 2>/dev/null; then
        chmod 600 "$pid_tmp" 2>/dev/null
        if mv -f "$pid_tmp" "$PID_FILE" 2>/dev/null; then
            echo "Recovered running core PID: $pid" >> "$LOG_FILE"
            return 0
        fi
    fi
    rm -f "$pid_tmp" 2>/dev/null
    return 1
}

start() {
    local blocked_reason
    if blocked_reason=$(inactive_reason); then
        echo "Refusing to start core: $blocked_reason." >> "$LOG_FILE"
        stop >/dev/null 2>&1
        return 1
    fi

    if is_running; then
        echo "Maodie Core is already running (PID: $(cat "$PID_FILE"))."
        return
    fi

    if [ ! -x "$KERNEL_BIN" ]; then
        echo "Error: Kernel binary not found or not executable: $KERNEL_BIN" | tee -a "$LOG_FILE"
        return 1
    fi

    if [ ! -f "$CONFIG_FILE" ]; then
        echo "Error: Config file not found: $CONFIG_FILE" | tee -a "$LOG_FILE"
        return 1
    fi

    if [ ! -r "$NETWORK_SCRIPT" ]; then
        echo "Error: Network controller not found: $NETWORK_SCRIPT" | tee -a "$LOG_FILE"
        return 1
    fi

    rotate_log
    echo "--- Starting Maodie (Time: $(date)) ---" >> "$LOG_FILE"

    # Validate every start. Manual edits and upgrade migrations do not pass
    # through configctl.sh, so its write-time validation is not sufficient.
    validate_config || return 1

    apply_tuning

    ulimit -n 65536 2>/dev/null

    nohup "$KERNEL_BIN" -d "$CONFIG_DIR" -f "$CONFIG_FILE" >> "$LOG_FILE" 2>&1 &
    PID=$!
    echo "$PID" > "$PID_FILE"
    chmod 600 "$PID_FILE" 2>/dev/null

    # 等待短暂时间确认进程存活
    sleep 1
    if ! kill -0 "$PID" 2>/dev/null; then
        echo "Error: Kernel exited immediately. Check log for details." | tee -a "$LOG_FILE"
        rm -f "$PID_FILE"
        restore_tuning
        return 1
    fi

    if [ -f /proc/$PID/oom_score_adj ]; then
        echo "$OOM_SCORE_ADJ" > /proc/$PID/oom_score_adj 2>/dev/null
    fi

    if ! network_apply; then
        kill -15 "$PID" 2>/dev/null
        wait=0
        while [ "$wait" -lt 3 ] && kernel_pid_alive "$PID"; do
            sleep 1
            wait=$((wait + 1))
        done
        kernel_pid_alive "$PID" && kill -9 "$PID" 2>/dev/null
        rm -f "$PID_FILE"
        network_clear >/dev/null 2>&1
        restore_tuning
        return 1
    fi

    echo "Core started with PID: $PID" >> "$LOG_FILE"
}

stop() {
    local wait=0 network_status=0
    if [ -f "$PID_FILE" ]; then
        PID=$(cat "$PID_FILE" 2>/dev/null)
        if kernel_pid_alive "$PID"; then
            kill -15 "$PID" 2>/dev/null

            while [ "$wait" -lt 3 ] && kill -0 "$PID" 2>/dev/null; do
                sleep 1
                wait=$((wait + 1))
            done

            if kernel_pid_alive "$PID"; then
                kill -9 "$PID" 2>/dev/null
                echo "Warning: Core didn't stop gracefully, force killed." >> "$LOG_FILE"
            fi
        fi
    fi
    rm -f "$PID_FILE"

    # Always perform the path-scoped orphan cleanup. A stale/reused PID file
    # must not suppress cleanup of another instance started by this module.
    if signal_module_cores -15; then
        sleep 2
        signal_module_cores -9 >/dev/null 2>&1
    fi

    network_clear || network_status=$?
    restore_tuning
    echo "--- Core stopped (Time: $(date)) ---" >> "$LOG_FILE"
    return "$network_status"
}

restart() {
    local blocked_reason
    if blocked_reason=$(inactive_reason); then
        echo "Refusing to restart core: $blocked_reason." >> "$LOG_FILE"
        stop >/dev/null 2>&1
        return 1
    fi

    # Preserve a currently healthy in-memory configuration when a manual
    # disk edit is invalid. Validate before terminating the running process.
    if is_running; then
        if [ ! -x "$KERNEL_BIN" ] || [ ! -f "$CONFIG_FILE" ]; then
            echo "Error: Restart preflight files are missing; current core kept running." >> "$LOG_FILE"
            return 1
        fi
        if ! validate_config; then
            echo "Error: Restart aborted; current core kept running." >> "$LOG_FILE"
            return 1
        fi
    fi

    stop >/dev/null 2>&1
    sleep 1
    start
}

status() {
    if is_running; then
        echo "Maodie Core is running (PID: $(cat "$PID_FILE"))."
    else
        echo "Maodie Core is not running."
    fi
}

# 幂等地重铺系统调优与模块专属防火墙规则（不重启内核）。
# 用于看门狗在 system_server 运行时重启、netd 冲掉规则后自愈。
reapply() {
    local blocked_reason
    if blocked_reason=$(inactive_reason); then
        echo "Refusing to reapply network state: $blocked_reason." >> "$LOG_FILE"
        stop >/dev/null 2>&1
        return 1
    fi

    apply_tuning
    if network_apply; then
        return 0
    fi
    echo "Error: Failed to reapply network rules." >> "$LOG_FILE"
    return 1
}

case "$1" in
    start|stop|restart|reapply)
        if ! acquire_lock; then
            echo "Error: Another core operation is still running." >&2
            exit 1
        fi
        trap release_lock EXIT
        ;;
esac

case "$1" in
    start)   start ;;
    stop)    stop ;;
    restart) restart ;;
    reapply) reapply ;;
    status)  status ;;
    *)       echo "Usage: $0 {start|stop|restart|reapply|status}"; exit 1 ;;
esac
