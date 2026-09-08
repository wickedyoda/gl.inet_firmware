#!/bin/sh

interface="$1"

/etc/openvpn/scripts/ovpnserver_func.sh "${interface}" "set_firewall"

