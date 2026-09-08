#!/bin/sh
. /lib/functions/modem.sh
#shellcheck disable=SC2140
#shellcheck disable=SC2153

set_log_level "$(get_modem_log_level)"

[ -n "$INCLUDE_ONLY" ] || {
	. /lib/functions.sh
	. /lib/functions/modem.sh
	. ../netifd-proto.sh
	init_proto "$@"
}

proto_qcm_init_config() {
	available=1
	no_device=1
	proto_config_add_string "device:device"
	proto_config_add_string "ifname"
	proto_config_add_string "apn"
	proto_config_add_string "pincode"
	proto_config_add_string "iccid"
	proto_config_add_string "auth"
	proto_config_add_string "username"
	proto_config_add_string "password"
	proto_config_add_string "node"
	proto_config_add_int "mtu"
	proto_config_add_int "apn_use"
	proto_config_add_string "ip_type"
	proto_config_add_string "bus"
	proto_config_add_string "date"
	proto_config_add_int "slot"
	proto_config_add_defaults
}

proto_qcm_setup() {
	local interface="$1"
	local devpath=""
	local devname=""

	local device ifname apn pincode iccid ifname auth username password  node $PROTO_DEFAULT_OPTIONS 
	local mtu apn_use ip_type date slot bus manual 
	json_get_vars device ifname iccid node $PROTO_DEFAULT_OPTIONS mtu ip_type slot bus apn_use apn
	local ipv6=`uci get glipv6.globals.enabled 2>/dev/null`
	
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
        #apn_use=$(get_sim_map_field "$iccid" cid)
	    mtu=$(get_sim_map_field "$iccid" mtu)
        auth=$(get_sim_map_field "$iccid" auth)
	    username=$(get_sim_map_field "$iccid" username)
	    password=$(get_sim_map_field "$iccid" password)
	fi

    log_info $LINENO "modem" "manual:$manual ip_type:$ip_type apn:$apn auth:$auth username:$username password:$password mtu:$mtu apn_use:$apn_use"
	case $auth in
	"PAP") auth=1 ;;
	"CHAP") auth=2 ;;
	"PAP or CHAP") auth=3 ;;
	"PAP/CHAP") auth=3 ;;
	*) auth=0 ;;
	esac

	if [ -n "$node" ];then
		devpath="$(find  /sys/devices/ -name "$node" 2>/dev/null)"
		devname="$(find "$devpath" -name  "cdc-wdm*" 2>/dev/null)"
		devname="$(basename "$devname")"
	else
 		devname="$(basename "$device")"

		#if [ ${devname/mhi//} = $devname ];then
		if ! echo "$devname" | grep -q 'mhi'; then
			devpath="$(readlink -f /sys/class/usbmisc/$devname/device/)"
			bus="$(basename "$devpath"|cut -d ':' -f 1)"
		else
			devpath="$(readlink -f /sys/class/net/rmnet_mhi0/device)"
			bus="$(basename $(dirname "$devpath"))"
		fi
	fi
	
	if [ -n "$node" ];then
		#fix config
		[ "$devname" = "$(basename "$device")" ] || {
			[ -n "$devname" ] && uci set "network.${interface}.device=/dev/${devname}" && uci commit
		}
	fi

	device="$(readlink -f $device)"
	[ -c "$device" ] || {
		log_error $LINENO "modem" "The specified control device does not exist."
		proto_notify_error "$interface" NO_DEVICE
		proto_set_available "$interface" 0
		set_interface_dial_progress "$interface" "3"
		return 1
	}

	ifname="$( ls "$devpath"/net 2>/dev/null)"
    if [ -z "$ifname" ]; then
		log_error $LINENO "modem" "The specified control device does not have an associated network interface."
		proto_notify_error "$interface" NO_IFNAME
		proto_set_available "$interface" 0
		set_interface_dial_progress "$interface" "3"
		return 1
	fi

	dataformat="$(uqmi -t 3000 -s -d "$device" --wda-get-data-format)"
	if [ "$dataformat" = '"raw-ip"' ]; then
		if [ -f /sys/class/net/$ifname/qmi/raw_ip ];then
			echo "Y" > /sys/class/net/$ifname/qmi/raw_ip
		else
			log_info $LINENO "modem" "Device only supports raw-ip mode but is missing this required driver attribute: /sys/class/net/$ifname/qmi/raw_ip."
		fi
	elif [ -n "`echo "$dataformat" | grep Failed`" ];then
		log_error $LINENO "modem" "Failed to connect to service"
		set_interface_dial_progress "$interface" "3"
		return 1
	else
		if [ -f /sys/class/net/$ifname/qmi/raw_ip ];then
			echo "N" > /sys/class/net/$ifname/qmi/raw_ip
		else
			log_info $LINENO "modem" "Device only supports 802.3 mode but is missing this required driver attribute: /sys/class/net/$ifname/qmi/raw_ip"
		fi
	fi

    if [ "$manual" = "true" ];then
    	ip_type=$(convert_ip_type ${ip_type})
    fi

    log_info $LINENO "modem" "Set ip type:$ip_type"
    case "$ip_type" in
    "IPV4V6") pdp_type='-4 -6' ;;
    "IPV6") pdp_type='-6' ;;
    *) pdp_type='-4' ;;
    esac

	[ -z "$apn" ] && {
		username=""
		password=""
		auth=""
	}

	[ -z "$username" ] && {
		password=""
		auth=""
	}

	if [ -n "$mtu" ];then
		log_info $LINENO "modem" "Setting ifname $ifname MTU to $mtu"
		/sbin/ip link set dev $ifname mtu $mtu
	else
        log_info $LINENO "modem" "Setting ifname $ifname MTU to default 1500"
		/sbin/ip link set dev $ifname mtu 1500
	fi

    apn_set=""
    if [ -n "$apn" ] && [ -n "$username" ]; then
        apn_set=1
    fi

    [ "$apn_use" = "" ] && apn_use=$(check_apn $bus $slot)


    log_info $LINENO "modem" "ifname:$ifname"

	if [ "$apn_use" != "-1" ];then
        if [ "$apn_use" != "" ]; then
            proto_run_command "$interface" qcm ${pdp_type:=-4 -6} \
                ${cid:=-n $apn_use} \
				${ifname:+${ifname:+-i $ifname}} \
                ${apn_set:+${apn:+-s $apn}} \
                ${username:+ $username} \
                ${password:+ $password} \
                ${auth:+ $auth} 
		  
	    else
            proto_run_command "$interface" qcm ${pdp_type:=-4 -6} \
                ${apn_set:+${apn:+-s $apn}} \
				${ifname:+${ifname:+-i $ifname}} \
                ${username:+ $username} \
                ${password:+ $password} \
                ${auth:+ $auth} 
		   
		fi
	else
		proto_run_command "$interface" qcm ${pdp_type:=-4 -6} ${ifname:+${ifname:+-i $ifname}} 
	fi


    proto_init_update "$ifname" 1                                                                                     
    proto_set_keep 1                                                                                     
    proto_send_update "$interface"

	time=`date '+%s'`
	json_init
	json_add_string name "${interface}_4"
	json_add_string ifname "@$interface"
	json_add_string proto "dhcp"
	json_add_string date "$time"
	proto_add_dynamic_defaults
	ubus call network add_dynamic "$(json_dump)"

    if ! echo "$bus" | grep -q '-'; then
	    (sleep 3;path=`find  /sys/devices/ -name 'link_state'`;[ -n $path ] && echo "0x1" > $path) &
    fi

	report_interface_dial_script_success "$interface"

	return 0
}

proto_qcm_teardown() {

	bus=$(uci -q get network.$1.bus)
    log_info $LINENO "modem" "teardown bus:$bus interface:$1"
    if ! echo "$bus" | grep -q '-'; then
        local path=`find  /sys/devices/ -name 'link_state'`
        echo 0x0 2>/dev/null > $path 
	fi
	local interface="$1"
	proto_kill_command "$interface"
}

[ -n "$INCLUDE_ONLY" ] || {
	add_protocol qcm
}
