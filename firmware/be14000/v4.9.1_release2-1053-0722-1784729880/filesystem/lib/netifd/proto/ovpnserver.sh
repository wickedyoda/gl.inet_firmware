#!/bin/sh
. /lib/functions/gl_util.sh

[ -x /usr/sbin/openvpn ] || exit 0

[ -n "$INCLUDE_ONLY" ] || {
	. /lib/functions.sh
	. ../netifd-proto.sh
	init_proto "$@"
}

proto_ovpnserver_init_config() {
	no_device=1
	available=1
}

add_iroute_rules() {
	local route_flag
	local dest
	local mask
	local gateway
	local vpn_mask="$2"
	local vpn_subnet="$3"

	local ccd_dir=/etc/openvpn/ccd
	local iroute_cfg=/etc/openvpn/ccd/DEFAULT

	[ -d "$ccd_dir" ] || mkdir -p "$ccd_dir"

	config_get route_flag "$1" "route_flag"
	config_get dest "$1" "dest"
	config_get mask "$1" "mask"
	config_get gateway "$1" "gateway"

	if [ $route_flag = "4" ]; then
		if [ -n "$gateway" ]; then
			gateway_subnet=$(ipcalc_network $gateway $vpn_mask | awk -F= '/NETWORK/{print $2}')
			[ $vpn_subnet != $gateway_subnet ] && return
		fi

		dest_ip=$(ipcalc_network $dest $mask | awk -F= '/NETWORK/{print $2}')
		netmask=$(ipcalc_network $dest $mask | awk -F= '/NETMASK/{print $2}')
		echo "iroute $dest_ip $netmask" >> $iroute_cfg
	elif [ $route_flag = "6" ]; then
		echo "iroute-ipv6 $dest/$mask" >> $iroute_cfg
	fi
}

load_config() {
	local cfg="$1"
	local auth
	local proto
	local port
	local dev
	local dev_type
	local cipher
	local comp
	local subnetv4
	local subnetv6
	local mask
	local start
	local end
	local verb
	local ca
	local key
	local cert
	local dh
	local ta
	local server
	local server_ipv6
	local global_ipv6_enable
	local lzo
	local compress
	local client_to_client
	local client
	local hmac
	local client_auth
	local tap_address
	local tap_mask
	local mtu

	config_load glipv6
	config_get global_ipv6_enable "globals" "enabled"

	local config
	config_load network
	config_get config "${interface}" "config"
	[ "$config" = "" ] && {
			config="vpn"
			uci set network.ovpnserver.config="$config"
			uci commit network
	}

	config_load ovpnserver

	config_get auth "${config}" "auth"
	config_get proto "${config}" "proto"
	config_get port "${config}" "port"
	config_get dev "${config}" "dev"
	config_get dev_type "${config}" "dev_type"
	config_get cipher "${config}" "cipher"
	config_get comp "${config}" "comp"
	config_get subnetv4 "${config}" "subnetv4"
	config_get subnetv6 "${config}" "subnetv6"
	config_get mask "${config}" "mask"
	config_get start "${config}" "start"
	config_get end "${config}" "end"
	config_get verb "${config}" "verb"
	config_get lzo "${config}" "lzo"
	config_get client_to_client "${config}" "client_to_client"
	config_get hmac "${config}" "hmac"
	config_get client_auth "${config}" "client_auth"
	config_get tap_address "${config}" "tap_address"
	config_get tap_mask "${config}" "tap_mask"
	config_get fwmark "${config}" "fwmark" ""
	config_get mtu "global" "mtu"

	if [ "${dev_type}" = "tun" -o "${dev_type}" = "tap-s2s" ]; then
		server="server ${subnetv4} ${mask:="255.255.255.0"}"
	elif [ "${dev_type}" = "tap" ]; then
		server="server-bridge ${tap_address} ${tap_mask:="255.255.255.255"} ${start} ${end}"
	fi

	if [ "${lzo}" = "1" ]; then
		compress="comp-lzo"
	fi

	if [ "${client_to_client}" = "1" ]; then
		client="client-to-client"
	fi
	if [ "$dev_type" = "tap-s2s" ]; then
		dev_type=tap
	fi

	# Compatibility: try legacy syntax first, fallback to CIDR
	eval "$(ipcalc.sh "${subnetv4}" "${mask:="255.255.255.0"}" "1" 2>/dev/null)"
	if [ -z "$START" ]; then
		eval "$(ipcalc.sh "${subnetv4}/${mask:="255.255.255.0"}" "1" "254")"
	fi
	local default_dns_v4="${START}"

	local default_dns_v6=$(gl_ipcalc "${subnetv6}" 6)

	local redirect_gateway="redirect-gateway def1"
	[ "${global_ipv6_enable}" = "1" ] && redirect_gateway="redirect-gateway def1 ipv6"

cat > ${cfg} << EOF
${client}
persist-key
persist-tun
auth ${auth:="SHA256"}
data-ciphers ${cipher}:AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305
dev ${dev:="ovpnserver"}
dev-type ${dev_type:="tun"}
group nogroup
keepalive 10 120
mode server
mute 5
port ${port:="1194"}
proto ${proto:="udp"}
push "persist-key"
push "persist-tun"
push "${redirect_gateway}"
push "dhcp-option DNS $default_dns_v4"
route-gateway dhcp
client-config-dir /etc/openvpn/ccd
topology subnet
duplicate-cn
user nobody
multihome
verb ${verb:="3"}
${server}
${compress}
EOF
	[ -n "$fwmark" ] && echo "mark $fwmark" >> ${cfg}
	[ "${global_ipv6_enable}" = "1" ] && {
		[ "${dev_type}" = "tun" -a "${subnetv6}" != "" ] && echo "server-ipv6 ${subnetv6}" >> ${cfg}
		echo "proto ${proto:="udp"}6" >> ${cfg}
		local model="$(get_model)"
		[ "${model}" = 'axt1800' -o "${model}" = 'ax1800' ] && echo "disable-dco" >> ${cfg}
		[ -n "${default_dns_v6}" ] && echo "push \"dhcp-option DNS6 ${default_dns_v6}\"" >> ${cfg}
	}
	if [ "${client_auth}" = "2" ]; then
		echo "script-security 3" >> ${cfg}
		echo "auth-user-pass-verify /etc/openvpn/scripts/checkpsw.sh via-env" >> ${cfg}
		echo "verify-client-cert none" >> ${cfg}
		echo "username-as-common-name" >> ${cfg}
	elif [ "${client_auth}" = "3" ]; then
		echo "script-security 3" >> ${cfg}
		echo "auth-user-pass-verify /etc/openvpn/scripts/checkpsw.sh via-env" >> ${cfg}
		echo "username-as-common-name" >> ${cfg}
	fi

	if [ -n "$mtu" ] ;then
		echo "tun-mtu $mtu" >> ${cfg}
	else
		echo "tun-mtu 1428" >> ${cfg}
	fi
	ca="$(cat /etc/openvpn/cert/ca.crt)"
	cert="$(cat /etc/openvpn/cert/server.crt)"
	key="$(cat /etc/openvpn/cert/server.key)"
	dh="$(cat /etc/openvpn/cert/dh1024.pem)"
	ta="$(cat /etc/openvpn/cert/ta.key)"

	[ -n "${ca}" ] && {
		echo "<ca>" >> ${cfg}
		echo "${ca}" >> ${cfg}
		echo "</ca>" >> ${cfg}
	}

	[ -n "${cert}" ] && {
		echo "<cert>" >> ${cfg}
		echo "${cert}" >> ${cfg}
		echo "</cert>" >> ${cfg}
	}

	[ -n "${key}" ] && {
		echo "<key>" >> ${cfg}
		echo "${key}" >> ${cfg}
		echo "</key>" >> ${cfg}
	}
	if [ -n "$(grep SAyVAhdDpHkJ5rAgEC /etc/openvpn/cert/dh1024.pem)" ]; then
		echo "dh none" >>${cfg}
	else
		[ -n "${dh}" ] && {
			echo "<dh>" >> ${cfg}
			echo "${dh}" >> ${cfg}
			echo "</dh>" >> ${cfg}
		}
	fi

	if [ "${hmac}" = "1" ]; then
		echo "<tls-auth>" >> ${cfg}
		echo "${ta}" >> ${cfg}
		echo "</tls-auth>" >> ${cfg}
	fi

	[ -f "/etc/openvpn/ccd/DEFAULT" ] && rm "/etc/openvpn/ccd/DEFAULT"
	config_foreach add_iroute_rules route_rules $mask $subnetv4
}

proto_ovpnserver_setup() {
	local interface="$1"
	local ovpn_cfg="/tmp/ovpnserver/${interface}"

	[ -d "/var/log/ovpnserver" ] || mkdir -p "/var/log/ovpnserver"
	[ -d "/tmp/ovpnserver" ] || mkdir -p "/tmp/ovpnserver"

	rm -f "$ovpn_cfg"
	load_config "$ovpn_cfg"

	# do something like set firewall
	/etc/openvpn/scripts/before_ovpnserver_instance_up.sh "${interface}"

	# Prevent potential crashes caused by conflicts between dco and the crypto_safexcel module
	rmmod crypto_safexcel 2>/dev/null

	#set -x
	proto_run_command "$interface" /usr/sbin/openvpn \
		--syslog 'ovpnserver' \
		--writepid "/var/run/ovpnserver-${interface}.pid" \
		--script-security 2 \
		--config "${ovpn_cfg}" \
		--up "/etc/openvpn/scripts/ovpnserver-up $interface"
		#--pull-filter ignore ifconfig-ipv6 \
		#--pull-filter ignore route-ipv6
	#set +x
}

proto_ovpnserver_teardown() {
	local interface="$1"

	#killall -9 openvpn
	proto_kill_command "$interface"

	# do something like set_firewall
	/etc/openvpn/scripts/after_ovpnserver_instance_down.sh "${interface}"
}

[ -n "$INCLUDE_ONLY" ] || {
	add_protocol ovpnserver
}

