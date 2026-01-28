#!/system/bin/sh

URL="http://127.0.0.1:9090/ui"

am start -a android.intent.action.VIEW -d "$URL" --user 0 >/dev/null 2>&1

exit 0