#!/bin/sh

[ -n "$INCLUDE_ONLY" ] || {
	. /lib/functions.sh
	. ../netifd-proto.sh
	. /lib/functions/modem.sh
	init_proto "$@"
}

proto_ncm_init_config() {
	no_device=1
	available=1
	proto_config_add_string "device:device"
	proto_config_add_string apn
	proto_config_add_string auth
	proto_config_add_string username
	proto_config_add_string password
	proto_config_add_string pincode
	proto_config_add_string iccid
	proto_config_add_string delay
	proto_config_add_string mode
	proto_config_add_string ip_type
	proto_config_add_string bus
	proto_config_add_int slot
	proto_config_add_string date
	proto_config_add_int profile
	proto_config_add_defaults
}


unlock_special_model_sim_pin(){

    local modem_bus="$1"
    local iccid="$2"
    local pincode="$3"
    local interface="$4"
    local device="$5"
 
    local sim_status=$(check_sim_and_pin_status $modem_bus)
    local curr_iccid=$(get_sim_iccid $modem_bus)

    if [ -z "$pincode" ] ;then                                                                                                                                                                
        pincode=`uci -q get glmodem.$iccid.pincode 2>/dev/null`                                                                                                                              
    fi

    [ -z "$sim_status" ] && {
        log_error $LINENO "modem" "(unlock_special_model_sim_pin)Failed to get simcard status, please check!"
        return 1
    }

    if [ "$sim_status" = "ERROR" -o "$sim_status" = "SIMPUK" ];then
        log_error $LINENO "modem" "(unlock_special_model_sim_pin)The current simcard status $sim_status, please check!"
        return 1
    fi

    log_info $LINENO "modem" "(unlock_special_model_sim_pin)sim_status:$sim_status modem_bus:$modem_bus interface:$interface device:$device pincode:$pincode iccid:$iccid"

    if [ "$sim_status" = "SIMPIN" ];then

        log_info $LINENO "modem" "(unlock_special_model_sim_pin)iccid:$iccid pincode:$pincode"
        
        if [ -z "$pincode" ];then
           log_error $LINENO "modem" "(unlock_special_model_sim_pin)The PIN does not exist or the PIN code does not match."
           return 1
        fi
        
        if [ -n "$curr_iccid" ] && [ -n "$iccid" ] && [ "$curr_iccid" = "$iccid" ];then
            PINCODE="$pincode" gcom -d "$device" -s /etc/gcom/setpin.gcom || {
			    log_error $LINENO "modem" "(unlock_special_model_sim_pin)The PIN code is incorrect, please check it!"
			    proto_notify_error "$interface" PIN_FAILED
			    proto_block_restart "$interface"
			    return 1
			}
        else
           log_error $LINENO "modem" "(unlock_special_model_sim_pin)The PIN does not exist or the PIN code does not match."
           return 1
        fi

    fi

    return 0
}

proto_ncm_setup() {
	local interface="$1"

	local manufacturer initialize setmode connect finalize ifname devname devpath manual pdptype

	local device bus slot username password pincode iccid delay mode ip_type profile $PROTO_DEFAULT_OPTIONS apn apn_use 
	json_get_vars device iccid bus slot delay mode ip_type $PROTO_DEFAULT_OPTIONS apn apn_use

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

    profile=$(get_sim_map_field "$iccid" cid)
    manual=$(get_sim_map_field "$iccid" manual)
    if [ "$manual" = "true" ];then
		ip_type=$(get_sim_map_field "$iccid" ip_type)
		apn=$(get_sim_map_field "$iccid" apn)
		mtu=$(get_sim_map_field "$iccid" mtu)
		auth=$(get_sim_map_field "$iccid" auth)
		username=$(get_sim_map_field "$iccid" username)
		password=$(get_sim_map_field "$iccid" password)
	fi

	[ -z "$apn" ] && {
		username=""
		password=""
		auth=""
	}

	[ -z "$username" ] && {
		password=""
		auth=""
	}

	[ -z "$auth" ] && {
		username=""
		password=""
	}

    if [ "$manual" = "true" ];then
    	    pdptype=$(convert_ip_type $ip_type)
	else
	    pdptype=$ip_type
	fi
    
        log_info $LINENO "modem" "Set ip type:$pdptype"
        [ -n "$mtu" ] || mtu=1500 

	[ "$metric" = "" ] && metric="0"

	[ -n "$profile" ] || profile=1

	[ "$pdptype" = "IP" -o "$pdptype" = "IPV6" -o "$pdptype" = "IPV4V6" ] || pdptype="IP"

	[ -n "$ctl_device" ] && device=$ctl_device

	[ -n "$device" ] || {
		log_error $LINENO "modem" "No control device specified"
		proto_notify_error "$interface" NO_DEVICE
		proto_set_available "$interface" 0
		set_interface_dial_progress "$interface" "2"
		return 1
	}

	device="$(readlink -f $device)"
	[ -e "$device" ] || {
		log_error $LINENO "modem" "Control device not valid"
		proto_set_available "$interface" 0
		set_interface_dial_progress "$interface" "2"
		return 1
	}

	devname="$(basename "$device")"
	case "$devname" in
	'tty'*)
		devpath="$(readlink -f /sys/class/tty/$devname/device)"
		ifname="$( ls "$devpath"/../../*/net )"
		;;
	*)
		devpath="$(readlink -f /sys/class/usbmisc/$devname/device/)"
		ifname="$( ls "$devpath"/net )"
		;;
	esac
	[ -n "$ifname" ] || {
		log_error $LINENO "modem" "The interface could not be found."
		proto_notify_error "$interface" NO_IFACE
		proto_set_available "$interface" 0
		set_interface_dial_progress "$interface" "2"
		return 1
	}

	[ -n "$delay" ] && sleep "$delay"

	manufacturer=$(gcom -d "$device" -s /etc/gcom/getcardinfo.gcom | awk 'NF && $0 !~ /AT\+CGMI/ { sub(/\+CGMI: /,""); print tolower($1); exit; }')
	[ $? -ne 0 -o -z "$manufacturer" ] && {
		log_error $LINENO "modem" "Failed to get modem information"
		proto_notify_error "$interface" GETINFO_FAILED
		set_interface_dial_progress "$interface" "3"
		return 1
	}

    log_info $LINENO "modem" "manufacturer:$manufacturer"

	json_load "$(cat /etc/gcom/ncm.json)"
	json_select "$manufacturer"
	[ $? -ne 0 ] && {
		log_error $LINENO "modem" "Unsupported modem"
		proto_notify_error "$interface" UNSUPPORTED_MODEM
		proto_set_available "$interface" 0
		set_interface_dial_progress "$interface" "2"
		return 1
	}

	json_get_values initialize initialize
	for i in $initialize; do
		eval COMMAND="$i" gcom -d "$device" -s /etc/gcom/runcommand.gcom || {
			log_error $LINENO "modem" "Failed to initialize modem"
			proto_notify_error "$interface" INITIALIZE_FAILED
			set_interface_dial_progress "$interface" "3"
			return 1
		}
	done

   
	json_get_values configure configure
	log_info $LINENO "modem" "Configuring modem"
	for i in $configure; do
		eval COMMAND="$i" gcom -d "$device" -s /etc/gcom/runcommand.gcom || {
			log_error $LINENO "modem" "Failed to configure modem"
			proto_notify_error "$interface" CONFIGURE_FAILED
			set_interface_dial_progress "$interface" "3"
			return 1
		}
	done

	[ -n "$mode" ] && {
		json_select modes
		json_get_var setmode "$mode"
		[ -n "$setmode" ] && {
			log_info $LINENO "modem" "Setting mode"
			eval COMMAND="$setmode" gcom -d "$device" -s /etc/gcom/runcommand.gcom || {
				log_error $LINENO "modem" "Failed to set operating mode"
				proto_notify_error "$interface" SETMODE_FAILED
				set_interface_dial_progress "$interface" "3"
				return 1
			}
		}
		json_select ..
	}

	log_info $LINENO "modem" "Starting network $interface"
	
	json_get_vars connect
	[ -n "$connect" ] && {
		log_info $LINENO "modem" "Connecting modem profile:$profile,apn:$apn"
		out="$(eval COMMAND=\"${connect}\" gcom -d \"$device\" -s /etc/gcom/runcommand.gcom 2>&1)"
		ret=$?
		[ $ret -ne 0 ] && {
			log_error $LINENO "modem" "Failed to connect (ret=$ret): ${out}"
			proto_notify_error "$interface" CONNECT_FAILED
			set_interface_dial_progress "$interface" "3"
			return 1
		}
	}

	json_get_vars finalize

	log_info $LINENO "modem" "Setting up $ifname"
	proto_init_update "$ifname" 1
	proto_add_data
	json_add_string "manufacturer" "$manufacturer"
	proto_close_data
	proto_send_update "$interface"

	local zone="$(fw3 -q network "$interface" 2>/dev/null)"

	[ "$pdptype" = "IP" -o "$pdptype" = "IPV4V6" ] && {
		json_init
		json_add_string name "${interface}_4"
		json_add_string ifname "@$interface"
		json_add_string proto "dhcp"
		proto_add_dynamic_defaults
		[ -n "$zone" ] && {
			json_add_string zone "$zone"
		}
		json_close_object
		ubus call network add_dynamic "$(json_dump)"
	}

	[ "$pdptype" = "IPV6" -o "$pdptype" = "IPV4V6" ] && {
		json_init
		json_add_string name "${interface}_6"
		json_add_string ifname "@$interface"
		json_add_string proto "dhcpv6"
		json_add_string extendprefix 1
		proto_add_dynamic_defaults
		[ -n "$zone" ] && {
			json_add_string zone "$zone"
		}
		json_close_object
		ubus call network add_dynamic "$(json_dump)"
	}

	[ -n "$finalize" ] && {
		eval COMMAND="$finalize" gcom -d "$device" -s /etc/gcom/runcommand.gcom || {
			log_error $LINENO "modem" "Failed to configure modem"
			proto_notify_error "$interface" FINALIZE_FAILED
			set_interface_dial_progress "$interface" "3"
			return 1
		}
	}

	report_interface_dial_script_success "$interface"

}

proto_ncm_teardown() {
	local interface="$1"

	local manufacturer disconnect

	local device profile
	json_get_vars device profile

	[ -n "$ctl_device" ] && device=$ctl_device

	[ -n "$device" ] || {
		log_error $LINENO "modem" "No control device specified"
		proto_notify_error "$interface" NO_DEVICE
		proto_set_available "$interface" 0
		return 1
	}

	device="$(readlink -f $device)"
	[ -e "$device" ] || {
		log_error $LINENO "modem" "Control device not valid"
		proto_set_available "$interface" 0
		return 1
	}

	[ -n "$profile" ] || profile=$(get_sim_map_field "$iccid" cid)
	[ -n "$profile" ] || profile=1

	log_error $LINENO "modem" "Stopping network $interface"

	json_load "$(ubus call network.interface.$interface status)"
	json_select data
	json_get_vars manufacturer
	[ $? -ne 0 -o -z "$manufacturer" ] && {
		# Fallback to direct detect, for proper handle device replug.
		manufacturer=$(gcom -d "$device" -s /etc/gcom/getcardinfo.gcom | awk 'NF && $0 !~ /AT\+CGMI/ { sub(/\+CGMI: /,""); print tolower($1); exit; }')
		[ $? -ne 0 -o -z "$manufacturer" ] && {
			log_error $LINENO "modem" "Failed to get modem information"
			proto_notify_error "$interface" GETINFO_FAILED
			return 1
		}
		json_add_string "manufacturer" "$manufacturer"
	}

	json_load "$(cat /etc/gcom/ncm.json)"
	json_select "$manufacturer" || {
		log_error $LINENO "modem" "Unsupported modem"
		proto_notify_error "$interface" UNSUPPORTED_MODEM
		return 1
	}

	json_get_vars disconnect
	[ -n "$disconnect" ] && {
		eval COMMAND="$disconnect" gcom -d "$device" -s /etc/gcom/runcommand.gcom || {
			log_error $LINENO "modem" "Failed to disconnect"
			proto_notify_error "$interface" DISCONNECT_FAILED
			return 1
		}
	}

	proto_init_update "*" 0
	proto_send_update "$interface"
}
[ -n "$INCLUDE_ONLY" ] || {
	add_protocol ncm
}
