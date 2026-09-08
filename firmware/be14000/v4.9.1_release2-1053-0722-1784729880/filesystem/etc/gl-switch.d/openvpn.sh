#!/bin/sh
. /lib/functions/gl_util.sh

action=$1

PORT=$(cat /etc/nginx/conf.d/gl.conf |grep -E "    listen [0-9]+;" |grep -oE '[0-9]+'| head -1)
[ -z "$PORT" ] && PORT=80

if [ "$action" = "on" ];then
	result=`curl -H 'glinet: 1' -s -k http://127.0.0.1:$PORT/rpc -d "{\"jsonrpc\":\"2.0\",\"method\":\"call\",\"params\":[\"\",\"ovpn-client\",\"get_status\",{}],\"id\":1}" | jsonfilter -e @.result`
	status=`echo $result | jsonfilter -e @.status`
	group_id=`echo $result | jsonfilter -e @.group_id`
	client_id=`echo $result | jsonfilter -e @.client_id`
	if [ "$status" = "0" -a -n "$group_id" -a "$group_id" != "0" -a -n "$client_id" -a "$client_id" != "0" ];then
		mcu_send_message "Turning OVPN ON"
		curl -H 'glinet: 1' -s -k http://127.0.0.1:$PORT/rpc -d "{\"jsonrpc\":\"2.0\",\"method\":\"call\",\"params\":[\"\",\"ovpn-client\",\"start\",{\"group_id\":$group_id,\"client_id\":$client_id}],\"id\":1}"
	fi
fi

if [ "$action" = "off" ];then
	result=`curl -H 'glinet: 1' -s -k http://127.0.0.1:$PORT/rpc -d "{\"jsonrpc\":\"2.0\",\"method\":\"call\",\"params\":[\"\",\"ovpn-client\",\"get_status\",{}],\"id\":1}" | jsonfilter -e @.result`
	status=`echo $result | jsonfilter -e @.status`
	group_id=`echo $result | jsonfilter -e @.group_id`
	client_id=`echo $result | jsonfilter -e @.client_id`
	if [ "$status" != "0" -a -n "$group_id" -a -n "$client_id" ];then
		mcu_send_message "Turning OVPN OFF"
		curl -H 'glinet: 1' -s -k http://127.0.0.1:$PORT/rpc -d "{\"jsonrpc\":\"2.0\",\"method\":\"call\",\"params\":[\"\",\"ovpn-client\",\"stop\",{\"group_id\":$group_id,\"client_id\":$client_id}],\"id\":1}"
	fi
fi

sleep 5
