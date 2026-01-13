#!/system/bin/sh
# Maodie Launcher - Service Script

MODDIR=${0%/*}
SCRIPT_DIR="$MODDIR/maodie/scripts"

# 1. 等待 Magisk 挂载完成
# 在某些老旧设备上，boot_completed 为 1 时 Magisk 模块目录可能还没准备好
until [ -d "$MODDIR" ]; do
  sleep 1
done

# 2. 等待系统启动完成标志 (兼容旧标准)
until [ "$(getprop sys.boot_completed)" = "1" ]; do
  sleep 2
done

# 3. 网络栈检测 (通用)
# 尝试 ping 环回地址，确保 TCP/IP 协议栈已加载
wait_count=0
while ! ping -c 1 -W 1 127.0.0.1 >/dev/null 2>&1; do
    sleep 1
    wait_count=$((wait_count+1))
    # 增加超时时间到 90秒，照顾老旧卡顿机型
    if [ $wait_count -gt 90 ]; then break; fi 
done

# 4. 启动脚本
# 使用 busybox nohup 以防系统自带 nohup 行为异常
nohup sh $SCRIPT_DIR/core.sh start > /dev/null 2>&1 &
nohup sh $SCRIPT_DIR/monitor.sh > /dev/null 2>&1 &