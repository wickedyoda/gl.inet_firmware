#!/bin/sh

while true;
do
    modem_crash_log=$(ls /data/vendor/ramdump/)
    if [ -n "$modem_crash_log" ]; then
        rm -r /data/vendor/modem_crash_log > /dev/null 2>&1
        mkdir -p /data/vendor/modem_crash_log/
        mv /data/vendor/ramdump/* /data/vendor/modem_crash_log/
        sync
    fi

    sleep 60
done
