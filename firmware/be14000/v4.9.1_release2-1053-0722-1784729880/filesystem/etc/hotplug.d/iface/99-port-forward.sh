#!/bin/sh

[ "$ACTION" = "ifup" -o "$ACTION" = "ifupdate" ] || exit 0

IF="$INTERFACE"

case "$INTERFACE" in
    wan*|wwan*|secondwan*|ppp*|lan*|guest*|br-*|eth[0-9]|eth[0-9].[0-9]*|tun*|tap*|wg*|modem*|usb*)
        /usr/bin/port_forward.lua &
        ;;
esac

exit 0
