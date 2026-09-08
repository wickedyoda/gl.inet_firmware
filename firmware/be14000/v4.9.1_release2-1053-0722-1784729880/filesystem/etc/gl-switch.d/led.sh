#!/bin/sh
action=$1

[ "$action" = "on" ] && /etc/init.d/gl_led turnon

[ "$action" = "off" ] && /etc/init.d/gl_led turnoff

sleep 5
