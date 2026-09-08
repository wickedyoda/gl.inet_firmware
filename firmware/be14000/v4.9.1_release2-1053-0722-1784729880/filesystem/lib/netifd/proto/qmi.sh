#!/bin/sh

UQMI="uqmi -t 3000"
[ -n "$INCLUDE_ONLY" ] || {
	. /lib/functions.sh
	. /lib/functions/modem.sh
	. ../netifd-proto.sh
	init_proto "$@"
}

set_log_level "$(get_modem_log_level)"

proto_qmi_init_config() {
	available=1
	no_device=1
	proto_config_add_string "device:device"
	proto_config_add_string iccid
	proto_config_add_string ip_type
	proto_config_add_string node
	proto_config_add_boolean dhcpv6
	proto_config_add_boolean autoconnect
	proto_config_add_int mtu
	proto_config_add_int apn_use
	proto_config_add_string bus
	proto_config_add_string date
	proto_config_add_int slot
	proto_config_add_defaults
}

proto_qmi_setup() {
	local interface="$1"
	local devname=""
	local dataformat connstat
	local device apn auth username password iccid delay modes ip_type node
	local profile dhcpv6 autoconnect plmn timeout mtu $PROTO_DEFAULT_OPTIONS
	local ip4table ip6table
	local cid_4 pdh_4 cid_6 pdh_6
	local ip_6 ip_prefix_length gateway_6 dns1_6 dns2_6
	local bus slot apn_use manual 

	json_get_vars device iccid bus slot apn_use apn
	json_get_vars ip_type dhcpv6 autoconnect ip4table node
	json_get_vars ip6table timeout mtu $PROTO_DEFAULT_OPTIONS

    if ! bus_exists_in_modem "$bus"; then
        log_debug $LINENO "modem" "bus[$bus] not ready, exit dial!"
        proto_block_restart "$interface"
		proto_notify_error "$interface" NO_DEVICE
	    set_interface_dial_progress "$interface" "2"
	    return 0
    fi

    local current_slot
	current_slot="$(get_current_sim_slot "$bus")"
	log_debug $LINENO "modem" "Current SIM slot on bus[$bus] is [$current_slot]"

	if [ -z "$current_slot" ] || [ "$current_slot" != "$slot" ]; then
		log_info $LINENO "modem" "Current SIM slot [$current_slot] does not match requested slot [$slot], exiting execution."
		proto_block_restart "$interface"
		set_interface_dial_progress "$interface" "2"
		return 1
	fi

    log_info $LINENO "modem" "start dialing for bus[$bus] slot[$slot]"
	local dial_status
	dial_status="$(get_dial_status_retry "$bus" "$slot" 3)" || {
    	    log_debug $LINENO "modem" "Dial status unavailable, defer dialing"
    	    return 1
	}

        log_debug $LINENO "modem" "Current dialing status $dial_status"
	if [ "$dial_status" != "7" ];then
		log_info $LINENO "modem" "Current status $dial_status does not meet dialing requirements, exiting execution."
		proto_block_restart "$interface"
		set_interface_dial_progress "$interface" "2"
		return 1
	fi
	
	manual=$(get_sim_map_field "$iccid" manual)
	if [ "$manual" = "true" ];then
		ip_type=$(get_sim_map_field "$iccid" ip_type)
		apn=$(get_sim_map_field "$iccid" apn)
		mtu=$(get_sim_map_field "$iccid" mtu)
		auth=$(get_sim_map_field "$iccid" auth)
		username=$(get_sim_map_field "$iccid" username)
		password=$(get_sim_map_field "$iccid" password)
	fi

	#profile=$(get_sim_map_field "$iccid" cid)
	profile=$apn_use

    log_info $LINENO "modem" "manual:$manual ip_type:$ip_type apn:$apn auth:$auth username:$username password:$password mtu:$mtu profile:$profile"
	[ "$timeout" = "" ] && timeout="10"

	[ "$metric" = "" ] && metric="0"

	[ -n "$ctl_device" ] && device=$ctl_device

	[ -n "$node" ] && {
		devpath="$(find  /sys/devices/ -name "$node")"
		devname="$(find "$devpath" -name  "cdc-wdm*"|head -n 1)"
		[ -n "$devname" ] && {
			devname=/dev/"$(basename "$devname")"
			#fix config
			[ "$devname" = "$device" ] || {
					uci set network."$interface".device="${devname}"
					uci commit
					device="$devname"
			}
		}
	}

	[ -n "$device" ] || {
		log_error $LINENO "modem" "No control device specified."
		proto_notify_error "$interface" NO_DEVICE
		proto_set_available "$interface" 0
		set_interface_dial_progress "$interface" "2"
		return 1
	}

	[ -n "$delay" ] && sleep "$delay"

	device="$(readlink -f $device)"
	[ -c "$device" ] || {
		log_error $LINENO "modem" "The specified control device does not exist."
		proto_notify_error "$interface" NO_DEVICE
		proto_set_available "$interface" 0
		set_interface_dial_progress "$interface" "2"
		return 1
	}

	devname="$(basename "$device")"
	devpath="$(readlink -f /sys/class/usbmisc/$devname/device/)"
	ifname="$( ls "$devpath"/net )"
	[ -n "$ifname" ] || {
		log_error $LINENO "modem" "The interface could not be found."
		proto_notify_error "$interface" NO_IFACE
		#proto_set_available "$interface" 0 #Ifup-failed is triggered when the configuration is wrong, which is consistent with 3g and qcm
		set_interface_dial_progress "$interface" "2"
		return 1
	}

    if [ -n "$mtu" ];then
		log_info $LINENO "modem" "Setting ifname $ifname MTU to $mtu"
		/sbin/ip link set dev $ifname mtu $mtu
	else
        log_info $LINENO "modem" "Setting ifname $ifname MTU to default 1500"
		/sbin/ip link set dev $ifname mtu 1500
	fi

	log_info $LINENO "modem" "Waiting for SIM initialization..."
	local init_res

	for i in $(seq 3); do 
		 init_res=$(uqmi -s -t 3000 -d $device --get-pin-status)
		 if [ "$init_res" != '"Failed to connect to service"' ]; then
			break
		 fi
	done

	if [ "$init_res" = '"Failed to connect to service"' ]; then
		log_error $LINENO "modem" "Connect to service Failed."
		set_interface_dial_progress "$interface" "3"
		return 1
	fi

	if [ -n "$(echo $init_res | grep '"UIM uninitialized"' > /dev/null)" ]; then
		[ -e "$device" ] || return 1
		log_error $LINENO "modem" "SIM not initialized."
		proto_notify_error "$interface" SIM_NOT_INITIALIZED
		proto_block_restart "$interface"
		set_interface_dial_progress "$interface" "3"
		return 1
	fi

	[ -n "$plmn" ] && {
		local mcc mnc
		if [ "$plmn" = 0 ]; then
			mcc=0
			mnc=0
			log_info $LINENO "modem" "Setting PLMN to auto"
		else
			#mcc=${plmn:0:3}
			mcc=$(echo $plmn | cut -c1-3)
			#mnc=${plmn:3}
			if [ ${#plmn} -eq 5 ];then
			    mnc=$(echo $plmn | cut -c4-5)
			else
			    mnc=$(echo $plmn | cut -c4-6)
			fi
			log_info $LINENO "modem" "Setting PLMN to $plmn"
		fi
		$UQMI -s -d "$device" --set-plmn --mcc "$mcc" --mnc "$mnc" > /dev/null 2>&1 || {
			log_error $LINENO "modem" "Unable to set PLMN."
			proto_notify_error "$interface" PLMN_FAILED
			proto_block_restart "$interface"
			set_interface_dial_progress "$interface" "3"
			return 1
		}
	}

	# Cleanup current state if any
	$UQMI -s -d "$device" --stop-network 0xffffffff --autoconnect > /dev/null 2>&1

	# Set IP format
	$UQMI -s -d "$device" --set-data-format 802.3 > /dev/null 2>&1
	$UQMI -s -d "$device" --wda-set-data-format 802.3 > /dev/null 2>&1
	dataformat="$($UQMI -s -d "$device" --wda-get-data-format)"

	if [ "$dataformat" = '"raw-ip"' ]; then
		if [ -f /sys/class/net/$ifname/qmi/raw_ip ];then
			echo "Y" > /sys/class/net/$ifname/qmi/raw_ip
		else
			log_info $LINENO "modem" "Device only supports raw-ip mode but is missing this required driver attribute: /sys/class/net/$ifname/qmi/raw_ip."
		fi
	elif [ -n "`echo "$dataformat" | grep Failed`" ];then
		log_error $LINENO "modem" "Failed to connect to service."
		set_interface_dial_progress "$interface" "3"
		return 1
	else
		if [ -f /sys/class/net/$ifname/qmi/raw_ip ];then
			echo "N" > /sys/class/net/$ifname/qmi/raw_ip
		else
			log_info $LINENO "modem" "Device only supports 802.3 mode but is missing this required driver attribute: /sys/class/net/$ifname/qmi/raw_ip."
		fi		
	fi

	$UQMI -s -d "$device" --sync > /dev/null 2>&1

	[ -n "$modes" ] && $UQMI -s -d "$device" --set-network-modes "$modes" > /dev/null 2>&1

	log_info $LINENO "modem" "Starting network $interface ..."
	
	if [ "$manual" = "true" ];then
		pdptype=$(convert_ip_type $ip_type)
	else
		pdptype=$ip_type
	fi

        log_info $LINENO "modem" "Set ip type:$pdptype"
	if [ "$pdptype" = "IP" ]; then
		[ -z "$autoconnect" ] && autoconnect=1
		[ "$autoconnect" = 0 ] && autoconnect=""
	else
		[ "$autoconnect" = 1 ] || autoconnect=""
	fi

    [ "$auth" = "PAP/CHAP" ] && auth="both"
	
	[ "$profile" = "" ] && profile=$(check_apn $bus $slot)
    
	[ "$pdptype" = "IP" -o "$pdptype" = "IPV4V6" ] && {
		cid_4=$($UQMI -s -d "$device" --get-client-id wds)
		if ! [ "$cid_4" -eq "$cid_4" ] 2> /dev/null; then
			log_error $LINENO "modem" "Unable to obtain client ID"
			proto_notify_error "$interface" NO_CID
			set_interface_dial_progress "$interface" "3"
			return 1
		fi

		$UQMI -s -d "$device" --set-client-id wds,"$cid_4" --set-ip-family ipv4 > /dev/null 2>&1

		pdh_4=$($UQMI -s -d "$device" --set-client-id wds,"$cid_4" \
			--start-network \
			${apn:+--apn $apn} \
			${profile:+--profile $profile} \
			${auth:+--auth-type $auth} \
			${username:+--username $username} \
			${password:+--password $password} \
			${autoconnect:+--autoconnect})

		# pdh_4 is a numeric value on success
		if ! [ "$pdh_4" -eq "$pdh_4" ] 2> /dev/null; then
			log_error $LINENO "modem" "Unable to connect IPv4"
			
			$UQMI -s -d "$device" --set-client-id wds,"$cid_4" --release-client-id wds > /dev/null 2>&1
			proto_notify_error "$interface" CALL_FAILED
			set_interface_dial_progress "$interface" "3"
			return 1
		fi

		# Check data connection state
		connstat=$($UQMI -s -d "$device" --get-data-status)
		[ "$connstat" = '"connected"' ] || {
			log_error $LINENO "modem" "No data link!"
			$UQMI -s -d "$device" --set-client-id wds,"$cid_4" --release-client-id wds > /dev/null 2>&1
			proto_notify_error "$interface" CALL_FAILED
			set_interface_dial_progress "$interface" "3"
			return 1
		}
	}

	[ "$pdptype" = "IPV6" -o "$pdptype" = "IPV4V6" ] && {
		cid_6=$($UQMI -s -d "$device" --get-client-id wds)
		if ! [ "$cid_6" -eq "$cid_6" ] 2> /dev/null; then
			log_error $LINENO "modem" "Unable to obtain client ID"
			proto_notify_error "$interface" NO_CID
			set_interface_dial_progress "$interface" "3"
			return 1
		fi

		$UQMI -s -d "$device" --set-client-id wds,"$cid_6" --set-ip-family ipv6 > /dev/null 2>&1

		pdh_6=$($UQMI -s -d "$device" --set-client-id wds,"$cid_6" \
			--start-network \
			${apn:+--apn $apn} \
			${profile:+--profile $profile} \
			${auth:+--auth-type $auth} \
			${username:+--username $username} \
			${password:+--password $password} \
			${autoconnect:+--autoconnect})

		# pdh_6 is a numeric value on success
		if ! [ "$pdh_6" -eq "$pdh_6" ] 2> /dev/null; then
			log_error $LINENO "modem" "Unable to connect IPv6"
			$UQMI -s -d "$device" --set-client-id wds,"$cid_6" --release-client-id wds > /dev/null 2>&1
			proto_notify_error "$interface" CALL_FAILED
			set_interface_dial_progress "$interface" "3"
			[ "$pdptype" = "IPV6" ] && {
				return 1
			}
		fi

		# Check data connection state
		connstat=$($UQMI -s -d "$device" --set-client-id wds,"$cid_6" --get-data-status)
		[ "$connstat" = '"connected"' ] || {
			log_error $LINENO "modem" "No data link!"
			$UQMI -s -d "$device" --set-client-id wds,"$cid_6" --release-client-id wds > /dev/null 2>&1
			proto_notify_error "$interface" CALL_FAILED
			set_interface_dial_progress "$interface" "3"
			return 1
		}
	}

	log_info $LINENO "modem" "Setting up $ifname"
	
	proto_init_update "$ifname" 1
	proto_set_keep 1
	proto_add_data
	[ -n "$pdh_4" ] && {
		json_add_string "cid_4" "$cid_4"
		json_add_string "pdh_4" "$pdh_4"
	}
	[ -n "$pdh_6" ] && {
		json_add_string "cid_6" "$cid_6"
		json_add_string "pdh_6" "$pdh_6"
	}
	proto_close_data
	proto_send_update "$interface"

	local zone="$(fw3 -q network "$interface" 2>/dev/null)"

	[ -n "$pdh_6" ] && {
		dhcpv6="1"
		if [ -z "$dhcpv6" -o "$dhcpv6" = 0 ]; then
			json_load "$($UQMI -s -d $device --set-client-id wds,$cid_6 --get-current-settings)"
			json_select ipv6
			json_get_var ip_6 ip
			json_get_var gateway_6 gateway
			json_get_var dns1_6 dns1
			json_get_var dns2_6 dns2
			json_get_var ip_prefix_length ip-prefix-length

			proto_init_update "$ifname" 1
			proto_set_keep 1
			proto_add_ipv6_address "$ip_6" "128"
			proto_add_ipv6_prefix "${ip_6}/${ip_prefix_length}"
			proto_add_ipv6_route "$gateway_6" "128"
			[ "$defaultroute" = 0 ] || proto_add_ipv6_route "::0" 0 "$gateway_6" "" "" "${ip_6}/${ip_prefix_length}"
			[ "$peerdns" = 0 ] || {
				proto_add_dns_server "$dns1_6"
				proto_add_dns_server "$dns2_6"
			}
			[ -n "$zone" ] && {
				proto_add_data
				json_add_string zone "$zone"
				proto_close_data
			}
			proto_send_update "$interface"
		else
			if [ "$(uci get glipv6.lan.mode)" = "relay" ] && [ "$(uci get dhcp.${interface}_6)" != "dhcp" ];then
				uci set dhcp.${interface}_6='dhcp'
				uci set dhcp.${interface}_6.interface="${interface}_6"
				uci set dhcp.${interface}_6.dhcpv6="relay"
				uci set dhcp.${interface}_6.ra="relay"
				uci set dhcp.${interface}_6.ndp="relay"
				uci set dhcp.${interface}_6.master="1"
				uci commit dhcp
				/etc/init.d/dnsmasq restart &
			fi
		fi
	}

	[ -n "$pdh_4" ] && {
		json_init
		json_add_string name "${interface}_4"
		json_add_string ifname "@$interface"
		json_add_string proto "dhcp"
		[ -n "$ip4table" ] && json_add_string ip4table "$ip4table"
		proto_add_dynamic_defaults
		[ -n "$zone" ] && json_add_string zone "$zone"
		json_close_object
		ubus call network add_dynamic "$(json_dump)"
	}

	report_interface_dial_script_success "$interface"

}

qmi_wds_stop() {
	local cid="$1"
	local pdh="$2"

	[ -n "$cid" ] || return

	$UQMI -s -d "$device" --set-client-id wds,"$cid" \
		--stop-network 0xffffffff \
		--autoconnect > /dev/null 2>&1

	[ -n "$pdh" ] && {
		$UQMI -s -d "$device" --set-client-id wds,"$cid" \
			--stop-network "$pdh" > /dev/null 2>&1
	}

	$UQMI -s -d "$device" --set-client-id wds,"$cid" \
		--release-client-id wds > /dev/null 2>&1
}

proto_qmi_teardown() {
	local interface="$1"

	local device cid_4 pdh_4 cid_6 pdh_6
	json_get_vars device

	[ -n "$ctl_device" ] && device=$ctl_device

	log_info $LINENO "modem" "Stopping network $interface"

	json_load "$(ubus call network.interface.$interface status)"
	json_select data
	json_get_vars cid_4 pdh_4 cid_6 pdh_6

	qmi_wds_stop "$cid_4" "$pdh_4"
	qmi_wds_stop "$cid_6" "$pdh_6"

	proto_init_update "*" 0
	proto_send_update "$interface"
}

[ -n "$INCLUDE_ONLY" ] || {
	add_protocol qmi
}
