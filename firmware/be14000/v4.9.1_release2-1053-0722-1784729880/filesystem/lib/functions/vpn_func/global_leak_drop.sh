#!/bin/sh
. /lib/functions/vpn_func/route_policy_func.sh

enable_failover="$(uci -q get route_policy.@default[0].enabled)"

clean_global_killswitch_dns_rule() {
    local source_ifs="${SOURCE_DATA_IF_LIST} ${EDGE_ROUTER_SOURCE_IFS}"
    for source_if in ${source_ifs} ;do
        uci -q delete firewall.${source_if}_drop_leaked_dns
        uci -q delete firewall.${source_if}_drop_leaked_adgdns
    done

    uci -q commit firewall
#    create_reload_service /etc/init.d/firewall
}

deal_per_if_drop_dns_leak_rule() {
    local source_if="$1"
    source_if="$(printf '%s' "$source_if" | tr -d '\r\n\t ')"
    [ -z "${source_if}" ] && return 1

    local zone_name="$(get_if_s_firewall_zone "${source_if}")"
    [ -z "${zone_name}" ] && return 1

    uci -q batch <<EOF
        set firewall.${zone_name}_drop_leaked_dns='rule'
        set firewall.${zone_name}_drop_leaked_dns.name='${zone_name}_drop_leaked_dns'
        set firewall.${zone_name}_drop_leaked_dns.src="${zone_name}"
        set firewall.${zone_name}_drop_leaked_dns.proto='udp'
        set firewall.${zone_name}_drop_leaked_dns.dest_port='53'
        set firewall.${zone_name}_drop_leaked_dns.mark="!${nonevpn_mark}/${vpn_mark_mask}"
        set firewall.${zone_name}_drop_leaked_dns.target='DROP'

        set firewall.${zone_name}_drop_leaked_adgdns='rule'
        set firewall.${zone_name}_drop_leaked_adgdns.name='${zone_name}_drop_leaked_adgdns'
        set firewall.${zone_name}_drop_leaked_adgdns.src="${zone_name}"
        set firewall.${zone_name}_drop_leaked_adgdns.proto='udp'
        set firewall.${zone_name}_drop_leaked_adgdns.dest_port='3053'
        set firewall.${zone_name}_drop_leaked_adgdns.mark="0x0/${vpn_mark_mask}"
        set firewall.${zone_name}_drop_leaked_adgdns.target='DROP'

        reorder firewall.${zone_name}_drop_leaked_dns=1
        reorder firewall.${zone_name}_drop_leaked_adgdns=1
EOF
    uci commit firewall
}

set_global_killswitch_dns_rule() {

    clean_global_killswitch_dns_rule

    local ifnames="${SOURCE_DATA_IF_LIST}"
    [ "$(uci -q get edgerouter.global.enabled)" = '1' ] && ifnames="${ifnames} ${EDGE_ROUTER_SOURCE_IFS}"
    for per_ifname in ${ifnames} ;do
        case "$per_ifname" in
            "guest" | "ovpnserver" | "wgserver")
                #[ "$(check_interface_is_enabled ${per_ifname})" = '1' ] && {
                    deal_per_if_drop_dns_leak_rule "${per_ifname}"
                #}
            ;;
            *)
                deal_per_if_drop_dns_leak_rule "${per_ifname}"
        esac
    done
#    create_reload_service /etc/init.d/firewall
}

mkdir -p /usr/share/nftables.d/ruleset-post
FILE_DROP_EXPLICT_VPN='/usr/share/nftables.d/ruleset-post/explict_vpn_drop.nft'
FILE_DROP_TCP_DNS_LEAK='/usr/share/nftables.d/ruleset-post/tcp_dns_leak_drop.nft'

clean_global_killswitch_tcp_dns_leak_rule() {
    if [ "$use_fw4" = '1' ] ;then
        rm -f "$FILE_DROP_TCP_DNS_LEAK"
    else
        uci -q set firewall.tcp_dns_leak_drop.enabled='0'
        uci -q commit firewall
    fi
}

set_global_killswitch_tcp_dns_leak_rule() {
    if [ "$use_fw4" = '1' ] ;then
        echo '' >"$FILE_DROP_TCP_DNS_LEAK"
        echo "insert rule inet fw4 output meta l4proto tcp meta skuid 453 meta mark and 0x0000f000 == 0x00000000 counter drop" >>"$FILE_DROP_TCP_DNS_LEAK"
    else
        uci -q batch <<EOF
    set firewall.tcp_dns_leak_drop='rule'
    set firewall.tcp_dns_leak_drop.name='tcp_dns_leak_drop'
    set firewall.tcp_dns_leak_drop.proto='tcp'
    set firewall.tcp_dns_leak_drop.family='any'
    set firewall.tcp_dns_leak_drop.mark='0x0/0xf000'
    set firewall.tcp_dns_leak_drop.target='DROP'
    set firewall.tcp_dns_leak_drop.enabled='1'
    set firewall.tcp_dns_leak_drop.extra='-m owner --uid-owner 453'
EOF
    fi
    uci -q commit firewall
}

set_global_novpn_route_rule() {
    uci -q batch <<EOF
	set network.novpn_to_main='rule'
	set network.novpn_to_main.gl_vpn_rules='1'
	set network.novpn_to_main.mark="${nonevpn_mark}/${vpn_mark_mask}"
	set network.novpn_to_main.priority="6000"
	set network.novpn_to_main.lookup='main'
	set network.novpn_to_main.disabled='0'

	set network.novpn_to_main_6='rule6'
	set network.novpn_to_main_6.gl_vpn_rules='1'
	set network.novpn_to_main_6.mark="${nonevpn_mark}/${vpn_mark_mask}"
	set network.novpn_to_main_6.priority="6000"
	set network.novpn_to_main_6.lookup='main'
	set network.novpn_to_main_6.disabled='0'
EOF
    [ "$v6_enabled" != '1' ] && uci -q delete network.novpn_to_main_6

    uci -q commit network
}

set_global_failover_rule() {
    local enable="$1";shift

    if [ "${enable}" = '1' ];then
        uci -q batch <<EOF
	set network.vpn_to_main='rule'
	set network.vpn_to_main.gl_vpn_rules='1'
	set network.vpn_to_main.mark="0x0/${vpn_mark_mask}"
	set network.vpn_to_main.priority="9000"
	set network.vpn_to_main.lookup='main'
	set network.vpn_to_main.invert='1'
	set network.vpn_to_main.disabled='0'

	set network.vpn_to_main_6='rule6'
	set network.vpn_to_main_6.gl_vpn_rules='1'
	set network.vpn_to_main_6.mark="0x0/${vpn_mark_mask}"
	set network.vpn_to_main_6.priority="9000"
	set network.vpn_to_main_6.lookup='main'
	set network.vpn_to_main_6.invert='1'
	set network.vpn_to_main_6.disabled='0'
EOF
        [ "$v6_enabled" != '1' ] && uci -q delete network.vpn_to_main_6
    else
        uci -q delete network.vpn_to_main
        uci -q delete network.vpn_to_main_6
    fi

    uci -q commit network
}

deal_per_if_rlbr() {
    local if_name="$1"
    local enable="$2"
    if [ "$enable" = '1' ];then
        uci -q batch <<EOF
            set network.vpn_block_${if_name}_leak='rule'
            set network.vpn_block_${if_name}_leak.gl_vpn_rules='1'
            set network.vpn_block_${if_name}_leak.in="${if_name}"
            set network.vpn_block_${if_name}_leak.priority="9920"
            set network.vpn_block_${if_name}_leak.action='blackhole'
            set network.vpn_block_${if_name}_leak.disabled='0'

            set network.vpn_block_${if_name}_leak_6='rule6'
            set network.vpn_block_${if_name}_leak_6.gl_vpn_rules='1'
            set network.vpn_block_${if_name}_leak_6.in="${if_name}"
            set network.vpn_block_${if_name}_leak_6.priority="9920"
            set network.vpn_block_${if_name}_leak_6.action='blackhole'
            set network.vpn_block_${if_name}_leak_6.disabled='0'
EOF
        [ "$v6_enabled" != '1' ] && uci -q delete network.vpn_block_${if_name}_leak_6
    else
        uci -q delete network.vpn_block_${if_name}_leak
        uci -q delete network.vpn_block_${if_name}_leak_6
    fi

    uci -q commit network
}

set_vpn_route_leak_block_rule() {
    uci -q batch <<EOF
	set network.vpn_leak_block='rule'
	set network.vpn_leak_block.gl_vpn_rules='1'
	set network.vpn_leak_block.mark="0x0/${vpn_mark_mask}"
	set network.vpn_leak_block.priority="9910"
	set network.vpn_leak_block.action='blackhole'
	set network.vpn_leak_block.invert='1'
	set network.vpn_leak_block.disabled='0'

	set network.vpn_leak_block_6='rule6'
	set network.vpn_leak_block_6.gl_vpn_rules='1'
	set network.vpn_leak_block_6.mark="0x0/${vpn_mark_mask}"
	set network.vpn_leak_block_6.priority="9910"
	set network.vpn_leak_block_6.action='blackhole'
	set network.vpn_leak_block_6.invert='1'
	set network.vpn_leak_block_6.disabled='0'
EOF
    [ "$v6_enabled" != '1' ] && uci -q delete network.vpn_leak_block_6

    local block_if_list="${SOURCE_DATA_IF_LIST}"

    local edge_r_enabled="$(uci -q get edgerouter.global.enabled)"
    if [ "$edge_r_enabled" = '1' ];then
        block_if_list="${block_if_list} ${EDGE_ROUTER_SOURCE_IFS}"
    else
        for per_if in ${EDGE_ROUTER_SOURCE_IFS} ;do
            deal_per_if_rlbr "${per_if}" '0'
        done
    fi

    for per_if in ${block_if_list} ;do
        #[ "$(check_interface_is_enabled ${per_if})" = '1' ] && {
            deal_per_if_rlbr "${per_if}" '1'
        #}
    done

    uci -q commit network
}

clean_global_killswitch_route_rule() {
    clean_gl_vpn_route_rule() {
        local section="$1"
        local vpn_rules

        config_get vpn_rules "$section" gl_vpn_rules '0'
        [ "${vpn_rules}" = '1' ] && uci -q delete network."${section}"
    }

    config_load network
    config_foreach clean_gl_vpn_route_rule rule
    config_foreach clean_gl_vpn_route_rule rule6
    uci commit network
}

set_vpn_global_route_static_net() {
    local rt_table="$1"

    uci -q delete network.main_static_net
    uci -q delete network.main_static_net_6

    uci -q batch <<EOF
        set network.main_static_net='rule'
        set network.main_static_net.gl_vpn_rules='1'
        set network.main_static_net.suppress_prefixlength='0'
        set network.main_static_net.priority="800"
        set network.main_static_net.lookup="$rt_table"
        set network.main_static_net.disabled='0'

        set network.main_static_net_6='rule6'
        set network.main_static_net_6.gl_vpn_rules='1'
        set network.main_static_net_6.suppress_prefixlength='0'
        set network.main_static_net_6.priority="800"
        set network.main_static_net_6.lookup="$rt_table"
        set network.main_static_net_6.disabled='0'
EOF
    [ "$v6_enabled" != '1' ] && uci -q delete network.main_static_net_6

    uci -q commit network
}

set_global_killswitch_route_rule() {
    clean_global_killswitch_route_rule

    set_global_novpn_route_rule

    if [ "$(uci -q get route_policy.@default[0].enabled)" = '1' ];then
        set_global_failover_rule '1'
    else
        set_global_failover_rule '0'
    fi

    set_vpn_route_leak_block_rule

    local edge_r_enabled="$(uci -q get edgerouter.global.enabled)"
    if [ "$edge_r_enabled" = '1' ];then
        set_vpn_global_route_static_net "main"
    else
        set_vpn_global_route_static_net "${VPN_DIRECT_TABLE}"
    fi
    uci commit network
}

fw3_add_explict_vpn_leak_if_drop_rule() {
    uci -q batch <<EOF
	set firewall.explict_vpn_drop_wan_leaked='rule'
	set firewall.explict_vpn_drop_wan_leaked.name="explict_vpn_drop_wan_leaked"
	set firewall.explict_vpn_drop_wan_leaked.proto='all'
	set firewall.explict_vpn_drop_wan_leaked.dest='wan'
	set firewall.explict_vpn_drop_wan_leaked.extra="-m owner --gid-owner 20000"
	set firewall.explict_vpn_drop_wan_leaked.mark="0x0/${vpn_mark_mask}"
	set firewall.explict_vpn_drop_wan_leaked.target='DROP'
	set firewall.explict_vpn_drop_wan_leaked.enabled='1'
EOF
    uci commit firewall
}
    
set_global_killswitch_explict_vpn_rule() {
    local wan_list="$(get_wan_device_list)"

    if [ "$use_fw4" = '1' ] ;then
        echo '' >"$FILE_DROP_EXPLICT_VPN"
        echo "add chain inet fw4 output_explict_vpn_wan_drop" >>"$FILE_DROP_EXPLICT_VPN"
        echo "add rule inet fw4 output_explict_vpn_wan_drop meta mark and ${vpn_mark_mask} == 0x0 drop" >>"$FILE_DROP_EXPLICT_VPN"
        echo "insert rule inet fw4 output_wan skgid 20000 jump output_explict_vpn_wan_drop" >>"$FILE_DROP_EXPLICT_VPN"
    else
        fw3_add_explict_vpn_leak_if_drop_rule
    fi
}

clean_global_killswitch_explict_vpn_rule() {
    if [ "$use_fw4" = '1' ] ;then
        rm -f "${FILE_DROP_EXPLICT_VPN}"
    else
        uci -q delete firewall.explict_vpn_drop_wan_leaked
        uci -q commit firewall
    fi
}

set_global_killswitch_local_policy_rule() {
    if [ "${enable_failover}" != '1' ];then
        set_global_killswitch_explict_vpn_rule
    else
        clean_global_killswitch_explict_vpn_rule
    fi
}

clean_global_killswitch_local_policy_rule() {
    clean_global_killswitch_explict_vpn_rule
}

set_global_killswitch_rule() {

    set_global_killswitch_dns_rule
    set_global_killswitch_tcp_dns_leak_rule
    set_global_killswitch_route_rule
    set_global_killswitch_local_policy_rule

    clean_conntrack
}

clean_global_killswitch_rule() {
    clean_global_killswitch_dns_rule
    clean_global_killswitch_tcp_dns_leak_rule
    clean_global_killswitch_route_rule
    clean_global_killswitch_local_policy_rule
}


