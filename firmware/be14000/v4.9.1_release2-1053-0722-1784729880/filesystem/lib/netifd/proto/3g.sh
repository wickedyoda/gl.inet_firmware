#!/bin/sh
[ -n "$INCLUDE_ONLY" ] || {
	NOT_INCLUDED=1
	INCLUDE_ONLY=1

	. ../netifd-proto.sh
	. /lib/functions/modem.sh
	. ./ppp.sh
	init_proto "$@"
}

set_log_level "$(get_modem_log_level)"

handle_2G_mode() {
	local count=0
	local dev=$(echo $1|cut -d '/' -f 3)
	local dir=modem.$(find /sys/devices/platform/  -name $dev |tail -n 1|cut -d '/' -f 8|cut -d ':' -f 1)
	local mode=$(cat /tmp/$dir/signal 2>/dev/null |cut -d '"' -f 4)
	[ -f /tmp/$dir/fail_count ] && {
		count=$(cat /tmp/$dir/fail_count 2>/dev/null)
	}
	[ "$mode" = "gsm" -o "$mode" = "cdma" -o "$mode" = "tdma" ] && {
		let count=count+1
		#((count=count+1))
		echo $count >/tmp/$dir/fail_count
		[ $count -gt 10 ] && {
			log_info $LINENO "modem" "modem delay dial,120s"
			sleep 120
		}
		return
	}
	[ -f /tmp/$dir/fail_count ] && {
		rm /tmp/$dir/fail_count 2>/dev/null
	}
}

proto_3g_init_config() {
	no_device=1
	available=1
	ppp_generic_init_config
	proto_config_add_string "device:device"
	proto_config_add_string "apn"
	proto_config_add_string "service"
	proto_config_add_string "pincode"
	proto_config_add_string "iccid"
	proto_config_add_string "dialnumber"
	proto_config_add_int "apn_use"
	proto_config_add_int "mtu"
	proto_config_add_string "ip_type"
	proto_config_add_string "bus"
	proto_config_add_string "date"
	proto_config_add_int "slot"
}

proto_3g_setup() {
	local interface="$1"
	local chat

	json_get_var device device
	json_get_var iccid iccid
	json_get_var service service
	json_get_var apn_use apn_use
	json_get_var dialnumber dialnumber
	json_get_var ip_type ip_type
	json_get_var bus bus
	json_get_var slot slot
	json_get_var apn apn
	json_get_var mtu mtu
	json_get_var pppname pppname
	
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
	local manual dial_status
	dial_status="$(get_dial_status_retry "$bus" "$slot" 3)" || {
    	log_debug $LINENO "modem" "Dial status unavailable, defer dialing"
    	return 1
	}

    log_debug $LINENO "modem" "Current dialing status $dial_status"
	if [ "$dial_status" != "7" ];then
		log_info $LINENO "modem" "Current dial_status $dial_status does not meet dialing requirements, exiting execution."
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

    log_info $LINENO "modem" "manual:$manual ip_type:$ip_type apn:$apn auth:$auth username:$username password:$password mtu:$mtu"
	[ -n "$dat_device" ] && device=$dat_device

	[ -n "$mtu" ] || mtu=1500

	device="$(readlink -f $device)"
	[ -e "$device" ] || {
		proto_set_available "$interface" 0
		set_interface_dial_progress "$interface" "2"
		return 1
	}
  
        if [ "$manual" = "true" ];then
    	    ip_type=$(convert_ip_type $ip_type)
	fi


        log_info $LINENO "modem" "Set ip type:$ip_type"
	#ipv6_enabled=`uci get glipv6.globals.enabled 2>/dev/null`
	[ "$ip_type" = "IPV4V6" -o "$ip_type" = "IPV6" ] && ipv6_enabled=1

	case "$service" in
		cdma|evdo)
			if [ "$ipv6_enabled" = "1" ];then
				chat="/etc/chatscripts/evdoipv6.chat"
			else
				chat="/etc/chatscripts/evdo.chat"
			fi
		;;
		*)
			if [ "$ipv6_enabled" = "1" ];then
				chat="/etc/chatscripts/3gipv6.chat"
			else
				chat="/etc/chatscripts/3g.chat"
			fi
			cardinfo=$(gcom -d "$device" -s /etc/gcom/getcardinfo.gcom)
			if echo "$cardinfo" | grep -q Novatel; then
				case "$service" in
					umts_only) CODE=2;;
					gprs_only) CODE=1;;
					*) CODE=0;;
				esac
				export MODE="AT\$NWRAT=${CODE},2"
			elif echo "$cardinfo" | grep -q Option; then
				case "$service" in
					umts_only) CODE=1;;
					gprs_only) CODE=0;;
					*) CODE=3;;
				esac
				export MODE="AT_OPSYS=${CODE}"
			elif echo "$cardinfo" | grep -q "Sierra Wireless"; then
				SIERRA=1
			elif echo "$cardinfo" | grep -qi huawei; then
				case "$service" in
					umts_only) CODE="14,2";;
					gprs_only) CODE="13,1";;
					*) CODE="2,2";;
				esac
				export MODE="AT^SYSCFG=${CODE},3FFFFFFF,2,4"
			fi

			[ -n "$MODE" ] && gcom -d "$device" -s /etc/gcom/setmode.gcom

			# wait for carrier to avoid firmware stability bugs
			[ -n "$SIERRA" ] && {
				gcom -d "$device" -s /etc/gcom/getcarrier.gcom || return 1
			}

			if [ -z "$dialnumber" ]; then
				dialnumber="*99***1#"
				[ "$apn_use" = "3" ] && dialnumber="*99***3#"
			fi

		;;
	esac
	handle_2G_mode $device

	if [ -z "$pppname" ] && [ "${interface#modem_}" != "$interface" ]; then
		pppname="$(build_3g_ppp_ifname "$interface")"
		log_info $LINENO "modem" "Generate pppname:${pppname}"
		json_add_string pppname "$pppname"
	fi

	connect="${apn:+USE_APN=$apn }${ip_type:+PDP_TYPE=$ip_type }DIALNUMBER=$dialnumber /usr/sbin/chat -t5 -v -E -f $chat"

	ppp_generic_setup "$interface" \
		noaccomp \
		nopcomp \
		novj \
		nobsdcomp \
		noauth \
		maxfail 1 \
		set EXTENDPREFIX=1 \
		lock \
		crtscts \
		115200 "$device"

	report_interface_dial_script_success "$interface"
	
	return 0
}

proto_3g_teardown() {
	proto_kill_command "$interface"
}

[ -z "$NOT_INCLUDED" ] || add_protocol 3g
