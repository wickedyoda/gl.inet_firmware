#!/bin/sh

tethering_event()
{
    local device=$1
    local mode=$2
    local action=$3
    local logEnabled=$(uci get tethering.@main[0].log_enabled)

    [ "$logEnabled" = "1" ] && echo "tethering  auto connect msg: device: $device mode: $mode action: $action" >> /tmp/tethering

    if [ "$action" = "add" ]; then
        if [ "$mode" = "host" ]; then
            local metric=$(uci -q get kmwan.tethering.metric)
            [ -n "$metric" ] || metric=30

            local inited_status=$(uci -q get glconfig.general.inited)
            if [ "$inited_status" != "1" ]; then
                [ "$logEnabled" = "1" ] && echo "wait for system init" >> /tmp/tethering
                return 0
            fi

            local auto_conn=$(uci -q get tethering.@main[0].auto)
            if [ "$auto_conn" = "0" ]; then
                [ "$logEnabled" = "1" ] && echo "tethering have been stop by usr" >> /tmp/tethering
                return 0
            fi

            uci delete network.tethering
            uci set network.tethering=interface
            uci set network.tethering.proto="dhcp"
            uci set network.tethering.ifname="$device"
            uci set network.tethering.metric="$metric"

            local mtu=$(uci -q get tethering.@main[0].mtu)
            local ttl=$(uci -q get tethering.@main[0].ttl)
            local ttl_ipv6=$(uci -q get tethering.@main[0].ttl_ipv6)

            [ -n "$mtu" ] && uci set network.tethering.mtu=$mtu
            [ -n "$ttl" ] && uci set network.tethering.ttl=$ttl
            [ -n "$ttl_ipv6" ] && uci set network.tethering.ttl_ipv6=$ttl_ipv6

            if [ -f /sbin/fw4 ]; then
                local cmd_str
                if [ -n "$ttl" ]; then
                    mkdir -p /usr/share/nftables.d/chain-pre/mangle_postrouting/
                    cmd_str="oifname $device ip ttl set $ttl"
                    echo $cmd_str > /usr/share/nftables.d/chain-pre/mangle_postrouting/01-tethering-set-ttl.nft
                else
                    rm /usr/share/nftables.d/chain-pre/mangle_postrouting/01-tethering-set-ttl.nft
                fi

                if [ -n "$ttl_ipv6" ]; then
                    mkdir -p /usr/share/nftables.d/chain-pre/mangle_postrouting/
                    cmd_str="oifname $device ip6 nexthdr != ipv6-icmp ip6 hoplimit != 255 ip6 hoplimit set $ttl_ipv6"
                    echo $cmd_str > /usr/share/nftables.d/chain-pre/mangle_postrouting/01-tethering-set-ttl_ipv6.nft
                else
                    rm /usr/share/nftables.d/chain-pre/mangle_postrouting/01-tethering-set-ttl_ipv6.nft
                fi
            fi

            local wan_zone_id=$(uci show firewall | grep -i name | grep -i -w "wan" | awk -F'[][]' '{print $2}')
            local wan_list=$(uci -q get firewall.@zone[$wan_zone_id].network)
            local found=$(echo $wan_list | grep -w -c "tethering")
            if [ $found -eq 0 ]; then
                uci add_list firewall.@zone[$wan_zone_id].network="tethering"
            fi

            uci commit firewall
        else
            local lan_device=$(uci -q get network.lan.device)
            if [ -n "$lan_device" ]; then
                local lan_device_id=$(uci show network | grep -i name | grep -i -w "br-lan" | awk -F'[][]' '{print $2}')
                local port_list=$(uci -q get network.@device[$lan_device_id].ports)
                local found=$(echo $port_list | grep -w -c $device)
                if [ $found -eq 0 ]; then
                    uci add_list network.@device[$lan_device_id].ports="$device"
                fi
            fi
        fi

        uci commit network
        sync

        /etc/init.d/network reload
        /etc/init.d/firewall reload
    elif [ "$action" = "unbind" -o "$action" = "remove" ];then
        if [ "$mode" = "host" ]; then
            local ttl_file="/usr/share/nftables.d/chain-pre/mangle_postrouting/01-tethering-set-ttl.nft"
            local ttl_file_v6="/usr/share/nftables.d/chain-pre/mangle_postrouting/01-tethering-set-ttl_ipv6.nft"
            if [ -f "$ttl_file" ]; then
                rm $ttl_file
            fi

            if [ -f "$ttl_file_v6" ]; then
                rm $ttl_file_v6
            fi
            uci delete network.tethering.ifname
            uci set network.tethering.disabled='1'
        else
            local lan_device=$(uci -q get network.lan.device)
            if [ -n "$lan_device" ]; then
                local lan_device_id=$(uci show network | grep -i name | grep -i -w "br-lan" | awk -F'[][]' '{print $2}')
                uci del_list network.@device[$lan_device_id].ports="$device"
            fi
        fi

        uci commit network
        sync

        /etc/init.d/network reload
    else
        [ "$logEnabled" = "1" ] && echo "no option for action: $action" >> /tmp/tethering
    fi
}

