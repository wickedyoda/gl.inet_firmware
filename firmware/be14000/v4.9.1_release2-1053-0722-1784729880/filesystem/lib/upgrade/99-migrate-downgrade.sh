#!/bin/sh
# filepath: /work4/run/copilt/gl-sdk4-vlan-subnet/files/99-migrate-downgrade.sh
# Downgrade migration: clean vlan-subnet config when module is removed

if [ -f /usr/lib/oui-httpd/rpc/vlan_subnet ] || \
   [ -f /usr/lib/oui-httpd/rpc/vlan_subnet.lua ] || \
   [ -f /usr/lib/lua/gl/vlan_subnet.lua ] || \
   [ -f /rom/usr/lib/oui-httpd/rpc/vlan_subnet ] || \
   [ -f /rom/usr/lib/oui-httpd/rpc/vlan_subnet.lua ] || \
   [ -f /rom/usr/lib/lua/gl/vlan_subnet.lua ]; then
	return 0 2>/dev/null
fi

vlan_ifaces=$(uci -q show network | grep "=interface" | cut -d. -f2 | cut -d= -f1 | grep "^vlan[0-9]")

[ -z "$vlan_ifaces" ] && \
    ! uci -q show network | grep -q "\.name='br-guest'\|\.name='br-iot'" && \
    return 0 2>/dev/null

for iface in $vlan_ifaces; do
    uci -q delete "network.$iface"
    uci -q delete "network.br_${iface}"

    uci -q show firewall | grep -E "\.name='${iface}'|\.src='${iface}'|\.dest='${iface}'" | \
        cut -d. -f2 | cut -d= -f1 | sort -u | while read -r sid; do
            uci -q delete "firewall.$sid"
        done

    uci -q show dhcp | grep -E "\.interface='${iface}'|\.network='${iface}'" | \
        cut -d. -f2 | cut -d= -f1 | sort -u | while read -r sid; do
            uci -q delete "dhcp.$sid"
        done

    uci -q show gl-black_white_list 2>/dev/null | grep "^gl-black_white_list\.${iface}" | \
        cut -d. -f2 | cut -d= -f1 | sort -u | while read -r sid; do
            uci -q delete "gl-black_white_list.$sid"
        done
done

uci -q show network | grep "\.name='br-guest'\|\.name='br-iot'" | \
    cut -d. -f2 | cut -d= -f1 | sort -u | while read -r sid; do
        uci -q delete "network.$sid"
    done

for iface in guest iot; do
    uci -q get "network.$iface" >/dev/null 2>&1 || continue
    uci -q set "network.$iface.device=br-lan"
    uci -q set "network.$iface.disabled=1"
    uci -q delete "network.$iface.display_name"
    uci -q delete "network.$iface.vlan_id"
done

uci -q delete network.lan.display_name

uci commit network
uci commit firewall
uci commit dhcp
uci -q commit gl-black_white_list

rm -f /tmp/vlan_port_map
return 0 2>/dev/null
