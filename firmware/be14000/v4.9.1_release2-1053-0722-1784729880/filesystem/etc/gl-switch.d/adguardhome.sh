#!/bin/sh

action=$1
status=$(uci -q get adguardhome.config.enabled)

if [ "$action" = "on" -a "$status" != "1" ];then
    ubus call gl-session call '{"module":"adguardhome", "func":"set_config", "params": {"enabled": true}}'
fi

if [ "$action" = "off" -a "$status" != "0" ];then
    ubus call gl-session call '{"module":"adguardhome", "func":"set_config", "params": {"enabled": false}}'
fi

sleep 5
