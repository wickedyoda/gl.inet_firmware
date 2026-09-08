#!/bin/sh
UNINSTALLED=0

/etc/init.d/uhttpd stop 2>/dev/null &

if [ -d /etc/luci_ipks ]; then
    pkgs=""
    for ipk_file in /etc/luci_ipks/*.ipk; do
        filename=$(basename "$ipk_file")

        pkg_name=$(echo "$filename" | cut -d'_' -f1)

        if [ -n "$pkg_name" ]; then
            if [ -n "$(echo $pkg_name | grep "nixio")" ]; then
                model=$(cat /proc/gl-hw-info/model)
                case $model in
                    be10000|be14000|mt3600be|mt5100)
                        continue
                        ;;
                    *)
                        ;;
                esac
            fi

            pkgs=$pkgs" "$pkg_name
        fi
    done

    opkg remove $pkgs --force-depends 2>/dev/null
else
    opkg remove luci --force-depends 2>/dev/null
    opkg remove luci-compat --force-depends 2>/dev/null
    opkg remove luci-i18n-base-en --force-depends 2>/dev/null
    opkg remove luci-i18n-base-zh-cn --force-depends 2>/dev/null
    opkg remove luci-i18n-firewall-en --force-depends 2>/dev/null
    opkg remove luci-i18n-firewall-zh-cn --force-depends 2>/dev/null
    opkg remove luci-i18n-opkg-en --force-depends 2>/dev/null
    opkg remove luci-i18n-opkg-zh-cn --force-depends 2>/dev/null
    opkg remove rpcd-mod-rrdns --force-depends 2>/dev/null
fi

if [ -e /etc/init.d/uhttpd ]; then
    uci set uhttpd.main.inited="0"
    uci delete uhttpd.main.listen_http
    uci delete uhttpd.main.listen_https
    uci add_list uhttpd.main.listen_http="127.0.0.1:8080"
    uci add_list uhttpd.main.listen_https="127.0.0.1:8443"
    uci commit uhttpd
fi

echo $UNINSTALLED > /tmp/luci_status 

sync
