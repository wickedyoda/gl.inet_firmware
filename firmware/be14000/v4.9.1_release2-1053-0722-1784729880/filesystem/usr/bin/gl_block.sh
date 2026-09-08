#!/bin/sh

# shellcheck disable=SC3043

. /lib/functions.sh

add_block_mac()
{
        local mac_list
        ipset flush GL_MAC_BLOCK
        config_get mac_list  block_mac mac
        for i in ${mac_list};do
                ipset add GL_MAC_BLOCK "$i"
        done                               
}  
         
create_ipset_entry()
{	
	local exist=$(ipset list GL_MAC_BLOCK 2>/dev/null)
	[ -z "$exist" ] && {
		ipset create GL_MAC_BLOCK hash:mac 2>/dev/null
	}
}

add_firewall()
{
	iptables -w -C FORWARD -m set --match-set GL_MAC_BLOCK src  -j DROP  2>/dev/null
	[ ! "$?" = "0" ] && iptables -w -I FORWARD -m set --match-set GL_MAC_BLOCK src  -j DROP
}

create_ipset_entry
add_firewall
if [ -f /etc/config/gl_block -a ! -e "/etc/config/gl-black_white_list" ];then 
	config_load gl_block
	config_foreach add_block_mac
else
	ipset flush GL_MAC_BLOCK
fi

