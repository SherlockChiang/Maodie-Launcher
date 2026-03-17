#!/system/bin/sh
# monitor.sh - 修正版 inotifyd (实时热重载守护)

MOD_DIR="/data/adb/modules/Maodie-Launcher"
CORE_SCRIPT="$MOD_DIR/maodie/scripts/core.sh"
CONTROL_FILE="disable"
DEBUG_LOG="$MOD_DIR/maodie/run/monitor.log"

pkill -f "inotifyd - $MOD_DIR" 2>/dev/null

busybox inotifyd - "$MOD_DIR" | while read -r events dir file; do
    

    if [ "$file" = "$CONTROL_FILE" ]; then
        
        case "$events" in
            *n*|*w*|*c*) 
                echo "$(date): Module disabled by user. Stopping core..." >> "$DEBUG_LOG"
                sh "$CORE_SCRIPT" stop
                ;;
            *d*) 
                echo "$(date): Module enabled by user. Starting core..." >> "$DEBUG_LOG"
                sh "$CORE_SCRIPT" start
                ;;
        esac
    fi
done &