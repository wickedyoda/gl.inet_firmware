#!/bin/sh
#
# Usage:
#   ./Cellular_debug.sh 1   # enable debug
#   ./Cellular_debug.sh 0   # disable debug
#

DEBUG="$1"

if [ "$DEBUG" != "0" ] && [ "$DEBUG" != "1" ]; then
    echo "Usage: $0 <0|1>"
    exit 1
fi

LOG_FILE="/tmp/cellular_manager.log"
BACKUP_LOG_FILE="/tmp/cellular_manager.log.bak"

LOG_FIFO="/tmp/cellular_debug_log.fifo"

LOG_PID_FILE="/tmp/cellular_debug_log.pid"
GREP_PID_FILE="/tmp/cellular_debug_grep.pid"
ROTATE_PID_FILE="/tmp/cellular_debug_rotate.pid"

MAX_SIZE=$((50*1024*1024))   # 50MB

echo "[INFO] Debug mode: $DEBUG"

###############################################################################
# Step 1: Get modem bus list
###############################################################################
MODEM_INFO="$(ubus call cellular.modem get_modem_info 2>/dev/null)"
if [ -z "$MODEM_INFO" ]; then
    echo "[ERROR] Failed to get modem info"
    exit 1
fi

MODEM_BUSES=$(echo "$MODEM_INFO" | jsonfilter -e '@.modems[*].bus')
if [ -n "$MODEM_BUSES" ]; then
    echo "[INFO] Found modem buses:"
    echo "$MODEM_BUSES"
fi

###############################################################################
# Step 2: UCI log level
###############################################################################
if [ "$DEBUG" = "1" ]; then
    uci -q set glmodem.global.log_level='0'
else
    uci -q set glmodem.global.log_level='1'
fi
uci commit glmodem

###############################################################################
# Step 3: Set ubus log levels
###############################################################################
set_ubus_loglevel() {
    LEVEL="$1"

    ubus call sms_manager set_sms_log_level "{\"level\":$LEVEL}" 2>/dev/null
    ubus call cellular.status set_cellular_log_level "{\"level\":$LEVEL}" 2>/dev/null

    AT_OBJECTS="$(ubus -v list | grep -o 'modem\.[^.]*\.AT' | sort -u)"
    for OBJ in $AT_OBJECTS; do
        ubus call "$OBJ" set_at_log_level "{\"level\":$LEVEL}" 2>/dev/null
    done
}

if [ "$DEBUG" = "1" ]; then
    set_ubus_loglevel 0
else
    set_ubus_loglevel 1
fi

###############################################################################
# Step 4: log rotate monitor
###############################################################################
rotate_log_monitor() {
    while true; do
        sleep 20
        if [ -f "$LOG_FILE" ]; then
            SIZE=$(stat -c %s "$LOG_FILE" 2>/dev/null)
            if [ -n "$SIZE" ] && [ "$SIZE" -ge "$MAX_SIZE" ]; then
                echo "[INFO] Rotate log: size=$SIZE bytes"
                rm -f "$BACKUP_LOG_FILE"
                cp "$LOG_FILE" "$BACKUP_LOG_FILE"
                : > "$LOG_FILE"
                echo "[INFO] Log rotated"
            fi
        fi
    done
}

###############################################################################
# Step 5: start / stop logread with FIFO
###############################################################################
start_logread() {
    stop_logread
    echo "[INFO] Start logread with FIFO filter"

    rm -f "$LOG_FIFO"
    mkfifo "$LOG_FIFO"

    # grep consumer
    grep -v -E "quec_battery|qms|T3991|LocSvc|LOW|hostapd|lpm|wpa_supplicant|ql_ril|QCMAP|kernel|vendor|odhcpd" \
        < "$LOG_FIFO" >> "$LOG_FILE" &
    GREP_PID=$!
    echo "$GREP_PID" > "$GREP_PID_FILE"

    # logread producer (this is the PID we control)
    logread -f > "$LOG_FIFO" 2>&1 &
    LOGREAD_PID=$!
    echo "$LOGREAD_PID" > "$LOG_PID_FILE"

    echo "[INFO] logread pid: $LOGREAD_PID"
    echo "[INFO] grep pid: $GREP_PID"

    rotate_log_monitor &
    ROTATE_PID=$!
    echo "$ROTATE_PID" > "$ROTATE_PID_FILE"
    echo "[INFO] rotate monitor pid: $ROTATE_PID"
}

stop_logread() {
    # stop logread
    if [ -f "$LOG_PID_FILE" ]; then
        PID=$(cat "$LOG_PID_FILE")
        if kill -0 "$PID" 2>/dev/null; then
            kill -9 "$PID"
            echo "[INFO] Stopped logread pid $PID"
        fi
        rm -f "$LOG_PID_FILE"
    fi

    # stop grep
    if [ -f "$GREP_PID_FILE" ]; then
        PID=$(cat "$GREP_PID_FILE")
        if kill -0 "$PID" 2>/dev/null; then
            kill -9 "$PID"
            echo "[INFO] Stopped grep pid $PID"
        fi
        rm -f "$GREP_PID_FILE"
    fi

    # stop rotate monitor
    if [ -f "$ROTATE_PID_FILE" ]; then
        PID=$(cat "$ROTATE_PID_FILE")
        if kill -0 "$PID" 2>/dev/null; then
            kill -9 "$PID"
            echo "[INFO] Stopped rotate monitor pid $PID"
        fi
        rm -f "$ROTATE_PID_FILE"
    fi

    rm -f "$LOG_FIFO"
}

###############################################################################
# Entry
###############################################################################
if [ "$DEBUG" = "1" ]; then
    start_logread
else
    stop_logread
fi

echo "[INFO] Done"
