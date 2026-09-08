#!/bin/sh

replace_ip()
{
    lan_ip=$(uci -q get network.lan.ipaddr)
    ori_ip=$(cat /etc/tor/torrc | grep TransPort|awk -F '[ :]' '{print $2}')
    if [ "$orig_ip" != "$lan_ip" ]; then
        sed -i "s/TransPort $ori_ip:/TransPort $lan_ip:/" /etc/tor/torrc
    fi

    ori_ip=$(cat /etc/tor/torrc | grep "SocksPort.*:"|awk -F '[ :]' '{print $2}')
    if [ "$orig_ip" != "$lan_ip"  ]; then
        sed -i "s/SocksPort $ori_ip:/SocksPort $lan_ip:/" /etc/tor/torrc
    fi

    ori_ip=$(cat /etc/tor/torrc | grep DNSPort|awk -F '[ :]' '{print $2}')

    if [ "$orig_ip" != "$lan_ip"  ]; then
        sed -i "s/DNSPort $ori_ip:/DNSPort $lan_ip:/" /etc/tor/torrc
    fi
}

configure_tor_countries() {
    TORRC_FILE="/etc/tor/torrc"

    [ ! -f "$TORRC_FILE" ] && return
    
    countries=$(uci get tor.global.countries 2>/dev/null)
    manual=$(uci get tor.global.manual 2>/dev/null)
    [ "$manual" != "1" ] && return
    
    [ -z "$countries" ] && return

    sed -i 's/.*GeoIPFile/GeoIPFile/' "$TORRC_FILE"

    if ! grep -q "^StrictNodes 1" "$TORRC_FILE"; then
        echo "StrictNodes 1" >> "$TORRC_FILE"
    fi

    exit_nodes="ExitNodes"
    for country in $countries; do
        exit_nodes="$exit_nodes {$country},"
    done
    exit_nodes=${exit_nodes%,}

    if grep -q "^ExitNodes" "$TORRC_FILE"; then
        sed -i '/^ExitNodes/d' "$TORRC_FILE"
    fi

    echo "$exit_nodes" >> "$TORRC_FILE"
}

stop_tor()
{
    local enable=$(uci get tor.global.enable)
    [ $enable != "1" ] && exit 0
    uci set firewall.tor_dhcp.enabled="0"
    uci set firewall.tor_dns.enabled="0"
    uci set firewall.tor_tras.enabled="0"
    uci set firewall.tor_socks.enabled="0"
    uci set firewall.tor_allow_http.enabled="0"
    uci set firewall.tor_allow_https.enabled="0"
    uci set firewall.tor_allow_luci_http.enabled="0"
    uci set firewall.tor_allow_luci_https.enabled="0"
    uci set firewall.tor_allow_adguardhome.enabled="0"
    uci set firewall.tor_allow_ssh.enabled="0"
    uci set firewall.tor_allow.enabled="0"
    uci set firewall.dns_int.enabled="0"
    uci set firewall.tcp_int.enabled="0"
    uci set firewall.@forwarding[0].enabled="1"
    uci set firewall.guestzone_fwd.enabled="1"

    uci commit firewall
    sync

    /etc/init.d/firewall reload
    /etc/init.d/tor stop
    /etc/init.d/tor disable
    rm /var/lib/tor/control.log
}

start_tor()
{
    local enable=$(uci get tor.global.enable)
    [ $enable != "1" ] && exit 0

    replace_ip

    uci set firewall.tor_dhcp.enabled="1"
    uci set firewall.tor_dns.enabled="1"
    uci set firewall.tor_tras.enabled="1"
    uci set firewall.tor_socks.enabled="1"
    uci set firewall.tor_allow_http.enabled="1"
    uci set firewall.tor_allow_https.enabled="1"
    uci set firewall.tor_allow_luci_http.enabled="1"
    uci set firewall.tor_allow_luci_https.enabled="1"
    uci set firewall.tor_allow_adguardhome.enabled="1"
    uci set firewall.tor_allow_ssh.enabled="1"
    uci set firewall.tor_allow.enabled="1"
    uci set firewall.dns_int.enabled="1"
    uci set firewall.tcp_int.enabled="1"
    uci set firewall.@forwarding[0].enabled="0"
    uci set firewall.guestzone_fwd.enabled="0"

    uci commit firewall
    sync

    /etc/init.d/tor stop
    rm /var/lib/tor/control.log
    /etc/init.d/firewall reload
    /etc/init.d/tor enable
    /etc/init.d/tor start
    /usr/bin/clean_client_conntrack
}

case $1 in
    stop_tor)
        stop_tor;;
    start_tor)
        start_tor;;
    replace_ip)
        replace_ip;;
    configure_tor_countries)
        configure_tor_countries;;
esac
