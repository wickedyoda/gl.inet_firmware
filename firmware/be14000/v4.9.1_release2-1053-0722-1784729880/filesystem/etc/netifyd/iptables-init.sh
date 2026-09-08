#!/bin/sh

iptables -w -F parental_control
iptables -w -D FORWARD -j parental_control
iptables -w -X parental_control
iptables -w -N parental_control 2>/dev/null
iptables -w -I FORWARD -j parental_control
ip6tables -w -F parental_control
ip6tables -w -D FORWARD -j parental_control
ip6tables -w -X parental_control
ip6tables -w -N parental_control 2>/dev/null
ip6tables -w -I FORWARD -j parental_control

qos_enable=$(uci -q get gl_dpi_qos.qos.prio_enable)
flow_statistics_enable=$(uci -q get gl_dpi_flow_statistics.global.enable)
content_protection_enable=$(uci -q get gl_dpi_content_protection.content_protection.enabled)

if ! ipset list GL_DPI_BLOCK >/dev/null 2>&1; then
    ipset create GL_DPI_BLOCK hash:net 2>/dev/null
fi

iptables -w -D parental_control -m set --match-set GL_DPI_BLOCK dst -j DROP
if [ "$content_protection_enable" = "1" ]; then
    iptables -w -I parental_control -m connmark --mark 0x300/0xf00 -j ACCEPT
    iptables -w -A parental_control -m connmark --mark 0x200000/0xf00000 -j DROP
    ip6tables -w -I parental_control -m connmark --mark 0x300/0xf00 -j ACCEPT
    ip6tables -w -A parental_control -m connmark --mark 0x200000/0xf00000 -j DROP
    iptables -w -I parental_control -m set --match-set GL_DPI_BLOCK dst -j DROP
fi

iptables -w -t mangle -D POSTROUTING -m connmark --mark 0x60/0xf0 -j MARK --set-mark 0x60/0xf0
iptables -w -t mangle -D POSTROUTING -m connmark --mark 0x70/0xf0 -j MARK --set-mark 0x70/0xf0
iptables -w -t mangle -D POSTROUTING -m connmark --mark 0x80/0xf0 -j MARK --set-mark 0x80/0xf0
ip6tables -w -t mangle -D POSTROUTING -m connmark --mark 0x60/0xf0 -j MARK --set-mark 0x60/0xf0
ip6tables -w -t mangle -D POSTROUTING -m connmark --mark 0x70/0xf0 -j MARK --set-mark 0x70/0xf0
ip6tables -w -t mangle -D POSTROUTING -m connmark --mark 0x80/0xf0 -j MARK --set-mark 0x80/0xf0
if [ "$qos_enable" = "1" ]; then
    iptables -w -t mangle -I POSTROUTING -m connmark --mark 0x60/0xf0 -j MARK --set-mark 0x60/0xf0
    iptables -w -t mangle -I POSTROUTING -m connmark --mark 0x70/0xf0 -j MARK --set-mark 0x70/0xf0
    iptables -w -t mangle -I POSTROUTING -m connmark --mark 0x80/0xf0 -j MARK --set-mark 0x80/0xf0
    ip6tables -w -t mangle -I POSTROUTING -m connmark --mark 0x60/0xf0 -j MARK --set-mark 0x60/0xf0
    ip6tables -w -t mangle -I POSTROUTING -m connmark --mark 0x70/0xf0 -j MARK --set-mark 0x70/0xf0
    ip6tables -w -t mangle -I POSTROUTING -m connmark --mark 0x80/0xf0 -j MARK --set-mark 0x80/0xf0
fi

iptables -w -t mangle -D FORWARD -m connbytes --connbytes 0:32 --connbytes-dir both --connbytes-mode packets -j NFQUEUE --queue-num 0 --queue-bypass
ip6tables -w -t mangle -D FORWARD -m connbytes --connbytes 0:32 --connbytes-dir both --connbytes-mode packets -j NFQUEUE --queue-num 0 --queue-bypass
if [ "$qos_enable" = "1" ] || [ "$flow_statistics_enable" = "1" ] || [ "$content_protection_enable" = "1" ]; then
    iptables -w -t mangle -A FORWARD -m connbytes --connbytes 0:32 --connbytes-dir both --connbytes-mode packets -j NFQUEUE --queue-num 0 --queue-bypass
    ip6tables -w -t mangle -A FORWARD -m connbytes --connbytes 0:32 --connbytes-dir both --connbytes-mode packets -j NFQUEUE --queue-num 0 --queue-bypass
fi
