#!/bin/sh
# Read the partner flag from the cfg partition

PARTNER_CACHE="/tmp/gl_partner"

read_partner_from_env() {
    local cfg="/etc/fw_env_gl.config"
    [ -f "$cfg" ] || cfg="/etc/fw_env.config"
    [ -f "$cfg" ] || return
    fw_printenv -c "$cfg" partner 2>/dev/null | sed -n '1s/^[^=]*=//p'
}

get_partner() {
    local partner

    if [ -f "$PARTNER_CACHE" ]; then
        cat "$PARTNER_CACHE"
        return
    fi

    partner="$(read_partner_from_env)"
    printf '%s\n' "$partner" > "$PARTNER_CACHE"
    printf '%s\n' "$partner"
}

is_expressvpn_device() {
    [ "$(get_partner)" = "expressvpn" ]
}
