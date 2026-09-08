#!/bin/sh
# Copyright 2016-2017 Dan Luedtke <mail@danrl.com>
# Licensed to the public under the Apache License 2.0.

WG=/usr/bin/wg
if [ ! -x $WG ]; then
	logger -t "wireguard" "error: missing wireguard-tools (${WG})"
	exit 0
fi

APPEND_CONF_DIR="/etc/wireguard/profile"

[ -n "$INCLUDE_ONLY" ] || {
	. /lib/functions.sh
	. ../netifd-proto.sh
	init_proto "$@"
}

proto_wgserver_init_config() {
	proto_config_add_int "config"
	available=1
	no_proto_task=1
}

detect_route_allowed(){
	local config="$1"
	local detect="$2"
	local gateway
	local mask
	local dest
	config_get gateway "$config" "gateway"

	[ -n "$( echo "$detect" | grep -oE '\b(:?[0-9a-fA-F]{0,4}:){1,7}[0-9a-fA-F]{0,4}(/[0-9]{1,3})?\b')" ] && [ -n "$(which sipcalc)" ] && detect=$(sipcalc "$detect" 2>/dev/null | grep -E "^Expanded Address" | awk '{print $4}')
	[ -n "$( echo "$gateway" | grep -oE '\b(:?[0-9a-fA-F]{0,4}:){1,7}[0-9a-fA-F]{0,4}(/[0-9]{1,3})?\b')" ] && [ -n "$(which sipcalc)" ] && gateway=$(sipcalc "$gateway" 2>/dev/null | grep -E "^Expanded Address" | awk '{print $4}')

	[ "$detect" = "$gateway" ] && {
		config_get dest "$config" "dest"
		config_get mask "$config" "mask"
		echo "AllowedIPs=${dest}/${mask}" >> "${wg_cfg}"
	}
}

add_route_rules() {
	local route_flag
	local dest
	local mask
	local gateway
	local metric
	local mtu
	local scope

	config_get route_flag "$1" "route_flag"
	config_get dest "$1" "dest"
	config_get mask "$1" "mask"
	config_get gateway "$1" "gateway"
	config_get metric "$1" "metric"
	config_get mtu "$1" "mtu"
	config_get scope "$1" "scope"

	logger -t wgserver-route "route_flag=$route_flag, dest=$dest, mask=$mask, gateway=$gateway, metric=$metric, mtu=$mtu"

	if [ $route_flag = "4" ]; then
		if [ "$scope" = 'nowhere' ] ;then
			ip route add blackhole "$dest"/"$mask"
		else
			#proto_add_ipv4_route "$dest" "$mask" "$gateway" "" "$metric"
			ip route add "$dest"/"$mask" ${gateway:+via $gateway} dev "wgserver" ${scope:+scope $scope} ${mtu:+mtu $mtu} ${metric:+metric $metric}
		fi
	elif [ $route_flag = "6" ]; then
		if [ "$scope" = 'nowhere' ] ;then
			ip -6 route add blackhole "$dest"/"$mask"
		else
			ip -6 route add "$dest"/"$mask" ${gateway:+via $gateway} dev "wgserver" ${scope:+scope $scope} ${mtu:+mtu $mtu} ${metric:+metric $metric}
			#proto_add_ipv6_route "$dest" "$mask" "$gateway" "$metric"
		fi
	fi
}

get_peer_allow_ips()
{
    local tmp_allow_ips client_ips tmp_ip val
    val=$1
    client_ips=$2

    while [ "X$client_ips" != "X$tmp_ip" ]
    do
        local ip
        tmp_ip=`echo ${client_ips%%,*}`
        ip=`echo ${tmp_ip%%/*}`
        if [ "X$tmp_allow_ips" = 'X' ]
            then
                tmp_allow_ips=${ip}
            else
                tmp_allow_ips="${tmp_allow_ips},${ip}"
            fi
        client_ips=`echo ${client_ips##*,}`
        [ -n ${ip} ] && config_foreach detect_route_allowed route_rules ${ip}
    done
    eval "$val=${tmp_allow_ips}"
}

load_peers() {
	local config="$1"

	local public_key
	local preshared_key
	local client_ip
	local allowed_ips
	local deprecated
	local enabled

	config_get public_key "${config}" "public_key"
	config_get preshared_key "${config}" "presharedkey"
	config_get client_ip "${config}" "client_ip"
	config_get deprecated "${config}" "deprecated" "0"
	config_get enabled "${config}" "enabled" "1"

	[ "$deprecated" != "0" ] && return 0
	[ "$enabled" != "1" ] && return 0

	echo "[Peer]" >> "${wg_cfg}"
	echo "PublicKey=${public_key}" >> "${wg_cfg}"
	if [ "${preshared_key}" ]; then
		echo "PresharedKey=${preshared_key}" >> "${wg_cfg}"
	fi

	get_peer_allow_ips allowed_ips $client_ip
	echo "AllowedIPs=$allowed_ips" >> "${wg_cfg}"
	config_foreach detect_route_allowed route_rules ${client_ip%%/*}

	echo "PersistentKeepalive=0" >> "${wg_cfg}"

}

proto_wgserver_setup() {
	local interface="$1"
	local wg_dir="/tmp/wireguard"
	local wg_cfg="${wg_dir}/${interface}"

	local config

	local public_key
	local private_key
	local listen_port
	local fwmark
	local address_v4
	local address_v6
	local mtu
	local type
	local dev_type='wireguard'

	local ipv6_enable="$(uci -q get glipv6.globals.enabled)"

	config_load network
	config_get config "${interface}" "config"

	ip link del dev "${interface}" 2>/dev/null

	umask 077
	mkdir -p "${wg_dir}"

	config_load wireguard_server
	config_get public_key "${config}" "public_key"
	config_get private_key "${config}" "private_key"
	config_get listen_port "${config}" "port"
	config_get fwmark "${config}" "fwmark" ""
	config_get address_v4 "${config}" "address_v4"
	config_get address_v6 "${config}" "address_v6"
	config_get mtu "${config}" "mtu"
	config_get type "${config}" "type" '0'

	rm -f "${wg_cfg}"
	echo "[Interface]" > "${wg_cfg}"
	echo "PrivateKey=${private_key}" >> "${wg_cfg}"
	if [ "${listen_port}" ]; then
		echo "ListenPort=${listen_port}" >> "${wg_cfg}"
	fi
	if [ "${fwmark}" ]; then
		echo "FwMark=${fwmark}" >> "${wg_cfg}"
	fi

	case "${type}" in
		"1")
			dev_type="amneziawg"
			WG=/usr/bin/awg
			if [ ! -x $WG ]; then
				logger -t "wireguard" "error: missing wireguard-tools (${WG})"
				exit 0
			fi
			ln -sf /usr/bin/awg /usr/bin/gl_wg
			echo "$(grep -iE '^(jc|jmax|jmin|s1|s2|s3|s4|h1|h2|h3|h4|i1|i2|i3|i4|i5)\b' ${APPEND_CONF_DIR}/wgserver/${config} 2>/dev/null)" >> "${wg_cfg}"
			;;
		*)
			dev_type="wireguard"
			ln -sf /usr/bin/wg /usr/bin/gl_wg
			;;
	esac

	config_foreach load_peers  peers

	ip link add dev "${interface}" type "${dev_type}"
	proto_init_update "${interface}" 1

	[ -n "$mtu" ] && ip link set mtu "$mtu" "${interface}"

	# do something like set firewall
	/etc/wireguard/scripts/before_wgserver_ifup.sh "${interface}"

	# apply configuration file
	${WG} setconf ${interface} "${wg_cfg}"
	WG_RETURN=$?

	if [ ${WG_RETURN} -ne 0 ]; then
		sleep 5
		proto_setup_failed "${interface}"
		exit 1
	fi

	if [ "$address_v4" ];then
		case "${address_v4}" in
			*.*/*)
				proto_add_ipv4_address "${address_v4%%/*}" "${address_v4##*/}"
				;;
			*.*)
				proto_add_ipv4_address "${address_v4%%/*}" "32"
				;;
		esac
	fi
	if [ "$ipv6_enable" = "1" ] && [ "$address_v6" != "" ];then
		case "${address_v6}" in
			*:*/*)
				proto_add_ipv6_address "${address_v6%%/*}" "${address_v6##*/}"
				;;
			*:*)
				proto_add_ipv6_address "${address_v6%%/*}" "128"
				;;
		esac
	fi

	# add custom route rules
	#config_foreach add_route_rules route_rules

	proto_send_update "${interface}"
	config_foreach add_route_rules route_rules
}

proto_wgserver_teardown() {
	local interface="$1"
	ip link del dev "${interface}" >/dev/null 2>&1

	# do something like set firewall
	/etc/wireguard/scripts/after_wgserver_if_down.sh "${interface}"
}

[ -n "$INCLUDE_ONLY" ] || {
	add_protocol wgserver
}
