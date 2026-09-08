#!/bin/sh
# shellcheck disable=SC1083

. /lib/functions.sh
. /lib/functions/system.sh
. /usr/share/libubox/jshn.sh

get_model() {
    local model=`uci get board_special.hardware.model 2>/dev/null`
    if [ -z "$model" ];then
        model=`cat /proc/gl-hw-info/model`
    fi
    echo $model
}

get_simo() {
    local simo=0
    if [ -n "$(ls /sys/class/net | grep 'simonet')" ]; then
        simo=1
    fi
    echo $simo
}

get_wan() {
    local wan=`uci get board_special.hardware.wan 2>/dev/null`
    if [ -z "$wan" ];then
        wan=`cat /proc/gl-hw-info/wan`
    fi
    echo $wan
}

get_radio() {
    local radio=`uci get board_special.hardware.radio 2>/dev/null`
    if [ -z "$radio" ];then
        radio=`cat /proc/gl-hw-info/radio 2>/dev/null`
    fi
    echo $radio
}

get_usb() {
    local model=$(get_model)
    case "$model" in
        "b3000"|\
        "x300b"|\
        "s200")
            echo 0
            ;;
        *)
            echo 1
            ;;
    esac
}

is_usb_otg() {
    local is_otg=`cat /proc/gl-hw-info/usb-otg 2>/dev/null`

    if [ "$is_otg" == "true" ];then
        echo 1
    else
        echo 0
    fi
}

get_country_code() {
    uci -q get board_special.hardware.country_code || cat /proc/gl-hw-info/country_code
}

reset_indicate_led_name() {
    local model=$(get_model)
    local led

    case "$model" in
        "ar150"|\
        "mifi"|\
        "ar300"|\
        "ar300m")
            led="/sys/class/leds/gl-${model}:green:lan"
            ;;
        "x300b")
            led="/sys/class/leds/gl-${model}:green:wan"
            ;;
        "mt300a"|\
        "mt300n"|\
        "mt300n-v2")
            led="/sys/class/leds/green:wan"
            ;;
        "usb150")
            led="/sys/class/leds/gl-${model}:green:power"
            ;;
        "ar750")
            led="/sys/class/leds/gl-$model:white:power"
            ;;
        "ar750s"|\
        "x750")
            led="/sys/class/leds/gl-$model:green:power"
            ;;
        "ap1300"|\
        "s1300"|\
        "b1300")
            led="/sys/class/leds/green:power"
            ;;
        "b2200")
            led="/sys/class/leds/power_white_led"
            ;;
        "x1200")
            led="/sys/class/leds/gl-${model}:green:power"
            ;;
        "xe300")
            led="/sys/class/leds/gl-${model}:green:wan"
            ;;
        "n300")
            led="/sys/class/leds/microuter-${model}:blue:power"
            ;;
        "a1300"|\
        "s200")
            led="/sys/class/leds/gl-${model}:blue"
            ;;
        "mv1000")
            led="/sys/class/leds/gl-mv1000:white:power"
            ;;
        "be5000"|\
        "ax1800"|\
        "axt1800")
            led="/sys/class/leds/blue_led"
            ;;
        "mt2500")
            led="/sys/class/leds/blue:system"
            ;;
        "mg1300"|\
        "mt1300"|\
        "mt6000"|\
        "mt3000"|\
        "mt3600be"|\
        "be5100"|\
        "mt5000"|\
        "sft3000")
            led="/sys/class/leds/blue:run"
            ;;
        "xe3000"|\
        "xe300v2"|\
        "x2000" |\
        "x3000")
            led="/sys/class/leds/power/"
            ;;
        "sft1200")
            led="use_i2c_control_blue_flash"
            ;;
        "b3000")
            led="/sys/class/leds/blue_led"
            ;;
        "e5800" |\
        "be10000" |\
        "be14000" |\
        "be3600")
            led="none"
            ;;
        "be9300" |\
        "be6500")
            led="/sys/class/leds/blue:run"
            ;;
        *)
    esac

    echo $led
}


# Some models, such as MT1300/SFT1200/AXT1800, require a daemon to control the LED
turnon_led() {
    model=$(get_model)

    case "$model" in
        "ax1800" |\
        "axt1800" |\
        "mg1300" |\
        "mt1300" |\
        "mt2500" |\
        "s200" |\
        "sft1200" |\
        "sft3000" |\
        "a1300" |\
        "be5000" |\
        "b3000" |\
        "be9300" |\
        "be6500")
            uci set gl_led.global.led_daemon='1'
            uci commit gl_led
            ;;
        "mt6000" |\
        "mt3600be"|\
        "be5100"|\
        "mt5000"|\
        "mt3000")
            uci set gl_led.global.led_daemon='1'
            uci commit gl_led
            echo 1 > /sys/class/leds/blue:run/brightness
            ;;
        "x3000" |\
        "x2000" |\
        "xe3000")
            uci set gl_led.global.led_daemon='1'
            uci commit gl_led
            /etc/init.d/led start
            /etc/init.d/led enable
            /etc/init.d/modem_signal start
            ;;
        "ar750")
            echo 1 > /sys/class/leds/gl-ar750:white:power/brightness
            /etc/init.d/led start
            /etc/init.d/led enable
            ;;
        "ar750s")
            echo 1 > /sys/class/leds/gl-ar750s:green:power/brightness
            echo "phy1tpt" > /sys/class/leds/gl-ar750s:green:wlan2g/trigger
            echo "phy0tpt" > /sys/class/leds/gl-ar750s:green:wlan5g/trigger
            ;;
        "xe300")
            echo "phy0tpt" > /sys/class/leds/gl-xe300:green:wlan/trigger
            /etc/init.d/led start
            /etc/init.d/led enable
            ;;
        "xe300v2")
            uci set gl_led.global.led_daemon='1'
            uci commit gl_led
            /etc/init.d/led start
            /etc/init.d/led enable
            ;;
        "mv1000")
            uci set gl_led.global.led_daemon='1'
            uci commit gl_led
            echo 1 > /sys/class/leds/gl-mv1000:white:power/brightness
            echo "netdev" > /sys/class/leds/gl-mv1000:white:wan/trigger
            echo "wan" > /sys/class/leds/gl-mv1000:white:wan/device_name
            echo 1 > /sys/class/leds/gl-mv1000:white:wan/link
            echo 1 > /sys/class/leds/gl-mv1000:white:wan/rx
            echo 1 > /sys/class/leds/gl-mv1000:white:wan/tx
            ;;
        "x750")
            echo 1 > /sys/class/leds/gl-x750:green:power/brightness
            echo "phy1tpt" > /sys/class/leds/gl-x750:green:wlan2g/trigger
            echo "phy0tpt" > /sys/class/leds/gl-x750:green:wlan5g/trigger
            /etc/init.d/led start
            /etc/init.d/led enable
            ;;
        "ar300m")
            echo 1 > /sys/class/leds/gl-ar300m:green:power/brightness
            echo "switch0" > /sys/class/leds/gl-ar300m:green:lan/trigger
            echo "phy0tpt" > /sys/class/leds/gl-ar300m:red:wlan/trigger
            /etc/init.d/led start
            /etc/init.d/led enable
            ;;
        "mt300n-v2")
            echo 1 > /sys/class/leds/green:power/brightness
            echo "switch0" > /sys/class/leds/green:wan/trigger
            echo "0x1" > /sys/class/leds/green:wan/port_mask
            echo "netdev" > /sys/class/leds/red:wlan/trigger
            echo "ra0" > /sys/class/leds/red:wlan/device_name
            echo 1 > /sys/class/leds/red:wlan/link
            echo 1 > /sys/class/leds/red:wlan/rx
            echo 1 > /sys/class/leds/red:wlan/tx
            ;;
        *)
            /etc/init.d/led start
            /etc/init.d/led enable
            ;;
    esac
}

# Some models, such as MT1300/SFT1200/AXT1800, require some special instructions to turn off the LED
turnoff_led() {
    model=$(get_model)

    case "$model" in
        "be5000" |\
        "axt1800")
            echo none > /sys/class/leds/blue_led/trigger
            echo 0 > /sys/class/leds/blue_led/brightness
            echo none > /sys/class/leds/white_led/trigger
            echo 0 > /sys/class/leds/white_led/brightness
            ;;
        "ax1800")
            gl_i2c_led off
            echo none > /sys/class/leds/blue_led/trigger
            echo 0 > /sys/class/leds/blue_led/brightness
            echo none > /sys/class/leds/white_led/trigger
            echo 0 > /sys/class/leds/white_led/brightness
            ;;
        "mt1300")
            gl_i2c_led off
            echo none > /sys/class/leds/blue:run/trigger
            echo 0 > /sys/class/leds/blue:run/brightness
            echo none > /sys/class/leds/white:system/trigger
            echo 0 > /sys/class/leds/white:system/brightness
            ;;
        "mg1300" |\
        "mt6000" |\
        "mt3000" |\
        "mt3600be"|\
        "be5100"|\
        "sft3000")
            echo none > /sys/class/leds/blue:run/trigger
            echo 0 > /sys/class/leds/blue:run/brightness
            echo none > /sys/class/leds/white:system/trigger
            echo 0 > /sys/class/leds/white:system/brightness
            ;;
        "mt2500")
            echo none > /sys/class/leds/blue:system/trigger
            echo 0 > /sys/class/leds/blue:system/brightness
            echo none > /sys/class/leds/white:system/trigger
            echo 0 > /sys/class/leds/white:system/brightness
            echo none > /sys/class/leds/vpn/trigger
            echo 0 > /sys/class/leds/vpn/brightness
            ;;
        "mt5000")
            echo none > /sys/class/leds/blue:run/trigger
            echo 0 > /sys/class/leds/blue:run/brightness
            echo none > /sys/class/leds/white:system/trigger
            echo 0 > /sys/class/leds/white:system/brightness
            echo none > /sys/class/leds/vpn/trigger
            echo 0 > /sys/class/leds/vpn/brightness
            ;;
        "xe3000"|\
        "x2000" |\
        "x3000")
            /etc/init.d/led stop
            /etc/init.d/led disable
            /etc/init.d/modem_signal stop
            for led in `ls /sys/class/leds/`
            do
                echo none > /sys/class/leds/$led/trigger
                echo 0 > /sys/class/leds/$led/brightness
            done
            ;;
        "s200")
            echo none > /sys/class/leds/gl-s200:blue/trigger
            echo 0 > /sys/class/leds/gl-s200:blue/brightness
            echo none > /sys/class/leds/gl-s200:green/trigger
            echo 0 > /sys/class/leds/gl-s200:green/brightness
            cat /sys/class/leds/gl-s200:green/brightness | grep "0" 1>/dev/null || ubus call gl_ledd on_off '{"led_name":"nwk_led","mode":"off"}'
            cat /sys/class/leds/gl-s200:blue/brightness | grep "0" 1>/dev/null || ubus call gl_ledd on_off '{"led_name":"sys_led","mode":"off"}'
            ;;
        "a1300")
            gl_i2c_led off
            echo none > /sys/class/leds/gl-a1300:blue/trigger
            echo 0 > /sys/class/leds/gl-a1300:blue/brightness
            echo none > /sys/class/leds/gl-a1300:white/trigger
            echo 0 > /sys/class/leds/gl-a1300:white/brightness
            ;;
        "sft1200")
            gl_i2c_led off
            ;;
        "s1300"|\
        "b1300")
            echo none > /sys/class/leds/green:power/trigger
            echo 0 > /sys/class/leds/green:power/brightness
            echo none > /sys/class/leds/green:wlan/trigger
            echo 0 > /sys/class/leds/green:wlan/brightness
            ;;
        "ap1300")
            echo none > /sys/class/leds/green:power/trigger
            echo 0 > /sys/class/leds/green:power/brightness
            echo none > /sys/class/leds/green:wan/trigger
            echo 0 > /sys/class/leds/green:wan/brightness
            ;;
        "x300b")
            /etc/init.d/led stop
            /etc/init.d/led disable
            echo none > /sys/class/leds/gl-x300b:green:lte/trigger
            echo 0 > /sys/class/leds/gl-x300b:green:lte/brightness
            echo none > /sys/class/leds/gl-x300b:green:wan/trigger
            echo 0 > /sys/class/leds/gl-x300b:green:wan/brightness
            echo none > /sys/class/leds/gl-x300b:green:wlan2g/trigger
            echo 0 > /sys/class/leds/gl-x300b:green:wlan2g/brightness
            ;;
        "ar750")
            echo none > /sys/class/leds/gl-ar750:white:power/trigger
            echo 0 > /sys/class/leds/gl-ar750:white:power/brightness
            echo none > /sys/class/leds/gl-ar750:white:wlan2g/trigger
            echo 0 > /sys/class/leds/gl-ar750:white:wlan2g/brightness
            echo none > /sys/class/leds/gl-ar750:white:wlan5g/trigger
            echo 0 > /sys/class/leds/gl-ar750:white:wlan5g/brightness
            ;;
        "ar750s")
            echo none > /sys/class/leds/gl-ar750s:green:power/trigger
            echo 0 > /sys/class/leds/gl-ar750s:green:power/brightness
            echo none > /sys/class/leds/gl-ar750s:green:wlan2g/trigger
            echo 0 > /sys/class/leds/gl-ar750s:green:wlan2g/brightness
            echo none > /sys/class/leds/gl-ar750s:green:wlan5g/trigger
            echo 0 > /sys/class/leds/gl-ar750s:green:wlan5g/brightness
            ;;
        "xe300")
            echo none > /sys/class/leds/gl-xe300:green:lte/trigger
            echo 0 > /sys/class/leds/gl-xe300:green:lte/brightness
            echo none > /sys/class/leds/gl-xe300:green:wlan/trigger
            echo 0 > /sys/class/leds/gl-xe300:green:wlan/brightness
            echo none > /sys/class/leds/gl-xe300:green:wan/trigger
            echo 0 > /sys/class/leds/gl-xe300:green:wan/brightness
            echo none > /sys/class/leds/gl-xe300:green:lan/trigger
            echo 0 > /sys/class/leds/gl-xe300:green:lan/brightness
            ;;
        "mv1000")
            echo none > /sys/class/leds/gl-mv1000:white:power/trigger
            echo 0 > /sys/class/leds/gl-mv1000:white:power/brightness
            echo none > /sys/class/leds/gl-mv1000:white:wan/trigger
            echo 0 > /sys/class/leds/gl-mv1000:white:wan/brightness
            echo none > /sys/class/leds/gl-mv1000:white:vpn/trigger
            echo 0 > /sys/class/leds/gl-mv1000:white:vpn/brightness
            ;;
        "x750")
            echo none > /sys/class/leds/gl-x750:green:power/trigger
            echo 0 > /sys/class/leds/gl-x750:green:power/brightness
            echo none > /sys/class/leds/gl-x750:green:wan/trigger
            echo 0 > /sys/class/leds/gl-x750:green:wan/brightness
            echo none > /sys/class/leds/gl-x750:green:lte/trigger
            echo 0 > /sys/class/leds/gl-x750:green:lte/brightness
            echo none > /sys/class/leds/gl-x750:green:wlan2g/trigger
            echo 0 > /sys/class/leds/gl-x750:green:wlan2g/brightness
            echo none > /sys/class/leds/gl-x750:green:wlan5g/trigger
            echo 0 > /sys/class/leds/gl-x750:green:wlan5g/brightness
            ;;
        "ar300m")
            echo none > /sys/class/leds/gl-ar300m:green:power/trigger
            echo 0 > /sys/class/leds/gl-ar300m:green:power/brightness
            echo none > /sys/class/leds/gl-ar300m:green:lan/trigger
            echo 0 > /sys/class/leds/gl-ar300m:green:lan/brightness
            echo none > /sys/class/leds/gl-ar300m:red:wlan/trigger
            echo 0 > /sys/class/leds/gl-ar300m:red:wlan/brightness
            ;;
        "mt300n-v2")
            echo none > /sys/class/leds/green:power/trigger
            echo 0 > /sys/class/leds/green:power/brightness
            echo none > /sys/class/leds/green:wan/trigger
            echo 0 > /sys/class/leds/green:wan/brightness
            echo none > /sys/class/leds/red:wlan/trigger
            echo 0 > /sys/class/leds/red:wlan/brightness
            ;;
        "b3000")
            echo none > /sys/class/leds/blue_led/trigger
            echo 0 > /sys/class/leds/blue_led/brightness
            echo none > /sys/class/leds/white_led/trigger
            echo 0 > /sys/class/leds/white_led/brightness
            ;;
        "be9300" |\
        "be6500")
            echo none > /sys/class/leds/blue:run/trigger
            echo 0 > /sys/class/leds/blue:run/brightness
            echo none > /sys/class/leds/white:system/trigger
            echo 0 > /sys/class/leds/white:system/brightness
            ;;
        *)
            /etc/init.d/led stop
            /etc/init.d/led disable

            [ -f "/etc/init.d/modem_signal" ] && /etc/init.d/modem_signal stop
            for led in `ls /sys/class/leds/`
            do
                echo none > /sys/class/leds/$led/trigger
                echo 0 > /sys/class/leds/$led/brightness
            done
            ;;
    esac
}

online_led_display() {
    model=$(get_model)

    case "$model" in
        "ax1800")
            echo none > /sys/class/leds/blue_led/trigger
            echo 0 > /sys/class/leds/blue_led/brightness
            echo none > /sys/class/leds/white_led/trigger
            echo 0 > /sys/class/leds/white_led/brightness
            gl_i2c_led white daemon
            ;;
        "be5000" |\
        "axt1800")
            cat /sys/class/leds/blue_led/trigger | grep "\[none\]" 1>/dev/null || echo none > /sys/class/leds/blue_led/trigger
            echo 0 > /sys/class/leds/blue_led/brightness
            echo 1 > /sys/class/leds/white_led/brightness
            ;;
        "mt1300")
            echo none > /sys/class/leds/blue:run/trigger
            echo 0 > /sys/class/leds/blue:run/brightness
            echo none > /sys/class/leds/white:system/trigger
            echo 0 > /sys/class/leds/white:system/brightness
            gl_i2c_led white daemon
            ;;
        "mg1300" |\
        "mt6000" |\
        "mt3600be"|\
        "be5100"|\
        "mt5000"|\
        "mt3000")
            cat /sys/class/leds/blue:run/trigger | grep "\[none\]" 1>/dev/null || echo none > /sys/class/leds/blue:run/trigger
            echo 0 > /sys/class/leds/blue:run/brightness
            echo 1 > /sys/class/leds/white:system/brightness
            ;;
        "x3000"|\
        "x2000"|\
        "xe300v2"|\
        "xe3000")
            echo 1 > /sys/class/leds/internet/brightness
            ;;
        "mt2500")
            cat /sys/class/leds/blue:system/trigger | grep "\[none\]" 1>/dev/null || echo none > /sys/class/leds/blue:system/trigger
            echo 0 > /sys/class/leds/blue:system/brightness
            echo 1 > /sys/class/leds/white:system/brightness
            ;;
        "a1300")
            echo none > /sys/class/leds/gl-a1300:blue/trigger
            echo 0 > /sys/class/leds/gl-a1300:blue/brightness
            echo none > /sys/class/leds/gl-a1300:white/trigger
            echo 0 > /sys/class/leds/gl-a1300:white/brightness
            gl_i2c_led white daemon
            ;;
        "s200")
            cat /sys/class/leds/gl-s200:blue/trigger | grep "\[none\]" 1>/dev/null || ubus call gl_ledd on_off '{"led_name":"sys_led","mode":"off"}'
            cat /sys/class/leds/gl-s200:green/brightness | grep "1" 1>/dev/null || ubus call gl_ledd on_off '{"led_name":"nwk_led","mode":"on"}'
            ;;
        "sft1200")
            gl_i2c_led white daemon
            ;;
        "b3000")
            cat /sys/class/leds/blue_led/trigger | grep "\[none\]" 1>/dev/null || echo none > /sys/class/leds/blue_led/trigger
            echo 0 > /sys/class/leds/blue_led/brightness
            echo 1 > /sys/class/leds/white_led/brightness
            ;;
        "be9300"|\
        "be6500"|\
        "sft3000")
            cat /sys/class/leds/blue:run/trigger | grep "\[none\]" 1>/dev/null || echo none > /sys/class/leds/blue:run/trigger
            echo 0 > /sys/class/leds/blue:run/brightness
            echo 1 > /sys/class/leds/white:system/brightness
            ;;
        *)
    esac
}


offline_led_display() {
    model=$(get_model)

    case "$model" in
        "ax1800")
            echo none > /sys/class/leds/blue_led/trigger
            echo 0 > /sys/class/leds/blue_led/brightness
            echo none > /sys/class/leds/white_led/trigger
            echo 0 > /sys/class/leds/white_led/brightness
            gl_i2c_led blue_breath daemon
            ;;
        "be5000" |\
        "axt1800")
            echo 0 > /sys/class/leds/white_led/brightness
            cat /sys/class/leds/blue_led/trigger | grep "\[timer\]" 1>/dev/null || echo timer > /sys/class/leds/blue_led/trigger
            ;;
        "mt1300")
            echo none > /sys/class/leds/blue:run/trigger
            echo 0 > /sys/class/leds/blue:run/brightness
            echo none > /sys/class/leds/white:system/trigger
            echo 0 > /sys/class/leds/white:system/brightness
            gl_i2c_led blue_breath daemon
            ;;
        "mt2500")
            echo 0 > /sys/class/leds/white:system/brightness
            cat /sys/class/leds/blue:system/trigger | grep "\[timer\]" 1>/dev/null || echo timer > /sys/class/leds/blue:system/trigger
            ;;
        "mg1300" |\
        "mt6000" |\
        "mt3600be"|\
        "be5100"|\
        "mt5000" |\
        "mt3000")
            echo 0 > /sys/class/leds/white:system/brightness
            cat /sys/class/leds/blue:run/trigger | grep "\[timer\]" 1>/dev/null || echo timer > /sys/class/leds/blue:run/trigger
            ;;
        "x3000"|\
        "x2000"|\
        "xe300v2"|\
        "xe3000")
            echo 0 > /sys/class/leds/internet/brightness
            ;;
        "a1300")
            echo none > /sys/class/leds/gl-a1300:blue/trigger
            echo 0 > /sys/class/leds/gl-a1300:blue/brightness
            echo none > /sys/class/leds/gl-a1300:white/trigger
            echo 0 > /sys/class/leds/gl-a1300:white/brightness
            gl_i2c_led blue_breath daemon
            ;;
        "s200")
            cat /sys/class/leds/gl-s200:blue/brightness | grep "0" 1>/dev/null || ubus call gl_ledd on_off '{"led_name":"sys_led","mode":"off"}'
            cat /sys/class/leds/gl-s200:green/trigger | grep "\[timer\]" 1>/dev/null || ubus call gl_ledd blink '{"led_name":"nwk_led","delay_on":"500","delay_off":"500"}'
            ;;
        "sft1200")
            gl_i2c_led blue_breath daemon
            ;;
        "b3000")
            echo 0 > /sys/class/leds/white_led/brightness
            cat /sys/class/leds/blue_led/trigger | grep "\[timer\]" 1>/dev/null || echo timer > /sys/class/leds/blue_led/trigger
            ;;
        "be9300"|\
        "be6500"|\
        "sft3000")
            echo 0 > /sys/class/leds/white:system/brightness
            cat /sys/class/leds/blue:run/trigger | grep "\[timer\]" 1>/dev/null || echo timer > /sys/class/leds/blue:run/trigger
            ;;
        *)
    esac
}

set_i2c_led_brightness() {
    model=$(get_model)

    case "$model" in
        "sft1200" |\
        "ax1800")
            i2cset  -f -y 0 0x30 0x06 0x0a
            i2cset  -f -y 0 0x30 0x07 0x0a
            ;;
        "mt1300" |\
        "a1300")
            i2cset  -f -y 0 0x30 0x06 0x3f
            i2cset  -f -y 0 0x30 0x07 0x7f
            ;;
        *)
    esac
}

cloud_offline_led_display(){
    model=$(get_model)

    case "$model" in
        "xe300v2")
            echo 0 > /sys/class/leds/cloud/brightness
            ;;
        *)
    esac
}

cloud_online_led_display(){
    model=$(get_model)

    case "$model" in
        "xe300v2")
            echo 1 > /sys/class/leds/cloud/brightness
            ;;
        *)
    esac
}

vpn_off_led_display(){
    model=$(get_model)

    case "$model" in
        "mt5000"|\
        "mt2500")
            echo none > /sys/class/leds/vpn/trigger
            echo 0 > /sys/class/leds/vpn/brightness
            ;;
        "mv1000")
            echo none > /sys/class/leds/gl-mv1000:white:vpn/trigger
            echo 0 > /sys/class/leds/gl-mv1000:white:vpn/brightness
            ;;
        *)
    esac
}

vpn_online_led_display(){
    model=$(get_model)

    case "$model" in
        "mt5000"|\
        "mt2500")
            echo none > /sys/class/leds/vpn/trigger
            echo 1 > /sys/class/leds/vpn/brightness
            ;;
        "mv1000")
            echo none > /sys/class/leds/gl-mv1000:white:vpn/trigger
            echo 1 > /sys/class/leds/gl-mv1000:white:vpn/brightness
            ;;
        *)
    esac
}

vpn_offline_led_display(){
    model=$(get_model)

    case "$model" in
        "mt5000"|\
        "mt2500")
            echo 0 > /sys/class/leds/vpn/brightness
            echo timer > /sys/class/leds/vpn/trigger
            ;;
        "mv1000")
            echo 0 > /sys/class/leds/gl-mv1000:white:vpn/brightness
            echo timer > /sys/class/leds/gl-mv1000:white:vpn/trigger
            ;;
        *)
    esac
}

led_blinking() {
    model=$(get_model)

    case "$model" in
        "mt300n-v2")
            echo timer > /sys/class/leds/green:power/trigger
            echo 1000 > /sys/class/leds/green:power/delay_off
            usleep 500000
            echo timer > /sys/class/leds/green:lan/trigger
            echo 1000 > /sys/class/leds/green:lan/delay_off
            usleep 500000
            echo timer > /sys/class/leds/red:wlan/trigger
            echo 1000 > /sys/class/leds/red:wlan/delay_off
            ;;
        "ar300m")
            echo timer > /sys/class/leds/gl-${model}:green:power/trigger
            echo 1000 > /sys/class/leds/gl-${model}:green:power/delay_off
            usleep 500000
            echo timer > /sys/class/leds/gl-${model}:green:lan/trigger
            echo 1000 > /sys/class/leds/gl-${model}:green:lan/delay_off
            usleep 500000
            echo timer > /sys/class/leds/gl-${model}:red:wlan/trigger
            echo 1000 > /sys/class/leds/gl-${model}:red:wlan/delay_off
        ;;
        "ar750" |\
        "ar750s")
            echo timer > /sys/class/leds/gl-${model}:green:power/trigger
            echo 1000 > /sys/class/leds/gl-${model}:green:power/delay_off
            usleep 500000
            echo timer > /sys/class/leds/gl-${model}:green:wlan2g/trigger
            echo 1000 > /sys/class/leds/gl-${model}:green:wlan2g/delay_off
            usleep 500000
            echo timer > /sys/class/leds/gl-${model}:green:wlan5g/trigger
            echo 1000 > /sys/class/leds/gl-${model}:green:wlan5g/delay_off
        ;;
        "x300b")
            echo timer >   /sys/class/leds/gl-${model}:green:lte/trigger
            echo 1000 >    /sys/class/leds/gl-${model}:green:lte/delay_off
            usleep 500000
            echo timer >   /sys/class/leds/gl-${model}:green:wan/trigger
            echo 1000 >    /sys/class/leds/gl-${model}:green:wan/delay_off
            usleep 500000
            echo timer >   /sys/class/leds/gl-${model}:green:wlan2g/trigger
            echo 1000 >    /sys/class/leds/gl-${model}:green:wlan2g/delay_off
        ;;
        "x750")
            echo timer >   /sys/class/leds/gl-${model}:green:power/trigger
            echo 2000 >    /sys/class/leds/gl-${model}:green:power/delay_off
            usleep 500000
            echo timer >   /sys/class/leds/gl-${model}:green:wan/trigger
            echo 2000 >    /sys/class/leds/gl-${model}:green:wan/delay_off
            usleep 500000
            echo timer >   /sys/class/leds/gl-${model}:green:wlan5g/trigger
            echo 2000 >    /sys/class/leds/gl-${model}:green:wlan5g/delay_off
            usleep 500000
            echo timer >   /sys/class/leds/gl-${model}:green:wlan2g/trigger
            echo 2000 >    /sys/class/leds/gl-${model}:green:wlan2g/delay_off
            usleep 500000
            echo timer >   /sys/class/leds/gl-${model}:green:lte/trigger
            echo 2000 >    /sys/class/leds/gl-${model}:green:lte/delay_off
        ;;
        "xe300v2")
            echo timer >   /sys/class/leds/internet/trigger
            echo 1500 >    /sys/class/leds/internet/delay_off
            usleep 500000
            echo timer >   /sys/class/leds/lan/trigger
            echo 1500 >    /sys/class/leds/lan/delay_off
            usleep 500000
            echo timer >   /sys/class/leds/cloud/trigger
            echo 1500 >    /sys/class/leds/cloud/delay_off
            usleep 500000
            echo timer >   /sys/class/leds/lte/trigger
            echo 1500 >    /sys/class/leds/lte/delay_off
        ;;
        "xe300")
            echo timer >   /sys/class/leds/gl-${model}:green:wan/trigger
            echo 1500 >    /sys/class/leds/gl-${model}:green:wan/delay_off
            usleep 500000
            echo timer >   /sys/class/leds/gl-${model}:green:lan/trigger
            echo 1500 >    /sys/class/leds/gl-${model}:green:lan/delay_off
            usleep 500000
            echo timer >   /sys/class/leds/gl-${model}:green:wlan/trigger
            echo 1500 >    /sys/class/leds/gl-${model}:green:wlan/delay_off
            usleep 500000
            echo timer >   /sys/class/leds/gl-${model}:green:lte/trigger
            echo 1500 >    /sys/class/leds/gl-${model}:green:lte/delay_off
        ;;
        "xe3000" |\
        "x2000"  |\
        "x3000")
            echo timer >   /sys/class/leds/internet/trigger
            echo 1000 >    /sys/class/leds/internet/delay_off
            usleep 500000
            echo timer >   /sys/class/leds/wifi:2g/trigger
            echo 1000 >    /sys/class/leds/wifi:2g/delay_off
            usleep 500000
            echo timer >   /sys/class/leds/wifi:5g/trigger
            echo 1000 >    /sys/class/leds/wifi:5g/delay_off
            ;;
        "mg1300" |\
        "mt6000" |\
        "mt3600be" |\
        "be5100"|\
        "mt5000"|\
        "sft3000")
            echo timer >   /sys/class/leds/blue:run/trigger
            echo 500 >    /sys/class/leds/blue:run/delay_off
            usleep 500000
            echo timer >   /sys/class/leds/white:system/trigger
            echo 500 >    /sys/class/leds/white:system/delay_off
            ;;
    *)
    esac
}

sysupgrade_led_display(){
    model=$(get_model)

    case "$model" in
        "sft1200" |\
        "mt1300" |\
        "a1300")
            /etc/init.d/gl_led stop
            gl_i2c_led blue_flash
            ;;
        "be5000" |\
        "axt1800")
            /etc/init.d/gl_led stop
            echo 0 > /sys/class/leds/white_led/brightness
            cat /sys/class/leds/blue_led/trigger | grep "\[timer\]" 1>/dev/null || echo timer > /sys/class/leds/blue_led/trigger
            ;;
        "be9300" |\
        "be6500" |\
        "sft3000")
            /etc/init.d/gl_led stop
            echo 0 > /sys/class/leds/white:system/brightness
            cat /sys/class/leds/blue:run/trigger | grep "\[timer\]" 1>/dev/null || echo timer > /sys/class/leds/blue:run/trigger
            ;;
        "s200")
            /etc/init.d/gl_led stop
            ubus call gl_ledd on_off '{"led_name":"iot_led","mode":"off"}'
            /etc/init.d/gl_ledd stop
            echo 0 > /sys/class/leds/gl-s200:green/brightness
            cat /sys/class/leds/gl-s200:blue/trigger | grep "\[timer\]" 1>/dev/null || echo timer > /sys/class/leds/gl-s200:blue/trigger
            ;;
        "mg1300" |\
        "mt300n-v2" |\
        "ar300m" |\
        "ar750" |\
        "xe300" |\
        "xe300v2" |\
        "x750"  |\
        "x300b" |\
        "ar750s" |\
        "mt6000" |\
        "xe3000" |\
        "x2000"  |\
        "mt3600be" |\
        "be5100"|\
        "mt5000"|\
        "x3000")
            /etc/init.d/gl_led stop
            led_blinking
            ;;
        "mv1000")
            echo timer > /sys/class/leds/gl-mv1000:white:power/trigger
            ;;
        "be14000" |\
        "be10000")
            mkdir -p /tmp/gl_screen/upgrade
            cp /etc/gl_screen/image/wallpaper.png /tmp/gl_screen/upgrade/
            [ -e /etc/gl_screen/wallpaper_home.png ] && cp /etc/gl_screen/wallpaper_home.png /tmp/gl_screen/upgrade/
            cp /etc/gl_screen/image/glinet.png /tmp/gl_screen/upgrade/
            cp /etc/gl_screen/language/ttf/default_medium.ttf /tmp/gl_screen/upgrade/
            ubus call gl_screen set '{"method": "upgrade"}'
            ;;
        "e5800" |\
        "be3600")
            ubus call gl_screen set '{"method": "upgrade"}'
            ;;
        *)
    esac
}

led_trigger_faster() {
    [ -n "$1" ] || return 0

    sleep 3
    [ -e "$1/delay_on" ] && echo "250" > $1/delay_on
    [ -e "$1/delay_off" ] && echo "250" > $1/delay_off

    # sft1200 can only control the led by use i2c
    [ -n "`echo $1 | grep use_i2c_control`" ] && gl_i2c_led "${1##use_i2c_control_}" medium
}

led_trigger_fastest() {
    [ -n "$1" ] || return 0

    sleep 8
    [ -e "$1/delay_on" ] && echo "125" > $1/delay_on
    [ -e "$1/delay_off" ] && echo "125" > $1/delay_off

    # sft1200 can only control the led by use i2c
    [ -n "`echo $1 | grep use_i2c_control`" ]  && gl_i2c_led "${1##use_i2c_control_}" fast
}

oled_control(){
    local model=$(get_model)
    local program_exit
    case "$model" in
        "e750")
            if [ "$1" = "pressed" ];then
                /usr/bin/e750_button &
            elif [ "$1" = "released" ];then
                program_exit=`ps | grep e750_button | grep -v grep`
                [ -n "$program_exit" ] && {
                    for pid in $(pgrep -f "e750_button")
                    do
                        kill -9 $pid
                    done
                }
            fi
    ;;
    esac
}

reset_btn_pressed() {
    local model=$(get_model)
    local led=$(reset_indicate_led_name)
    local all_led=''
    oled_control "pressed"

    [ -n "$led" ] || return 0

    led_trigger_faster $led &
    echo "$!" >> /tmp/led_trigger_pid
    led_trigger_fastest $led &
    echo "$!" >> /tmp/led_trigger_pid

    case "$model" in
        "ax1800" |\
        "axt1800" |\
        "be5000" |\
        "b3000")
            /etc/init.d/gl_led stop
            echo 0 > /sys/class/leds/white_led/brightness
            echo "timer" > $led/trigger
            ;;
        "be9300" |\
        "be6500" |\
        "sft3000" |\
        "mt1300")
            /etc/init.d/gl_led stop
            echo 0 > /sys/class/leds/white:system/brightness
            echo "timer" > $led/trigger
            ;;
        "mg1300" |\
        "mt2500" |\
        "mt6000" |\
        "mt3600be"|\
        "be5100"|\
        "mt5000"|\
        "mt3000")
            /etc/init.d/gl_led stop
            echo 0 > /sys/class/leds/white:system/brightness
            echo "timer" > $led/trigger
            ;;
        "a1300")
            /etc/init.d/gl_led stop
            echo 0 > /sys/class/leds/gl-a1300:white/brightness
            echo "timer" > $led/trigger
            ;;
        "s200")
            /etc/init.d/gl_led stop
            all_led=`uci -q get gl_led_cfg.global.all_led`
            if [ "$all_led" = "1" ];then
                ubus call gl_ledd blink '{"led_name":"sys_led","delay_on":"500","delay_off":"500"}'
            else
                echo "timer" > $led/trigger
            fi
            ;;
        "sft1200")
            /etc/init.d/gl_led stop
            gl_i2c_led blue_flash normal
            ;;
        "e5800" |\
        "be10000" |\
        "be14000" |\
        "be3600")
            ubus call gl_screen set '{"method": "button", "params": { "status": 0 }}'
            ;;
        *)
            echo "timer" > $led/trigger
            ;;
    esac
}

reset_btn_released() {
    local model=$(get_model)
    local led=$(reset_indicate_led_name)
    local all_led=''
    oled_control "released"
    [ -n "$led" ] || return 0

    [ -e /tmp/led_trigger_pid ] && {
        cat /tmp/led_trigger_pid | xargs kill -9
        rm /tmp/led_trigger_pid
    }

    case "$model" in
        "e750")
            echo "none" > $led/trigger
            killall -17 e750-mcu
            ;;
        "ax1800" |\
        "axt1800" |\
        "mg1300" |\
        "mt1300" |\
        "mt2500" |\
        "mt6000" |\
        "mt3000" |\
        "x300b" |\
        "b1300" |\
        "s1300" |\
        "sft3000" |\
        "ap1300" |\
        "a1300" |\
        "mv1000" |\
        "be5000" |\
        "b3000" |\
        "be9300"|\
        "mt3600be"|\
        "be5100"|\
        "mt5000"|\
        "be6500")
            echo "none" > $led/trigger
            /etc/init.d/gl_led start
            ;;
        "s200")
            all_led=`uci -q get gl_led_cfg.global.all_led`
            if [ "$all_led" = "1" ];then
                ubus call gl_ledd on_off '{"led_name":"sys_led","mode":"off"}'
            else
                echo "none" > $led/trigger
            fi
            /etc/init.d/gl_led start
            ;;
        "ar300m" |\
        "mt300n-v2" |\
        "sft1200" |\
        "x300b" |\
        "xe300" |\
        "ar750s")
            /etc/init.d/gl_led start
            ;;
        "e5800" |\
        "be10000" |\
        "be14000" |\
        "be3600")
            ubus call gl_screen set '{"method": "button", "params": { "status": 1 }}'
            for i in `seq 1 20`
            do
                usleep 100000
                result="$(ubus call gl_screen set '{"method": "get_button_press_time"}')"
                status="$(echo "$result" | jsonfilter -e @.result.status)"
                if [ "$status" = "1" ];then
                    press_time=$(echo "$result" | jsonfilter -e @.result.press_time)
                    [ -n $press_time ] && SEEN=$press_time
                    break
                fi
            done
            ;;
        *)
            echo "none" > $led/trigger
            echo 1 > $led/brightness
            ;;
    esac
}

set_modem_cfun0() {
    if [ -e "/lib/functions/modem.sh" ]; then
    . /lib/functions/modem.sh
    fi

    if [ -e "/proc/gl-hw-info/build-in-modem" -a -n "$(ls /dev/ | grep -E 'ttyU|mhi_')" ]; then
        local ret
        local bus=$(get_modem_bus)
        local model=$(get_model)

        case "$model" in
        "x3000")
            for count in $(seq 1 3); do
                ret=$(gl_modem -B $bus SAT sp AT+CFUN=0 | grep "OK")
                [ -n "$ret" ] && logger "set modem cfun0 success" && break
                sleep 1
            done
            ;;
        "xe3000")
            for count in $(seq 1 3); do
                ret=$(gl_modem -B $bus SAT sp AT+CFUN=0 | grep "OK")
                [ -n "$ret" ] && logger "set modem cfun0 success" && break
                sleep 1
            done
            sleep 1
            gl_modem -B $bus SAT sp AT+QPOWD
            ;;
        esac
    fi
}

factory_reset() {
    local model=$(get_model)
    local led=$(reset_indicate_led_name)

    echo "FACTORY RESET" > /dev/console

    case "$model" in
        "s200")
            ubus call gl_ledd on_off '{"led_name":"nwk_led","mode":"off"}'
            ubus call gl_ledd blink '{"led_name":"sys_led","delay_on":"200","delay_off":"200"}'
            ;;
        "e750")
            program_button_exit=`ps | grep e750_button | grep -v grep`
            [ -n "$program_button_exit" ] && {
                for pid in $(pgrep -f "e750_button")
                do
                    kill -9 $pid
                done
            }

            sleep 1
            ubus call mcu system_reft {\"system\":\"reft\"}
            sleep 2
            /etc/init.d/mcu stop
            ;;
        "x3000")
            set_modem_cfun0
            ;;
        *)
            /etc/init.d/gl_led stop
            [ -e "$led/trigger" ] && echo "timer" > $led/trigger
            [ -e "$led/delay_on" ] && echo 200 > $led/delay_on
            [ -e "$led/delay_off" ] && echo 200 > $led/delay_off
            # sft1200 can only control the led by use i2c
            [ -n "`echo $led | grep use_i2c_control`" ] && gl_i2c_led "${1##use_i2c_control_}" medium
            ;;
    esac

    [ -e "/etc/init.d/tailscale" ] && /etc/init.d/tailscale stop

    ubus call gl-session call "{\"module\":\"logread\",\"func\":\"remove_crash_log\",\"params\":{}}" > /dev/null

    if [ "$model" = "e5800" ]; then
        if [ -f "/etc/gl_screen/scripts/gl_screen_event.lua" ]; then
            ubus call gl_screen set '{"method": "poweroff anim start"}'
            local time=$(lua /etc/gl_screen/scripts/gl_screen_event.lua get_screen_poweroff_anim_time)
            sleep $time
        fi
        ifconfig eth1 down
        echo 1 > /sys/class/power_supply/charger/device/sgm41542s/mos1_pin
        atcmd AT+QCFG=\"ResetFactory\"
    else
        /sbin/firstboot -y;reboot
    fi
}

mv1000_reset_wireless() {
    local phy=''
    local i=0
    local mode=''

    while true
    do
        phy=`uci -q get wireless.@wifi-device[$i].phy`
        mode=`uci -q get wireless.@wifi-iface[$i].mode`
        if [ "$phy" = "phy" ];then
            i=$((i+1))
            continue
        elif [ "$phy" = "" ];then
            break
        fi

        if [ "$mode" = "sta" ];then
            uci set wireless.@wifi-device[$i].disabled='1'
            i=$((i+1))
            continue
        fi

        uci set wireless.@wifi-device[$i].disabled='0'
        uci set wireless.@wifi-iface[$i].disabled='0'
        i=$((i+1))
    done

    local dev=`uci -q get wireless.guest2g.device`
    if [ "$dev" != "" ];then
        uci set wireless.guest2g.disabled='1'
    fi
}

disable_mlo_wifi_iface() {
    config_get mld "$1" mld

    if [ -n "$mld" ]; then
        uci -q set wireless.$1.disabled='1'
        if [ -n "$(uci get wireless.$mld)" ]; then
            config_get device "$1" device
            [ -n "$device" ] && type=$(uci get wireless.$device.type)
            if [ "$type" == "mtkwifi" ]; then
                uci -q set wireless.$mld.disabled='1'
            else
                uci delete wireless.$mld
                uci -q set mlo.$mld.disabled='1'
            fi
        fi
    fi
}

reset_mlo_wireless() {
    config_load wireless
    config_foreach disable_mlo_wifi_iface wifi-iface
    uci commit wireless
}

access_vpn_tap() {
    local vpnid path config profile
    vpnid="$(uci get glconfig.openvpn.clientid)"
    path="$(uci get ovpnclients.${vpnid}.path)"
    config="$(uci get ovpnclients.${vpnid}.defaultserver)"
    profile="$(echo ${path}/${config})"
    [ -n "$(cat $profile |grep dev| grep tap)" ] && return 0
    return 1
}

platform_network_restart() {
    local model=$(get_model)
    if [ "$model" = "ar750s" -o "$model" = "x1200" ];then
        /etc/init.d/network restart; swconfig dev switch0 set phy_reset
    elif [ "$model" = "mt1300" ];then
        ethtool -i eth0 1>/dev/null; /etc/init.d/network restart
    elif [ "$model" = "xe300" -o "$model" = "s200" -o "$model" = "x750" ];then
        /etc/init.d/network restart;swconfig dev switch0 set reset
    elif [ "$model" = "a1300" -o "$model" = "b1300" -o "$model" = "s1300" -o "$model" = "ap1300" ];then
        etc/init.d/network restart
        swconfig dev switch0 set linkdown 1
        swconfig dev switch0 set linkdown 0
    elif [ "$model" = "mt5000" ];then
        /etc/init.d/network restart
        swconfig dev switch0 port 0 set disable 1
        swconfig dev switch0 port 1 set disable 1
        sleep 1
        swconfig dev switch0 port 0 set disable 0
        swconfig dev switch0 port 1 set disable 0
    else
        /etc/init.d/network restart
    fi
}

platform_usb_lan_restart() {
    if [ -f "/proc/gl-hw-info/usb-otg" -a "$(cat /proc/gl-hw-info/usb-otg)" = "true" ]; then
        if [ -f "/proc/gl-hw-info/usb-port" ];then
            local usb_proto=""
            ports=$(cat /proc/gl-hw-info/usb-port |sed 's/,/ /g')
            for port in $ports; do
                if [ -f "/sys/bus/usb/devices/$port/idVendor" ]; then
                    if [ "$port" = "1-1" ]; then
                        usb_proto="usb1"
                    else
                        usb_proto="usb2"
                    fi

                    break
                fi
            done

            if [ "$usb_proto" != "" ]; then
                echo 1 > /sys/class/power_supply/charger/device/sgm41542s/mos1_pin
                sleep 4
                echo 0 > /sys/class/power_supply/charger/device/sgm41542s/mos1_pin
            else
                udc=$(cat /sys/kernel/config/usb_gadget/g1/UDC)
                echo '' > /sys/kernel/config/usb_gadget/g1/UDC
                sleep 2
                echo $udc > /sys/kernel/config/usb_gadget/g1/UDC
            fi
        fi
    fi
}

_restore_hairpin_callback() {
    local device mode network ifname hairpin disabled
    config_get device $1 device
    config_get mode $1 mode
    config_get disabled $1 disabled
    config_get network $1 network
    config_get ifname $1 ifname
    config_get hairpin $1 hairpin

    local target_network="$2"

    if [ "$(echo "$device" | cut -c1-6)" != "MT7990" ]; then
        return
    fi
    if [ "$mode" != "ap" ]; then
        return
    fi
    if [ "$disabled" = "1" ]; then
        return
    fi
    if [ "$network" != "$target_network" ]; then
        return
    fi

    if [ -z "$hairpin" ] || [ "$hairpin" = "1" ]; then
        logger -t gl_util "hairpin on $ifname"
        mwctl phy phy0 set hairpin_mode 1 2>/dev/null
        bridge link set dev "$ifname" hairpin on 2>/dev/null
    else
        logger -t gl_util "hairpin off $ifname"
        mwctl phy phy0 set hairpin_mode 0 2>/dev/null
        bridge link set dev "$ifname" hairpin off 2>/dev/null
    fi
}

# 恢复 bridge hairpin 模式
# $1=network  目标网络名称
restore_hairpin_mode() {
    local driver=$(uci get wireless.@wifi-device[0].type 2>/dev/null)
    if [ "$driver" != "mtkwifi" ]; then
        return
    fi

    config_load wireless
    config_foreach _restore_hairpin_callback wifi-iface "$1"
}

qsdk_kick_all_wireless_station() {
    config_get mode $1 mode
    config_get disabled $1 disabled
    config_get ifname $1 ifname

    if [ "$mode" != "ap" -o "$disabled" = "1" ]; then
        return
    fi

    cfg80211tool $ifname kickmac ff:ff:ff:ff:ff:ff
}

disconnect_lan_clients(){
    local model=$(get_model)

    if [ -e /sys/class/ieee80211 -a ! -e /lib/wifi/qcawificfg80211.sh ]; then
        /sbin/wifi
    fi

    if [ -e /lib/wifi/qcawificfg80211.sh ]; then
       config_load wireless
       config_foreach qsdk_kick_all_wireless_station wifi-iface
    fi

    if [ -e /sys/class/net/ra0 ]; then
        iwpriv ra0 set DisConnectAllSta=1
        iwpriv ra1 set DisConnectAllSta=1
        if [ -e /sys/class/net/rax0 ]; then
            iwpriv rax0 set DisConnectAllSta=1
            iwpriv rax1 set DisConnectAllSta=1
        fi
    fi

    local filtered_ports
    filtered_ports=$(uci get network.@device[0].ports 2>/dev/null | tr ' ' '\n' | grep -E '^(eth[0-9]|lan[0-9])')
    if [ -n "$filtered_ports" ]; then
        for port in $filtered_ports; do
            ip link set "$port" down
        done
        sleep 1
        for port in $filtered_ports; do
            ip link set "$port" up
        done
    fi
    case "$model" in
        "ar150"|\
        "mifi"|\
        "ar750"|\
        "ar300m"|\
        "x750"|\
        "e750"|\
        "x300b"|\
        "xe300"|\
        "s200"|\
        "ar750s")
            swconfig dev switch0 set reset
            ;;
        "a1300"|\
        "b1300"|\
        "s1300"|\
        "ap1300")
            swconfig dev switch0 set linkdown 1
            sleep 1
            swconfig dev switch0 set linkdown 0
            ;;
        "mt300n-v2")
            swconfig dev switch0 port 1 set disable 1
            swconfig dev switch0 set apply 1
            sleep 1
            swconfig dev switch0 port 1 set disable 0
            swconfig dev switch0 set apply 1
            ;;
        "sft1200"|\
        "sf1200")
            ip link set dev eth0 down; sleep 1; ip link set dev eth0 up
            ;;
        "b3000")
            swconfig dev switch1 load network
            ;;
        "be9300"|\
        "be6500")
            local ports
            if [ "$(uci -q get glconfig.general.lan2wan)" = "1" ]; then
                ports=$(seq 4 6)
            else
                ports=$(seq 4 7)
            fi

            for i in $ports;
            do
                swconfig dev switch1 port $i set disable 1
            done

            sleep 1

            for i in $ports;
            do
                swconfig dev switch1 port $i set disable 0
            done
        ;;
        "mt5000")
            local ports
            if [ "$(uci -q get glconfig.general.lan2wan)" = "1" ]; then
                ports=1
            else
                ports=$(seq 0 1)
            fi
            for i in $ports;
            do
                swconfig dev switch0 port $i set disable 1
                sleep 1
                swconfig dev switch0 port $i set disable 0
            done
            ;;
        "be14000")
            local ports="$(seq 0 4)"
            local wan_ports
            wan_ports="$(
                uci -q show eth_ports_config_map 2>/dev/null | awk -F"'" '
                    /^eth_ports_config_map\.[^.]+=.port$/ { sid=$1; sw=""; p=""; m=""; next }
                    /\.switch=/ { sw=$2; next }
                    /\.port=/ { p=$2; next }
                    /\.mode=/ { m=$2; next }
                    sw=="switch0" && m=="wan" && p!="" { print p; sw=""; p=""; m="" }
                ' | tr '\n' ' '
            )"

            for i in $ports; do
                case " $wan_ports " in
                    *" $i "*)
                        continue
                        ;;
                esac
                swconfig dev switch0 port "$i" set enable_port 0
                sleep 1
                swconfig dev switch0 port "$i" set enable_port 1
                sleep 1
            done
        ;;
    esac
}

reset_network() {
    [ -f "/tmp/lock/procd_reset_network.lock" ] && {
        ubus call mcu system_renw {\"system\":\"renw\"}
        logger "the reset button is pressed too fast,reset network lock"
        return
    }

    touch /tmp/lock/procd_reset_network.lock
    local model=$(get_model)
    local osver
    local index=0

    echo "Now resetting network" > /dev/console

    if [ -f /etc/board.json ];
    then
        . /etc/os-release
        osver=$(echo $VERSION_ID | grep -o '^[0-9]*')

        json_init
        json_load "$(cat /etc/board.json)"

        json_select network

        json_is_a lan object
        if [ $? -eq 0 ];
        then
            json_select lan
            json_get_vars protocol ifname
            json_select ..

            uci set network.lan.proto="$protocol"
            if [ $osver -gt 20 ];
            then
                if [ "$model" == "b3000" ]; then
                    index=1
                else
                    index=0
                fi

                if [ "$model" != "e5800" ]; then
                    uci delete network.@device[$index].ports

                    for port in $(cat /proc/gl-hw-info/lan);
                    do
                        uci add_list network.@device[$index].ports="$port"
                    done
                fi

                if [ "$model" = "be9300" ] || [ "$model" = "be6500" ]; then
uci batch <<EOF
                    delete board_special.hardware.wan
                    delete board_special.hardware.secondwan
                    delete network.wan.vlanid
                    delete network.wan.ifname
                    delete network.secondwan.vlanid
                    delete network.secondwan.ifname
                    delete network.secondwan_dev
                    delete network.@switch_vlan[0]
                    delete network.@switch_vlan[0]
                    delete network.@switch_vlan[0]
                    set board_special.hardware.lan='eth1.1'
                    set network.vlan_lan='switch_vlan'
                    set network.vlan_lan.device='switch1'
                    set network.vlan_lan.vid='1'
                    set network.vlan_lan.vlan='1'
                    set network.vlan_lan.ports='4 5 6 7 3t'
                    set network.lan_dev.name='eth1.1'
                    set network.lan.ifname="$ifname"
EOF
                elif [ "$model" == "mt5000" ]; then
uci batch <<EOF
                    delete board_special.hardware.wan
                    delete board_special.hardware.secondwan
                    delete network.wan.vlanid
                    delete network.wan.ifname
                    delete network.secondwan.vlanid
                    delete network.secondwan.ifname
                    delete network.secondwan_dev
                    delete network.@switch_vlan[0]
                    delete network.@switch_vlan[0]
                    delete network.@switch_vlan[0]
                    set board_special.hardware.lan='eth0.1'
                    set network.vlan_lan='switch_vlan'
                    set network.vlan_lan.device='switch0'
                    set network.vlan_lan.vlan='1'
                    set network.vlan_lan.ports='0 1 17t'
EOF
                fi
            else
                if [ "$model" == "b3000" ]; then
uci batch <<EOF
                    delete board_special.hardware.wan
                    delete board_special.hardware.secondwan
                    delete network.wan.vlanid
                    delete network.wan.ifname
                    delete network.secondwan.vlanid
                    delete network.secondwan.ifname
                    delete network.@switch_vlan[0]
                    delete network.@switch_vlan[0]
                    delete network.@switch_vlan[0]
                    set board_special.hardware.lan='eth1.2'
                    set network.vlan_wan.device='switch1'
                    set network.vlan_wan.vlan='1'
                    set network.vlan_wan.ports='1 6t'
                    set network.vlan_lan='switch_vlan'
                    set network.vlan_lan.device='switch1'
                    set network.vlan_lan.vid='2'
                    set network.vlan_lan.vlan='2'
                    set network.vlan_lan.ports='2 3 6t'
                    set network.wan_dev.name='eth1.1'
                    set network.lan_dev.name='eth1.2'
                    set network.secondwan_dev.name='eth1.3'
EOF
                elif [ "$model" == "sft1200" ]; then
uci batch <<EOF
                    delete network.@switch_vlan[0]
                    delete network.@switch_vlan[0]
                    delete network.@switch_vlan[0]
                    set network.vlan_lan='switch_vlan'
                    set network.vlan_lan.device='switch0'
                    set network.vlan_lan.vlan='1'
                    set network.vlan_lan.ports='1 2 5t'
                    set network.lan_dev.name='eth0.1'
EOF
                fi
                uci set network.lan.ifname="$ifname"
            fi
        else
            uci delete network.lan
        fi

        json_is_a wan object
        if [ $? -eq 0 ];
        then
            json_select wan
            json_get_vars protocol ifname device
            json_select ..

            uci set network.wan.proto="$protocol"

            if [ "$model" == "b3000" ]; then
                uci del network.wan.vlanid
                uci set network.vlan_wan.ports='1 6t'
                uci set network.vlan_wan.vid='1'
                uci set network.vlan_wan.vlan='1'
            elif [ "$model" == "sft1200" ]; then
                uci delete board_special.hardware.wan
                uci delete glconfig.general.wan
                uci set network.vlan_wan='switch_vlan'
                uci set network.vlan_wan.device='switch0'
                uci set network.vlan_wan.vlan='2'
                uci set network.vlan_wan.ports='0 5t'
                uci set network.wan_dev.name='eth0.2'
            fi

            [ $osver -gt 20 ] && uci set network.wan.device="$device" || uci set network.wan.ifname="$ifname"
        else
            if [ "$model" != "e750" -a "$model" != "e5800" ]; then
                uci delete network.wan
            fi
        fi
    else
        local wan_eth="$(cat /proc/gl-hw-info/wan)"
        local lan_eth="$(cat /proc/gl-hw-info/lan)"

        uci set network.wan.ifname="$wan_eth"
        uci set network.wan.proto="dhcp"
        uci set network.lan.proto="static"
        uci set network.lan.ifname="$lan_eth"
    fi

    if [ -z "$(uci -q get network.lan.ipaddr)" ]; then
        uci -q rename network.lan.ipaddr_old=ipaddr
    fi

    if [ "$model" == "be3600" -o "$model" == "mt6000" ]; then
        wan_interface=$(uci -q get board_special.hardware.wan)
        if [ -n "$wan_interface" ]; then
            device_num=$(uci -q show network | grep ".name='$wan_interface'" | awk -F'[][]' '{print $2}')
            uci -q delete network.@device[$device_num].mtu
            uci -q delete network.wan.ttl
            uci -q delete network.wan.ttl_ipv6
            if [ "$wan_interface" != "$(uci -q get board_special.network.wan)" -a  "$wan_interface" != "$(uci -q get board_special.network.lan)" ]; then
                device_name=$(uci -q get board_special.hardware.wan | cut -d '.' -f1)
                uci -q set network.@device[$device_num].name="$device_name"
                uci -q set board_special.hardware.wan="$device_name"
            fi
        fi
        secondwan_interface=$(uci -q get board_special.hardware.secondwan)
        if [ -n "$secondwan_interface" ]; then
            device_num=$(uci -q show network | grep ".name='$secondwan_interface'" | awk -F'[][]' '{print $2}')
            uci -q delete network.@device[$device_num].mtu
            uci -q delete network.secondwan.ttl
            uci -q delete network.secondwan.ttl_ipv6
            if [ "$secondwan_interface" != "$(uci -q get board_special.network.wan)" -a  "$secondwan_interface" != "$(uci -q get board_special.network.lan)" ]; then
                device_name=$(uci -q get board_special.hardware.secondwan | cut -d '.' -f1)
                uci -q set network.@device[$device_num].name="$device_name"
                uci -q delete board_special.hardware.secondwan
                uci -q set board_special.hardware.wan="$(cat /proc/gl-hw-info/wan)"
            fi
        fi
        uci commit network
        uci commit board_special
    fi

    case "$model" in
        "ar150"|\
        "s200"|\
        "mifi"|\
        "ar300m"|\
        "x300b"|\
        "xe300"|\
        "xe300v2"|\
        "mt300a"|\
        "mt300n"|\
        "n300"|\
        "usb150")
            uci set wireless.radio0.disabled='0'
            uci set wireless.@wifi-iface[0].disabled='0'
            uci -q set wireless.guest2g.disabled='1'
            ;;
        "mt300n-v2")
            uci set wireless.radio0.disabled='0'
            uci set wireless.@wifi-iface[0].disabled='0'
            uci -q set wireless.guest2g.disabled='1'

            uci set system.led_wifi_led.dev='ra0'
            /etc/init.d/led restart
            ;;
        "mv1000")
            mv1000_reset_wireless
            ;;
        "be9300"|\
        "be6500")
            uci set wireless.radio0.disabled='0'
            uci set wireless.radio1.disabled='0'
            uci set wireless.radio2.disabled='0'
            uci set wireless.@wifi-iface[0].disabled='0'
            uci set wireless.@wifi-iface[1].disabled='0'
            uci set wireless.@wifi-iface[2].disabled='0'
            uci -q set wireless.guest2g.disabled='1'
            uci -q set wireless.guest5g.disabled='1'
            uci -q set wireless.iot2g.disabled='1'
            uci -q set wireless.iot5g.disabled='1'
            uci -q set wireless.guest6g.disabled='1'
            reset_mlo_wireless
            ;;
        "e5800")
            uci set wireless.wifi0.disabled='0'
            uci set wireless.wifi1.disabled='0'
            uci set wireless.wifi2.disabled='0'
            uci set wireless.wifi2g.disabled='1'
            uci set wireless.wifi5g.disabled='0'
            uci set wireless.wifi6g.disabled='1'
            uci set wireless.guest2g.disabled='1'
            uci set wireless.guest5g.disabled='1'
            uci set wireless.guest6g.disabled='1'
            uci set wireless.autoparam.usemode='auto'
            uci set wireless.autoparam.useband='5g'
            uci set wireless.autoparam.use_enable='0'
            uci set wireless.autoparam.use_guestenable='1'
            ;;
        "be5100"|\
        "mt3600be")
            uci set wireless.MT7993_1_1.disabled='0'
            uci set wireless.MT7993_1_2.disabled='0'
            uci set wireless.@wifi-iface[0].disabled='0'
            uci set wireless.@wifi-iface[1].disabled='0'
            uci -q set wireless.guest2g.disabled='1'
            uci -q set wireless.guest5g.disabled='1'
            uci -q set wireless.iot2g.disabled='1'
            uci -q set wireless.iot5g.disabled='1'
            reset_mlo_wireless
            ;;
        "be14000"|\
        "be10000")
            uci set wireless.MT7990_1_1.disabled='0'
            uci set wireless.MT7990_1_2.disabled='0'
            uci set wireless.MT7990_1_3.disabled='0'
            uci set wireless.@wifi-iface[0].disabled='0'
            uci set wireless.@wifi-iface[1].disabled='0'
            uci set wireless.@wifi-iface[2].disabled='0'
            uci -q set wireless.guest2g.disabled='1'
            uci -q set wireless.guest5g.disabled='1'
            uci -q set wireless.guest6g.disabled='1'
            uci -q set wireless.iot2g.disabled='1'
            uci -q set wireless.iot5g.disabled='1'
            reset_mlo_wireless
            ;;
        *)
            uci set wireless.radio0.disabled='0'
            uci set wireless.radio1.disabled='0'
            uci set wireless.@wifi-iface[0].disabled='0'
            uci set wireless.@wifi-iface[1].disabled='0'
            uci -q set wireless.guest2g.disabled='1'
            uci -q set wireless.guest5g.disabled='1'
            uci -q set wireless.iot2g.disabled='1'
            uci -q set wireless.iot5g.disabled='1'
            reset_mlo_wireless
            ;;
    esac

    uci -q set network.guest.disabled=1
    uci -q set network.iot.disabled=1

    uci -q delete network.wan.disabled
    uci -q delete network.wan.peerdns
    uci -q delete network.wan.dns
    uci -q delete network.lan.macaddr

    default_macaddr=$(uci get network.lan.default_macaddr)
    [ -n "$default_macaddr" ] && uci set network.lan.macaddr=$default_macaddr

    interface=$(uci -q get network.wan.device)
    wan_num=`uci -q show network | grep ".name='$interface'" | awk -F'[][]' '{print $2}'`
    mac_clone=$(uci -q get network.@device[$wan_num].mac_mode)
    [ -n "`echo $mac_clone | grep -E 'r|c'`" ] && {
        mac=$(uci -q get board_special.hardware.device_mac || cat /proc/gl-hw-info/device_mac)

        uci -q set network.@device[$wan_num].macaddr="$mac"
        uci -q delete network.@device[$wan_num].mac_mode
        uci -q delete network.@device[$wan_num].mac_expire
    }

    not_device_mac_clone=$(uci -q get network.wan.mac_mode)
    [ -n "`echo $not_device_mac_clone | grep -E 'r|c'`" ] && {
        mac=$(uci -q get board_special.hardware.device_mac || cat /proc/gl-hw-info/device_mac)

        uci -q set network.wan.macaddr="$mac"
        uci -q delete network.wan.mac_mode
        uci -q delete network.wan.mac_expire
    }

    [ "$model" = "e5800" ] && {
        mac=$(uci -q get board_special.hardware.device_mac || cat /proc/gl-hw-info/device_mac)
        lan_interface=$(uci -q get board_special.network.lan)
        lan_num=`uci -q show network | grep ".name='$lan_interface'" | awk -F'[][]' '{print $2}'`
        lan_mac=$(macaddr_add "$mac" 1)
        lan_mac_default=$(uci -q get network.@device[$lan_num].macaddr)

        if [ "$lan_mac_default" != "$lan_mac" ]; then
            uci -q set network.@device[$lan_num].macaddr="$lan_mac"
        fi
    }

    uci -q delete network.tethering.dns
    uci -q delete network.modem.dns

    uci set dhcp.lan.ignore='0'
    uci set dhcp.@dnsmasq[0].disabled='0'

    if [ "$model" = "e750" ]; then
        ubus call mcu system_renw {\"system\":\"renw\"}
        uci set glconfig.general.wan2lan='1'
    elif [ "$model" = "e5800" ]; then
        uci -q delete network.wan.hostname
        local wan2lan=`uci -q get glconfig.general.wan2lan`
        if [ "$wan2lan" = "0" ]; then
            /etc/data/tethering.sh set_eth_config 2 1 1
            /etc/data/tethering.sh set_eth_type eth0 0 1
            sleep 2
        fi
        uci set glconfig.general.wan2lan='1'

        local usb_lan2wan=`uci -q get glconfig.general.usb_lan2wan`
        if [ "$usb_lan2wan" = "1" ]; then
            local usb_ifname=`uci -q get network.usbwan.device`
            if [ -n "$usb_ifname" ]; then
                uci add_list network.@device[0].ports="$usb_ifname"
            fi
            uci -q delete network.usbwan.device
            uci set glconfig.general.usb_lan2wan='0'
        fi
    else
        uci set glconfig.general.wan2lan='0'
    fi

    local passthrough=`uci -q get passthrough.passthrough.enable`
    if [ "$passthrough" = "1" ];then
        uci -q del firewall.passthrough
        uci commit firewall
        /etc/init.d/firewall restart
        uci set passthrough.passthrough.enable='0'
        uci commit passthrough
    fi

    local lan2wan=`uci -q get glconfig.general.lan2wan`
    if [ "$lan2wan" = "1" ];then
        br_lan_num=`uci -q show network | grep ".name='br-lan'" | awk -F'[][]' '{print $2}'`
        lan_mac=`uci -q get network.@device[$br_lan_num].macaddr`
        device=`uci -q get network.secondwan.device`
        uci -q delete network.secondwan.device
        uci -q delete network.secondwan.disabled
        number=`uci -q show network | grep ".name='$device'" | awk -F'[][]' '{print $2}'`
        uci -q set network.@device[$number].macaddr="$lan_mac"
        uci -q delete network.@device[$number].mac_mode
        uci -q delete network.@device[$number].mac_expire
        uci set glconfig.general.lan2wan='0'
    fi

    [ -e "/usr/bin/reset_network_utils.lua" ] && /usr/bin/lua /usr/bin/reset_network_utils.lua 'turn_off_all'

    [ "$model" = "be14000" ] && {
        local wan_interface="$(cat /proc/gl-hw-info/wan)"
        local secondwan_interface="$(cat /proc/gl-hw-info/secondwan)"
        local sfp_mac=$(uci -q get eth_ports_config_map.sfp.default_mac)
        uci -q set network.vlan_secondwan='switch_vlan'
        uci -q set network.vlan_secondwan.device='switch0'
        uci -q set network.vlan_secondwan.vlan='2'
        uci -q set network.vlan_secondwan.ports='4 5t'
        uci -q set network.secondwan_dev='device'
        uci -q set network.secondwan_dev.name="$secondwan_interface"
        uci -q set network.secondwan_dev.ifname='eth1'
        [ -n "$sfp_mac" ] && uci -q set network.secondwan_dev.macaddr="$sfp_mac"
        uci -q set network.secondwan.device="$secondwan_interface"
        uci -q set board_special.hardware.secondwan="$secondwan_interface"
        uci -q set board_special.hardware.wan="$wan_interface"
        uci set glconfig.general.lan2wan='1'
        uci set glconfig.general.wan2lan='0'
        uci -q delete glconfig.general.secondwan
        uci commit network
        uci commit board_special
        uci commit glconfig
    }

    uci -q set gl-black_white_list.global.enable='1'
    uci commit

    [ -e /proc/gl-hw-info/screen ] && {
        for i in `seq 1 3`;do sleep 3;ubus call gl_screen set '{"method": "network_mode_change"}';done &
    }

    [ -d "/etc/gl-reset-network.d" ] && {
        for a in $(ls /etc/gl-reset-network.d); do
            . /etc/gl-reset-network.d/$a
        done
    }
    if [ "$model" = "a1300" -o "$model" = "b1300" -o "$model" = "s1300" -o "$model" = "ap1300" ]; then
        sleep 5
    fi

    uci set glipv6.wan.addrmode='auto'
    uci set glipv6.wan.dnsmode='auto'
    uci commit glipv6

    /etc/init.d/gl_ipv6 reload_wan
    /etc/init.d/gl_ipv6 reload
    /etc/init.d/network restart
    /etc/init.d/sysctl restart
    /etc/init.d/dnsmasq enable
    /etc/init.d/dnsmasq restart
    /etc/init.d/repeater restart
    /etc/init.d/gl-cloud restart
    [ -e /etc/init.d/gl_cellular_manager ] && /etc/init.d/gl_cellular_manager  restart
    [ -e /etc/init.d/gl-black_white_list ] && /etc/init.d/gl-black_white_list restart
    [ "$(uci -q get tor.global.enable)" = "1" ] && /usr/bin/tor.sh start_tor&

    if [ "$model" = "ar150" -o "$model" = "mifi" -o "$model" = "ar750" -o "$model" = "ar300m" -o "$model" = "x750" -o "$model" = "e750" \
        -o "$model" = "x300b" -o "$model" = "xe300" -o "$model" = "s200" -o "$model" = "ar750s" ];then
            swconfig dev switch0 set reset
    elif [ "$model" = "a1300" -o "$model" = "b1300" -o "$model" = "s1300" -o "$model" = "ap1300" ]; then
            swconfig dev switch0 set linkdown 1
            sleep 2
            swconfig dev switch0 set linkdown 0
    elif [ "$model" = "mt3600be" -o "$model" = "be5100" ]; then
            ip link set eth1 down
            sleep 2
            ip link set eth1 up
    elif [ "$model" = "mt5000" ]; then
            swconfig dev switch0 port 0 set disable 1
            swconfig dev switch0 port 1 set disable 1
            sleep 1
            swconfig dev switch0 port 0 set disable 0
            swconfig dev switch0 port 1 set disable 0
    fi
    if [ "$model" = "ar150" -o "$model" = "mifi" -o "$model" = "ar750" -o "$model" = "ar300m" -o "$model" = "x750"  \
        -o "$model" = "x300b" -o "$model" = "xe300" -o "$model" = "xe300v2" ];then
            /etc/init.d/led  reload
    fi

    if [ "$model" = "x2000" ]; then
        sleep 10
    fi

    [ "$(uci -q get zerotier.gl.enabled)" = "1" ] && /etc/init.d/zerotier restart

    if [ "$model" != "be3600" -a "$model" != "xe300v2" -a "$model" != "x2000" -a "$model" != "sft3000" -a "$model" != "mt3600be" -a "$model" != "e5800" -a "$model" != "be10000" -a "$model" != "mt5000" -a "$model" != "be5100" -a "$model" != "be14000" ]; then
        sleep 5
        /etc/init.d/network restart
    fi

    platform_usb_lan_restart

    rm -rf /tmp/lock/procd_reset_network.lock
}

dnsmasq_set_resolvfile()
{
    local target=$1
    [ -z $target ] && return
    [ -f /tmp/"$target" ] && {
        uci set dhcp.@dnsmasq[0].resolvfile=/tmp/"$target"
        uci commit dhcp
        return
    }
    [ -f /tmp/resolv.conf.d/"$target" ] && {
        uci set dhcp.@dnsmasq[0].resolvfile=/tmp/resolv.conf.d/"$target"
        uci commit dhcp
        return
    }
}

usb_driver_crash_avoidance_scheme()
{
    local model=$(get_model)
    local action=$1
    if [ "$model" = a1300 -o "$model" = b1300 -o "$model" = s1300 -o "$model" = ap1300 ];
    then
         if [ "$action" = offline ];then
                rmmod /lib/modules/5.4.179/xhci-plat-hcd.ko
                insmod /lib/modules/5.4.179/xhci-plat-hcd.ko
         fi

    fi
}

remount_ubifs()
{
    local model=$(get_model)
    if [ "$model" = a1300 ]; then
        mount -o remount,sync,assert=report /overlay/
    fi
}

fan_init()
{
    local model=$(get_model)
    local temperature=75
    local minimum_temperature=70
    local sysfs="/sys/devices/virtual/thermal/thermal_zone0/temp"
    local div=1

    case "$model" in
    mt6000 |\
    mt3000)
        div=1000
        temperature=76
        ;;
    be5100 |\
    be14000 |\
    mt3600be |\
    mt5000 |\
    be3600 |\
    be9300 |\
    be6500 |\
    xe3000 |\
    x2000  |\
    x3000)
        div=1000
        ;;
    be10000)
        temperature=70
        minimum_temperature=65
        div=1000
        ;;
    *)
        ;;
    esac

    uci rename glfan.@globals[0]="globals"
    uci set glfan.@globals[0].temperature="$temperature"
    uci set glfan.@globals[0].warn_temperature="$temperature"
    uci set glfan.@globals[0].minimum_temperature="$minimum_temperature"
    uci set glfan.@globals[0].sysfs="$sysfs"
    uci set glfan.@globals[0].div="$div"
    uci commit glfan
}

fix_ipq40xx_wan_vlan()
{
    if [ -f /proc/sys/net/edma/default_wan_tag ]; then
        if [ -z "$(grep "ports '5 0'" /etc/config/network)" ]; then
            uci add network switch_vlan
            uci set network.@switch_vlan[-1].device='switch0'
            uci set network.@switch_vlan[-1].vlan='2'
            uci set network.@switch_vlan[-1].ports='5 0'
            uci commit network
        fi
    fi
}

fix_ax1800_upgrade_url()
{
    local model=$(get_model)
    if [ "$model" = ax1800 ]; then
        if [ "$(uci -q get upgrade.general.url)" != "https://fw.gl-inet.com/firmware/ax1800/v4" ]; then
            uci set upgrade.general.url='https://fw.gl-inet.com/firmware/ax1800/v4'
            uci commit upgrade
        fi
    fi
}

kmwan_init() {
        local model=$(get_model)
    local simo=$(get_simo)
        local member
        if [ "$model" = s200 -o "$model" = x300b ]; then
           uci -q delete kmwan.tethering
           uci -q delete kmwan.tethering6
           uci -q commit kmwan
           member="wan wwan wan6 wwan6"
        elif [ "$simo" = "1" ]; then
           member="wan wwan tethering simo wan6 wwan6 tethering6 simo6"
        else
           member="wan wwan tethering wan6 wwan6 tethering6"
        fi
        echo $member
}

turnoff_iot_led() {
    model=$(get_model)

    case "$model" in
        "s200")
            ubus call gl_ledd all_status '{"all_led_status":"off"}'
            ;;
        *)
    esac

}

turnon_iot_led() {
    model=$(get_model)

    case "$model" in
        "s200")
            ubus call gl_ledd all_status '{"all_led_status":"on"}'
            ;;
        *)
    esac
}

set_nginx_thread() {
    model=$(get_model)

    case "$model" in
	"mg1300")
            sed 's/ca-certificates.crt/ca-certificates-simple.crt/g' -i /etc/nginx/conf.d/gl.conf
            sed 's/worker_processes.*;/worker_processes 1;/g' -i /etc/nginx/nginx.conf
	    ;;
        "sf1200" |\
        "sft1200" |\
        "x750" |\
        "ar750" |\
        "ar750s" |\
        "mt300n-v2"|\
        "x300b" |\
        "xe300v2" |\
        "xe300" |\
        "e750" |\
        "mt3600be" |\
        "be5100"|\
        "ar300m")
            sed 's/worker_processes.*;/worker_processes 2;/g' -i /etc/nginx/nginx.conf
            ;;
        *)
    esac
}

set_hnat_by_default() {
    local model=$(get_model)
    local flow_offloading
    local flow_offloading_hw

    case "$model" in
        "sft3000" |\
        "mg1300" |\
        "mt1300" |\
        "sft1200")
            flow_offloading=1
            flow_offloading_hw=1
            ;;
        "mt3000" |\
        "be5100" |\
        "be10000" |\
        "mt5000" |\
        "mt3600be" |\
        "mt6000")
            [ -d /proc/mtketh ] || {
                flow_offloading=1
                flow_offloading_hw=1
            }
            ;;
        "e5800")
            flow_offloading=1
            ;;
        *)
    esac

    uci set firewall.@defaults[0].flow_offloading="$flow_offloading"
    uci set firewall.@defaults[0].flow_offloading_hw="$flow_offloading_hw"
    uci commit  firewall
}

set_mcu_uart_dev_by_default() {
    model=$(get_model)

    case "$model" in
               "e750")
               dev=`cut -f 1 -d , /proc/gl-hw-info/mcu 2>/dev/null`
               baudrate=`cut -f 2 -d , /proc/gl-hw-info/mcu 2>/dev/null`
               oled=`cut -f 2 -d , /proc/gl-hw-info/oled 2>/dev/null`
               if [ -n "$dev" -a -n "$baudrate" -a -n "$oled" ];then
                   uci set glconfig.mcu=service
                   uci set glconfig.mcu.dev="$dev"
                   uci set glconfig.mcu.baudrate="$baudrate"
                   uci set glconfig.mcu.oled="$oled"
                   uci set glconfig.mcu.printk="0"
                   uci commit glconfig
               fi
               ;;

        *)
            dev=`cut -f 1 -d , /proc/gl-hw-info/mcu 2>/dev/null`
            baudrate=`cut -f 2 -d , /proc/gl-hw-info/mcu 2>/dev/null`
            if [ -n "$dev" -a -n "$baudrate" ];then
                uci set glconfig.mcu=service
                uci set glconfig.mcu.dev="$dev"
                uci set glconfig.mcu.baudrate="$baudrate"
                uci commit glconfig
            fi
            ;;
    esac
}

sysupgrade_mcu_screen_display(){
    model=$(get_model)
    case "$model" in
        "e750")
            ubus call mcu system_update
            sleep 2
            /etc/init.d/mcu stop
        ;;
    esac
}

# return 0 means has secondwan
has_secondwan() {
    model=$(get_model)

    case "$model" in
        "mt6000" |\
        "x3000"  |\
        "x2000"  |\
        "xe3000" |\
        "be3600" |\
        "be9300" |\
        "be6500" |\
        "xe300v2" |\
        "be5100" |\
        "be10000" |\
        "be14000" |\
        "mt3600be" |\
        "mt5000" |\
        "sft3000" |\
        "b3000")
            return 0
        ;;
        *)
            return 1
        ;;
    esac
}

create_reload_service()
{
    local name="$(basename $1)"
    if [ "$GL_SERVICE_QUEUE" = "1" ];then
        mkdir -p /var/run/gl_reload_service
        echo "$1" >/var/run/gl_reload_service/"$name"
    else
        $1 reload
    fi
}

create_restart_service()
{
    local name="$(basename $1)"
    if [ "$GL_SERVICE_QUEUE" = "1" ];then
        mkdir -p /var/run/gl_restart_service
        echo "$1" >/var/run/gl_restart_service/"$name"
    else
        $1 restart
    fi
}

set_tuning_switch()
{
    local band=$1
    model=$(get_model)

    case "$model" in
        "e750")
            if [ $band = "1" -o $band = "2" -o $band = "7" -o $band = "8" \
              -o $band = "25" -o $band = "38" -o $band = "39" -o $band = "40" -o $band = "41" ]; then
                echo 0 > /sys/class/gpio/gpio13/value
                echo 0 > /sys/class/gpio/gpio14/value
                echo 0 > /sys/class/gpio/gpio17/value
            elif [ -o $band = "3" -o $band = "4" $band = "5" -o $band = "20" -o $band = "26" -o $band = "66" ]; then
                echo 0 > /sys/class/gpio/gpio13/value
                echo 1 > /sys/class/gpio/gpio14/value
                echo 0 > /sys/class/gpio/gpio17/value
            elif [ $band = "12" -o $band = "13" -o $band = "17" -o $band = "28" ]; then
                echo 1 > /sys/class/gpio/gpio13/value
                echo 0 > /sys/class/gpio/gpio14/value
                echo 0 > /sys/class/gpio/gpio17/value
            elif [ $band = "71" ]; then
                echo 1 > /sys/class/gpio/gpio13/value
                echo 1 > /sys/class/gpio/gpio14/value
                echo 0 > /sys/class/gpio/gpio17/value
            fi
            ;;
        *)
    esac
}

wan2lan_init()
{
    model=$(get_model)

    case "$model" in
        "e750"|"e5800")
            uci set glconfig.general.wan2lan='1'

            uci set network.wan=interface
            uci set network.wan.proto='dhcp'
            uci set network.wan.force_link='0'
            uci set network.wan.ipv6='0'

            uci set network.wan6=interface
            uci set network.wan6.proto='dhcpv6'
            uci set network.wan6.ifname='@wan'
            uci set network.wan6.disabled='1'
            uci commit
            ;;
        *)
    esac
}

set_br_lan_bridge_empty()
{
    model=$(get_model)

    case "$model" in
	"be10000"|\
        "e5800")
            uci set network.@device[0].bridge_empty='1'
            uci commit network
            ;;
        *)
    esac
}

generate_default_ssid()
{
    local band="$1"
    local mac="$2"
    model=$(get_model | awk '{ print toupper($1) }')

    local ssid="GL-$model-$mac"

    if [ "$model" != "E750" -a "$model" != "E5800" ]; then
        case $1 in
        5g)
            ssid="$ssid-5G"
            ;;
        6g)
            ssid="$ssid-6G"
            ;;
        esac
    fi
    echo $ssid
}
set_mcu_auto_start(){
    model=$(get_model)
    case "$model" in
        "e750")
            echo [\"auto_start\": \"0\"] > /dev/ttyS0
        ;;
        *)
    esac
}

set_mini_free_kbytes()
{
    local CTL_FILE="/etc/sysctl.d/12-free-kbytes.conf"
    [ -e "$CTL_FILE"  ] && return
    model=$(get_model)
    case "$model" in
    "ar150" |\
    "ar300m" |\
    "ar750" |\
    "ar750s" |\
    "mifi" |\
    "usb150" |\
    "mt300n-v2" |\
    "sft1200" |\
    "xe300v2" |\
    "xe300" |\
    "x300b" |\
    "x750" |\
        "e750")
            echo "vm.min_free_kbytes=6144" > "$CTL_FILE"
        ;;
        *)
    esac
}

mcu_send_message()
{
    local model=$(get_model)
    local name
    if [ "$model" = "e750" ]; then
    #ubus call mcu send_custom_msg "{\"msg\": \"$1\"}"
    if [ "$2" == "wireguard" ]; then
       if [ -z "$(uci -q get network.wgclient)" ]; then
          name=`uci -q get wireguard.@peers[0].name`
       else
          local config=`uci -q get network.wgclient.config`
          name=`uci -q get wireguard.$config.name`
       fi

       if [ -z "$name" ]; then
          echo {\"msg\": \"WG NO Configuration File\"} > /dev/ttyS0
          exit 0
       else
          echo {\"msg\": \"$1\"} > /dev/ttyS0
       fi
    elif [ "$2" == "openvpn" ]; then
       if [ -z "$(uci -q get network.ovpnclient)" ]; then
          name=`uci -q get ovpnclient.@clients[0].name`
       else
          local config=`uci -q get network.ovpnclient.config`
          name=`uci -q get ovpnclient.$config.name`
       fi

       if [ -z "$name" ]; then
          echo {\"msg\": \"OVPN NO Configuration File\"} > /dev/ttyS0
          exit 0
       else
          echo {\"msg\": \"$1\"} > /dev/ttyS0
       fi
        else
          echo {\"msg\": \"$1\"} > /dev/ttyS0
    fi
    fi
}

wait_for_wifi_ready()
{
    local model=$(get_model)
    local n=10
    local radios=""
    local iw_info=""
    local index=0
    case "$model" in
        "x2000" |\
        "b3000")
            n=60
            radios="wifi0 wifi1"
        ;;
        "be9300")
            n=60
            radios="wifi0 wifi1 wifi2"
        ;;
	"be10000" |\
        "be6500" |\
        "be3600")
            n=0
        ;;
        *)
    esac

    while [ "$iw_info" == "" -a $n -gt 0 ]
    do
        for radio in $radios
        do
            index=$(echo $radio | sed 's/[^0-9]*//g')
            if [ "$(uci -q get wireless.@wifi-iface[$index].disabled)" == "1" ]; then
                iw_info=`iwinfo $radio info`
            else
                iw_info=`iwinfo wlan$index info`
            fi
        done
        let n=n-1
        sleep 1
    done
}

ipcalc_network()
{
    local response
    if [ $# -ge 2 ] && [ ! $(echo "$2" | grep "\.") ]; then
        local ip=$1
        local mask=$2

        shift 2
        response=$(ipcalc.sh $ip/$mask $@)
    else
        response=$(ipcalc.sh $@)
    fi

    echo "$response"
}

get_2B_art()
{
    local dev=`get_model`
    local mtd=''

    case $dev in
    "xe3000"|\
    "x3000")
        mtd="mmcblk0p3"
        ;;
    "usb150"|\
    "inet"|\
    "ar150"|\
    "ar300m"|\
    "mifi"|\
    "ar750"|\
    "ar750s"|\
    "x750"|\
    "x300b"|\
    "e750"|\
    "x1200")
        mtd=$(cat /proc/mtd | awk -F: '/art/{print $1}')
        ;;
    "mt300a"|\
    "mt300n"|\
    "vixmini"|\
    "n300"|\
    "mt300n-v2")
        mtd="mtd2"
        ;;
    *)
        mtd=$(cat /proc/mtd | awk -F: '/art|ART|factory|Factory/{print $1}')
        ;;
    esac

    echo "$mtd"
}

get_2B_art_skip()
{
    local dev=`get_model`
    local dev_art_skip=0

    case $dev in
    "mt1300")
        dev_art_skip=0x4000
        ;;
    "x750")
        dev_art_skip=0
        ;;
    "sft1200")
        dev_art_skip=0x400
        ;;
    "*")
        dev_art_skip=0
        ;;
    esac

    echo "$dev_art_skip"
}

get_art_fw()
{
    local mtd=`get_2B_art`
    local dev_art_skip=`get_2B_art_skip`

    [ "$mtd" = "" ] && return

    dd if=/dev/$mtd bs=1 count=2 skip=$((dev_art_skip+0x90)) 2>/dev/null | sed 's/[^[:print:]]//g'
}

get_2B_passwd()
{
    local mtd=`get_2B_art`
    local dev_art_skip=`get_2B_art_skip`

    [ "$mtd" = "" ] && return

    dd if=/dev/$mtd bs=1 count=32 skip=$((dev_art_skip+0xa0)) 2>/dev/null | sed 's/[^[:print:]]//g'
}

get_2B_model()
{
    local mtd=`get_2B_art`
    local dev_art_skip=`get_2B_art_skip`

    [ "$mtd" = "" ] && return

    dd if=/dev/$mtd bs=1 count=16 skip=$((dev_art_skip+0xc0)) 2>/dev/null | sed 's/[^[:print:]]//g'
}

get_2B_hostname()
{
    local mtd=`get_2B_art`
    local dev_art_skip=`get_2B_art_skip`

    [ "$mtd" = "" ] && return

    dd if=/dev/$mtd bs=1 count=16 skip=$((dev_art_skip+0xd0)) 2>/dev/null | sed 's/[^[:print:]]//g'
}

get_2B_2g_ssid()
{
    local mtd=`get_2B_art`
    local dev_art_skip=`get_2B_art_skip`

    [ "$mtd" = "" ] && return

    dd if=/dev/$mtd bs=1 count=32 skip=$((dev_art_skip+0xe0)) 2>/dev/null | sed 's/[^[:print:]]//g'
}

get_2B_5g_ssid()
{
    local mtd=`get_2B_art`
    local dev_art_skip=`get_2B_art_skip`

    [ "$mtd" = "" ] && return

    dd if=/dev/$mtd bs=1 count=32 skip=$((dev_art_skip+0x100)) 2>/dev/null | sed 's/[^[:print:]]//g'
}

get_2B_wifi_key()
{
    local mtd=`get_2B_art`
    local dev_art_skip=`get_2B_art_skip`

    [ "$mtd" = "" ] && return

    dd if=/dev/$mtd bs=1 count=32 skip=$((dev_art_skip+0x120)) 2>/dev/null | sed 's/[^[:print:]]//g'
}

get_vpn_group() {
    local service_policy_en=$(uci -q get route_policy.global.service_policy_en) # v4.8
    local service_policy=$(uci -q get vpnpolicy.global.service_policy) # before v4.8

    if [ -n "$service_policy_en" ] && [ "$service_policy_en" = 1 ]; then
        echo "usevpn"
    elif [ -n "$service_policy" ] && [ "$service_policy" = 1 ]; then
        echo "nonevpn"
    else
        echo ""
    fi
}

get_switch_button_status() {
    [ "$(uci -q get board_special.hardware.switch_button)" = "" ] && [ ! -f "/proc/gl-hw-info/switch-button" ] && {
        echo "no support"
        return
    }
    model=$(cat /proc/gl-hw-info/model)
    gpio=$(cat /proc/gl-hw-info/switch-button)

    if [ "$model" = "mt3000" -o "$model" = "mt3600be" -o "$model" = "be5100" ]; then
        status=$(cat /sys/kernel/debug/gpio | grep "switch" | grep "hi")
    elif [ "$model" = "axt1800" -o "$model" = "be3600" ]; then
        status=$(cat /sys/kernel/debug/gpio | grep "$gpio" | grep "hi")
    elif [ "$model" = "a1300" ]; then
        status=$(cat /sys/kernel/debug/gpio | grep "gpio0" | grep "lo")
    else
        status=$(cat /sys/kernel/debug/gpio | grep "switch" | grep "lo")
    fi

    if [ -z "$status" ]; then
        echo "off"
    else
        echo "on"
    fi
}

set_fw4_nat6()
{
    [ "$(which fw4)" = "" ] && return

    local ip6prefix=$(uci get network.guest.ip6prefix | awk -F "::" '{print $1}')
    local ip6hint=$(uci get network.guest.ip6hint)
    local wgserver_addr=$(uci -q get wireguard_server.main_server.address_v6)
    local ovpnserver_addr=$(uci -q get ovpnserver.vpn.subnetv6)
    [ "$wgserver_addr" = "" ] && [ "$ovpnserver_addr" = "" ] && [ "$ip6prefix" = "" ] && return

    uci delete firewall.wan6
    uci set firewall.wan6="zone"
    uci set firewall.wan6.masq6='1'
    uci set firewall.wan6.name='wan6'
    uci set firewall.wan6.output='ACCEPT'
    uci set firewall.wan6.forward='REJECT'
    uci set firewall.wan6.input='DROP'
    uci set firewall.wan6.mtu_fix='1'
    uci set firewall.wan6.family='ipv6'
    uci add_list firewall.wan6.masq_src="$ip6prefix:$ip6hint::/64"

    [ -n "$wgserver_addr" ] && {
        prefix=$(echo "$wgserver_addr" | awk -F "::" '{print $1}')
        prefix_len=$(echo "$wgserver_addr" | awk -F "/" '{print $2}')
        [ -n "$prefix" ] && [ -n "$prefix_len" ] && uci add_list firewall.wan6.masq_src="$prefix::/$prefix_len"
    }

    [ -n "$ovpnserver_addr" ] && {
        prefix=$(echo "$ovpnserver_addr" | awk -F "::" '{print $1}')
        prefix_len=$(echo "$ovpnserver_addr" | awk -F "/" '{print $2}')
        [ -n "$prefix" ] && [ -n "$prefix_len" ] && uci add_list firewall.wan6.masq_src="$prefix::/$prefix_len"
    }

    uci delete firewall.wan6.network
    local modem
    for bus in `cat /proc/gl-hw-info/usb-port | sed 's/,/ /g' | sed 's/-/_/g'`
    do
        if [ -f /usr/bin/cellular_manager ]; then
            modem="modem_${bus}_s1_6 $modem"
        else
            modem="modem_${bus}_6 $modem"
        fi
    done
    local interface="wan6 wwan6 tethering6 $modem"
    for iface in $interface
    do
        uci add_list firewall.wan6.network="$iface"
    done

    [ -e "/proc/gl-hw-info/secondwan" ] && {
        uci add_list firewall.wan6.network="secondwan6"
    }

    local usbwan=$(uci -q get glconfig.general.usb_lan2wan)
    [ -n "$usbwan" ] && {
        uci add_list firewall.wan6.network="usbwan6"
    }

    [ -e "/proc/gl-hw-info/modem-cpu" ] && {
        uci add_list firewall.wan6.network="modem_cpu_6"
    }

    uci commit firewall
}

