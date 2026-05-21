#!/system/bin/sh

MODDIR="$(dirname "$0")"
PID_FILE="$MODDIR/maodie/run/kernel.pid"
LOCK_FILE="$MODDIR/maodie/run/adblock.lock"

if [ -f "$PID_FILE" ]; then
    pid=$(cat "$PID_FILE" 2>/dev/null)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        kill -9 "$pid" 2>/dev/null
    fi
    rm -f "$PID_FILE"
fi

for cmdline in /proc/[0-9]*/cmdline; do
    [ -r "$cmdline" ] || continue
    if tr '\0' ' ' < "$cmdline" 2>/dev/null | grep -Fq "Mihomo"; then
        pid=${cmdline#/proc/}
        pid=${pid%/cmdline}
        kill -9 "$pid" 2>/dev/null
    fi
done

pkill -f "inotifyd - $MODDIR" 2>/dev/null

if [ -f "$LOCK_FILE" ]; then
    pid=$(cat "$LOCK_FILE" 2>/dev/null)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        kill -9 "$pid" 2>/dev/null
    fi
    rm -f "$LOCK_FILE"
fi

iptables -D FORWARD -i "utun+" -j ACCEPT 2>/dev/null
iptables -D FORWARD -o "utun+" -j ACCEPT 2>/dev/null
iptables -t mangle -D PREROUTING -m mark --mark 2022 -j RETURN 2>/dev/null
ip6tables -D FORWARD -i "utun+" -j ACCEPT 2>/dev/null
ip6tables -D FORWARD -o "utun+" -j ACCEPT 2>/dev/null
