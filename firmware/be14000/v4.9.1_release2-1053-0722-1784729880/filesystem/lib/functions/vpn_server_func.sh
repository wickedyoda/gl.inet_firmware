. /lib/functions/vpn_func.sh

server_set_firewall()
{
        local interface=$1
        local port=$2
        local protocol=$3
        local ipv6_enable=$4
        local masq=$5
        local local_access=$6
        local client_to_client=$7

        local family='ipv4'
        [ "${ipv6_enable}" = "1" ] && family='any'

        [ "$(uci -q get firewall.${interface}.name)" != "${interface}" ] && {
                uci -q set firewall.${interface}='zone'
                uci -q set firewall.${interface}.name="${interface}"
                uci -q set firewall.${interface}.output='ACCEPT'
                uci -q set firewall.${interface}.mtu_fix='1'
                uci -q set firewall.${interface}.network="${interface}"
        }
        if [ "${local_access}" = "ACCEPT" ]; then
                uci -q set firewall.${interface}.input='ACCEPT'
        else
                uci -q set firewall.${interface}.input='REJECT'
        fi
        if [ "${masq}" = "1" ]; then
                uci -q set firewall.${interface}.masq='1'
                uci -q set firewall.${interface}.masq6='1'
        else
                uci -q set firewall.${interface}.masq='0'
                uci -q set firewall.${interface}.masq6='0'
        fi
        uci -q set firewall.${interface}.family="${family}"
        uci -q set firewall.${interface}.enabled='1'

        uci -q set firewall.${interface}_allow='rule'
        uci -q set firewall.${interface}_allow.name="${interface}_allow"
        uci -q set firewall.${interface}_allow.target='ACCEPT'
        uci -q set firewall.${interface}_allow.src='wan'
        uci -q set firewall.${interface}_allow.proto="${protocol}"
        uci -q set firewall.${interface}_allow.dest_port=${port:=51820}
        uci -q set firewall.${interface}_allow.family="${family}"
        uci -q set firewall.${interface}_allow.enabled='1'

        [ "$(uci -q get firewall.${interface}2lan.name)" != "${interface}2lan" ] && {
                uci -q set firewall.${interface}2lan='rule'
                uci -q set firewall.${interface}2lan.name="${interface}2lan"
                uci -q set firewall.${interface}2lan.src="${interface}"
                uci -q set firewall.${interface}2lan.dest='lan'
                uci -q set firewall.${interface}2lan.proto='all'
        }
        if [ "${local_access}" = "ACCEPT" ]; then
                uci -q set firewall.${interface}2lan.target='ACCEPT'
                uci -q set firewall.${interface}2lan.enabled='1'
        else
                uci -q set firewall.${interface}2lan.enabled='0'
        fi
        uci -q set firewall.${interface}2lan.family="${family}"

        [ "$(uci -q get firewall.${interface}2wan.name)" != "${interface}2wan" ] && {
                uci -q set firewall.${interface}2wan='forwarding'
                uci -q set firewall.${interface}2wan.name="${interface}2wan"
                uci -q set firewall.${interface}2wan.src="${interface}"
                uci -q set firewall.${interface}2wan.dest='wan'
        }
        uci -q set firewall.${interface}2wan.family="${family}"
        uci -q set firewall.${interface}2wan.enabled='1'

        [ "$(uci -q get firewall.lan2${interface}.name)" != "lan2${interface}" ] && {
                uci -q set firewall.lan2${interface}='forwarding'
                uci -q set firewall.lan2${interface}.name="lan2${interface}"
                uci -q set firewall.lan2${interface}.src='lan'
                uci -q set firewall.lan2${interface}.dest="${interface}"
        }
        uci -q set firewall.lan2${interface}.family="${family}"
        uci -q set firewall.lan2${interface}.enabled='1'

        [ "$(uci -q get firewall.${interface}2${interface}.name)" != "${interface}2${interface}" ] && {
                uci -q set firewall.${interface}2${interface}='rule'
                uci -q set firewall.${interface}2${interface}.name="${interface}2${interface}"
                uci -q set firewall.${interface}2${interface}.src="${interface}"
                uci -q set firewall.${interface}2${interface}.dest="${interface}"
                uci -q set firewall.${interface}2${interface}.proto='all'
        }
        if [ "${client_to_client}" = "1" ]; then
                uci -q set firewall.${interface}2${interface}.target='ACCEPT'
        else
                uci -q set firewall.${interface}2${interface}.target='REJECT'
        fi
        uci -q set firewall.${interface}2${interface}.family="${family}"
        uci -q set firewall.${interface}2${interface}.enabled='1'

        [ "$(uci -q get firewall.${interface}_allow_dns.name)" != "${interface}_allow_dns" ] && {
                uci -q set firewall.${interface}_allow_dns='rule'
                uci -q set firewall.${interface}_allow_dns.name="${interface}_allow_dns"
                uci -q set firewall.${interface}_allow_dns.src="${interface}"
                uci -q set firewall.${interface}_allow_dns.target='ACCEPT'
                uci -q set firewall.${interface}_allow_dns.dest_port='53'
        }
        uci -q set firewall.${interface}_allow_dns.family="${family}"
        uci -q set firewall.${interface}_allow_dns.enabled='1'

        uci commit firewall
        create_reload_service /etc/init.d/firewall
}

set_localservice()
{
        local section="$1"
        local value="$2"
        local origin_va
        config_get origin_va "$section" "localservice" "0"
        [ "$value" != "$origin_va" ] && uci -q set dhcp.${section}.localservice="$value"
}

server_set_dhcp()
{
        local interface="$1";shift
        local action="$1";shift

        config_load dhcp

        local localservice_value
        if [ "$action" = "up" ] ;then
                localservice_value='0'
        else
                [ "$(uci -q get network.ovpnserver.disabled)" = '1' -a "$(uci -q get network.wgserver.disabled)" = '1' ] && localservice_value='1'
        fi

        [ -n "$localservice_value" ] && {
                config_foreach set_localservice dnsmasq "$localservice_value"
        }

        uci commit dhcp
        create_reload_service /etc/init.d/dnsmasq
}

server_disabled_firewall()
{
        local interface=$1
        uci -q set firewall.${interface}.enabled='0'
        uci -q set firewall.${interface}_allow.enabled='0'
        uci -q set firewall.${interface}2lan.enabled='0'
        uci -q set firewall.${interface}2wan.enabled='0'
        uci -q set firewall.lan2${interface}.enabled='0'
        uci -q set firewall.${interface}2${interface}.enabled='0'
        uci -q set firewall.${interface}_allow_dns.enabled='0'

        uci commit firewall
        create_reload_service /etc/init.d/firewall
}

