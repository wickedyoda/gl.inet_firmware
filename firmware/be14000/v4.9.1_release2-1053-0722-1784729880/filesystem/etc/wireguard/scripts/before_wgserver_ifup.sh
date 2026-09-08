#!/bin/sh

interface="$1"

/etc/wireguard/scripts/wgserver_func.sh "${interface}" "set_firewall"
/etc/wireguard/scripts/wgserver_func.sh "${interface}" "set_dhcp" "up"

