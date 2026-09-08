#!/bin/sh

. /lib/functions/gl_util.sh
. /lib/functions.sh

DHCP_FILE="/tmp/dnsmasq.d/drop-in-dhcp"
DHCP_INFO="/tmp/drop-in-dhcp-info"

WAN="$(get_wan)"
POOL_START=""
POOL_END=""
POOL_NETMASK=""
POOL_LEASETIME=""
UPSTREAM_GATEWAY=""
UPSTREAM_DNS=""
LOCAL_IPADDR=""

add_parental_control_dev()
{
    [ -f "/etc/config/parental_control" ] && {
        uci -q del_list parental_control.global.src_dev="$WAN"
        uci -q add_list parental_control.global.src_dev="$WAN"
    }
    [ -f "/etc/config/parental_control_v2" ] && {
        uci -q del_list parental_control_v2.global.src_dev="$WAN"
        uci -q add_list parental_control_v2.global.src_dev="$WAN"
    }
    uci commit 2>/dev/null
    /etc/init.d/parental_control restart 2>/dev/null
}

remove_parental_control_dev()
{
    [ -f "/etc/config/parental_control" ] && {
        uci -q del_list parental_control.global.src_dev="$WAN"
    }
    [ -f "/etc/config/parental_control_v2" ] && {
        uci -q del_list parental_control_v2.global.src_dev="$WAN"
    }
    uci commit 2>/dev/null
    if [ "$1" != "shutdown" ];then
        /etc/init.d/parental_control restart 2>/dev/null
    fi
}

load_edgerouter_config()
{
    config_load edgerouter
    config_get POOL_START "wandhcp" "start"
    config_get POOL_END "wandhcp" "end"
    config_get POOL_NETMASK "wandhcp" "netmask"
    config_get POOL_LEASETIME "wandhcp" "leasetime"
    config_get LOCAL_IPADDR "wandhcp" "ip"
    config_get UPSTREAM_GATEWAY "wandhcp" "gateway"
    config_get UPSTREAM_DNS "wandhcp" "dns"
}

setup_drop_in_interface()
{
    wan_device="$(uci -q get network.wan.device)"
    [ -z "$wan_device" ] && wan_device="$(uci -q get network.wan.ifname)"
    [ ! $(uci -q get network.wan_ori) ] && {
        uci rename network.wan='wan_ori'
        uci set network.wan_ori.disabled="1"
        uci commit 2>/dev/null
    }

    uci set network.wan="interface"
    if [ "$(cat /etc/os-release|grep VERSION|head -n1|awk -F "[=\".]" '{print $3}')" -gt 19 ];then
        if [ -n "$wan_device" ]; then
            uci set network.wan.device="$wan_device"
            uci set network.wan_ori.device="$wan_device"
        else
            uci delete network.wan.device
            uci delete network.wan_ori.device
        fi
    else
        if [ -n "$wan_device" ]; then
            uci set network.wan.ifname="$wan_device"
            uci set network.wan_ori.ifname="$wan_device"
        else
            uci delete network.wan.ifname
            uci delete network.wan_ori.ifname
        fi
    fi
    uci set network.wan.proto="static"
    uci set network.wan.ipaddr="$LOCAL_IPADDR"
    uci set network.wan.gateway="$UPSTREAM_GATEWAY"
    uci set network.wan.netmask="$POOL_NETMASK"
    uci set network.wan.peerdns="0"
    uci set network.wan.dns="$UPSTREAM_DNS"
    uci set network.wan.force_link="0"
    [ -e "/proc/gl-kmwan" ] && uci set network.wan.metric="$(uci get kmwan.wan.metric)"

    uci commit 2>/dev/null
    /etc/init.d/network reload

    echo a "$WAN" >/proc/oui-tertf/subnet
    add_parental_control_dev
}

remove_drop_in_interface()
{
    wan_device="$(uci -q get network.wan.device)"
    [ -z "$wan_device" ] && wan_device="$(uci -q get network.wan.ifname)"
    [ -n "$(uci -q get network.wan_ori)" ] && {
        uci -q del network.wan
        if [ "$(cat /etc/os-release|grep VERSION|head -n1|awk -F "[=\".]" '{print $3}')" -gt 19 ];then
            if [ -n "$wan_device" ]; then
                uci set network.wan_ori.device="$wan_device"
            else
                uci delete network.wan_ori.device
            fi
        else
            if [ -n "$wan_device" ]; then
                uci set network.wan_ori.ifname="$wan_device"
            else
                uci delete network.wan_ori.ifname
            fi
        fi
        uci set network.wan_ori.disabled="0"
        uci rename network.wan_ori='wan'
        uci commit 2>/dev/null
        if [ "$1" != "shutdown" ];then
            /etc/init.d/network reload
        fi
    }
    if [ "$1" != "shutdown" ];then
        echo d "$WAN" >/proc/oui-tertf/subnet
    fi
    remove_parental_control_dev "$1"
}

setup_dhcp_for_drop_in()
{
    uci set dhcp.wan.start=${POOL_START}
    uci set dhcp.wan.limit=$((POOL_END-POOL_START))
    uci set dhcp.wan.leasetime=${POOL_LEASETIME}
    uci set dhcp.wan.force=1
    [ ! $(uci -q get dhcp.wan.ignore_ori) ] && uci rename dhcp.wan.ignore='ignore_ori'
    [ $(uci -q get edgerouter.wandhcp.ignore) = 0 ] && uci set dhcp.wan.ignore="0" || uci set dhcp.wan.ignore="1"
    uci commit 2>/dev/null
    #echo "dhcp-range=set:drop_in,${POOL_START},${POOL_END},${POOL_NETMASK},${POOL_LEASETIME}" >$DHCP_FILE
    #restart dnsmasq after "/etc/init.d/network reload" is complete, which was executed in setup_drop_in_interface()
    sleep 2 && /etc/init.d/dnsmasq restart&
}

remove_dhcp_for_drop_in()
{
    [ -n "$(uci -q get dhcp.wan.ignore_ori)" ] && [ $(uci -q get edgerouter.global.enabled) = 0 ] && {
        uci delete dhcp.wan.ignore
        uci rename dhcp.wan.ignore_ori='ignore'
        uci delete dhcp.wan.start
        uci delete dhcp.wan.limit
        uci delete dhcp.wan.leasetime
        uci delete dhcp.wan.force
        uci commit 2>/dev/null
    }
    if [ "$1" != "shutdown" ];then
        #rm $DHCP_FILE
        /etc/init.d/dnsmasq restart
    fi
}

check_dhcp_server()
{
    local INFO
    INFO="$(dhcpdiscover -i ${WAN} -p -t 4 ${LOCAL_IPADDR:+-b $LOCAL_IPADDR} )"
    if [ -n "$INFO" ];then
        echo -e "$INFO" > $DHCP_INFO
    else
        rm $DHCP_INFO 2>/dev/null
    fi
}

load_edgerouter_config

