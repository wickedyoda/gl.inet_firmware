. /lib/functions.sh
. /lib/functions/gl_util.sh

check_interface_is_enabled() {
    local interface="$1"
    [ -n "$(uci -q get network.${interface})" ] && {
        [ "$(uci -q get network.${interface}.disabled)" = '0' -o -z "$(uci -q get network.${interface}.disabled)" ] && {
            echo "1"
            return
        }
    }
    echo "0"
    return
}

check_interface_is_up() {
    local ret
    local interface="$1"
    local active="$(ifstatus ${interface} | grep -w '"up' | awk -F ' ' '{print $2}' | awk -F ',' '{print $1}')"

    if [ "$active" = 'true' ];then
        ret='true'
    else
        ret='false'
    fi
    echo "${ret}"
}

get_if_s_l3_device() {
    local if_name="$1";shift
    local devices="$(ubus call network.interface.${if_name} status 2>/dev/null | grep '"l3_device' | awk -F '"' '{print $4}')"
    echo "${devices}"
}

get_wan_device_list(){
    local device_list=''
    local iflist=''

    get_firewall_zone_if(){
        local section="$1"
        local zone_name="$2"
        local name
        local network

        config_get name "$section" name
        config_get network "$section" network
        [ "$zone_name" = "${name}" ] && iflist=$network
    }

    config_load "firewall"
    config_foreach get_firewall_zone_if zone 'wan'

    for if_name in $iflist ;do
        local devices="$(get_if_s_l3_device ${if_name})"
        for device in ${devices} ;do
            [ -n "${device}" -a "$(echo ${device_list} | awk -v dev="${device}" '{for(i=1;i<=NF;i++) if($i==dev) print $i}')" = '' ] && {
                device_list="${device_list}${device_list:+ }${device}"
            }
        done
    done
    echo "${device_list}"
}

if_is_valid_source() {
    local if_name="$1"
    local ret="$(ubus call network.interface.${if_name} status 2>/dev/null)"
    if [ -n "${ret}" ] ;then
        return 1
    else
        return 0
    fi
}

get_if_s_firewall_zone() {
    local if_name="$1";shift
    local zone_name=''
    get_if_s_zone(){
        local section="$1"
        local if_name="$2"
        local network
        config_get network "$section" network
        for per_if in $network ;do
            [ "${if_name}" = "${per_if}" ] && {
                local name
                config_get name "$section" name ''
                [ -n "${name}" ] && {
                    zone_name="$name"
                    return 0
                }
            }
        done
    }

    config_load "firewall"
    config_foreach get_if_s_zone zone "${if_name}"
    [ -n "${zone_name} " ] && {
        echo "$zone_name"
        return 0
    }
}

get_if_ip_addrs() {
        local addrs=''
        local if=$1
        local v6=''
        [ "$2" = "-6" ] && v6="6"

        local if_device=`ubus call network.interface.${if} status 2>/dev/null | grep l3_device | awk -F '"' '{print $4}'`
        [ "${if_device}" != "" ] && {
                local addr_count=`ip addr show ${if_device} 2>/dev/null | grep -w inet${v6} | awk -F ' ' '{print $2}' | awk -F '/' '{print $1}' | wc -l`
                echo "${addr_count:="0"}" >/dev/null 2>&1
                local i="1"
                while [ ${i} -le ${addr_count} ];do
                        local tmp_addr=`ip addr show ${if_device} 2>/dev/null | grep -w inet${v6} | awk -F ' ' '{print $2}' | awk -F '/' '{print $1}' | head -n $i | tail -n 1`
                        [ -n ${tmp_addr} ] && {
                                addrs="${addrs}${addrs:+" "}${tmp_addr}"
                        }
                        i="`expr $i + 1`"
                done
        }
        echo "$addrs"
}

get_vpn_if_list()
{
        get_vpn_server_list()
        {
                local section="$1"
                local proto
                config_get proto "$section" "proto"
                [ "$proto" = "wgserver" -o "$proto" = 'ovpnserver' ] && {
                        ret_list="${ret_list}${proto} "
                }
        }

        get_vpn_client_list()
        {
                local section="$1"
                local proto
                config_get proto "$section" "proto"
                [ "$proto" = "wgclient" -o "$proto" = 'ovpnclient' ] && {
                        ret_list="${ret_list}${proto} "
                }
        }

        local if_types=$1
        local ret_list=''
        local list=''
        config_load network
        for type in $if_types; do
            [ "$type" = 'client' ] && config_foreach get_vpn_client_list "interface"
            [ "$type" = 'server' ] && config_foreach get_vpn_server_list "interface"
        done

        for dev in $ret_list; do
                list="${list}${dev} "
        done
        echo "$list"
}

do_reload_service()
{
    local p
    [ -d /var/run/gl_reload_service/ ] || return
    services=$(ls /var/run/gl_reload_service/* 2>/dev/null)
    for s in $services;do
        p="$(cat $s)"
        [ -x "$p" ] && {
            $p reload 2>/dev/null
            rm $s
        }
    done
}

do_restart_service()
{
    local p
    [ -d /var/run/gl_restart_service/ ] || return
    services=$(ls /var/run/gl_restart_service/* 2>/dev/null)
    for s in $services;do
        p="$(cat $s)"
        [ -x "$p" ] && {
            $p restart 2>/dev/null
            rm $s
        }
    done
}

call_service_action()
{
        do_reload_service
        do_restart_service
}

reload_modified_service()
{
        $(call_service_action >/dev/null 2>&1)
}

