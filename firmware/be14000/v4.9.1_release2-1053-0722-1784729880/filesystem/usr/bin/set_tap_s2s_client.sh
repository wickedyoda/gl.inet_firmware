#!/bin/sh

. /lib/functions/gl_util.sh

notify_vpn_status() {
    status=$(ubus call gl-session call '{"module":"vpn-client", "func":"get_status"}' | jsonfilter -e '@.result')
    ubus call gl-session notify "{\"name\": \"vpnclient.status\", \"data\":$status}"
}

uci_supports_save_path_option() {
    uci -h 2>&1 | grep -q -- '-t <path>'
}

cleanup_uci_tmpdir() {
    [ -n "$uci_tmpdir" ] || return 0
    rm -rf "$uci_tmpdir"
    uci_tmpdir=""
}

init_uci_tmpdir() {
    if uci_supports_save_path_option; then
        uci_tmpdir="$(mktemp -d /tmp/set_tap_s2s_client.XXXXXX 2>/dev/null)" || return 0
        use_uci_save_path=1
    fi
}

uci_stage_cmd() {
    if [ "$use_uci_save_path" = 1 ]; then
        uci -t "$uci_tmpdir" "$@"
    else
        uci "$@"
    fi
}

uci_commit_cmd() {
    if [ "$use_uci_save_path" = 1 ]; then
        uci -t "$uci_tmpdir" commit "$@"
    else
        uci commit "$@"
    fi
}

start() {
    local group_id="$1"
    local client_id="$2"

    if [ -f "/usr/bin/gl-vlan-lifecycle" ]; then
        /usr/bin/gl-vlan-lifecycle tap_s2s_enter
    fi
    local uci_tmpdir use_uci_save_path=0

    init_uci_tmpdir

    uci_stage_cmd -q delete network.ovpnclient
    uci_stage_cmd set network.ovpnclient=interface
    uci_stage_cmd set network.ovpnclient.proto='ovpnclient'
    uci_stage_cmd set network.ovpnclient.config="${group_id}_${client_id}"
    uci_stage_cmd set network.ovpnclient.disabled='0'
    uci_commit_cmd network

    cleanup_uci_tmpdir
    /usr/bin/setup_vpn_dns up ovpnclient >/dev/null 2>&1

    /etc/init.d/network reload
    platform_usb_lan_restart
    sync

    notify_vpn_status
}

stop() {
    local uci_tmpdir use_uci_save_path=0

    init_uci_tmpdir
    uci_stage_cmd -q delete network.ovpnclient
    uci_commit_cmd network
    cleanup_uci_tmpdir

    if [ -f "/usr/bin/gl-vlan-lifecycle" ]; then
        /usr/bin/gl-vlan-lifecycle tap_s2s_exit
    fi

    /usr/bin/setup_tap_s2s client_ifdown >/dev/null 2>&1

    /etc/init.d/network reload
    platform_usb_lan_restart
    sync

    notify_vpn_status
}

operate=$1;shift

case $operate in
    "start")
        start "$1" "$2"
    ;;
    "stop")
        stop
    ;;
esac
