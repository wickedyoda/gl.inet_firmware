#!/bin/sh

interface="$1"

/etc/wireguard/scripts/wgserver_func.sh "${interface}" "disabled_firewall"
/etc/wireguard/scripts/wgserver_func.sh "${interface}" "set_dhcp" "down"

