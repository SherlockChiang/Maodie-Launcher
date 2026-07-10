#!/system/bin/sh
# Maodie Core - 兼容版 (Android 7.0 - Android 16)

MOD_DIR="/data/adb/modules/Maodie-Launcher"
KERNEL_BIN="$MOD_DIR/maodie/kernel/Mihomo"
CONFIG_DIR="$MOD_DIR/maodie/config"
CONFIG_FILE="$CONFIG_DIR/config.yaml"
RUN_DIR="$MOD_DIR/maodie/run"
PID_FILE="$RUN_DIR/kernel.pid"
LOG_FILE="$RUN_DIR/kernel.log"
LOG_MAX_SIZE=524288  # 512KB
OOM_SCORE_ADJ=${MAODIE_OOM_SCORE_ADJ:--200}
WAIT_MODE_FILE="$RUN_DIR/iptables_wait.mode"
LOCK_DIR="$RUN_DIR/core.lock"
SYSCTL_STATE="$RUN_DIR/sysctl.state"

API_LEVEL=$(getprop ro.build.version.sdk)

mkdir -p "$RUN_DIR"
chmod 700 "$RUN_DIR" 2>/dev/null

kernel_pid_alive() {
    local pid="$1"
    [ -n "$pid" ] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    [ -r "/proc/$pid/cmdline" ] && grep -aq "$KERNEL_BIN" "/proc/$pid/cmdline" 2>/dev/null
}

acquire_lock() {
    local attempts=0 old_pid
    while ! mkdir "$LOCK_DIR" 2>/dev/null; do
        old_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null)
        if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
            attempts=$((attempts + 1))
            [ "$attempts" -ge 15 ] && return 1
            sleep 1
        else
            rm -rf "$LOCK_DIR"
        fi
    done
    echo $$ > "$LOCK_DIR/pid"
}

release_lock() {
    [ "$(cat "$LOCK_DIR/pid" 2>/dev/null)" = "$$" ] && rm -rf "$LOCK_DIR"
}

rotate_log() {
    if [ -f "$LOG_FILE" ]; then
        local size=$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)
        if [ "$size" -gt "$LOG_MAX_SIZE" ]; then
            mv -f "$LOG_FILE" "${LOG_FILE}.old"
        fi
    fi
}

detect_iptables_wait() {
    # 记忆化：单次脚本调用内最多探测一次，并跨 reapply 调用缓存探测结果。
    [ -n "$IPT_WAIT_DETECTED" ] && return
    IPT_WAIT_DETECTED=1

    if [ -f "$WAIT_MODE_FILE" ]; then
        local cached_mode=$(cat "$WAIT_MODE_FILE" 2>/dev/null)
        case "$cached_mode" in
            interval)
                IPT_WAIT="-w 2"
                IPV6_WAIT="-w 2"
                return
                ;;
            wait)
                IPT_WAIT="-w 2"
                IPV6_WAIT="-w 2"
                return
                ;;
            none)
                IPT_WAIT=""
                IPV6_WAIT=""
                return
                ;;
        esac
    fi

    local wait_mode
    if iptables --help 2>/dev/null | grep -q "wait"; then
        if iptables --help 2>/dev/null | grep -q "wait interval"; then
            IPT_WAIT="-w 2"
            IPV6_WAIT="-w 2"
            wait_mode="interval"
        else
            IPT_WAIT="-w 2"
            IPV6_WAIT="-w 2"
            wait_mode="wait"
        fi
    else
        IPT_WAIT=""
        IPV6_WAIT=""
        wait_mode="none"
        echo "Info: 当前系统 iptables 不支持等待锁，已降级运行。" >> "$LOG_FILE"
    fi
    echo "$wait_mode" > "$WAIT_MODE_FILE" 2>/dev/null
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

restore_tuning() {
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

    safe_sysctl 65536 /proc/sys/net/netfilter/nf_conntrack_max
    safe_sysctl 8388608 /proc/sys/net/core/wmem_max
    safe_sysctl 8388608 /proc/sys/net/core/rmem_max
}

apply_iptables() {
    detect_iptables_wait
    local failed=0

    iptables $IPT_WAIT -C FORWARD -i "utun+" -j ACCEPT 2>/dev/null || iptables $IPT_WAIT -I FORWARD -i "utun+" -j ACCEPT || failed=1
    iptables $IPT_WAIT -C FORWARD -o "utun+" -j ACCEPT 2>/dev/null || iptables $IPT_WAIT -I FORWARD -o "utun+" -j ACCEPT || failed=1

    iptables $IPT_WAIT -t mangle -C PREROUTING -m mark --mark 2022 -j RETURN 2>/dev/null || iptables $IPT_WAIT -t mangle -I PREROUTING -m mark --mark 2022 -j RETURN || failed=1

    if [ -f /proc/net/if_inet6 ]; then
        ip6tables $IPV6_WAIT -C FORWARD -i "utun+" -j ACCEPT 2>/dev/null || ip6tables $IPV6_WAIT -I FORWARD -i "utun+" -j ACCEPT
        ip6tables $IPV6_WAIT -C FORWARD -o "utun+" -j ACCEPT 2>/dev/null || ip6tables $IPV6_WAIT -I FORWARD -o "utun+" -j ACCEPT
    fi

    if [ "$failed" -ne 0 ]; then
        echo "Error: Failed to apply required IPv4 iptables rules." >> "$LOG_FILE"
        return 1
    fi
    echo "iptables rules applied." >> "$LOG_FILE"
}

clear_iptables() {
    detect_iptables_wait

    while iptables $IPT_WAIT -C FORWARD -i "utun+" -j ACCEPT 2>/dev/null; do
        iptables $IPT_WAIT -D FORWARD -i "utun+" -j ACCEPT 2>/dev/null || break
    done
    while iptables $IPT_WAIT -C FORWARD -o "utun+" -j ACCEPT 2>/dev/null; do
        iptables $IPT_WAIT -D FORWARD -o "utun+" -j ACCEPT 2>/dev/null || break
    done
    while iptables $IPT_WAIT -t mangle -C PREROUTING -m mark --mark 2022 -j RETURN 2>/dev/null; do
        iptables $IPT_WAIT -t mangle -D PREROUTING -m mark --mark 2022 -j RETURN 2>/dev/null || break
    done

    if [ -f /proc/net/if_inet6 ]; then
        while ip6tables $IPV6_WAIT -C FORWARD -i "utun+" -j ACCEPT 2>/dev/null; do
            ip6tables $IPV6_WAIT -D FORWARD -i "utun+" -j ACCEPT 2>/dev/null || break
        done
        while ip6tables $IPV6_WAIT -C FORWARD -o "utun+" -j ACCEPT 2>/dev/null; do
            ip6tables $IPV6_WAIT -D FORWARD -o "utun+" -j ACCEPT 2>/dev/null || break
        done
    fi

    echo "iptables rules cleared." >> "$LOG_FILE"
}

is_running() {
    if [ -f "$PID_FILE" ]; then
        local pid=$(cat "$PID_FILE" 2>/dev/null)
        kernel_pid_alive "$pid" && return 0
        # PID 文件存在但进程已死或 PID 被复用，清理残留
        rm -f "$PID_FILE"
    fi
    return 1
}

start() {
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

    rotate_log
    echo "--- Starting Maodie (Time: $(date)) ---" >> "$LOG_FILE"

    apply_tuning

    ulimit -n 65536 2>/dev/null

    nohup "$KERNEL_BIN" -d "$CONFIG_DIR" -f "$CONFIG_FILE" >> "$LOG_FILE" 2>&1 &
    PID=$!
    echo $PID > "$PID_FILE"

    # 等待短暂时间确认进程存活
    sleep 1
    if ! kill -0 $PID 2>/dev/null; then
        echo "Error: Kernel exited immediately. Check log for details." | tee -a "$LOG_FILE"
        rm -f "$PID_FILE"
        return 1
    fi

    if [ -f /proc/$PID/oom_score_adj ]; then
        echo "$OOM_SCORE_ADJ" > /proc/$PID/oom_score_adj 2>/dev/null
    fi

    if ! apply_iptables; then
        kill -15 "$PID" 2>/dev/null
        rm -f "$PID_FILE"
        restore_tuning
        return 1
    fi

    echo "Core started with PID: $PID" >> "$LOG_FILE"
}

stop() {
    if [ -f "$PID_FILE" ]; then
        PID=$(cat "$PID_FILE" 2>/dev/null)
        if kernel_pid_alive "$PID"; then
            kill -15 $PID 2>/dev/null

            local wait=0
            while [ $wait -lt 3 ] && kill -0 $PID 2>/dev/null; do
                sleep 1
                wait=$((wait + 1))
            done

            if kernel_pid_alive "$PID"; then
                kill -9 $PID 2>/dev/null
                echo "Warning: Core didn't stop gracefully, force killed." >> "$LOG_FILE"
            fi
        fi
        rm -f "$PID_FILE"
    else
        # 无 PID 文件时，仅清理本模块核心，避免误伤其它 Mihomo 实例。
        pkill -15 -f "$KERNEL_BIN" 2>/dev/null
        sleep 2
        pkill -9 -f "$KERNEL_BIN" 2>/dev/null
    fi

    clear_iptables
    restore_tuning
    echo "--- Core stopped (Time: $(date)) ---" >> "$LOG_FILE"
}

status() {
    if is_running; then
        echo "Maodie Core is running (PID: $(cat "$PID_FILE"))."
    else
        echo "Maodie Core is not running."
    fi
}

# 幂等地重铺系统调优与 iptables 规则（不重启内核）。
# 用于看门狗在 system_server 运行时重启、netd 冲掉规则后自愈。
# apply_tuning / apply_iptables 本身幂等（sysctl 同值写入、iptables -C || -I），
# 规则在位时为空操作；临时静音日志避免每 30s 刷屏 kernel.log。
reapply() {
    local old_log="$LOG_FILE"
    LOG_FILE=/dev/null
    apply_iptables
    LOG_FILE="$old_log"
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
    restart) stop; sleep 1; start ;;
    reapply) reapply ;;
    status)  status ;;
    *)       echo "Usage: $0 {start|stop|restart|reapply|status}"; exit 1 ;;
esac
