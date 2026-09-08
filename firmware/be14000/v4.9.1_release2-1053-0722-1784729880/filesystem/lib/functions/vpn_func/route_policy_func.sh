#!/bin/sh

. /lib/functions.sh
. /lib/functions/gl_util.sh
. /lib/functions/vpn_func.sh

wg_mark_base=0x1000
ovpn_mark_base=0xa000
nonevpn_mark=0x8000
vpn_mark_mask=0xf000
vpn_mask_reverse="$(printf "0x%x" $((~${vpn_mark_mask} & 0xffffffff)))"

v6_enabled="$(uci -q get glipv6.globals.enabled)"

use_fw4='0'
[ -n "$(which fw4)" ] && use_fw4='1'

clean_vpn_conntrack()
{
    local conn_track_mask=$((${vpn_mark_mask}))
    local zero_string=''
    while [ "$(expr $conn_track_mask % 16)" = '0' ]; do
        zero_string="${zero_string}0"
	conn_track_mask=$(expr $conn_track_mask / 16)
    done
    local connmark_max=$conn_track_mask

    local interval=1
    while [ "$(expr $conn_track_mask % 2)" = '0' ]; do
	    interval=$(expr $interval \* 2)
	    conn_track_mask=$(expr $conn_track_mask / 2)
    done

    local connmark=$interval
    local connmark_mask=$conn_track_mask
    while [ ${connmark} -le $connmark_max ] ;do
        conntrack -D --mark 0x$(printf "%x" ${connmark})${zero_string}/${vpn_mark_mask}  2>/dev/null
        conntrack -f ipv6 -D --mark 0x$(printf "%x" ${connmark})${zero_string}/${vpn_mark_mask}  2>/dev/null
        connmark=$(expr $connmark + $interval)
    done
}

clean_conntrack() {
    conntrack -D -p udp --dport 53 2>/dev/null
    conntrack -D -p tcp --dport 53 2>/dev/null
    for i in $(seq 1 5); do
        conntrack -D -p udp --dport 2"$i"53 2>/dev/null
        conntrack -D -p tcp --dport 2"$i"53 2>/dev/null
        conntrack -D -p udp --dport 4"$i"53 2>/dev/null
        conntrack -D -p tcp --dport 4"$i"53 2>/dev/null
    done

    clean_vpn_conntrack
}

get_vpn_source_if_list() {
    local list='ovpnserver wgserver lan guest'
    add_if_to_list(){
        local new_if="$1"
        case " $list " in
            *" $new_if "*)
            return 0 ;;
        esac
        if_is_valid_source "$new_if"
        [ $? -eq 1 ] && {
            list="${list} ${new_if}"
        }
    }
    local extra_list="$(uci -q get route_policy.global.append_source_if)"
    for per_if in ${extra_list} ;do
        add_if_to_list "${per_if}"
    done

    echo "$list"
}

SOURCE_DATA_IF_LIST="$(get_vpn_source_if_list)"

EDGE_ROUTER_SOURCE_IFS='wan secondwan'

is_vpn_source_if() {
    local if_name="$1";shift
    local if_name="${if_name%% *}"
    [ -z "${if_name}" -o -z "${SOURCE_DATA_IF_LIST}" ] && {
        echo "0"
        return 1
    }

    case " $SOURCE_DATA_IF_LIST " in
        *" $if_name "*)
            echo "1"
        ;;
        *)
            echo "0"
        ;;
    esac

    return 0
}

vpn_set_firewall_forwarding_section() {
    local from_if="$1";shift
    local to_if="$1";shift

    local from_zone="$(get_if_s_firewall_zone "${from_if}")"
    local to_zone="$(get_if_s_firewall_zone "${to_if}")"

    [ -n "${from_zone}" -a  -n "${to_zone}" ] && {
        uci set firewall.${from_zone}2${to_zone}=forwarding
        uci set firewall.${from_zone}2${to_zone}.src=${from_zone}
        uci set firewall.${from_zone}2${to_zone}.dest=${to_zone}
        uci set firewall.${from_zone}2${to_zone}.gl_vpn_rules='1'
    }

    uci commit firewall
}

instance_set_forwarding_with_per_source_if() {
    local vpn_if_name="$1";shift
    local per_source_if="$1";shift
    local forward_type="$1";shift

    vpn_set_firewall_forwarding_section "$per_source_if" "$vpn_if_name"
    [ "${forward_type}" = 'both-directions' ] && vpn_set_firewall_forwarding_section "$vpn_if_name" "$per_source_if"
}

