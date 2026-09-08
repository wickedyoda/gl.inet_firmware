#!/bin/sh
. /lib/functions/vpn_func.sh

pid=$(ps | grep "/etc/wireguard/scripts/start_random_client.sh" | grep -v grep | grep -v timeout | awk '{print $1}' 2>/dev/null)

netifd_update(){
    local interface="$1"
    ifup "$interface"
}

mark_expressvpn_endpoint_failed() {
    local interface="$1"
    local reason="$2"
    local peer group_id group_name location_id mode state_file selected_index offset

    peer="$(uci -q get network."$interface".config)"
    [ -n "$peer" ] || return 0

    location_id="$(uci -q get wireguard."$peer".expressvpn_location_id)"
    [ -n "$location_id" ] || return 0

    group_id="$(uci -q get wireguard."$peer".group_id)"
    group_name="$(uci -q get wireguard.group_"$group_id".group_name)"
    [ "$group_name" = "ExpressVPN" ] || return 0

    mode="$(uci -q get expressvpn.global.endpoint_mode)"
    [ "$mode" = "obfuscated" ] && return 0

    mkdir -p /tmp/expressvpn
    state_file="/tmp/expressvpn/endpoint_state_${peer}"
    selected_index="$(sed -n 's/^selected_index=//p' "$state_file" 2>/dev/null | head -n1)"
    if echo "$selected_index" | grep -Eq '^[0-9]+$'; then
        offset=$((selected_index + 1))
    else
        offset="$(sed -n 's/^offset=//p' "$state_file" 2>/dev/null | head -n1)"
        echo "$offset" | grep -Eq '^[0-9]+$' || offset=0
        offset=$((offset + 1))
    fi

    {
        echo "location_id=${location_id}"
        echo "offset=${offset}"
        echo "reason=${reason}"
    } > "$state_file"
    logger -t expressvpn "Marked endpoint failure for ${peer}/${location_id}: next_offset=${offset} reason=${reason}"
}

if [ "${ACTION}" = "REKEY-TIMEOUT"  -a -n "$(echo "${ifname}" | grep "^wgclient")" ]; then
    # logger -t wireguard-debug `env`
    [ "$pid" ] && kill -SIGUSR1 $pid 2>/dev/null&
    [ -f /tmp/wireguard/"${ifname}"_state ] || exit 0
    state="$(cat /tmp/wireguard/"${ifname}"_state)"
    [ "$state" = "connected" ] || exit 0

    echo "connecting" >/tmp/wireguard/"${ifname}"_state
    rm -f /tmp/run/wg_resolved_ip/${ifname}
    mark_expressvpn_endpoint_failed "${ifname}" "rekey-timeout"
    #vpn_dns_stop_dnsmasq
    /usr/bin/rtp2.sh 'interface_status_change' "${ifname}" 'down'
    netifd_update $ifname
fi

if [ "${ACTION}" = "REKEY-GIVEUP"  -a -n "$(echo "${ifname}" | grep "^wgclient")" ]; then
    [ "$pid" ] && kill -SIGUSR1 $pid 2>/dev/null&
    logger -t wireguard-debug `env`
    echo "connecting" >/tmp/wireguard/"${ifname}"_state
    rm -f /tmp/run/wg_resolved_ip/${ifname}
    mark_expressvpn_endpoint_failed "${ifname}" "rekey-giveup"
    /usr/bin/rtp2.sh 'interface_status_change' "${ifname}" 'down'
    netifd_update $ifname
fi
