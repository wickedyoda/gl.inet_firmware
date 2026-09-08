#!/bin/sh
# shellcheck disable=SC3037
# shellcheck disable=SC3003

. /lib/functions/gl_util.sh

handle_dns()
{
	echo -e "# Interface $1" > /tmp/resolv.conf.d/resolv.conf.$interface

	if [ "${dns}" ]; then
		for d in ${dns};do
			case "${d}" in
				*,*)
					old_IFS=$IFS
					IFS="$old_IFS,"
					for s in $d;do
						#proto_add_dns_server "$s}"
						echo -e "nameserver ${s}" >> /tmp/resolv.conf.d/resolv.conf.$interface
					done
					IFS=$old_IFS
					;;
				*)
					if [ "${d%%,*}" ]; then
						#proto_add_dns_server "${d%%,*}"
						echo -e "nameserver ${d%%,*}" >> /tmp/resolv.conf.d/resolv.conf.$interface
					fi
					;;
			esac
		done
	fi
}

netifd_update()
{
	. /lib/functions.sh
	. /lib/netifd/netifd-proto.sh

	local interface="$1"

	local peer_id
	local config
	local end_point
	local public_key
	local private_key
	local listen_port
	local fwmark
	local address_v4
	local address_v6
	local preshared_key
	local allowed_ips
	local route_allowed_ips
	local persistent_keepalive
	local nohostroute
	local global_proxy
	local dns
	local group_id
	local type
	local dns_v4
	local default_dns_v4
	local default_dns_v6
	local glipv6_globals=$(uci -q get glipv6.globals.enabled)

	config_load network
	config_get config "${interface}" "config"
	peer_id=${config#*_}

	config_load wireguard
	config_get end_point "${config}" "end_point"
	config_get public_key "${config}" "public_key"
	config_get private_key "${config}" "private_key"
	config_get listen_port "${config}" "listen_port"
	config_get address_v4 "${config}" "address_v4"
	config_get address_v6 "${config}" "address_v6"
	config_get preshared_key "${config}" "preshared_key"
	config_get allowed_ips "${config}" "allowed_ips"
	config_get_bool route_allowed_ips "${config}" "route_allowed_ips" 1
	config_get persistent_keepalive "${config}" "persistent_keepalive"
	config_get nohostroute "${config}" "nohostroute"
	config_get dns "${config}" "dns"
	config_get default_dns_v4 "global" "default_dns_v4" '1.0.0.1'
	config_get default_dns_v6 "global" "default_dns_v6" '2606:4700:4700::1111'
	config_get group_id "${config}" "group_id"
	config_get type "${config}" "type"
	[ -z "$dns" ] && config_get dns "group_${group_id}" "dns"

	if [ -z "$dns" ]; then
		dns="${default_dns_v4}"
		[ "$glipv6_globals" = '1' ] && dns="${dns} ${default_dns_v6}"
	else
		dns_v4="$(echo "$dns" | grep -oE '\b([0-9]{1,3}\.){3}[0-9]{1,3}([#:][0-9]{1,2})?\b')"
		[ -z "$dns_v4" ] && dns="${dns} ${default_dns_v4}"
	fi

	proto_init_update "${interface}" 1
	proto_set_keep 1

	handle_dns "$interface"

	if [ ${route_allowed_ips} -ne 0 ]; then
		allowed_ips="${allowed_ips//,/ }"
		for allowed_ip in ${allowed_ips}; do
			case "${allowed_ip}" in
				*:*/*)
					proto_add_ipv6_route "${allowed_ip%%/*}" "${allowed_ip##*/}"
					;;
				*.*/*)
					proto_add_ipv4_route "${allowed_ip%%/*}" "${allowed_ip##*/}"
					;;
				*:*)
					proto_add_ipv6_route "${allowed_ip%%/*}" "128"
					;;
				*.*)
					proto_add_ipv4_route "${allowed_ip%%/*}" "32"
					;;
			esac
		done
	fi
	#for azire address set in config group
	[ -z "$address_v4" ] && config_get address_v4 "group_${group_id}" "address_v4"
	[ -z "$address_v6" ] && config_get address_v6 "group_${group_id}" "address_v6"
	# endpoint dependency
	for address in ${address_v4} ${address_v6}; do
		case "${address}" in
			*:*/*)
				[ "$glipv6_globals" = '1' ] && proto_add_ipv6_address "${address%%/*}" "${address##*/}"
				;;
			*.*/*)
				proto_add_ipv4_address "${address%%/*}" "${address##*/}"
				;;
			*:*)
				[ "$glipv6_globals" = '1' ] && proto_add_ipv6_address "${address%%/*}" "128"
				;;
			*.*)
				proto_add_ipv4_address "${address%%/*}" "32"
				;;
		esac
	done

	if [ "${nohostroute}" != "1" ]; then
		if [ "${type}" = "1" ]; then
			wg_cmd="awg"
		elif [ "${type}" = "0" ]; then
			wg_cmd="wg"
		else
			wg_cmd="wg"
		fi
		${wg_cmd} show "${interface}" endpoints | \
		sed -E 's/\[?([0-9.:a-f]+)\]?:([0-9]+)/\1 \2/' | \
		while IFS=$'\t ' read -r key address port; do
			[ -n "${port}" ] || continue
			[ -d /tmp/run/wg_resolved_ip ] || mkdir -p /tmp/run/wg_resolved_ip
			echo "${address}" >/tmp/run/wg_resolved_ip/${interface}
		done
	fi

	proto_send_update "$interface"

}

clear_expressvpn_endpoint_state() {
	local interface="$1"
	local peer group_id group_name location_id state_file tmp_file

	peer="$(uci -q get network."$interface".config)"
	[ -n "$peer" ] || return 0

	location_id="$(uci -q get wireguard."$peer".expressvpn_location_id)"
	[ -n "$location_id" ] || return 0

	group_id="$(uci -q get wireguard."$peer".group_id)"
	group_name="$(uci -q get wireguard.group_"$group_id".group_name)"
	[ "$group_name" = "ExpressVPN" ] || return 0

	state_file="/tmp/expressvpn/endpoint_state_${peer}"
	if [ -f "$state_file" ]; then
		tmp_file="${state_file}.ifup"
		grep -vE '^(offset|reason)=' "$state_file" > "$tmp_file" 2>/dev/null && mv "$tmp_file" "$state_file"
		rm -f "$tmp_file"
		logger -t expressvpn "Cleared endpoint failure marker for ${peer}/${location_id}"
	fi
}

if [ "${ACTION}" = "KEYPAIR-CREATED" -a -n "$(echo "${ifname}" | grep "^wgclient")" ]; then
	#logger -t wireguard-debug `env`
	[ -f /tmp/wireguard/"${ifname}"_state ] || exit 0
	state="$(cat /tmp/wireguard/"${ifname}"_state)"
	[ "$state" = "connecting" ] || exit 0
if [ ! -f  /tmp/wireguard/"${ifname}"_boot ]; then
		exit 0
	fi
		rm -f /tmp/wireguard/"${ifname}"_boot

	/usr/bin/rtp2.sh 'interface_status_change' "${ifname}" 'up'
	netifd_update $ifname
	echo "connected" >/tmp/wireguard/"${ifname}"_state
	clear_expressvpn_endpoint_state "${ifname}"
fi
