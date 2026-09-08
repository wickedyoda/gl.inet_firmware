#!/bin/sh

PIDFILE="/tmp/hostapd_monitor.pid"

[ ! -d "/tmp/hostapd_core" ] && mkdir -p /tmp/hostapd_core

# Ensure single instance: kill previous if still running
if [ -f "$PIDFILE" ]; then
    OLDPID="$(cat "$PIDFILE" 2>/dev/null)"
    if [ -d "/proc/$OLDPID" ] && [ "$OLDPID" != "$$" ]; then
        kill "$OLDPID" 2>/dev/null || true
        # wait briefly, then force kill if needed
        sleep 2
        [ -d "/proc/$OLDPID" ] && sleep 2
        [ -d "/proc/$OLDPID" ] && kill -9 "$OLDPID" 2>/dev/null
    fi
fi

echo "$$" > "$PIDFILE"


is_hostapd_running() {
    if [ -f "/var/run/hostapd-global.pid" ]; then
        HOSTAPD_PID=$(cat "/var/run/hostapd-global.pid" 2>/dev/null)
        if [ -n "$HOSTAPD_PID" ]; then
            if [ -d "/proc/$HOSTAPD_PID" ]; then
                [ -f "/proc/$HOSTAPD_PID/comm" ] && [ "$(cat /proc/$HOSTAPD_PID/comm 2>/dev/null)" = "hostapd" ] && return 0
            fi
        fi
    fi
    return 1
}

restart_services() {
    mv /tmp/hostapd.*.core /tmp/hostapd_core/ 2>/dev/null
    if [ -f /lib/wifi/qcawificfg80211.sh ]; then
        /etc/init.d/qca-hostapd boot 2>&1
        /sbin/wifi 2>&1
    fi

}

while true; do
    core_count=$(ls /tmp/hostapd.*.core 2>/dev/null | wc -l)
    if [ "$core_count" -gt 0 ]; then
        if ! is_hostapd_running; then
            restart_services
        fi
    fi
    sleep 40
done


