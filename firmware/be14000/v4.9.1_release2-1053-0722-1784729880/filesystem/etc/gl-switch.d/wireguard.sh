#!/bin/sh
. /lib/functions/gl_util.sh

action=$1

PORT=$(cat /etc/nginx/conf.d/gl.conf |grep -E "    listen [0-9]+;" |grep -oE '[0-9]+'| head -1)
[ -z "$PORT" ] && PORT=80
if [ "$action" = "on" ];then
	result=`curl -H 'glinet: 1' -s -k http://127.0.0.1:$PORT/rpc -d "{\"jsonrpc\":\"2.0\",\"method\":\"call\",\"params\":[\"\",\"wg-client\",\"get_status\",{}],\"id\":1}" | jsonfilter -e @.result`
	status=`echo $result | jsonfilter -e @.status`
	group_id=`echo $result | jsonfilter -e @.group_id`
	peer_id=`echo $result | jsonfilter -e @.peer_id`
	if [ "$status" = "0" -a -n "$group_id" -a "$group_id" != "0" -a -n "$peer_id" -a "$peer_id" != "0" ];then
		mcu_send_message "Turning WG ON"
		curl -H 'glinet: 1' -s -k http://127.0.0.1:$PORT/rpc -d "{\"jsonrpc\":\"2.0\",\"method\":\"call\",\"params\":[\"\",\"wg-client\",\"start\",{\"group_id\":$group_id,\"peer_id\":$peer_id}],\"id\":1}"
	fi
fi

if [ "$action" = "off" ];then
	mcu_send_message "Turning WG OFF"
	curl -H 'glinet: 1' -s -k http://127.0.0.1:$PORT/rpc -d "{\"jsonrpc\":\"2.0\",\"method\":\"call\",\"params\":[\"\",\"wg-client\",\"stop\",{}],\"id\":1}"
fi

sleep 5
