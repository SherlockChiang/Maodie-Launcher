#!/system/bin/sh
# Maodie Core - 兼容版 (Android 7.0 - Android 16)

# --- 变量定义 ---
MOD_DIR="/data/adb/modules/Maodie-Launcher"
KERNEL_BIN="$MOD_DIR/maodie/kernel/Mihomo"
CONFIG_FILE="$MOD_DIR/maodie/config/config.yaml"
RUN_DIR="$MOD_DIR/maodie/run"
PID_FILE="$RUN_DIR/kernel.pid"
LOG_FILE="$RUN_DIR/kernel.log"
# 获取安卓 SDK 版本 (用于日志或特定判断)
API_LEVEL=$(getprop ro.build.version.sdk)

mkdir -p $RUN_DIR

# --- 兼容性检测函数 ---

# 检测 iptables 是否支持 -w (等待锁)
# Android 9+ 通常支持，Android 7 以前可能不支持
detect_iptables_wait() {
    if iptables --help 2>/dev/null | grep -q "wait"; then
        IPT_WAIT="-w 10" # 等待10秒
        IPV6_WAIT="-w 10"
    else
        IPT_WAIT=""
        IPV6_WAIT=""
        echo "Info: 当前系统 iptables 不支持等待锁，已降级运行。" >> $LOG_FILE
    fi
}

# 安全写入 Sysctl (如果节点不存在则跳过，防止报错)
safe_sysctl() {
    local val=$1
    local file=$2
    if [ -f "$file" ]; then
        # 尝试写入，如果失败也不中断脚本
        echo "$val" > "$file" 2>/dev/null
    fi
}

# --- 功能函数 ---

apply_tuning() {
    echo "--- System Tuning (SDK: $API_LEVEL) ---" >> $LOG_FILE
    
    # 基础转发 (所有安卓版本都适用)
    safe_sysctl 1 /proc/sys/net/ipv4/ip_forward
    safe_sysctl 1 /proc/sys/net/ipv6/conf/all/forwarding
    
    # 关闭 rp_filter (防止断流)
    # 遍历所有接口，兼容不同网卡命名的设备
    for file in /proc/sys/net/ipv4/conf/*/rp_filter; do
        safe_sysctl 0 "$file"
    done
    
    # 增大连接数限制 (适配旧设备较小的默认值)
    # 很多旧设备默认只有 16384，跑 BT 容易死机
    safe_sysctl 65536 /proc/sys/net/netfilter/nf_conntrack_max
    
    # 增大缓冲区 (提升吞吐)
    safe_sysctl 8388608 /proc/sys/net/core/wmem_max
    safe_sysctl 8388608 /proc/sys/net/core/rmem_max
}

apply_iptables() {
    # 检测兼容性
    detect_iptables_wait

    # IPv4 规则
    # 检查规则是否存在，不存在则添加
    iptables $IPT_WAIT -C FORWARD -i "utun+" -j ACCEPT 2>/dev/null || iptables $IPT_WAIT -I FORWARD -i "utun+" -j ACCEPT
    iptables $IPT_WAIT -C FORWARD -o "utun+" -j ACCEPT 2>/dev/null || iptables $IPT_WAIT -I FORWARD -o "utun+" -j ACCEPT
    
    # 防止环路 (Mark 2022)
    iptables $IPT_WAIT -t mangle -C PREROUTING -m mark --mark 2022 -j RETURN 2>/dev/null || iptables $IPT_WAIT -t mangle -I PREROUTING -m mark --mark 2022 -j RETURN

    # IPv6 规则 (部分旧设备内核可能禁用了 IPv6，需要容错)
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

    echo "--- Starting Maodie (Time: $(date)) ---" > $LOG_FILE
    
    # 1. 环境调优
    apply_tuning
    
    # 2. 资源限制解除
    ulimit -n 65536 2>/dev/null

    # 3. 启动核心
    # 注意：旧版本安卓可能没有 /dev/null 的写入权限(极少见)，但 nohup 依然安全
    nohup $KERNEL_BIN -d $(dirname $CONFIG_FILE) -f $CONFIG_FILE >> $LOG_FILE 2>&1 &
    PID=$!
    echo $PID > $PID_FILE
    
    # 4. 进程保活
    # Android 7-9 使用 oom_adj (旧接口)，Android 10+ 使用 oom_score_adj
    # 我们优先写 score_adj，如果不存在则尝试写 adj (虽然现在大部分都通用 score_adj)
    if [ -f /proc/$PID/oom_score_adj ]; then
        echo -900 > /proc/$PID/oom_score_adj 2>/dev/null
    else
        # 兼容远古版本
        echo -16 > /proc/$PID/oom_adj 2>/dev/null
    fi
    
    # 5. 网络规则
    apply_iptables
    
    echo "Core started with PID: $PID" >> $LOG_FILE
}

stop() {
    if [ -f "$PID_FILE" ]; then
        PID=$(cat "$PID_FILE")
        kill -15 $PID 2>/dev/null
        rm "$PID_FILE"
    else
        killall Mihomo 2>/dev/null
    fi
    clear_iptables
    echo "Core stopped." >> $LOG_FILE
}

case "$1" in
    start) start ;;
    stop)  stop ;;
    restart) stop; sleep 1; start ;;
    *) echo "Usage: $0 {start|stop|restart}" ;;
esac