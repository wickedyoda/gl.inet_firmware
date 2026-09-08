#!/bin/sh
# Copyright 2016-2017 Dan Luedtke <mail@danrl.com>
# Licensed to the public under the Apache License 2.0.

WG=/usr/bin/wg
if [ ! -x $WG ]; then
	logger -t "wireguard" "error: missing wireguard-tools (${WG})"
	exit 0
fi

APPEND_CONF_DIR="/etc/wireguard/profile"
EXPRESSVPN_ENDPOINT_SETUP_TIMEOUT="${EXPRESSVPN_ENDPOINT_SETUP_TIMEOUT:-12}"

[ -n "$INCLUDE_ONLY" ] || {
	. /lib/functions.sh
	. ../netifd-proto.sh
	. /lib/functions/gl_util.sh
	init_proto "$@"
}

proto_wgclient_init_config() {
	proto_config_add_string config
	proto_config_add_int "mtu"
	available=1
	no_proto_task=1
#	no_device=1
}

trigger_setup_failover() {
	[ -n "$interface" ] || return 0
	[ -x /usr/bin/vpn-failover-trigger.sh ] || return 0

	/usr/bin/vpn-failover-trigger.sh trigger \
		"$interface" setup-failure setup-failed >/dev/null 2>&1
}

fail_handle() {
	local status="$?"

	trap - EXIT INT TERM
	[ "$status" -eq 0 ] && return 0
	trigger_setup_failover
	return 0
}

run_script() {
	local script="$1"
	local interface="$2"
	local config="$3"
	local ret timeout_sec group_id group_name

	timeout_sec=5
	group_id="$(uci -q get wireguard."$config".group_id)"
	group_name="$(uci -q get wireguard.group_"$group_id".group_name)"
	if [ "$group_name" = "ExpressVPN" ]; then
		timeout_sec=20
	fi

	timeout "$timeout_sec" $script "$config" 2>/dev/null

	ret=$?

	if [ ${ret} -ne 0 ]
	then
		sleep 5
		proto_setup_failed "${interface}"
		exit 1
	fi
}

watch_expressvpn_setup_timeout() {
	local interface="$1"
	local state_file="$2"
	local timeout="${3:-$EXPRESSVPN_ENDPOINT_SETUP_TIMEOUT}"
	local peer group_id group_name location_id mode endpoint_state attempt_id

	peer="$(uci -q get network."$interface".config)"
	[ -n "$peer" ] || return 0

	location_id="$(uci -q get wireguard."$peer".expressvpn_location_id)"
	[ -n "$location_id" ] || return 0

	group_id="$(uci -q get wireguard."$peer".group_id)"
	group_name="$(uci -q get wireguard.group_"$group_id".group_name)"
	[ "$group_name" = "ExpressVPN" ] || return 0

	mode="$(uci -q get expressvpn.global.endpoint_mode)"
	[ "$mode" = "obfuscated" ] && return 0

	endpoint_state="/tmp/expressvpn/endpoint_state_${peer}"
	attempt_id="$(sed -n 's/^attempt_id=//p' "$endpoint_state" 2>/dev/null | head -n1)"
	[ -n "$attempt_id" ] || return 0

	(
		local selected_index offset state current_attempt_id

		sleep "$timeout"
		state="$(cat "$state_file" 2>/dev/null)"
		[ "$state" = "connecting" ] || exit 0

		current_attempt_id="$(sed -n 's/^attempt_id=//p' "$endpoint_state" 2>/dev/null | head -n1)"
		[ "$current_attempt_id" = "$attempt_id" ] || exit 0

		selected_index="$(sed -n 's/^selected_index=//p' "$endpoint_state" 2>/dev/null | head -n1)"
		if echo "$selected_index" | grep -Eq '^[0-9]+$'; then
			offset=$((selected_index + 1))
		else
			offset="$(sed -n 's/^offset=//p' "$endpoint_state" 2>/dev/null | head -n1)"
			echo "$offset" | grep -Eq '^[0-9]+$' || offset=0
			offset=$((offset + 1))
		fi

		{
			echo "location_id=${location_id}"
			echo "selected_index=${selected_index}"
			echo "attempt_id=${attempt_id}"
			echo "offset=${offset}"
			echo "reason=setup-timeout"
		} > "$endpoint_state"
		logger -t expressvpn "Marked endpoint failure for ${peer}/${location_id}: next_offset=${offset} reason=setup-timeout"
	) &
}

clear_expressvpn_endpoint_state_on_disable() {
	local interface="$1"
	local peer group_id group_name location_id state_file

	peer="$(uci -q get network."$interface".config)"
	[ -n "$peer" ] || return 0

	location_id="$(uci -q get wireguard."$peer".expressvpn_location_id)"
	[ -n "$location_id" ] || return 0

	group_id="$(uci -q get wireguard."$peer".group_id)"
	group_name="$(uci -q get wireguard.group_"$group_id".group_name)"
	[ "$group_name" = "ExpressVPN" ] || return 0

	state_file="/tmp/expressvpn/endpoint_state_${peer}"
	if [ -f "$state_file" ]; then
		rm -f "$state_file"
		logger -t expressvpn "Cleared endpoint failure state on disable for ${peer}/${location_id}"
	fi
}

proto_wgclient_setup() {
	local interface="$1"
	local wg_dir="/tmp/wireguard"
	local wg_cfg="${wg_dir}/${interface}"
	local wg_state="${wg_dir}/${interface}"_state

	local config

	local end_point
	local end_point_ip
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
	local mtu
	local group_id
	local type

	local endpoint_port_part
	local endpoint_ip_part

	local dev_type='wireguard'

	trap 'exit 1' INT TERM
	trap fail_handle EXIT

	config_load network
	config_get config "${interface}" "config"
	config_get mtu "${interface}" "mtu"
	config_list_foreach "${interface}" pre_setup_script run_script "${interface}" "${config}"

	ip link del dev "${interface}" 2>/dev/null

	#proto_init_update "${interface}" 1

	umask 077
	mkdir -p "${wg_dir}"
	echo "[Interface]" > "${wg_cfg}"

	config_load glconfig
	config_get proxy_mode "route_policy" "proxy_mode" "0"

	config_load wireguard
	config_get end_point "${config}" "end_point"
	config_get end_point_ip "${config}" "end_point_ip"
	config_get public_key "${config}" "public_key"
	config_get private_key "${config}" "private_key"
	config_get listen_port "${config}" "listen_port"
	config_get address_v4 "${config}" "address_v4"
	config_get address_v6 "${config}" "address_v6"
	config_get preshared_key "${config}" "preshared_key"
	config_get presharedkey_enable "${config}" "presharedkey_enable"
	config_get allowed_ips "${config}" "allowed_ips"
	config_get_bool route_allowed_ips "${config}" "route_allowed_ips" 0
	config_get persistent_keepalive "${config}" "persistent_keepalive"
	config_get nohostroute "${config}" "nohostroute"
	config_get dns "${config}" "dns"
	config_get fwmark "${config}" "fwmark" 0x8000
	[ -z "$mtu" ] && {
		config_get mtu "${config}" "mtu"
	}

	config_get group_id "${config}" "group_id"
	[ -z "$private_key" ] && config_get private_key "group_${group_id}" "private_key"
	[ -z "$address_v4" ] && config_get address_v4 "group_${group_id}" "address_v4"
	[ -z "$address_v6" ] && config_get address_v6 "group_${group_id}" "address_v6"
	[ -z "$dns" ] && config_get dns "group_${group_id}" "dns"

	config_get type "${config}" "type" "0"

	#rm -f "${wg_cfg}"

	echo "[Interface]" > "${wg_cfg}"
	if [ "${listen_port}" ]; then
		echo "ListenPort=${listen_port}" >> "${wg_cfg}"
	fi

	if [ "${fwmark}" ]; then
		echo "FwMark=${fwmark}" >> "${wg_cfg}"
	fi

	echo "PrivateKey=${private_key}" >> "${wg_cfg}"

	case "${type}" in
		"1")
			dev_type="amneziawg"
			WG=/usr/bin/awg
			echo "$(grep -iE '^(jc|jmax|jmin|s1|s2|s3|s4|h1|h2|h3|h4|i1|i2|i3|i4|i5)\b' "${APPEND_CONF_DIR}/${group_id}/${config}" 2>/dev/null)" >> "${wg_cfg}"
		;;
		*)
			dev_type="wireguard"
			WG=/usr/bin/wg
		;;
	esac

	echo "[Peer]" >> "${wg_cfg}"
	echo "PublicKey=${public_key}" >> "${wg_cfg}"

	endpoint_port_part="${end_point##*:}"
	endpoint_ip_part="${end_point%:*}"
	[ "$endpoint_ip_part" = "$(echo "$endpoint_ip_part" | grep -oE '\b([0-9a-fA-F]{0,4}:){1,7}[0-9a-fA-F]{0,4}\b')" ] && {
		end_point="[$endpoint_ip_part]:$endpoint_port_part"
	}
	echo "Endpoint=${end_point_ip:-${end_point}}" >> "${wg_cfg}"
	if [ "${preshared_key}" ] && [ "${presharedkey_enable}" != "0" ]; then
		echo "PresharedKey=${preshared_key}" >> "${wg_cfg}"
	fi

	echo "AllowedIPs=${allowed_ips}" >> "${wg_cfg}"

	if [ -n "${persistent_keepalive}" -a ! "${persistent_keepalive}" = "0" ]; then
		echo "PersistentKeepalive=${persistent_keepalive}" >> "${wg_cfg}"
	else
		echo "PersistentKeepalive=25" >> "${wg_cfg}"
	fi

	ip link add dev "${interface}" type "${dev_type}"
	[ -n "$mtu" ] && {
		ip link set mtu "$mtu" "${interface}"
	}

	# apply configuration file
	# ip address add dev "${interface}" "$address_v4"
	# [ -n "$address_v6" ] && ip -6 address add dev "${interface}" "$address_v6"
	${WG} setconf ${interface} "${wg_cfg}"
	WG_RETURN=$?

	rm -f "${wg_cfg}"

	if [ ${WG_RETURN} -ne 0 ]; then
		sleep 5
		proto_setup_failed "${interface}"
		exit 1
	fi
	echo connecting > "${wg_cfg}"_state
	if [ -x /usr/bin/vpn-failover-trigger.sh ] && \
	   /usr/bin/vpn-failover-trigger.sh check "$interface" >/dev/null 2>&1 && \
	   [ -x /usr/bin/vpn-failover-watcher.sh ]; then
		/usr/bin/vpn-failover-watcher.sh \
			"$interface" "${wg_cfg}_state" 30 >/dev/null 2>&1 &
	fi
	watch_expressvpn_setup_timeout "$interface" "${wg_cfg}_state" "$EXPRESSVPN_ENDPOINT_SETUP_TIMEOUT"
	touch "${wg_cfg}"_boot
	ip link set up dev "${interface}"

	# cleanup the trap.
	trap - EXIT INT TERM
}

proto_wgclient_teardown() {
	local interface="$1"
	local wg_dir="/tmp/wireguard"
	local disabled="$(uci -q get network.${interface}.disabled)"
	local wg_state="${wg_dir}/${interface}"_state

	if [ "$disabled" = "0" ];then
		echo "connecting" > "${wg_state}"
	else
		rm "${wg_state}"
		rm -f /tmp/run/wg_resolved_ip/${interface}
		clear_expressvpn_endpoint_state_on_disable "${interface}"
	fi
	ip link del dev "${interface}" >/dev/null 2>&1
	/usr/bin/rtp2.sh 'interface_status_change' "${interface}" 'down' 2>/dev/null
}

[ -n "$INCLUDE_ONLY" ] || {
	add_protocol wgclient
}
