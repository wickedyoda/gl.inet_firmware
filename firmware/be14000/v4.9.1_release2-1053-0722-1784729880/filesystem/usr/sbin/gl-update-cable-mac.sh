#!/bin/sh

generate_random_macaddr() {
    local mac
    mac=$(dd if=/dev/urandom bs=1 count=6 2>/dev/null | hexdump -v -e '1/1 "%02X"' | sed 's/\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)/\1:\2:\3:\4:\5:\6/')

    local first_byte=$(echo "$mac" | cut -d: -f1)
    first_byte=$(printf "%02X" $((0x$first_byte & 0xFE | 0x02)))

    echo "$first_byte:$(echo "$mac" | cut -d: -f2-)"
}

action="$1"
changed=0
change_marker="/tmp/gl-mac-changed-$$"
rm -f "$change_marker"

update_device_mac() {
    local device="$1"
    local mode

    mode=$(uci get "network.$device.mac_mode" 2>/dev/null)

    if [ "$action" = "reboot" ]; then
        [ "$mode" != "rr" ] && return
    elif [ "$action" = "time" ]; then
        [ ! -f "/var/state/ntp-valid" ] && return

        local expire
        expire=$(uci get "network.$device.mac_expire" 2>/dev/null)

        if [ -z "$mode" ] || [ -z "$expire" ]; then
            return
        fi

        local now
        now=$(date +%s)

        if [ "$now" -lt "$expire" ]; then
            return
        fi

        local period
        period=$(echo "$mode" | sed -n 's/^r\([0-9]\+\)$/\1/p')
        local new_expire=$((now + period * 60))
        uci set "network.$device.mac_expire=$new_expire"
    else
        return
    fi

    local macaddr
    macaddr=$(generate_random_macaddr)
    uci set "network.$device.macaddr=$macaddr"
    touch "$change_marker"
}

uci show network 2>/dev/null | grep '=device$' | while read -r line; do
    device_name=$(echo "$line" | sed 's/^network\.\([^=]*\).*/\1/')
    if ! echo "$device_name" | grep -q '^\[' && [ "$device_name" != "device" ] && [ -n "$device_name" ]; then
        update_device_mac "$device_name"
        if [ -f "$change_marker" ]; then
            changed=1
        fi
    fi
done

if [ ! -f "$change_marker" ]; then
    mode=$(uci get "network.wan.mac_mode" 2>/dev/null)

    if [ "$action" = "reboot" ]; then
        if [ "$mode" = "rr" ]; then
            macaddr=$(generate_random_macaddr)
            uci set "network.wan.macaddr=$macaddr"
            touch "$change_marker"
        fi
    elif [ "$action" = "time" ]; then
        if [ -f "/var/state/ntp-valid" ]; then
            expire=$(uci get "network.wan.mac_expire" 2>/dev/null)

            if [ -n "$mode" ] && [ -n "$expire" ]; then
                now=$(date +%s)

                if [ "$now" -ge "$expire" ]; then
                    period=$(echo "$mode" | sed -n 's/^r\([0-9]\+\)$/\1/p')
                    new_expire=$((now + period * 60))
                    uci set "network.wan.mac_expire=$new_expire"

                    macaddr=$(generate_random_macaddr)
                    uci set "network.wan.macaddr=$macaddr"
                    touch "$change_marker"
                fi
            fi
        fi
    fi
fi

uci commit network

sync

if [ -f "$change_marker" ] && [ "$action" != "reboot" ]; then
    /etc/init.d/network reload
fi

rm -f "$change_marker"
