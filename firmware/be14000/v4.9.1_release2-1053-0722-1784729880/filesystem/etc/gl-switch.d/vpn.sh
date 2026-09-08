#!/bin/sh
. /lib/functions/gl_util.sh

[ "$1" = "on" ] && enabled=1 || enabled=0

tunnel=$(uci -q get switch-button.@main[0].sub_func)

switch_rule() {
    config_get tunnel_id $1 tunnel_id
    if [ "$tunnel" != "$tunnel_id" ];then
        return
    fi

    config_get via_type $1 via_type
    config_get peer_id $1 peer_id
    config_get group_id $1 group_id
    config_get client_id $1 client_id

    [ "$via_type" != "wireguard" ] && [ "$via_type" != "openvpn" ] && [ "$via_type" != "novpn" ] && return

    [ "$via_type" = "wireguard" ] && [ "$(uci -q get wireguard.peer_$peer_id)" != "peers" ] && return
    [ "$via_type" = "openvpn" ] && [ "$(uci -q get ovpnclient."$group_id"_"$client_id")" != "clients" ] && return

    uci set route_policy.$1.enabled=$enabled
    uci commit route_policy

    /etc/init.d/vpn-client restart&
    sleep 5
}

config_load route_policy

config_foreach switch_rule rule
