#!/bin/sh

. /lib/functions.sh
. /lib/functions/gl_util.sh

fix_wifi_speed() {
    wait_for_wifi_ready

    is_6g_auto_channel=$(uci get wireless.wifi2.channel)
    [ "$is_6g_auto_channel" != "auto" ] && exit 0
    is_320M_bandwidth=$(uci get wireless.wifi2.htmode)
    [ "$is_320M_bandwidth" != "HT320" ] && exit 0

    for i in `seq 1 20`; do
        speed=$(iwinfo wlan2 info|grep "Bit Rate:"|awk {'printf $3'})
        if [ "$?" -eq 0 ] && [ "$speed" != "unknown" ]; then
            if [ "$speed" != "5764" ]; then
                cfg80211tool wlan2 channel 0
                logger -t "fix_qsdk_speed" "Waiting for wlan2 to be ready, retrying in 5 seconds..."
            else
                exit 0
            fi
        fi
        sleep 1
    done
}

model=$(cat /proc/gl-hw-info/model)

case $model in
be9300)
    fix_wifi_speed
    ;;
esac
