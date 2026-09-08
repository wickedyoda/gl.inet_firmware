#!/bin/sh
[ -x /usr/sbin/openvpn ] || exit 0

[ -n "$INCLUDE_ONLY" ] || {
	. /lib/functions.sh
	. ../netifd-proto.sh
	. /lib/functions/gl_util.sh
	init_proto "$@"
}

proto_ovpnclient_init_config() {
	no_device=1
	available=1
	#no-proto-task=1
	proto_config_add_string config
	proto_config_add_int "mtu"
	proto_config_add_defaults
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

proto_ovpnclient_setup() {
	local interface="$1"
	local config
	local ovpn_cfg apply_cfg
	local dev_type="tun"
	local mtu
	local work_mode
	local disable_dco
	json_get_vars config

	trap 'exit 1' INT TERM
	trap fail_handle EXIT

	config_load ovpnclient
	config_get ovpn_cfg "${config}" "path"
	config_get group_id "${config}" "group_id"

	# Find work_mode from groups section by matching group_id
	if [ -n "${group_id}" ]; then
		local section_name=$(uci -q show ovpnclient | grep "@groups\[.*\]\.group_id='${group_id}'" | cut -d "." -f2)
		[ -n "${section_name}" ] && work_mode=$(uci -q get ovpnclient."${section_name}".work_mode)
	fi

	[ -f "$ovpn_cfg" ] || {
		proto_notify_error "$interface" CONFIG_NOT_FOUND
		exit 1
	}

	[ -d "/tmp/ovpnclient" ] || mkdir -p "/tmp/ovpnclient"
	apply_cfg="/tmp/ovpnclient/${interface}"
	rm -f "${apply_cfg}"

	[ -n "$(cat "${ovpn_cfg}"|grep 'dev-type'|grep tap)" ] && dev_type="tap"

	# set mtu if dev-type is tun.
	[ "${dev_type}" = 'tun' ] && {
		mtu="$(uci -q get network.${interface}.mtu)"
		[ -z "$mtu" ] && mtu="$(cat "${ovpn_cfg}" | grep -iE "^tun-mtu($|[[:space:]])" | awk -F ' ' '{print $2}')"
		[ -n "$mtu" ] && set_mtu="--pull-filter ignore tun-mtu --tun-mtu ${mtu}"
	}
	#copy the raw file and fix some options
	#remove option daemon dev and dev-type
	sed  -e '/^daemon/d'  -e '/^dev /d' -e '/^dev-type/d' -e '/^tun-mtu/d' "${ovpn_cfg}" > "${apply_cfg}"

	echo "connecting" > ${apply_cfg}_state

	if [ -x /usr/bin/vpn-failover-trigger.sh ] && \
	   /usr/bin/vpn-failover-trigger.sh check "$interface" >/dev/null 2>&1 && \
	   [ -x /usr/bin/vpn-failover-watcher.sh ]; then
		/usr/bin/vpn-failover-watcher.sh \
			"$interface" "${apply_cfg}_state" 30 >/dev/null 2>&1 &
	fi

	work_mode=${work_mode:-"modern"}

	# set data-ciphers if not already in config
	if [ -z "$(grep "data-ciphers" ${apply_cfg})" ] ; then
		local base_ciphers="AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305"
		if [ "$work_mode" = "legacy" ]; then
			local cbc_cipher=$(grep '^cipher ' ${apply_cfg} | awk '{print $2}' | grep 'AES-.*-CBC' | tail -n1)
			data_cipher_option="--data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305${cbc_cipher:+:$cbc_cipher}"
			# Disable DCO (Data Channel Offload) in legacy mode for compatibility,
			# as legacy configurations may not support DCO or require features incompatible with DCO.
			disable_dco="--disable-dco"
		else
			data_cipher_option="--data-ciphers ${base_ciphers}"
		fi
	fi

	if [ "$(uci -q get glipv6.globals.enabled)" != 1 ]; then
		ipv6_pull_filter="--pull-filter ignore ifconfig-ipv6"
	fi

	local up_parameter=''
	up_parameter="${up_parameter} ${set_mtu:+mtu_is_set=1}"

	local mute_option
	[ "$(cat $apply_cfg | grep mute)" = "" ] && mute_option="--mute 5"

	# Prevent potential crashes caused by conflicts between dco and the crypto_safexcel module
	rmmod crypto_safexcel 2>/dev/null

	proto_run_command "$interface" /usr/sbin/openvpn \
		--syslog "$interface" \
		--dev "${interface}" \
		--dev-type "${dev_type}" \
		--route-delay 2 \
		--route-noexec $mute_option\
		--writepid "/var/run/ovpnclient-${interface}.pid" \
		--script-security 3 \
		--config "${apply_cfg}" \
		--remap-usr1 SIGHUP \
		--up "/etc/openvpn/scripts/ovpnclient-up ${interface} \"${up_parameter}\"" \
		--ipchange "/etc/openvpn/scripts/ovpnclient-ipchange ${interface}" \
		--down "/etc/openvpn/scripts/ovpnclient-down ${interface}" \
		${ipv6_pull_filter} \
		${data_cipher_option} \
		${set_mtu} \
		${disable_dco} \
		--mark 32768 --allow-recursive-routing \
		--remote-random

	trap - EXIT INT TERM
}

teardown_update_status()
{
	client_info_dir="/var/ovpnclient"
	[ -d ${client_info_dir} ] || mkdir -p ${client_info_dir}

	local interface=$1
	uci -q -c ${client_info_dir} set status_table.${interface}.active='0'
	uci -q -c ${client_info_dir} commit status_table
}

proto_ovpnclient_teardown() {
	local interface="$1"
	local disabled=1  # default: no section -> disabled
	local pid="$(cat /var/run/ovpnclient-${interface}.pid 2>/dev/null)"
	local client_tap=$(uci -q get ovpnclient.$(uci -q get network.${interface}.config).mode)

	if uci -q get network.${interface} >/dev/null; then
		disabled="$(uci -q get network.${interface}.disabled || echo 0)"
	fi

	if [ "$disabled" = "0" ]; then
		echo "connecting" > /tmp/ovpnclient/${interface}_state
	else
		rm -f /tmp/ovpnclient/${interface}_state
	fi

	if [ -f /tmp/run/disconnect_lan_flag ]; then
		disconnect_lan_clients &
		rm -f /tmp/run/disconnect_lan_flag
	fi

	if [ "$client_tap" != tap-s2s -a "$client_tap" != tap ]; then
		# teardown must not be blocked for more than 5 seconds
		/usr/bin/rtp2.sh 'interface_status_change' "${interface}" 'down' 2>/dev/null &
	fi
	rm -f /tmp/run/ovpn_resolved_ip/${interface}
	#openvpn exiting due fatal error, block proro restart
	[ -z "$pid" ] && {
		#proto_init_update "$interface" 1
		#proto_setup_failed "$interface"
		#proto_block_restart
		#proto_send_update "$interface"
		#proto_notify_error "$interface" OPENVPN_EXITING_DUE_FATAL_ERROR
		logger 'openvpn process exit and try again 5 seconds later'
		sleep 5
	}
	[ -n "$pid" ] && {
		kill -15 "$pid" 2>/dev/null
		rm -f /var/run/ovpnclient-ovpnclient.pid
		ip link del dev "$interface" 2>/dev/null
	}

	teardown_update_status ${interface}
}

[ -n "$INCLUDE_ONLY" ] || {
	add_protocol ovpnclient
}
