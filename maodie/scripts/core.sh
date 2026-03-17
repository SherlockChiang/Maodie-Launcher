#!/system/bin/sh
# Maodie Core - 兼容版 (Android 7.0 - Android 16)

MOD_DIR="/data/adb/modules/Maodie-Launcher"
KERNEL_BIN="$MOD_DIR/maodie/kernel/Mihomo"
CONFIG_DIR="$MOD_DIR/maodie/config"
CONFIG_FILE="$CONFIG_DIR/config.yaml"
RUN_DIR="$MOD_DIR/maodie/run"
PID_FILE="$RUN_DIR/kernel.pid"
LOG_FILE="$RUN_DIR/kernel.log"

API_LEVEL=$(getprop ro.build.version.sdk)

mkdir -p "$RUN_DIR"


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
}

start() {
    if [ -f "$PID_FILE" ] && kill -0 $(cat "$PID_FILE") 2>/dev/null; then
        echo "Maodie Core is already running."
        return
    fi

    echo "--- Starting Maodie (Time: $(date)) ---" > "$LOG_FILE"
    
    apply_tuning
    
    ulimit -n 65536 2>/dev/null

    nohup "$KERNEL_BIN" -d "$CONFIG_DIR" -f "$CONFIG_FILE" >> "$LOG_FILE" 2>&1 &
    PID=$!
    echo $PID > "$PID_FILE"
    
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
        PID=$(cat "$PID_FILE")
        kill -15 $PID 2>/dev/null
        
        sleep 1
        
        if kill -0 $PID 2>/dev/null; then
            kill -9 $PID 2>/dev/null
            echo "Warning: Core didn't stop gracefully, force killed." >> "$LOG_FILE"
        fi
        rm -f "$PID_FILE"
    else
        killall -15 Mihomo 2>/dev/null
    fi
    
    clear_iptables
    echo "Core stopped." >> "$LOG_FILE"
}

case "$1" in
    start)   start ;;
    stop)    stop ;;
    restart) stop; sleep 1; start ;;
    *)       echo "Usage: $0 {start|stop|restart}" ;;
esac