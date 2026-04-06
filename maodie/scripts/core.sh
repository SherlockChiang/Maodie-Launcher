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

API_LEVEL=$(getprop ro.build.version.sdk)

mkdir -p "$RUN_DIR"

rotate_log() {
    if [ -f "$LOG_FILE" ]; then
        local size=$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)
        if [ "$size" -gt "$LOG_MAX_SIZE" ]; then
            mv -f "$LOG_FILE" "${LOG_FILE}.old"
        fi
    fi
}

detect_iptables_wait() {
    if iptables --help 2>/dev/null | grep -q "wait"; then
        if iptables --help 2>/dev/null | grep -q "wait interval"; then
            IPT_WAIT="-w 2"
            IPV6_WAIT="-w 2"
        else
            IPT_WAIT="-w"
            IPV6_WAIT="-w"
        fi
    else
        IPT_WAIT=""
        IPV6_WAIT=""
        echo "Info: 当前系统 iptables 不支持等待锁，已降级运行。" >> "$LOG_FILE"
    fi
}

safe_sysctl() {
    local val=$1
    local file=$2
    if [ -f "$file" ]; then
        echo "$val" > "$file" 2>/dev/null
    fi
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

    iptables $IPT_WAIT -C FORWARD -i "utun+" -j ACCEPT 2>/dev/null || iptables $IPT_WAIT -I FORWARD -i "utun+" -j ACCEPT
    iptables $IPT_WAIT -C FORWARD -o "utun+" -j ACCEPT 2>/dev/null || iptables $IPT_WAIT -I FORWARD -o "utun+" -j ACCEPT

    iptables $IPT_WAIT -t mangle -C PREROUTING -m mark --mark 2022 -j RETURN 2>/dev/null || iptables $IPT_WAIT -t mangle -I PREROUTING -m mark --mark 2022 -j RETURN

    if [ -f /proc/net/if_inet6 ]; then
        ip6tables $IPV6_WAIT -C FORWARD -i "utun+" -j ACCEPT 2>/dev/null || ip6tables $IPV6_WAIT -I FORWARD -i "utun+" -j ACCEPT
        ip6tables $IPV6_WAIT -C FORWARD -o "utun+" -j ACCEPT 2>/dev/null || ip6tables $IPV6_WAIT -I FORWARD -o "utun+" -j ACCEPT
    fi

    echo "iptables rules applied." >> "$LOG_FILE"
}

clear_iptables() {
    detect_iptables_wait

    iptables $IPT_WAIT -D FORWARD -i "utun+" -j ACCEPT 2>/dev/null
    iptables $IPT_WAIT -D FORWARD -o "utun+" -j ACCEPT 2>/dev/null
    iptables $IPT_WAIT -t mangle -D PREROUTING -m mark --mark 2022 -j RETURN 2>/dev/null

    if [ -f /proc/net/if_inet6 ]; then
        ip6tables $IPV6_WAIT -D FORWARD -i "utun+" -j ACCEPT 2>/dev/null
        ip6tables $IPV6_WAIT -D FORWARD -o "utun+" -j ACCEPT 2>/dev/null
    fi

    echo "iptables rules cleared." >> "$LOG_FILE"
}

is_running() {
    if [ -f "$PID_FILE" ]; then
        local pid=$(cat "$PID_FILE" 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
        # PID 文件存在但进程已死，清理残留
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
        echo -900 > /proc/$PID/oom_score_adj 2>/dev/null
    else
        echo -16 > /proc/$PID/oom_adj 2>/dev/null
    fi

    apply_iptables

    echo "Core started with PID: $PID" >> "$LOG_FILE"
}

stop() {
    if [ -f "$PID_FILE" ]; then
        PID=$(cat "$PID_FILE" 2>/dev/null)
        if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
            kill -15 $PID 2>/dev/null

            # 等待优雅退出，最多 3 秒
            local wait=0
            while [ $wait -lt 3 ] && kill -0 $PID 2>/dev/null; do
                sleep 1
                wait=$((wait + 1))
            done

            if kill -0 $PID 2>/dev/null; then
                kill -9 $PID 2>/dev/null
                echo "Warning: Core didn't stop gracefully, force killed." >> "$LOG_FILE"
            fi
        fi
        rm -f "$PID_FILE"
    else
        # 兜底：通过进程名清理
        killall -15 Mihomo 2>/dev/null
        sleep 1
        killall -9 Mihomo 2>/dev/null
    fi

    clear_iptables
    echo "--- Core stopped (Time: $(date)) ---" >> "$LOG_FILE"
}

status() {
    if is_running; then
        echo "Maodie Core is running (PID: $(cat "$PID_FILE"))."
    else
        echo "Maodie Core is not running."
    fi
}

case "$1" in
    start)   start ;;
    stop)    stop ;;
    restart) stop; sleep 1; start ;;
    status)  status ;;
    *)       echo "Usage: $0 {start|stop|restart|status}" ;;
esac