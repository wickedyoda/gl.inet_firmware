#!/bin/sh

# include netifd library
. /lib/netifd/netifd-proto.sh

interface="$1"

logger -t wgserver-route "env value:"`env`

add_route_rules()
{
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
		#proto_add_ipv4_route "$dest" "$mask" "$gateway" "" "$metric"
		ip route add "$dest"/"$mask" ${gateway:+via $gateway} dev "wgserver" ${scope:+scope $scope} ${mtu:+mtu $mtu} ${metric:+metric $metric}
	elif [ $route_flag = "6" ]; then
		#proto_add_ipv6_route "$dest" "$mask" "$gateway" "$metric"
		ip -6 route add "$dest"/"$mask" ${gateway:+via $gateway} dev "wgserver" ${scope:+scope $scope} ${mtu:+mtu $mtu} ${metric:+metric $metric}
	fi
}

add_custom_route_settings()
{
	. /lib/functions.sh

	config_load wireguard_server
	config_foreach add_route_rules route_rules
	ifup $interface
}

proto_init_update "${interface}" 1
proto_set_keep 1
#add_custom_route_settings
proto_send_update "${interface}"
add_custom_route_settings
exit 0
