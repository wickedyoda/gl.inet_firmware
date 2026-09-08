#!/bin/sh

# shellcheck disable=SC3057,SC2124
INSTALL_BY_WEB=$1
LUCI_LOCK="/tmp/luci.lock"

parse_addresses() {
    str="$@"
    len=${#str}
    ips_ports=""

    i=0
    bracket_context=0

    while [ $i -lt $len ]; do
        char=${str:$i:1}
        i=$((i+1))
        if [ "$char" = ' ' ]; then
            ips_ports=$ips_ports" "
        elif [ "$char" = '[' ]; then
            bracket_context=1
            ips_ports=$ips_ports$char
        elif [ "$char" = ']' ]; then
            bracket_context=0
            ips_ports=$ips_ports$char
        elif [ "$char" = ':' -a ! $bracket_context = 1 ]; then
            ips_ports=$ips_ports" "
        else
            ips_ports=$ips_ports$char
        fi
    done
}

configure_ports() {
    local protocol=$1
    local is_ip=1
    local luci_port=""

    [ $protocol = "http" ] && luci_port="8080" || luci_port="8443"

    for i in $ips_ports ;do
        [ $is_ip = 1 ] && {
            ip=$i
            is_ip=0
            continue
        }
        [ $is_ip = 0 ] && {
            [ -n "$i" ] && [ "$i" != "$http_port" ] && [ "$i" != "$https_port" ] && luci_port="$i"
            is_ip=1
            uci add_list uhttpd.main.listen_$protocol="$ip:$luci_port"
            continue
        }
    done

    [ $protocol = "http" ] && tor_luci_port=$luci_port || tor_luci_port_https=$luci_port
}

touch $LUCI_LOCK
if [ -d /etc/luci_ipks ]; then
    opkg install  /etc/luci_ipks/*.ipk -f /etc/luci_ipks/feeds.conf > /dev/null
    [ $? != 0 ] && {
        rm $LUCI_LOCK
        exit 1
    }
else
    opkg update > /dev/null
    [ $? != 0 ] && {
        rm $LUCI_LOCK
        exit 1
    }
    opkg install luci
    opkg install luci-compat
    opkg install luci-i18n-base-en
    opkg install luci-i18n-base-zh-cn
    opkg install luci-i18n-firewall-en
    opkg install luci-i18n-firewall-zh-cn
    opkg install luci-i18n-opkg-en
    opkg install luci-i18n-opkg-zh-cn
    opkg install rpcd-mod-rrdns
fi

[ -e /rom/www/luci-static/resources/view/network/wireless.js.mtk ] && cp /rom/www/luci-static/resources/view/network/wireless.js.mtk /www/luci-static/resources/view/network/wireless.js
[ -e /usr/lib/lua/luci-mod-network.json.mtk ] && cp /usr/lib/lua/luci-mod-network.json.mtk /usr/share/luci/menu.d/luci-mod-network.json

if [ -e /etc/init.d/uhttpd ]; then
    http_port=$(cat /etc/nginx/conf.d/gl.conf | awk '/listen/{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+;$/) {gsub(/;/,"",$i); print $i}}')
    https_port=$(cat /etc/nginx/conf.d/gl.conf | awk '/listen/{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+$/ && $(i+1) == "ssl;") {print $i}}')
    http_port_luci=$(uci -q get uhttpd.main.listen_http)
    https_port_luci=$(uci -q get uhttpd.main.listen_https)

    uci delete uhttpd.main.listen_http
    uci delete uhttpd.main.listen_https

    [ "$INSTALL_BY_WEB" = "web" ] && {
        uci add_list uhttpd.main.listen_http="0.0.0.0:8080"
        uci add_list uhttpd.main.listen_http="[::]:8080"
        uci add_list uhttpd.main.listen_https="0.0.0.0:8443"
        uci add_list uhttpd.main.listen_https="[::]:8443"
    } || {
        parse_addresses $http_port_luci
        configure_ports http

        parse_addresses $https_port_luci
        configure_ports https

        [ "$(uci -q get firewall.tor_allow_luci_http)" = "redirect" ] && {
            uci set firewall.tor_allow_luci_http.src_dport="$tor_luci_port"
            uci set firewall.tor_allow_luci_https.src_dport="$tor_luci_port_https"
            uci commit firewall
            /etc/init.d/firewall reload > /dev/null &
        } || {
            [ $(uci -q get firewall.tor_allow_http) = "redirect" ] && {
                src_ip=$(uci -q get firewall.tor_allow_http.src_ip)
                src_dip=$(uci -q get firewall.tor_allow_http.src_dip)

                uci set firewall.tor_allow_luci_http=redirect
                uci set firewall.tor_allow_luci_http.name="Allow access luci http"
                uci set firewall.tor_allow_luci_http.src=lan
                uci set firewall.tor_allow_luci_http.src_ip=$src_ip
                uci set firewall.tor_allow_luci_http.src_dip=$src_dip
                uci set firewall.tor_allow_luci_http.src_dport=$tor_luci_port
                uci set firewall.tor_allow_luci_http.family=ipv4
                uci set firewall.tor_allow_luci_http.proto=tcp
                uci set firewall.tor_allow_luci_http.target=ACCEPT

                uci set firewall.tor_allow_luci_https=redirect
                uci set firewall.tor_allow_luci_https.name="Allow access luci https"
                uci set firewall.tor_allow_luci_https.src=lan
                uci set firewall.tor_allow_luci_https.src_ip=$src_ip
                uci set firewall.tor_allow_luci_https.src_dip=$src_dip
                uci set firewall.tor_allow_luci_https.src_dport=$tor_luci_port_https
                uci set firewall.tor_allow_luci_https.family=ipv4
                uci set firewall.tor_allow_luci_https.proto=tcp
                uci set firewall.tor_allow_luci_https.target=ACCEPT

                order_num=$(cat /etc/config/firewall | grep config | grep -n tor_allow_https | awk -F : '{print $1}')
                uci reorder firewall.tor_allow_luci_http=$((order_num+1))
                uci reorder firewall.tor_allow_luci_https=$((order_num+2))
                uci commit firewall
                /etc/init.d/firewall reload > /dev/null &
            }
        }
    }

    lang_en=$(uci -q get luci.languages.en)
    if [ -z "$lang_en" ]
    then
        uci set luci.languages.en='English'
        uci commit luci
    fi

    uci set uhttpd.main.rfc1918_filter="0"
    uci set uhttpd.main.inited="1"
    uci commit uhttpd
    /etc/init.d/uhttpd restart
fi

rm $LUCI_LOCK -rf


