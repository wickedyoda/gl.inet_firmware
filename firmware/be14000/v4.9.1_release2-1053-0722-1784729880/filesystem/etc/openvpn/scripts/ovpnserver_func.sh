#!/bin/sh

# shellcheck disable=SC2068

. /lib/functions/vpn_server_func.sh

set_firewall()
{
        local interface=$1
        local disable
        local config_section

        local port
        local proto
        local ipv6_enable
        local subnetv6
        local masq
        local local_access

        config_load network
        config_get disable "${interface}" "disabled"
        config_get config_section "${interface}" "config"
        [ "${disabled}" = '1' ] && return 1

        config_load ovpnserver
        config_get port "${config_section}" "port"
        config_get proto "${config_section}" "proto" "udp"
        config_get subnetv6 "${config_section}" "subnetv6"
        config_get masq "global" "masq"
        config_get local_access "global" "access"

        config_load glipv6
        config_get ipv6_enable "globals" "enabled"
        config_get client_to_client "vpn" "client_to_client"
        [ "$client_to_client" = "" ] && client_to_client="0"

        if [ "$ipv6_enable" = "1" ] ;then
                ipv6_enable=1
        else
                ipv6_enable=0
        fi

        server_set_firewall ${interface} ${port} ${proto} ${ipv6_enable} ${masq} ${local_access} ${client_to_client}
}

disabled_firewall()
{
        local interface=$1
        server_disabled_firewall ${interface}
}

set_dhcp()
{
        local interface=$1
        local action="$2"
        server_set_dhcp "$interface" "$action"
}

interface="$1"; shift
cmd="$1"; shift

case "$cmd" in
        set_firewall)
                #set_firewall "${interface}"
                set_firewall "${interface}"
                reload_modified_service
        ;;
        disabled_firewall)
                disabled_firewall "${interface}"
                reload_modified_service
        ;;
        set_dhcp)
                set_dhcp "${interface}" $@
        ;;
        *)
esac

exit $?
