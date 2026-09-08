#!/bin/sh

. /lib/functions/vpn_func.sh

rebuild_client_conntrack()
{
        __rebuild_client_conntrack()
        {
                local section="$1"
                local proto
                local disabled
                local if_name=${section}

                config_get proto "$section" "proto"
                config_get disabled "$section" "disabled" "1"

                [ -n "${disabled}" -a "${disabled}" != "0" ] && return

                if [ "$proto" = "wgclient" ]; then
                        local ip_addr="$(cat /tmp/run/wg_resolved_ip/${if_name} 2>/dev/null | sed -e 's/\s*#.*$//')"
                        if [ -n "$(echo "${ip_addr}" | sed -e 's/\s*#.*$//' | grep -oE '\b([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?\b')" ] ;then
                                conntrack -D --dst $ip_addr &>/dev/null
                                ping 8.8.8.8 -w 10 -I ${if_name} >/dev/null 2>&1 &
                        else
                                conntrack -D -f ipv6 --dst $ip_addr &>/dev/null
                                ping6 2606:4700:4700::1111 -w 10 -I ${if_name} >/dev/null 2>&1 &
                        fi
                elif [ "$proto" = "ovpnclient" ]; then
                        local ip_addr="$(cat /tmp/run/ovpn_resolved_ip/${if_name} 2>/dev/null | sed -e 's/\s*#.*$//')"
                        if [ -n "$(echo "${ip_addr}" | sed -e 's/\s*#.*$//' | grep -oE '\b([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?\b')" ] ;then
                                conntrack -D --dst $ip_addr &>/dev/null
                                ping 8.8.8.8 -w 10 -I ${if_name} >/dev/null 2>&1 &
                        else
                                conntrack -D -f ipv6 --dst $ip_addr &>/dev/null
                                ping6 2606:4700:4700::1111 -w 10 -I ${if_name} >/dev/null 2>&1 &
                        fi
                fi
        }

        config_load network
        config_foreach __rebuild_client_conntrack "interface"
}
