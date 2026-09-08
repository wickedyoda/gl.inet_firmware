#!/bin/sh
. /lib/functions/gl_util.sh

action=$1

PORT=$(cat /etc/nginx/conf.d/gl.conf |grep -E "    listen [0-9]+;" |grep -oE '[0-9]+'| head -1)

if [ "$PORT" != "" -a "$PORT" != "80" ];then
    URL="http://127.0.0.1:$PORT/rpc"
else
    URL="http://127.0.0.1/rpc"
fi

if [ "$action" = "on" ];then
	result=`curl -H 'glinet: 1' -s -k $URL -d "{\"jsonrpc\":\"2.0\",\"method\":\"call\",\"params\":[\"\",\"tor\",\"get_config\",{}],\"id\":1}" | jsonfilter -e @.result`
	countries=`echo $result | jsonfilter -e @.countries`
	manual=`echo $result | jsonfilter -e @.manual`
	mcu_send_message "Turning TOR ON"
	if [ "$manual" = "true" ];then
		curl -H 'glinet: 1' -s -k $URL -d "{\"jsonrpc\":\"2.0\",\"method\":\"call\",\"params\":[\"\",\"tor\",\"set_config\",{\"enable\":true,\"manual\":true,\"countries\":$countries}],\"id\":1}"
	else
		curl -H 'glinet: 1' -s -k $URL -d "{\"jsonrpc\":\"2.0\",\"method\":\"call\",\"params\":[\"\",\"tor\",\"set_config\",{\"enable\":true,\"manual\":false}],\"id\":1}"
	fi
fi

if [ "$action" = "off" ];then
	result=`curl -H 'glinet: 1' -s -k $URL -d "{\"jsonrpc\":\"2.0\",\"method\":\"call\",\"params\":[\"\",\"tor\",\"get_config\",{}],\"id\":1}" | jsonfilter -e @.result`
	countries=`echo $result | jsonfilter -e @.countries`
	manual=`echo $result | jsonfilter -e @.manual`
	mcu_send_message "Turning TOR OFF"
	if [ "$manual" = "true" ];then
		curl -H 'glinet: 1' -s -k $URL -d "{\"jsonrpc\":\"2.0\",\"method\":\"call\",\"params\":[\"\",\"tor\",\"set_config\",{\"enable\":false,\"manual\":true,\"countries\":$countries}],\"id\":1}"
	else
		curl -H 'glinet: 1' -s -k $URL -d "{\"jsonrpc\":\"2.0\",\"method\":\"call\",\"params\":[\"\",\"tor\",\"set_config\",{\"enable\":false,\"manual\":false}],\"id\":1}"
	fi
fi

sleep 5
