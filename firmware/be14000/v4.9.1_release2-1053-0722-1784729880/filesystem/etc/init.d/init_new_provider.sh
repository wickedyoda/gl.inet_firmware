#!/bin/sh /etc/rc.common

START=90

ensure_expressvpn_group_visible() {
    local gid

    gid=$(uci -q get wireguard.ExpressVPN.group_id)
    [ -n "$gid" ] || return
    uci -q set "wireguard.group_${gid}.show=1"
    uci -q commit wireguard
    sync
}

cleanup_expressvpn_legacy_profile() {
    local changed=0

    if uci -q delete expressvpn.global.oidc_client_secret; then
        changed=1
    fi
    [ "$changed" = "0" ] || uci -q commit expressvpn
    rm -f /etc/expressvpn/client_credentials
}

start() {
    # Read the partner flag to decide which providers to initialize
    . /etc/wireguard/scripts/get_partner.sh

    if is_expressvpn_device; then
        cleanup_expressvpn_legacy_profile
        # Partner devices initialize only ExpressVPN and skip other providers
        if ! uci -q get wireguard.ExpressVPN > /dev/null; then
        {
            echo "config providers 'ExpressVPN'
        option auth_type '1'
        option procedure '0'
" >> /etc/config/wireguard
        }
        fi

        ubus call gl-session call "{\"module\":\"wg_client\",\"func\":\"init_provider_group\",\"params\":{}}" > /dev/null
        ensure_expressvpn_group_visible
        return
    fi

    # Regular devices initialize all providers except ExpressVPN, which is partner-only
    if ! uci -q get wireguard.Hideme > /dev/null; then
    {
            echo "config providers 'Hideme'
            option auth_type '1'
            option procedure '0'
            " >> /etc/config/wireguard
    }
    fi

    if ! uci -q get wireguard.IPVanish > /dev/null; then
    {
        echo "config providers 'IPVanish'
        option auth_type '1'
        option procedure '1'
        " >> /etc/config/wireguard
    }
    fi

    if ! uci -q get wireguard.NordVPN > /dev/null; then
    {
        echo "config providers 'NordVPN'
        option auth_type '2'
        option procedure '1'
        " >> /etc/config/wireguard
    }
    fi

    if ! uci -q get wireguard.PureVPN > /dev/null; then
    {
        echo "config providers 'PureVPN'
        option auth_type '1'
        option procedure '0'
        " >> /etc/config/wireguard
    }
    fi

    if ! uci -q get wireguard.PIA > /dev/null; then
    {
        echo "config providers 'PIA'
        option auth_type '1'
        option procedure '1'
        " >> /etc/config/wireguard
    }
    fi

    if ! uci -q get wireguard.Surfshark > /dev/null; then
    {
        echo "config providers 'Surfshark'
        option auth_type '1'
        option procedure '1'
        " >> /etc/config/wireguard
    }
    fi

    if ! uci -q get wireguard.Windscribe > /dev/null; then
    {
        echo "config providers 'Windscribe'
        option auth_type '1'
        option procedure '1'
        " >> /etc/config/wireguard
    }
    fi

    ubus call gl-session call "{\"module\":\"wg_client\",\"func\":\"init_provider_group\",\"params\":{}}" > /dev/null
}
