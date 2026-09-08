. /usr/share/libubox/jshn.sh

. /lib/functions/gl_log.sh


LTE=" 1 2 3 4 5 7 8 12 13 14 17 18 19 20 25 26 28 29 30 32 34 38 39 40 41 42 43 46 48 66 71 "
SA=" 1 2 3 5 7 8 12 13 14 18 20 25 26 28 29 30 38 40 41 48 66 70 71 75 76 77 78 79 "
NSA=" 1 2 3 5 7 8 12 13 14 18 20 25 26 28 29 30 38 40 41 48 66 70 71 75 76 77 78 79 "
LTE_US=" 2 4 5 7 12 13 14 25 26 29 30 41 48 66 71 "
LTE_EU=" 1 3 5 7 8 20 28 32 38 40 41 42 43 "

get_modem_log_level(){

    level=$(uci -q get glmodem.global.log_level)

    if [ "$level" = "0" ];then
        echo "DEBUG"
    elif [ "$level" = "1" ];then
        echo "INFO"
    elif [ "$level" = "2" ];then
        echo "ERROR"
    else
        echo "INFO"
    fi
}

set_log_level "$(get_modem_log_level)"

idVendor_arr="2c7c 12d1 17cb 5c6 19d2"

get_modem_bus()
{
    local modem_bus="1-1.2"
    node=$(uci -q get glmodem.global.usbnode)
    if [ -z "$node" ]; then
        build_in="$(cat /proc/gl-hw-info/build-in-modem 2>/dev/null)"
        [ -z "$build_in" ] && build_in="$(cat /proc/gl-hw-info/usb-port 2>/dev/null)"
    else
        build_in=$node
    fi

    if [ -e /var/run/modem/extern_modem_bus ] && [ ! -e "/proc/gl-hw-info/build-in-modem" ];then
        modem_bus=$(cat /var/run/modem/extern_modem_bus 2>/dev/null) 
    else
        if [ "$(echo $build_in | grep -q ',';echo $?)" = "0" ]; then
            build_in_array="${build_in/,/ }"
            for modem in $build_in_array; do
                if [ -z "$(echo $modem | grep '-')" ]; then
                    ls /sys/bus/pci/devices/* | grep -q "$modem" && modem_bus=$modem ;break
                else
                    [ -n "$(find /sys/bus/usb/devices/ -name "$modem")" ] && {
                        idVendor=$(cat /sys/bus/usb/devices/$modem/idVendor 2>/dev/null)
                        if [ -n "$(echo ${idVendor_arr} | grep ${idVendor})" ];then
                             modem_bus=$modem
                             break
                        else
                            for sub_dir in /sys/bus/usb/devices/$modem/*; do
                                if [ -d "$sub_dir" ]; then
                                    sub_idVendor=$(cat $sub_dir/idVendor 2>/dev/null)
                                    if [ -n "$sub_idVendor" ] && [ -n "$(echo ${idVendor_arr} | grep ${sub_idVendor})" ];then
                                        modem_bus=$(basename $sub_dir)
                                        break
                                    fi
                                fi
                            done
                        fi
                    }
                fi
            done
        elif [ -z "$(echo $build_in | grep '-')" ]; then
            ls /sys/bus/pci/devices/* |grep -q "$build_in"
            [ "$(echo $?)" = "0" ] && modem_bus=$build_in
        else
            ls /sys/bus/usb/devices/* | grep -q "$build_in"
            [ "$(echo $?)" = "0" ] && modem_bus=$build_in
        fi
    fi
    echo $modem_bus
}

get_current_sim_slot() {
    local bus="$1"
    ubus -t 5 call cellular.modem status 2>/dev/null \
    | jsonfilter -e "@.modems[@.bus='$bus'].current_sim_slot" \
    | tr -d '\n'
}

get_modem_iface()
{
    local modem_iface=""
    local bus=$1
    [ -z "$bus" ] && bus=$(get_modem_bus)
    if [ -n "$(echo $bus | grep ':')" -a -e "/proc/gl-hw-info/pcie-bus" ] && [[ $(cat /proc/gl-hw-info/pcie-bus 2>/dev/null) == *$bus* ]];then
        modem_iface="modem_$(echo ${bus%%:*})"
    elif [ -n "$(echo $bus | grep '-')" ]; then
        modem_iface="modem_$(echo $bus | sed 's/-/_/g' | sed 's/\./_/g')"
    fi
    echo $modem_iface
}

build_3g_ppp_ifname()
{
    local config="$1"

    if [ "${config#modem_}" != "$config" ]; then
        echo "3g-m_${config#modem_}"
    else
        echo "3g-${config}"
    fi
}

get_modem_bus_list()
{
    local bus_list=""
    local bus_in=""
    local bus_ex=""
    bus_in=$(uci -q get board_special.hardware.build_in_modem | tr ',' ' ')
    bus_ex=$(uci -q get board_special.hardware.usb_port  | tr ',' ' ')
    bus_list="$bus_in $bus_ex"
    if [ -z "$bus_in" ] || [ -z "$bus_ex" ]; then
        bus_in="$(cat /proc/gl-hw-info/build-in-modem 2>/dev/null | tr ',' ' ')"
        bus_ex="$(cat /proc/gl-hw-info/usb-port 2>/dev/null | tr ',' ' ')"
        bus_list="$bus_in $bus_ex $bus_list"
    fi

    echo $bus_list
}

get_modem_iface_list()
{
    local iface_list=""
    local iface=""
    local bus_list="$(get_modem_bus_list)"
    for bus in $bus_list; do

        if [ "$bus" = "cpu" ];then
            iface="modem_cpu"
            iface_list="$iface_list $iface"
        else
            type=$(ubus call cellular.modem info | jsonfilter -e '@.modems[@.bus="'"$bus"'"].type')
            [ -z "$type" ] && type="1"
            if [ "$type" = "1" ]; then
                iface="modem_$(echo $bus | sed 's/-/_/g' | sed 's/\./_/g')_s1"
                iface_list="$iface_list $iface"
            else
                sim_slot_num=$(ubus call cellular.modem info | jsonfilter -e '@.modems[@.bus="'"$bus"'"].sim_slot_num')
                [ -z "$sim_slot_num" ] && sim_slot_num="1"
                for slot in $(seq 0 $((sim_slot_num - 1))); do
                    if [ -n "$(echo $bus | grep ':')" ]; then
                        iface="modem_${bus%%:*}_s$((slot + 1))"
                    elif [ -n "$(echo $bus | grep '-')" ]; then
                        iface="modem_$(echo $bus | sed 's/-/_/g' | sed 's/\./_/g')_s$((slot + 1))"
                    else
                        iface="modem_${bus}_s$((slot + 1))"
                    fi
                    iface_list="$iface_list $iface"
                done
            fi
        fi
    done
    echo $iface_list
}

get_modem_iface6_list()
{
    local iface6_list=""
    local iface6=""
    local iface_list="$(get_modem_iface_list)"
    for iface in $iface_list; do
        iface6="${iface}_6"
        iface6_list="$iface6_list $iface6"
    done
    echo $iface6_list
}

band2hex()
{
    local band="$@"
    local l=0;
    local h=0;
    for i in $band;do
        let i=i-1
        if [ $i -lt 64 ];then
            v=$((1<<$i))
            let l=l+v
        else
            let i=i-64
            v=$((1<<$i))
            let h=h+v
        fi
    done
    if [ $h -gt 0 ];then
        printf "%x%016x" $h $l
    else
        printf "%x" $l
    fi
}

allow_bands()
{
    [ -f "/proc/gl-hw-info/build-in-modem" ] || return
    local mode="$1"
    local bands=`echo $2 | sed 's/ /:/g'`
    local bus=$(get_modem_bus)

    [ "$bands" = "all" ] && bands=$(eval echo \$$mode | sed 's/ /:/g')
    [ "$bands" = "" ] && return

    case $mode in
        *LTE*)
            local hex
            if [ "$2" = "all" ]; then
                hex="$(band2hex $LTE)"  
            elif [ -n "$2" ] ; then
                hex="$(band2hex $2)"
            fi
            eval gl_modem -B $bus AT \'AT+QNWPREFCFG=\"lte_band\",$bands\' 1>/dev/null 2>&1
            eval gl_modem -B $bus AT \'AT+QCFG=\"band\",0,$hex\' 1>/dev/null 2>&1
        ;;
        SA*)
            eval gl_modem -B $bus AT \'AT+QNWPREFCFG=\"nr5g_band\",$bands\' 1>/dev/null 2>&1
        ;;
        *NSA*)
            eval gl_modem -B $bus AT \'AT+QNWPREFCFG=\"nsa_nr5g_band\",$bands\' 1>/dev/null 2>&1
        ;;
    esac
}

disable_bands()
{
    local mode="$1"
    local dis_bands="$2"

    local bands=$(eval echo \$$mode)
    for dis_band in $dis_bands
    do
        bands=`echo $bands | sed 's/\<'"$dis_band"'\>//'`
    done

    allow_bands "$mode" "$bands"
}

set_5G_mode()
{
    local lte_band="$1"
    local sa_band="$2"
    local nsa_band="$3"
    local bus=$(get_modem_bus)

    if [ "$lte_band" = "" -a "$sa_band" = "" -a "$nsa_band" = "" ];then
        eval gl_modem -B $bus AT \'AT+QNWPREFCFG=\"mode_pref\",AUTO\' 1>/dev/null 2>&1
        eval gl_modem -B $bus AT \'AT+QNWPREFCFG=\"nr5g_disable_mode\",0\' 1>/dev/null 2>&1
    elif [ "$lte_band" = "" ] && [ "$sa_band" != "" -o "$nsa_band" != "" ];then
        eval gl_modem -B $bus AT \'AT+QNWPREFCFG=\"mode_pref\",NR5G\' 1>/dev/null 2>&1
        if [ "$sa_band" != "" -a "$nsa_band" = "" ];then
            eval gl_modem -B $bus AT \'AT+QNWPREFCFG=\"nr5g_disable_mode\",2\' 1>/dev/null 2>&1
        elif [ "$sa_band" = "" -a "$nsa_band" != "" ];then
            eval gl_modem -B $bus AT \'AT+QNWPREFCFG=\"nr5g_disable_mode\",1\' 1>/dev/null 2>&1
        elif [ "$sa_band" != "" -a "$nsa_band" != "" ];then
            eval gl_modem -B $bus AT \'AT+QNWPREFCFG=\"nr5g_disable_mode\",0\' 1>/dev/null 2>&1
        fi
    elif [ "$lte_band" != "" ] && [ "$sa_band" != "" -o "$nsa_band" != "" ];then
        eval gl_modem -B $bus AT \'AT+QNWPREFCFG=\"mode_pref\",LTE:NR5G\' 1>/dev/null 2>&1
        if [ "$sa_band" != "" -a "$nsa_band" = "" ];then
            eval gl_modem -B $bus AT \'AT+QNWPREFCFG=\"nr5g_disable_mode\",2\' 1>/dev/null 2>&1
        elif [ "$sa_band" = "" -a "$nsa_band" != "" ];then
            eval gl_modem -B $bus AT \'AT+QNWPREFCFG=\"nr5g_disable_mode\",1\' 1>/dev/null 2>&1
        elif [ "$sa_band" != "" -a "$nsa_band" != "" ];then
            eval gl_modem -B $bus AT \'AT+QNWPREFCFG=\"nr5g_disable_mode\",0\' 1>/dev/null 2>&1
        fi
    elif [ "$lte_band" != "" ] && [ "$sa_band" = "" -o "$nsa_band" = "" ];then
        eval gl_modem -B $bus AT \'AT+QNWPREFCFG=\"mode_pref\",LTE\' 1>/dev/null 2>&1
    fi
}

set_5G_mode_mask()
{
    local lte_band="$1"
    local sa_band="$2"
    local nsa_band="$3"
    local bus=$(get_modem_bus)

    if [ "$lte_band" = "" -a "$sa_band" = "" -a "$nsa_band" = "" ];then
        eval gl_modem -B $bus AT \'AT+QNWPREFCFG=\"mode_pref\",AUTO\' 1>/dev/null 2>&1
        eval gl_modem -B $bus AT \'AT+QNWPREFCFG=\"nr5g_disable_mode\",0\' 1>/dev/null 2>&1
    elif [ " $lte_band " = "$LTE" ] && [ " $sa_band " != "$SA" -o " $nsa_band " != "$NSA" ];then
        eval gl_modem -B $bus AT \'AT+QNWPREFCFG=\"mode_pref\",NR5G\' 1>/dev/null 2>&1
        if [ " $sa_band " != "$SA" -a " $nsa_band " = "$NSA" ];then
            eval gl_modem -B $bus AT \'AT+QNWPREFCFG=\"nr5g_disable_mode\",2\' 1>/dev/null 2>&1
        elif [ " $sa_band " = "$SA" -a " $nsa_band " != "$NSA" ];then
            eval gl_modem -B $bus AT \'AT+QNWPREFCFG=\"nr5g_disable_mode\",1\' 1>/dev/null 2>&1
        elif [ " $sa_band " != "$SA" -o " $nsa_band " != "$NSA" ];then
            eval gl_modem -B $bus AT \'AT+QNWPREFCFG=\"nr5g_disable_mode\",0\' 1>/dev/null 2>&1
        fi
    elif [ " $lte_band " != "$LTE" ] && [ " $sa_band " != "$SA" -o " $nsa_band " != "$NSA" ];then
        eval gl_modem -B $bus AT \'AT+QNWPREFCFG=\"mode_pref\",LTE:NR5G\' 1>/dev/null 2>&1
        if [ " $sa_band " != "$SA" -a " $nsa_band " = "$NSA" ];then
            eval gl_modem -B $bus AT \'AT+QNWPREFCFG=\"nr5g_disable_mode\",2\' 1>/dev/null 2>&1
        elif [ " $sa_band " = "$SA" -a " $nsa_band " != "$NSA" ];then
            eval gl_modem -B $bus AT \'AT+QNWPREFCFG=\"nr5g_disable_mode\",1\' 1>/dev/null 2>&1
        elif [ " $sa_band " != "$SA" -o " $nsa_band " != "$NSA" ];then
            eval gl_modem -B $bus AT \'AT+QNWPREFCFG=\"nr5g_disable_mode\",0\' 1>/dev/null 2>&1
        fi
    elif [ " $lte_band " != "$LTE" ] && [ " $sa_band " = "$SA" -o " $nsa_band " = "$NSA" ];then
        eval gl_modem -B $bus AT \'AT+QNWPREFCFG=\"mode_pref\",LTE\' 1>/dev/null 2>&1
    else
        eval gl_modem -B $bus AT \'AT+QNWPREFCFG=\"mode_pref\",WCDMA\' 1>/dev/null 2>&1
    fi

}

set_4G_mode()
{
    local lte_band="$1"

    if [ "$lte_band" != "" ];then
        eval gl_modem -B $bus AT \'AT+QNWPREFCFG=\"mode_pref\",LTE\' 1>/dev/null 2>&1
    else
        eval gl_modem -B $bus AT \'AT+QNWPREFCFG=\"mode_pref\",AUTO\' 1>/dev/null 2>&1
    fi
}

set_4G_mode_mask()
{
    local lte_band="$1"
    local mode="$2"
    local lte=""
    if [ "$mode" != "" ];then
        lte=$(eval echo \$$mode)
    else
        lte="$LTE"
    fi

    if [ " $lte_band " = " $lte " ];then
        eval gl_modem -B $bus AT \'AT+QNWPREFCFG=\"mode_pref\",WCDMA\' 1>/dev/null 2>&1
    fi
}

handle_bands()
{
    local version=""
    local bus=$(get_modem_bus)
    for count in $(seq 1 10)
    do
        version=`gl_modem -B $bus AT ATI 2>/dev/null | grep Revision: | awk '{print $2}'`
        [ "$version" != "" ] && break
        sleep 1
    done

    local interface="$1"
    local lte=""
    [ -n "$interface" ] || return
    local band_filter=`uci -q get network.$interface.band_filter_mode`
    local band_list=`uci -q get network.$interface.band_list`
    json_load "$band_list"
    json_get_values "lte" "LTE"
    case $version in
        *RM520NGL*)
            json_get_values "sa" "NR-SA"
            json_get_values "nsa" "NR-NSA"
            [ -z "$band_filter" ] && {
                set_5G_mode "$lte" "$sa" "$nsa"
                allow_bands "LTE" all
                allow_bands "SA"  all
                allow_bands "NSA" all
            }
            [ "$band_filter" = "0" ] && {
                set_5G_mode "$lte" "$sa" "$nsa"
                allow_bands "LTE" "$lte"
                allow_bands "SA" "$sa"
                allow_bands "NSA" "$nsa"
            }
            [ "$band_filter" = "1" ] && {
                set_5G_mode_mask "$lte" "$sa" "$nsa"
                [ " $lte " != "$LTE" ] && disable_bands "LTE" "$lte"
                [ " $sa" != "$SA" ] && disable_bands "SA" "$sa"
                [ " $nsa" != "$NSA" ] && disable_bands "NSA" "$nsa"
            }
        ;;
        *EG120KNA*)
            [ -z "$band_filter" ] && {
                set_4G_mode
                allow_bands "LTE_US" all
            }
            [ "$band_filter" = "0" ] && {
                set_4G_mode
                allow_bands "LTE_US" "$lte"
            }
            [ "$band_filter" = "1" ] && {
                set_4G_mode_mask "$lte" "LTE_US"
                disable_bands "LTE_US" "$lte"
            }
        ;;
        *EG120KEA*)
            [ -z "$band_filter" ] && {
                set_4G_mode
                allow_bands "LTE_EU" all
            }
            [ "$band_filter" = "0" ] && {
                set_4G_mode
                allow_bands "LTE_EU" "$lte"
            }
            [ "$band_filter" = "1" ] && {
                set_4G_mode_mask "$lte" "LTE_EU"
                disable_bands "LTE_EU" "$lte"
            }
        ;;
        *)
            [ -z "$band_filter" ] && {
                set_4G_mode
                allow_bands "LTE" all
            }
            [ "$band_filter" = "0" ] && {
                set_4G_mode
                allow_bands "LTE" "$lte"
            }
            [ "$band_filter" = "1" ] && {
                set_4G_mode_mask "$lte"
                disable_bands "LTE" "$lte"
            }
        ;;
    esac

}

modem_AT_set_band()
{
    local modem_iface=""
    local bus=$(get_modem_bus)
    if [ -f "/proc/gl-hw-info/build-in-modem" ];then
        modem_iface=$(get_modem_iface $bus)
    else
        return
    fi

    handle_bands $modem_iface
}

modem_AT_set_roaming()
{
    [ -f "/proc/gl-hw-info/build-in-modem" ] || return
    local bus=$(get_modem_bus)
    local modem_iface=$(get_modem_iface $bus)
    local roaming=`uci -q get network.$modem_iface.roaming`
    log_debug $LINENO "modem" "(modem_AT_set_roaming)roaming:$roaming"
    if [ "$roaming" = "0" ];then
        gl_modem -B $bus AT AT+QNWPREFCFG=\"roam_pref\",1  1>/dev/null 2>&1
        gl_modem -B $bus AT AT+QNWCFG=\"data_roaming\",1  1>/dev/null 2>&1
        gl_modem -B $bus AT AT+QCFG=\"roamservice\",1  1>/dev/null 2>&1
    else
        gl_modem -B $bus AT AT+QNWPREFCFG=\"roam_pref\",255 1>/dev/null 2>&1
        gl_modem -B $bus AT AT+QNWCFG=\"data_roaming\",0  1>/dev/null 2>&1
        gl_modem -B $bus AT AT+QCFG=\"roamservice\",255  1>/dev/null 2>&1
    fi

}

get_operator_type()
{
    local bus=$1
    local slot=$2
    local tmobiles="310160 310200 310210 310220 310230 310240 310250 310260 310270 310280 310300 310310 310330 310660 310800 310490 310530 310580 310590 310640 311500"

    for count in $(seq 1 3)
    do
        flag=`gl_modem -B $bus -U $slot AT AT 2>/dev/null | grep 'OK'`
        [ "$flag" != "" ] && break
        [ $count -eq 3 ] && return
        sleep 1
    done

    local ret=""
    local operator=$(gl_modem -B $bus -U $slot AT AT+COPS? 2>/dev/null | grep COPS | cut -d '"' -f 2)
    [ -n "$operator" ] || operator=$(gl_modem -B $bus -U $slot AT AT+COPS? 2>/dev/null | grep COPS | cut -d '"' -f 2)
    if [ "$operator" = "T-Mobile" -o "$operator" = "Verizon" ]; then
        ret=$operator
        echo $ret
        log_debug $LINENO "modem" "(get_operator_type)operator:$ret"
        return
    fi

    local version=""
    for count in $(seq 1 10)
    do
        version=`gl_modem -B $bus -U $slot AT ATI 2>/dev/null | grep Revision: | awk '{print $2}'`
        [ "$version" != "" ] && break
        sleep 1
    done
    local imsi=$(gl_modem -B $bus -U $slot AT AT+CIMI 2>/dev/null | tr -cd [0-9] | cut -b 1-6)
    local num=`echo $imsi | wc -c`
    if [ "$imsi" != "" ] && [ $num -gt 5 ] ;then
        for i in $(echo $tmobiles)
        do
            if [ "$i" = "$imsi" ]; then
                ret="T-Mobile"
            fi
        done

        local operator=`cat /etc/carrier/verizon.type 2>/dev/null | grep "$imsi"`
        if [ "$operator" != "" ];then
            ret="Verizon"
        fi

        [ "$ret" = "" ] && ret="normal"
    else
        case $version in
            *EM160R*)
                ret="normal"
                ;;
            *)
        esac
    fi

    
    for i in $(seq 1 3) ;do
        local sim_status=$(gl_modem -B $bus -U $slot AT AT+CPIN? 2>/dev/null | grep "+CPIN:" | cut -d ':' -f 2 | tr -cd "a-z0-9A-Z")
        [ -n "$sim_status" ] && [ "$sim_status" = "READY" ] && break
        [ $i -eq 3 ] && ret="-1" && break
        sleep 1
    done

    log_debug $LINENO "modem" "(get_operator_type)operator:$ret" 
    echo $ret
}

fix_tmobile_dial()
{
    local operator=$(get_operator_type)
    if [ -n "$operator" -a "$operator" = "T-Mobile" ] ; then
        local bus=$(get_modem_bus)
        pdp=$(gl_modem -B $bus AT 'AT$QCPRFMOD=PID:1' 2>/dev/null | grep OVRRIDEHOPDP | cut -d '"' -f 2)
        [ ! "$pdp" = "IPV4V6" ] && gl_modem -B $bus AT 'AT$QCPRFMOD=PID:1,OVRRIDEHOPDP:"IPV4V6"' 1>/dev/null 2>&1
    fi
}

__check_modem_kmwan_network()
{
    local iface=`get_modem_iface`
    local tracks=""
    local track_ips=""
    local track_method=""

    tracks=$(uci -q get kmwan.$iface.tracks)
    if [ -z "$tracks" ]; then
        track_ips="8.8.8.8"
        track_method="ping"
    else
        track_method=$(echo $tracks | awk -F ',' '{print $1}')
        for iter in $tracks; do
            local ip=$(echo $tracks | awk -F ',' '{print $2}')
            track_ips="$ip $track_ips"
        done
    fi

    local proto=`uci get network.$iface.proto`
    local ifname=""

    local enable_ssl=`uci -q get kmwan.$iface.enable_ssl`
    if [ "$proto" != "3g" ];then
        if [ -f "/proc/gl-hw-info/pcie-bus" ];then
            ifname="rmnet_mhi0"
        else
            ifname="wwan0"
        fi
    else
        return 0
    fi

    for track_ip in $track_ips; do
        case "$track_method" in
            ping)
                /bin/ping -I $ifname -c 1 -W 1 $track_ip
                [ 0 -eq $? ] && return 0
            ;;
            httping)
                if [ "$enable_ssl" -eq "1" ]; then
                    httping -O $ifname -c 1 -t 1 -q "https://$track_ip" &> /dev/null
                else
                    httping -O $ifname -c 1 -t 1 -q "http://$track_ip" &> /dev/null
                fi
                [ 0 -eq $? ] && return 0
            ;;
        esac
    done

    return 1
}

__check_modem_network()
{
    local iface=`get_modem_iface`

    local track_ips=""
    track_ips=`uci -q get mwan3.$iface.track_ip`
    [ "$track_ips" = "" ] && track_ips="8.8.8.8"

    local track_method=""
    track_method=`uci -q get mwan3.$iface.track_method`
    [ "$track_method" = "" ] && track_method="ping"

    local proto=`uci get network.$iface.proto`
    local ifname=""

    local httping_ssl=`uci -q get mwan3.$iface.httping_ssl`
    if [ "$proto" != "3g" ];then
        if [ -f "/proc/gl-hw-info/pcie-bus" ];then
            ifname="rmnet_mhi0"
        else
            ifname="wwan0"
        fi
    else
        return 0
    fi

    for track_ip in $track_ips; do
        case "$track_method" in
            ping)
                /bin/ping -I $ifname -c 1 -W 1 $track_ip
                [ 0 -eq $? ] && return 0
            ;;
            httping)
                if [ "$httping_ssl" -eq 1 ]; then
                    httping -O $ifname -c 1 -t 1 -q "https://$track_ip" &> /dev/null
                else
                    httping -O $ifname -c 1 -t 1 -q "http://$track_ip" &> /dev/null
                fi
                [ 0 -eq $? ] && return 0
            ;;
        esac
    done

    return 1
}


IP_CHECK_PATH="/tmp/ip_check_counter"
increment_and_check() {

    local current_value=$(cat "$IP_CHECK_PATH" 2>/dev/null)

    if [ "$current_value" = "3" ]; then
        return 1
    else
        let current_value++
        echo "$current_value" > "$IP_CHECK_PATH"
        return 0
    fi
}

clean_ip_check(){
    echo "0" > "$IP_CHECK_PATH"
}


check_ip()
{

    [ -e /proc/gl-hw-info/build-in-modem -o -e /var/run/modem/extern_modem_bus ] || return
    
    local bus=$(get_modem_bus)
    local modem_iface=$(get_modem_iface $bus)
    [ "$(uci -q get  network.$modem_iface.disabled)" = "0" ] || return
    local operator=$(get_operator_type)
    local apn_route=1
    if [ "$operator" = "Verizon" ]; then
        apn_route=3
    elif [ "$operator" = '' -o "$operator" = '-1' ];then
        return 0
    fi

    log_debug $LINENO "modem" "(check_ip)[$(date)]bus:$bus modem_iface:$modem_iface operator:$operator apn_route:$apn_route" 
    
    for count in $(seq 1 3); do
        module_ip=$(gl_modem -B $bus AT AT+CGPADDR 2>/dev/null | grep "+CGPADDR: $apn_route" | grep -v '"0.0.0.0"')
        [ -n "$module_ip" ] && break
        sleep 1
    done

    local interface_ip
    # interface_ip=$(ifconfig rmnet_mhi0 | grep inet | sed -n '1p'|awk '{print $2}'|awk -F ':' '{print $2}')
    if [ -n "$(ubus list | grep $modem_iface)" ]; then
        interface_ip=$(ubus call network.interface.${modem_iface}_4 status | jsonfilter -e '@["ipv4-address"][0].address')
        [ -z "$interface_ip" ] && interface_ip=$(ubus call network.interface.${modem_iface} status | jsonfilter -e '@["ipv4-address"][0].address')
    fi

     
    if [ -n "$module_ip" -a -n "$interface_ip" ]; then
        if [ -z "$(echo $module_ip | grep $interface_ip)" ]; then
            #local status=`cat /var/run/mwan3/iface_state/modem_0001_4`
            tmp_modele_ip=$(echo $module_ip | cut -d ',' -f 2 | tr -d '"')
            log_info $LINENO "modem" "(check_ip)module_ip:$tmp_modele_ip interface_ip:$interface_ip"
            local flag=0
            for i in $(seq 1 3)
            do
                if [ ! -f "/proc/gl-kmwan/status" ];then
                    if __check_modem_network; then
                        flag=1
                        break
                    fi
                else
                    if __check_modem_kmwan_network; then
                        flag=1
                        break
                    fi
                fi
            done
            if [ 1 -eq $flag ];then
                clean_ip_check
                log_debug $LINENO "modem" "(check_ip)[$(date)]Current interface $modem_iface online, exit" 
                return
            fi
            
            log_info $LINENO "modem" "(check_ip)[$(date)]modem ip different, now regain ip ..."
            
            Enable=`uci -q get passthrough.passthrough.enable`
            if [ "$Enable" = "1" ];then
            
                increment_and_check
                if [ "$(echo $?)" = "1" ];then
                    log_info $LINENO "modem" "(check_ip)[$(date)]Perform cfun0/1 to reattach the network..."
                    gl_modem -B $bus SAT sp AT+CFUN=0 >/dev/null 2>&1
                    sleep 1
                    gl_modem -B $bus SAT sp AT+CFUN=1 >/dev/null 2>&1
                    sleep 10
                fi
                
                log_info $LINENO "modem" "(check_ip)[$(date)]Passthrough is enabled to restart the network iface:$modem_iface"
                ifdown $modem_iface 2>/dev/null
                sleep 1
                ifup $modem_iface 2>/dev/null
                #local value=`date +%s`
                #uci set network.$modem_iface.date='$value'
                #uci commit network
                #/etc/init.d/network reload
                exit
            fi

            local device=$(ubus call network.interface.${modem_iface} status | jsonfilter -e @.l3_device)
            [ -n "$device" ] && ip addr del $(ip addr show | grep $interface_ip | awk -F ' ' '{print $2}') dev $device 2>/dev/null
            #kill -9 $(pgrep -f 'udhcpc') 2>/dev/null
            local proto=`uci get network.$modem_iface.proto`
            local ifname=""

            if [ "$proto" != "3g" ];then
                if [ -f "/proc/gl-hw-info/pcie-bus" ];then
                    ifname="rmnet_mhi0"
                else
                    ifname="wwan0"
                fi
            else
                ifname=$(ubus call network.interface.${modem_iface} status | jsonfilter -e @.l3_device)
                [ -n "$ifname" ] || ifname=$(build_3g_ppp_ifname "$modem_iface")
            fi

            log_debug $LINENO "modem" "(check_ip)[$(date)]device:$device proto:$proto ifname:$ifname"
            
            if [ "$ifname" != "" ];then
                local pid
                if [ "$proto" == "3g" ]; then
                    pid=`ps -w | grep pppd | grep "$ifname" | awk '{print $1}'`
                else
                    pid=`ps -w | grep udhcpc | grep "$ifname" | awk '{print $1}'`
                fi
                
                log_debug $LINENO "modem" "(check_ip)[$(date)]Kill the proto:$proto process ID:$pid"
                kill -9 $pid
            else
                local pid=`ps -w | grep udhcpc | grep rmnet_mhi0 | awk '{print $1}'`
                log_debug $LINENO "modem" "(check_ip)[$(date)]Kill the proto:$proto process ID:$pid"
                kill -9 $pid
            fi

        fi
    fi
}

generate_mwan3_config()
{
    local bus=$(get_modem_bus)
    local modem_iface=$(get_modem_iface $bus)
    local metric="4"
    local secondwan_ret=$(uci -q get mwan3.secondwan)
    if [ -n "$secondwan_ret" ]; then
        metric="5"
    fi
    uci set mwan3.$modem_iface='interface'
    uci set mwan3.$modem_iface.enabled='1'
    uci set mwan3.$modem_iface.family='ipv4'
    uci set mwan3.$modem_iface.reliability='1'
    uci set mwan3.$modem_iface.count='1'
    uci set mwan3.$modem_iface.timeout='2'
    uci set mwan3.$modem_iface.interval='5'
    uci set mwan3.$modem_iface.down='3'
    uci set mwan3.$modem_iface.up='8'
    track_ip_list=$(uci -q get glconfig.general.track_ip)
    uci -q delete mwan3.${modem_iface}.track_ip
    for ip in $track_ip_list; do
        uci add_list mwan3.${modem_iface}.track_ip="$ip"
    done

    uci set mwan3.${modem_iface}_6='interface'
    uci set mwan3.${modem_iface}_6.enabled='1'
    uci set mwan3.${modem_iface}_6.family='ipv6'
    uci set mwan3.${modem_iface}_6.reliability='1'
    uci set mwan3.${modem_iface}_6.count='1'
    uci set mwan3.${modem_iface}_6.timeout='2'
    uci set mwan3.${modem_iface}_6.interval='5'
    uci set mwan3.${modem_iface}_6.down='3'
    uci set mwan3.${modem_iface}_6.up='8'
    track_ipv6_list=$(uci -q get glconfig.general.track_ipv6)
    uci -q delete mwan3.${modem_iface}_6.track_ip
    for ipv6_addr in $track_ipv6_list; do
        uci add_list mwan3.${modem_iface}_6.track_ip="$ipv6_addr"
    done

    uci set mwan3.${modem_iface}_only='member'
    uci set mwan3.${modem_iface}_only.interface="$modem_iface"
    uci set mwan3.${modem_iface}_only.metric="$metric"
    uci set mwan3.${modem_iface}_only.weight='3'
    uci set mwan3.${modem_iface}_balance='member'
    uci set mwan3.${modem_iface}_balance.interface="$modem_iface"
    uci set mwan3.${modem_iface}_balance.metric='1'
    uci set mwan3.${modem_iface}_balance.weight='3'

    uci set mwan3.${modem_iface}_6_only='member'
    uci set mwan3.${modem_iface}_6_only.interface="${modem_iface}_6"
    uci set mwan3.${modem_iface}_6_only.metric="$metric"
    uci set mwan3.${modem_iface}_6_only.weight='3'
    uci set mwan3.${modem_iface}_6_balance='member'
    uci set mwan3.${modem_iface}_6_balance.interface="${modem_iface}_6"
    uci set mwan3.${modem_iface}_6_balance.metric='1'
    uci set mwan3.${modem_iface}_6_balance.weight='3'

    local mwan3_mode=$(uci -q get gl_mwan3.mwan3.mode)
    if [ "$mwan3_mode" = "0" ]; then
        [ -n "$(uci -q get mwan3.default_poli.use_member | grep modem)" ] || uci add_list mwan3.default_poli.use_member="${modem_iface}_only"
        [ -n "$(uci -q get mwan3.default_poli_v6.use_member | grep modem)" ] || uci add_list mwan3.default_poli_v6.use_member="${modem_iface}_6_only"
    elif [ "$mwan3_mode" = "1" ]; then
        [ -n "$(uci -q get mwan3.default_poli.use_member | grep modem)" ] || uci add_list mwan3.default_poli.use_member="${modem_iface}_balance"
        [ -n "$(uci -q get mwan3.default_poli_v6.use_member | grep modem)" ] || uci add_list mwan3.default_poli_v6.use_member="${modem_iface}_6_balance"
    fi
    uci commit mwan3
}

generate_kmwan_config()
{
    local bus=$(get_modem_bus)
    local modem_iface=$(get_modem_iface $bus)
    local metric="4"
    local secondwan_ret=$(uci -q get kmwan.secondwan)
    if [ -n "$secondwan_ret" ]; then
        metric="5"
    fi

    local tracks_arr=$(uci -q get kmwan.$modem_iface.tracks)
    local track_method=""
    if [ -z "$tracks_arr" ]; then
        track_method="ping"
    else
        track_method=$(echo $tracks_arr | awk -F ',' '{print $1}')
    fi

    uci set kmwan.$modem_iface='member'
    uci set kmwan.$modem_iface.disabled='0'
    uci set kmwan.$modem_iface.addr_type='4'
    uci set kmwan.$modem_iface.metric="$metric"
    uci set kmwan.$modem_iface.track_mode='passive'
    uci set kmwan.$modem_iface.weight='1'
    uci set kmwan.$modem_iface.interface="$modem_iface"

    track_ip_list=$(uci -q get glconfig.general.track_ip)
    uci -q delete kmwan.${modem_iface}.tracks
    for ip in $track_ip_list; do
        uci add_list kmwan.${modem_iface}.tracks="${track_method},$ip"
    done

    tracks_arr=$(uci -q get kmwan.${modem_iface}_6.tracks)
    track_method=""
    if [ -z "$tracks_arr" ]; then
        track_method="ping"
    else
        track_method=$(echo $tracks_arr | awk -F ',' '{print $1}')
    fi

    uci set kmwan.${modem_iface}_6='member'
    uci set kmwan.${modem_iface}_6.disabled='1'
    uci set kmwan.${modem_iface}_6.addr_type='6'
    uci set kmwan.${modem_iface}_6.metric="$metric"
    uci set kmwan.${modem_iface}_6.track_mode='passive'
    uci set kmwan.${modem_iface}_6.weight='1'
    uci set kmwan.${modem_iface}_6.interface="${modem_iface}_6"

    track_ipv6_list=$(uci -q get glconfig.general.track_ipv6)
    uci -q delete kmwan.${modem_iface}_6.tracks
    for ipv6_addr in $track_ipv6_list; do
        uci add_list kmwan.${modem_iface}_6.tracks="${track_method},$ipv6_addr"
    done

    uci commit kmwan
}

modem_AT_lock_cell_tower()
{

    local bus=`get_modem_bus`

    local slot=''
    local sim=$(cat /proc/gl-hw-info/sim 2>/dev/null)
    if [ "$sim" = "dual" ];then
        slot=`gl_modem -B $bus AT AT+QUIMSLOT? 2>/dev/null | grep "+QUIMSLOT:" | tr -cd "0-9" 2>/dev/null` 
        if [ "$slot" != "1" ] && [ "$slot" != "2" ];then
            local iface=`get_modem_iface`
            slot=`cat /tmp/run/dual_sim/$iface/current_sim 2>/dev/null`
        fi
    fi

    #If the lock operator configuration exists, the base station is not allowed to be locked
    if [ -n "$(cat /etc/config/glmodem 2>/dev/null | grep operator_sim$slot)" ] ;then
        log_error $LINENO "modem" "(modem_AT_lock_cell_tower)Lock operator configuration exists, lock base station is prohibited." 
        return 
    fi


    local section=''
    if [ "$slot" = "" ];then
        section="tower_sim"
    else
        section="tower_sim${slot}"
    fi

    local network_type=`uci -q get glmodem.$section.network_type`
    local pci=''
    local freq=''
    local band=''
    local scs=''
    local mnc=''
    local mcc=''
    if [ "NR5G" = "$network_type" ];then
        pci=`uci -q get glmodem.$section.pci`
        freq=`uci -q get glmodem.$section.freq`
        band=`uci -q get glmodem.$section.band`
        scs=`uci -q get glmodem.$section.scs`

        local tmp=`gl_modem -B $bus AT AT+QNWLOCK=\"common/5g\" 2>/dev/null | grep "QNWLOCK"`
        local tmp_pci=`echo $tmp | awk -F "," '{print $2}'`
        local tmp_freq=`echo $tmp | awk -F "," '{print $3}'`
        local tmp_scs=`echo $tmp | awk -F "," '{print $4}'`
        local tmp_band=`echo $tmp | awk -F "," '{print $5}' | sed 's/[^0-9]//g'`

        eval gl_modem -B $bus AT \'AT+QNWPREFCFG=\"mode_pref\",NR5G\' 1>/dev/null 2>&1
        if [ "$pci" = "$tmp_pci" ] && [ "$freq" = "$tmp_freq" ] && [ "$band" = "$tmp_band" ] && [ "$scs" = "$tmp_scs" ];then
            return 0
        fi
        eval gl_modem -B $bus SAT sp 'AT+QNWLOCK=\"common/5g\",$pci,$freq,$scs,$band' 1>/dev/null 2>&1
    elif [ "LTE" = "$network_type" ];then
        pci=`uci -q get glmodem.$section.pci`
        freq=`uci -q get glmodem.$section.freq`

        local tmp=`gl_modem -B $bus AT AT+QNWLOCK=\"common/4g\" | grep "QNWLOCK" 2>/dev/null` 
        local tmp_pci=`echo $tmp | awk -F "," '{print $4}' | sed 's/[^0-9]//g'`
        local tmp_freq=`echo $tmp | awk -F "," '{print $3}'`

        eval gl_modem -B $bus AT \'AT+QNWPREFCFG=\"mode_pref\",LTE:NR5G\' 1>/dev/null 2>&1
        eval gl_modem -B $bus AT \'AT+QNWPREFCFG=\"nr5g_disable_mode\",1\' 1>/dev/null 2>&1
        if [ "$pci" = "$tmp_pci" ] && [ "$freq" = "$tmp_freq" ];then
            return 0
        fi
        eval gl_modem -B $bus SAT sp 'AT+QNWLOCK=\"common/4g\",1,$freq,$pci' 1>/dev/null 2>&1
    else
        return 0
    fi

    #gl_modem -B $bus SAT sp AT+CFUN=0
    #gl_modem -B $bus SAT sp AT+CFUN=1

    sleep 5
}


set_network_mode(){

    local bus=$1
    local network_type=$2

    if [ "$network_type" = "5G" ];then
        eval gl_modem -B $bus AT \'AT+QNWPREFCFG=\"mode_pref\",NR5G\' 1>/dev/null 2>&1
    elif [ "$network_type" = "4G" ];then
        eval gl_modem -B $bus AT \'AT+QNWPREFCFG=\"mode_pref\",LTE\' 1>/dev/null 2>&1
    elif [ "$network_type" = "3G" ];then
        eval gl_modem -B $bus AT \'AT+QNWPREFCFG=\"mode_pref\",WCDMA\' 1>/dev/null 2>&1
    else
        eval gl_modem -B $bus AT \'AT+QNWPREFCFG=\"mode_pref\",AUTO\' 1>/dev/null 2>&1
    fi
}


modem_manual_lock_operator()
{
   
    local bus=$(get_modem_bus)
    local slot=''
    local sim=$(cat /proc/gl-hw-info/sim 2>/dev/null)
    if [ "$sim" = "dual" ];then
        slot=$(gl_modem -B $bus AT AT+QUIMSLOT? 2>/dev/null | grep "+QUIMSLOT:" | tr -cd "0-9" 2>/dev/null)
        if [ "$slot" != "1" ] && [ "$slot" != "2" ];then
            local iface=$(get_modem_iface)
            slot=$(cat /tmp/run/dual_sim/$iface/current_sim 2>/dev/null)
        fi
    fi

    #If there is a locked base station configuration, the locked carrier is not allowed
    if [ -n "$(cat /etc/config/glmodem 2>/dev/null | grep tower_sim$slot)" ] ;then
        log_info $LINENO "modem" "(modem_manual_lock_operator)Lock base station configuration exists, lock operator is prohibited." 
        return 0
    fi

    
    local section=''
    if [ "$slot" = "" ];then
        section="operator_sim"
    else
        section="operator_sim${slot}"
    fi

    operator_config_exist=$(uci -q get glmodem.$section)
    [ -z "$operator_config_exist" ] && return 0

    log_info $LINENO "modem" "(modem_manual_lock_operator)slot:$slot section:$section"
    
    local long_opername=''
    local short_opername=''
    local mode='' 
    local plmn=''
    local act=''
    local format=''
    local network_type=''
   
    long_opername=$(uci -q get glmodem.$section.long_opername)
    short_opername=$(uci -q get glmodem.$section.short_opername)
    mode=$(uci -q get glmodem.$section.mode)
    plmn=$(uci -q get glmodem.$section.plmn)
    act=$(uci -q get glmodem.$section.act)
    format=$(uci -q get glmodem.$section.format)
    network_type=$(uci -q get glmodem.$section.network_type)

    log_info $LINENO "modem" "(modem_manual_lock_operator)glmodem config[mode:$mode format:$format long_opername:$long_opername short_opername:$short_opername act:$act network_type:$network_type]"
    local tmp_mode=''
    local tmp_format=''
    local tmp_oper=''
    local tmp_act=''
    local tmp_count=0
    
    for i in $(seq 1 3);do
        local tmp_cops=$(gl_modem -B "$bus" AT AT+COPS? 2>/dev/null | tr -d '\r\n')
        if echo ${tmp_cops} | grep -q "OK";then
            local cops=$(echo $tmp_cops | grep "COPS:" | sed 's/OK//')
            log_info $LINENO "modem" "(modem_manual_lock_operator)curr cops:$cops" 
            tmp_count=$(echo ${cops} | tr -cd ',' | wc -c)   
            if [ $tmp_count -eq 3 ];then
                tmp_mode=$(echo "$cops" | cut -d ',' -f 1 | cut -d ' ' -f 2)
                tmp_format=$(echo "$cops" | cut -d ',' -f 2)
                tmp_oper=$(echo "$cops" | cut -d ',' -f 3 | tr -d '"')
                tmp_act=$(echo "$cops" | cut -d ',' -f 4)
            else
                tmp_mode=$(echo "$cops" | cut -d ',' -f 1 | cut -d ' ' -f 2)
            fi
   
            if echo ${tmp_oper} | grep -q "?" ;then
                log_info $LINENO "modem" "(modem_manual_lock_operator)Fix the china mobile card name display issue."
                if [ "$tmp_format" = "0" ];then
                   tmp_oper="$long_opername"
                elif [ "$tmp_format" = "1" ] ;then
                   tmp_oper="$short_opername"
                elif [ "$tmp_format" = "2" ] ;then
                   tmp_oper="$plmn"
                fi
            fi

            log_info $LINENO "modem" "(modem_manual_lock_operator)regist info[mode:$tmp_mode format:$tmp_format oper:$tmp_oper act:$tmp_act]"

            #+COPS: 1
            #if [ -z "$tmp_format" -a -z "$tmp_oper" -a -z "$tmp_act" ] && [ $tmp_mode -eq 1 ];then
            #    log_info $LINENO "modem" "(modem_manual_lock_operator)The operator is already locked and does not need to be locked repeatedly,exit"
            #    return 0
            #fi

            #If it is already locked, exit it
            if [ "$tmp_mode" = "$mode" -a "$tmp_format" = "$format" ] || [ "$mode" = "4" -a "$tmp_mode" = "1" ];then

                [ "$tmp_act" = "11" ] && [ "$act" != "12" ] && break
                
                if [ "$format" = "0" ];then
                    [ "$tmp_oper" = "$long_opername" ] && {
                        set_network_mode "$bus" "$network_type"
                        return 0
                    }
                elif [ "$format" = "1" ] ;then
                   [ "$tmp_oper" = "$short_opername" ] && {
                       set_network_mode "$bus" "$network_type"
                       return 0
                   }
                elif [ "$format" = "2" ] ;then
                    [ "$tmp_oper" = "$plmn" ] && {
                       set_network_mode "$bus" "$network_type"
                       return 0
                    }
                fi
            
            fi
            
            break
        fi
        sleep 1
    done

    log_info $LINENO "modem" "(modem_manual_lock_operator)Start trying to lock in operator..."
    local result=''
    local count=0                                                                                                                            
                                                                                                                                             
    for count in $(seq 1 2);do                                                                                                               
                                                                                                                                             
        if [ "$format" = "0" ];then                                                                                                          
            result=$(gl_modem -B "$bus" AT "AT+COPS=${mode},${format},\"${long_opername}\",${act}" 2>/dev/null)                              
        elif [ "$format" = "1" ] ;then                                                                                                       
             result=$(gl_modem -B "$bus" AT "AT+COPS=${mode},${format},\"${short_opername}\",${act}" 2>/dev/null)                            
        elif [ "$format" = "2" ] ;then                                                                                                       
             result=$(gl_modem -B "$bus" AT "AT+COPS=${mode},${format},\"${plmn}\",${act}" 2>/dev/null)                                      
        fi                                                                                                                                   
                                                                                                                                             
        result=$(echo "$result" | tr -d '\r\n')                                                                                              
        log_info $LINENO "modem" "(modem_manual_lock_operator)AT+COPS set result:$result"    
        
        if [ -n "$result" ] ;then                                                                                                            
            if echo ${result} | grep -q "OK" ;then 
                log_info $LINENO "modem" "(modem_manual_lock_operator)Operator lock successful^_^"   
                set_network_mode "$bus" "$network_type"
                return 0                                                                                                                     
            fi                                                                                                                               
        fi                                                                                                       
                                                                                                                 
        if [ -n "$result" ];then                                                                                 
           if echo ${result} | grep  -q "30" ;then
                uci set glmodem.$section.manual_unlock_needed='1' 2>/dev/null
                uci commit glmodem
                log_error $LINENO "modem" "(modem_manual_lock_operator)Failed to lock operator"                  
                return 1                                                                                         
           fi                                                                                                    
        fi                                                                                                       
                                                                                                                 
        sleep 2                                                                                                  
    done          

    log_error $LINENO "modem" "(modem_manual_lock_operator)Failed to lock operator"
    return 1
}



check_apn()
{
    local name=`get_operator_type $1 $2`
    local tmp=`echo $name | tr [A-Z] [a-z]`
    local apn=""

    if [ "$tmp" = "verizon" ] || [ "$tmp" = "visible" ];then
        apn="3"
    elif [ "$tmp" = "" ];then
        apn="0"
    elif [ "$tmp" = "-1" ];then
        apn="-1"
    else
        apn="1"
    fi

    log_debug $LINENO "modem" "(check_apn)apn:$apn"
    echo $apn
}



get_sim_imsi(){

    local bus="$1"
    [ -z $bus ] && return
    local sim_imsi=""
    local check_count=0
    while [ true ];do
        sim_imsi=$(gl_modem -B $bus AT AT+CIMI 2>/dev/null | tr -cd "0-9")
        [ -n "$sim_imsi" ] && break
        [ $check_count -ge  3 ] && return
        let check_count++
        sleep 2
    done

    log_debug $LINENO "modem" "(get_sim_imsi)imsi:$sim_imsi"
    echo "$sim_imsi"
}

get_sim_iccid(){

    local bus="$1"
    [ -z $bus ] && return
    local sim_iccid=""
    local check_count=0
    while [ true ];do
        sim_iccid=$(gl_modem -B $bus AT AT+QCCID 2>/dev/null | grep "+QCCID:" | cut -d ':' -f 2 | tr -cd "a-z0-9A-Z")
        [ -n "$sim_iccid" ] && break
        [ $check_count -ge  3 ] && break
        let check_count++
        sleep 1
    done

    check_count=0
    if [ -z "$sim_iccid" ];then
        while [ true ];do
            sim_iccid=$(gl_modem -B $bus AT AT+ICCID 2>/dev/null | grep "+ICCID:" | cut -d ':' -f 2 | tr -cd "a-z0-9A-Z")
            [ -n "$sim_iccid" ] && break
            [ $check_count -ge  3 ] && break
            let check_count++
            sleep 1
        done
    fi

    check_count=0
    if [ -z "$sim_iccid" ];then
        while [ true ];do
            sim_iccid=$(gl_modem -B $bus AT AT^ICCID? 2>/dev/null | grep "ICCID:" | cut -d ':' -f 2 | tr -cd "a-z0-9A-Z")
            [ -n "$sim_iccid" ] && break
            [ $check_count -ge  3 ] && break
            let check_count++
            sleep 1
        done
    fi


    log_debug $LINENO "modem" "(get_sim_iccid)iccid:$sim_iccid"
    echo "$sim_iccid"
}


check_sim_and_pin_status() {

    local bus="$1"
    [ -z $bus ] && return
    local sim_status=""
    local i=0
    local ret=''
    while [ true ];do
        sim_status=$(gl_modem -B $bus AT AT+CPIN? 2>/dev/null | grep "+CPIN:" | cut -d ':' -f 2 | tr -cd "a-z0-9A-Z")
        [ -n "$sim_status" ] && [ "$sim_status" = "READY" -o "$sim_status" = "SIMPIN" -o "$sim_status" = "SIMPUK" ] && break
        [ $i -ge 3 ]  && break
        let i++
        sleep 2
    done

    if [ "$sim_status" = "READY" ]; then
        ret="READY"
    elif [ "$sim_status" = "SIMPIN" ];then 
        ret="SIMPIN"
    elif [ "$sim_status" = "SIMPUK" ];then
        ret="SIMPUK"
    else
        ret="ERROR"
    fi

    log_debug $LINENO "modem" "(check_sim_and_pin_status)sim_status:$ret"

    echo $ret
}


unlock_sim_pin(){

    local modem_bus="$1"
    local iccid="$2"
    local pincode="$3"
 
    local sim_status=$(check_sim_and_pin_status $modem_bus)
    local curr_iccid=$(get_sim_iccid $modem_bus)

    if [ -z "$pincode" ] ;then                                                                                                                                                                
        pincode=`uci -q get glmodem.$iccid.pincode 2>/dev/null)`                                                                                                                              
    fi

    [ -z "$sim_status" ] && return 1


    if [ "$sim_status" = "ERROR" ];then
        log_error $LINENO "modem" "(unlock_sim_pin)The current simcard does not exist, please check."
        return 1
    fi

    
    if [ "$sim_status" = "SIMPUK" ];then
        log_error $LINENO "modem" "(unlock_sim_pin)The current simcard needs to be unlocked by PUK."
        return 1
    fi

    log_info $LINENO "modem" "(unlock_sim_pin)sim_status:$sim_status modem_bus:$modem_bus"

    if [ "$sim_status" = "SIMPIN" ];then

        log_info $LINENO "modem" "(unlock_sim_pin)iccid:$iccid pincode:$pincode"
        
        if [ -z "$pincode" ];then
           log_error $LINENO "modem" "(unlock_sim_pin)The PIN does not exist or the PIN code does not match."
           return 1
        fi
        
        if [ -n "$curr_iccid" ] && [ -n "$iccid" ] && [ "$curr_iccid" = "$iccid" ];then
            local pinnum=''
            for count in $(seq 1 5); do
                pinnum=$(gl_modem -B $modem_bus AT AT+QPINC? 2>/dev/null | grep "+QPINC: \"SC\""| awk -F, '{print $2}')
                [ -n "$pinnum" ] && break
                [ $count -eq 5 ] && log_error $LINENO "modem" "(unlock_sim_pin)Failed to obtain the remaining number of unlocks of the PIN,exit!" && return 1
                sleep 1
            done

            if [ $pinnum -le 1 ];then
                log_error $LINENO "(unlock_sim_pin)There are not enough attempts to unlock the PIN code remaining" 
                return 1
            fi


            local pincode_error=$(gl_modem -B $modem_bus AT AT+CPIN=\"$pincode\" 2>/dev/null | grep 16)
            [ -n "$pincode_error" ] && {
                log_error $LINENO "modem" "(unlock_sim_pin)The PIN code is incorrect, please check it!"
                return 1
            }

        else
           log_error $LINENO "modem" "(unlock_sim_pin)The PIN does not exist or the PIN code does not match."
           return 1
        fi

    fi

    return 0
}


modem_AT_set_apn()
{
    local bus=`get_modem_bus`
    local iccid="$1"
    local pin_code="$2"
    local modem_iface=$(get_modem_iface $bus)
    local execute_cfun01=0

    log_debug $LINENO "modem" "(modem_AT_set_apn)bus:$bus iccid:$iccid pin_code:$pin_code modem_iface:$modem_iface"
    
    local apns=`uci -q get network.$modem_iface.apns | sed 's/\[\|\]\|\,//g'`
    local dial_apn=`uci -q get network.$modem_iface.apn`
    local apn_use=`uci -q get network.$modem_iface.apn_use`
    local ip_type=$(uci -q get network.$modem_iface.ip_type)
    local ip_type_value=''

    log_debug $LINENO "modem" "(modem_AT_set_apn)apns:$apns dial_apn:$dial_apn apn_use:$apn_use ip_type:$ip_type"
    
    [ "$apn_use" = "" ] && apn_use=$(check_apn)

    [ $apn_use -le 0 ] && {
        log_error $LINENO "modem" "(modem_AT_set_apn)apn_use:$apn_use is illegal,  PDP context configuration is prohibited."
        return 0
    }

    case "$ip_type" in
    "IPV4V6") ip_type_value="IPV4V6" ;;
    "IPV6") ip_type_value="IPV6" ;;
    *) ip_type_value="IP" ;;
    esac

    if [ "$apns" = "" ];then
        local curr_use_apn=$(gl_modem -B $bus AT AT+CGDCONT? | grep "+CGDCONT: $apn_use" | awk -F '\"' '{print $4}')
        local curr_iptype=$(gl_modem -B $bus AT AT+CGDCONT? | grep "+CGDCONT: $apn_use" | awk -F '\"' '{print $2}')
        if [ "$curr_use_apn" != "$dial_apn" ] || [ "$ip_type" != "$curr_iptype" ];then
            log_debug $LINENO "modem" "(modem_AT_set_apn)curr_use_apn:$curr_use_apn dial_apn:$dial_apn, curr_iptype:$curr_iptype dial_iptype:$ip_type apn or ip_type is different, execute configuration operation"
            eval gl_modem -B $bus AT 'AT+CGDCONT=$apn_use,\"$ip_type_value\",\"$dial_apn\"' 1>/dev/null 2>&1
            execute_cfun01=1
        fi
    else
        local i=0
        local apn=''
        for apn in $apns
        do
            apn=`echo $apn | sed 's/\"//g'`
            i=$((i+1))
            if [ "$apn" != "" ];then
                eval gl_modem -B $bus AT 'AT+CGDCONT=$i,\"IPV4V6\",\"$apn\"' 1>/dev/null 2>&1
            else
                if [ "$apn_use" = "$i" ];then
                    eval gl_modem -B $bus AT 'AT+CGDCONT=$i,\"$ip_type_value\",\"$dial_apn\"' 1>/dev/null 2>&1
                fi
            fi
        done
        execute_cfun01=1
    fi

    if [ $execute_cfun01 -eq 1 ];then
        gl_modem -B $bus SAT sp AT+CFUN=0 1>/dev/null 2>&1
        sleep 1
        gl_modem -B $bus SAT sp AT+CFUN=1 1>/dev/null 2>&1
        sleep 8

        unlock_sim_pin "$bus" "$iccid" "$pin_code"
        if [ "$(echo $?)" = "1" ];then 
            return 1
        fi
    fi
    
    return 0
}


modem_check_cellular()
{
    local custom_apn="$2"

    local bus="$1"
    local code=`gl_modem -B $bus AT AT+CIMI 2>/dev/null | tr -cd "[0-9]" | cut -b 1-6`
    local cellular=`cat /etc/carrier/${custom_apn}.type | grep "$code"`

    if [ "$cellular" = "" ];then
        return 1
    else
        return 0
    fi
}

modem_custom_apn_handle()
{
    local iface="$1"
    local bus=$(get_modem_bus)
    
    [ -d "/tmp/run/dual_sim/${iface}" ] && mkdir -p "/tmp/run/dual_sim/${iface}"

    local disabled=`uci -q get network.modem_0001.disabled`
    [ "$disabled" = "1" ] && return 1

    local sw_pid=`ps -w | grep "switch_sim_slot" | grep -v grep`
    [ "$sw_pid" != "" ] && return 1

    local sim=`cat /tmp/run/dual_sim/${iface}/current_sim`
    if [ "$sim" != "1" ] && [ "$sim" != 2 ];then
        return 1
    fi

    local count=`cat /tmp/run/dual_sim/${iface}/count_sim${sim} 2>/dev/null`
    [ "$count" = "" ] && count=1
    [ $count -ge 6 ] && return 1

    local custom_apn=`uci -q get glmodem.global.custom_apn`
    [ "$custom_apn" = "" ] && return 1

    local bus=`get_modem_bus`
    if ! modem_check_cellular $bus $custom_apn;then
        return 1
    fi
    count=$((count+1))
    echo $count > /tmp/run/dual_sim/${iface}/count_sim${sim}

    [ -f "/var/run/switch-sim.lock" ] && return 1
    local apns=`uci -q get custom_apn.${custom_apn}.apns | sed 's/\[\|\]\|\,//g' | sed 's/\"//g'`
    local i=0
    local current_apn=`uci -q get network.${iface}.apn`
    local last=`echo "$apns" | awk '{print $NF}'`
    for apn in $apns
    do
        i=$((i+1))
        [ "$apn" = "$current_apn" ] && break
    done
    i=$((i+1))
    apn=`echo "$apns" | awk -v j=$i '{print $j}'`
    [ "$apn" = "" ] && apn=`echo "$apns" | awk '{print $NR}'`
    touch /var/run/switch-sim.lock

    local current_sim=`cat /var/run/dual_sim/$modem_iface/current_sim 2>/dev/null`
    local sim1_apn_poll=`uci -q get glmodem.global.sim1_apn_polling`
    local sim2_apn_poll=`uci -q get glmodem.global.sim2_apn_polling`
    [ "$current_sim" = "1" ] && [ "$sim1_apn_poll" = "0" ] && rm /var/run/switch-sim.lock && return 1
    [ "$current_sim" = "2" ] && [ "$sim2_apn_poll" = "0" ] && rm /var/run/switch-sim.lock && return 1

    log_info $LINENO "modem" "(modem_custom_apn_handle)Start restarting the interface $iface apn:$apn sim:$sim"
    uci set network.${iface}.apn="$apn"
    curr_iccid=$(get_sim_iccid $bus)
    [ -n "$curr_iccid" ] && uci set glmodem.$curr_iccid.apn="$apn"
    uci commit network
    uci commit glmodem
    /etc/init.d/network reload
    rm /var/run/switch-sim.lock

    return 0
}

modem_net_monitor()
{
    [ ! -f "/proc/gl-hw-info/build-in-modem" ] && exit

    local modem_iface=`get_modem_iface`

    local pin=`uci -q get network.$modem_iface.pincode`
    [ "$pin" != "" ] && exit

    local disabled=`uci -q get network.$modem_iface.disabled`
    [ "$disabled" = 1 ] && exit

    local current_sim=`cat /var/run/dual_sim/$modem_iface/current_sim 2>/dev/null`
    local sim1_apn_poll=`uci -q get glmodem.global.sim1_apn_polling`
    local sim2_apn_poll=`uci -q get glmodem.global.sim2_apn_polling`
    [ "$current_sim" = "1" ] && [ "$sim1_apn_poll" = "0" ] && exit
    [ "$current_sim" = "2" ] && [ "$sim2_apn_poll" = "0" ] && exit

    if [ -n "$(ubus list | grep $modem_iface)" ]; then
        local interface_ip=$(ubus call network.interface.${modem_iface}_4 status | jsonfilter -e '@["ipv4-address"][0].address')
        [ -z "$interface_ip" ] && interface_ip=$(ubus call network.interface.${modem_iface} status | jsonfilter -e '@["ipv4-address"][0].address')

        if [ "$interface_ip" = "" ];then
            if modem_custom_apn_handle $modem_iface;then
                exit
            fi

            log_info $LINENO "modem" "(modem_net_monitor)Start restarting the interface $modem_iface"
            
            ubus call network.interface.$modem_iface down
            sleep 2
            ubus call network.interface.$modem_iface up

            return
        fi
    fi

    if [ -f "/proc/gl-hw-info/sim" ] && [ `cat /proc/gl-hw-info/sim` = "dual" ];then
        echo 0 > /tmp/run/dual_sim/${modem_iface}/count_sim1
        echo 0 > /tmp/run/dual_sim/${modem_iface}/count_sim2
    fi
}

frist_generate_kmwan_config()
{
    local bus=$(get_modem_bus)
    local modem_iface=$(get_modem_iface $bus)
    local metric="40"

    local tracks_arr=$(uci -q get kmwan.$modem_iface.tracks)
    local track_method=""
    if [ -z "$tracks_arr" ]; then
        track_method="ping"
    else
        track_method=$(echo $tracks_arr | awk -F ',' '{print $1}')
    fi

    uci set kmwan.$modem_iface='member'
    uci set kmwan.$modem_iface.disabled='0'
    uci set kmwan.$modem_iface.addr_type='4'
    uci set kmwan.$modem_iface.metric="$metric"
    uci set kmwan.$modem_iface.track_mode='passive'
    uci set kmwan.$modem_iface.weight='1'
    uci set kmwan.$modem_iface.interface="$modem_iface"

    track_ip_list=$(uci -q get glconfig.general.track_ip)
    uci -q delete kmwan.${modem_iface}.tracks
    for ip in $track_ip_list; do
        uci add_list kmwan.${modem_iface}.tracks="${track_method},$ip"
    done

    tracks_arr=$(uci -q get kmwan.${modem_iface}_6.tracks)
    track_method=""
    if [ -z "$tracks_arr" ]; then
        track_method="ping"
    else
        track_method=$(echo $tracks_arr | awk -F ',' '{print $1}')
    fi

    uci set kmwan.${modem_iface}_6='member'
    uci set kmwan.${modem_iface}_6.disabled='1'
    uci set kmwan.${modem_iface}_6.addr_type='6'
    uci set kmwan.${modem_iface}_6.metric="$metric"
    uci set kmwan.${modem_iface}_6.track_mode='passive'
    uci set kmwan.${modem_iface}_6.weight='1'
    uci set kmwan.${modem_iface}_6.interface="${modem_iface}_6"

    track_ipv6_list=$(uci -q get glconfig.general.track_ipv6)
    uci -q delete kmwan.${modem_iface}_6.tracks
    for ipv6_addr in $track_ipv6_list; do
        uci add_list kmwan.${modem_iface}_6.tracks="${track_method},$ipv6_addr"
    done

    uci commit kmwan
}

detect_modem_kmwan_config(){

    [ -n "$(ls /sys/class/net | grep 'simonet')" ] && return
        
    local bus=$(get_modem_bus)
    local modem_iface=$(get_modem_iface $bus)
    [ -z "$bus" ] || [ -z "$modem_iface" ] && return
    log_debug $LINENO "modem" "(detect_modem_kmwan_config)bus:$bus modem_ifcae:$modem_iface"
    local modem_v4=$(uci -q get kmwan.${modem_iface})
    local modem_v6=$(uci -q get kmwan.${modem_iface}_6)
    local exist_modem_config="$(cat /etc/config/kmwan 2>/dev/null | grep "config member" | awk -F "'" '{print $2}' | grep "modem")"
    
    if [ -z "$modem_v4" ] && [ -z "$modem_v6" ] && [ -z "$exist_modem_config" ]; then
        frist_generate_kmwan_config
    else
        local count=$(echo "$exist_modem_config" | wc -w)
        log_debug $LINENO "modem" "(detect_modem_kmwan_config)delete old kmwan config:$exist_modem_config count:$count"
        
        if [ $count -eq 2 ];then
            for modem_kmwan in $exist_modem_config ;do
                case $modem_kmwan in
                *_6)
                    uci set kmwan.${modem_kmwan}.interface="${modem_iface}_6"
                    uci rename kmwan.${modem_kmwan}="${modem_iface}_6"
                ;;
                *)
                    uci set kmwan.${modem_kmwan}.interface="${modem_iface}"
                    uci rename kmwan.${modem_kmwan}="${modem_iface}"
                ;;
                esac
            done
            uci commit kmwan
        else
        
            for modem_kmwan in $exist_modem_config ;do
                uci -q delete kmwan.$modem_kmwan
            done
            uci commit kmwan
            frist_generate_kmwan_config
        fi
    fi                
}

check_sim_operator_configure() {

    local bus=$1
    local iface=$2

    [ ! -f "/proc/gl-hw-info/sim" ] && return
  
    local sim_content=$(cat /proc/gl-hw-info/sim 2>/dev/null)
    [ "$sim_content" != "dual" ] && return

    for count in $(seq 1 3); do
        current_sim=$(gl_modem -B $bus AT AT+QUIMSLOT? | grep "+QUIMSLOT:" | tr -cd "0-9")
        [ -n "$current_sim" ] && break
        [ $count -eq 3 ]  && return
        sleep 1
    done

    if [ "$current_sim" != "1" -a "$current_sim" != "2" ] ;then
        current_sim=$(cat /tmp/run/dual_sim/$iface/current_sim 2>/dev/null)
    fi

    local curr_section=''
    local other_section=''
    if [ "$current_sim" = "1" ];then
        curr_section="operator_sim1"
        othen_section="operator_sim2"
    else
        curr_section="operator_sim2"
        othen_section="operator_sim1"
    fi

    curr_operator_config_exist=$(uci -q get glmodem.$curr_section)
    other_operator_config_exist=$(uci -q get glmodem.$othen_section)
    [ -z "$curr_operator_config_exist" -a -z "$other_operator_config_exist" ] && return

    if [ -n "$other_operator_config_exist" -a -z "$curr_operator_config_exist" ]; then
        log_info $LINENO "modem" "(check_sim_operator_configure)Set to auto-attach network mode"
        gl_modem -B $bus AT AT+QNWPREFCFG=\"mode_pref\",NR5G >/dev/null 2>&1
        sleep 1
        gl_modem -B $bus AT AT+QNWPREFCFG=\"mode_pref\",AUTO >/dev/null 2>&1
        sleep 1
        gl_modem -B $bus AT AT+COPS=0,0 >/dev/null 2>&1
    fi
}


get_curr_slot(){

    local bus=$1
    local iface=$2
    local current_sim=''
    
    for count in $(seq 1 3); do
        current_sim=$(gl_modem -B $bus AT AT+QUIMSLOT? 2>/dev/null | grep "+QUIMSLOT:" | tr -cd "0-9")
        [ -n "$current_sim" ] && break
        [ $count -eq 3 ]  && return
        sleep 1
    done

    if [ "$current_sim" != "1" -a "$current_sim" != "2" ] ;then
        current_sim=$(cat /tmp/run/dual_sim/$iface/current_sim 2>/dev/null)
    fi

    log_debug $LINENO "modem" "(get_curr_slot)slot:$current_sim"
    echo "$current_sim"
}

#get_dial_status() {
    #local bus="$1"
    #local slot="$2"

    #local resp
    #resp=$ubus -t 1 call cellular.cm cm_get_status '{}' 2>/dev/null | jsonfilter -e "@.cms[@.bus='$bus' && @.slot=$slot].status"
    #resp=$(ubus -t 1 call cellular.cm cm_get_status "{\"bus\":\"$bus\",\"slot\":$slot}")
    #local status
    #status=$(echo "$resp" | awk -v bus="$bus" -v slot="$slot" '
    #    BEGIN {RS="{"; FS=","}
    #    $0 ~ "\"bus\":[[:space:]]*\""bus"\"" && $0 ~ "\"slot\":[[:space:]]*"slot {
    #        for (i=1;i<=NF;i++) {
    #            if ($i ~ /"status"/) {
    #                gsub(/[^0-9]/,"",$i)
    #                print $i
    #                exit
    #            }
    #        }
    #    }')
    #
    #echo "$status"
#}

get_dial_status() {
    local bus="$1"
    local slot="$2"

    ubus -t 1 call cellular.cm cm_get_status "{\"bus\":\"$bus\",\"slot\":$slot}" 2>/dev/null \
    | jsonfilter -e "@.cms[@.bus='$bus' && @.slot=$slot].status" \
    | tr -d '\n'
}

#get_sim_map_field() {
#    local iccid="$1"
#    local field="$2"
#    local file="/etc/config/cellular/sim_map.json"
#
#    [ ! -f "$file" ] && return
#
#   local block
#    block=$(awk -v iccid="$iccid" '
#        $0 ~ "\""iccid"\"[[:space:]]*:" {flag=1}
#        flag {print}
#        flag && /}/ {flag=0}' "$file")
#
#
#    [ -z "$block" ] && echo "" && return
#
#    local value
#    value=$(echo "$block" \
#        | grep "\"$field\"" \
#        | head -n1 \
#        | sed -E 's/^[[:space:]]*"[^"]*"[[:space:]]*:[[:space:]]*("?)([^",}]*)"?[,}]?.*/\2/')
#
#    echo "$value"
#}

get_sim_map_field() {
    local iccid="$1"
    local field="$2"
    local file="/etc/config/cellular/sim_map.json"

    [ -f "$file" ] || return 1

    jsonfilter -i "$file" -e '@["'$iccid'"]["'$field'"]'
}


convert_ip_type() {
    local type="$1"
    case "$type" in
        0) echo "IPV4V6" ;;
        1) echo "IP" ;;
        2) echo "IPV6" ;;
        *) echo "IPV4V6" ;;
    esac
}

update_dial_status() {
    local bus="$1"
    local slot="$2"

    (
        ubus -t 1 call cellular.network update_status "{\"bus\":\"${bus}\",\"slot\":${slot}}"
        ubus -t 1 call cellular.network update_info "{\"bus\":\"${bus}\",\"slot\":${slot}}"
    ) &
}

map_dial_progress_to_cm_script_status() {
    local progress="$1"

    case "$progress" in
        2)
            echo 5
            ;;
        3)
            echo 3
            ;;
        *)
            return 1
            ;;
    esac
}

report_interface_dial_script_status() {
    local iface="$1"
    local progress="$2"
    local status=""

    [ -n "$iface" ] || return 1

    status="$(map_dial_progress_to_cm_script_status "$progress")" || return 0
    report_interface_dial_script_status_value "$iface" "$status"
    return 0
}

report_interface_dial_script_status_value() {
    local iface="$1"
    local status="$2"
    local bus=""
    local slot=""

    [ -n "$iface" ] || return 1
    [ -n "$status" ] || return 1

    bus="$(uci -q get network."$iface".bus 2>/dev/null)"
    slot="$(uci -q get network."$iface".slot 2>/dev/null)"

    if [ -z "$bus" ] || [ -z "$slot" ]; then
        log_debug $LINENO "modem" "report_interface_dial_script_status: missing bus/slot for network.$iface"
        return 0
    fi

    ubus -t 1 call cellular.cm cm_dial_script_status "{\"bus\":\"${bus}\",\"slot\":${slot},\"status\":${status}}" >/dev/null 2>&1
    log_debug $LINENO "modem" "report_interface_dial_script_status: bus[$bus] slot[$slot] status[$status]"
    return 0
}

report_interface_dial_script_success() {
    local iface="$1"

    report_interface_dial_script_status_value "$iface" "4"
}

set_interface_dial_progress() {
    local iface="$1"
    local status="$2"

    if [ -z "$iface" ]; then
        log_debug $LINENO "modem" "set_interface_dial_progress: empty interface name"
        return 1
    fi

    if ! uci -q get network."$iface" >/dev/null; then
        log_debug $LINENO "modem" "set_interface_dial_progress: network.$iface not exist"
        return 2
    fi

    local curr
    curr=$(uci -q get network."$iface".dial_progress 2>/dev/null)

    if [ "$curr" != "$status" ]; then
        uci -q set network."$iface".dial_progress="$status"
        uci commit network
        log_debug $LINENO "modem" "set_interface_dial_progress: set network.$iface.dial_progress = ${status}"
    fi

    report_interface_dial_script_status "$iface" "$status"

    return 0
}


get_dial_status_retry() {
    local bus="$1"
    local slot="$2"
    local max_retry="${3:-3}"
    local i=0
    local s=""

    while [ $i -lt $max_retry ]; do
        s="$(get_dial_status "$bus" "$slot")"
        [ -n "$s" ] && { echo "$s"; return 0; }
        sleep 1
        i=$((i + 1))
    done

    return 1
}

get_history_apn_db_field() {
    local iccid="$1"
    local field="$2"
    local file="/etc/config/cellular/history_apn_database.json"

    [ ! -f "$file" ] && return 1

    jsonfilter -i "$file" -e "@.apns[@.iccid='$iccid'].$field" 2>/dev/null
}

bus_exists_in_modem() {
    local bus="$1"
    local retry=3

    while [ $retry -gt 0 ]; do
        if ubus -t 1 call cellular.modem get_modem_info 2>/dev/null \
            | jsonfilter -e "@.modems[@.bus='$bus'].bus" \
            | grep -q "^$bus$"
        then
            return 0
        fi

        retry=$((retry - 1))
        [ $retry -gt 0 ] && sleep 1
    done

    return 1
}
