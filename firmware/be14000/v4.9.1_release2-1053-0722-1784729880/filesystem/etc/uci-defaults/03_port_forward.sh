#!/bin/sh

GL_PREFIX="GL-"
FW_CFG=firewall
PF_CFG=port_forward

changed=0

uci -q show $PF_CFG >/dev/null || touch /etc/config/$PF_CFG

GL_SECS=""

. /lib/functions.sh

has_all_opts() {
    sec="$1"
    shift

    for opt in "$@"; do
        uci -q get firewall.$sec.$opt >/dev/null || return 1
    done

    return 0
}

handle_fw_redirect() {
    sec="$1"

    name=$(uci -q get firewall.$sec.name)
    echo "$name" | grep -q "^$GL_PREFIX" || return

    enabled=$(uci -q get firewall.$sec.enabled)
    dest_ip=$(uci -q get firewall.$sec.dest_ip)

    if [ -z "$enabled" ]; then
        enabled=1
    elif [ "$enabled" != "0" ] && [ "$enabled" != "1" ]; then
        return
    fi

    [ "$enabled" = "0" ] && [ -z "$dest_ip" ] && return

    case "$name" in
        GL-DMZ|GL-DMZ-*)
            has_all_opts "$sec" src dest dest_ip proto || return
            ;;
        *)
            has_all_opts "$sec" src src_dport dest dest_ip dest_port proto || return
            ;;
    esac

    GL_SECS="$GL_SECS $sec"

    rule_exists=0

    handle_pf_redirect() {
        pf_sec="$1"
        match=1

        for opt in $(uci show firewall.$sec | cut -d. -f3 | cut -d= -f1); do
            fw_val=$(uci -q get firewall.$sec.$opt)
            pf_val=$(uci -q get port_forward.$pf_sec.$opt)
            [ "$fw_val" != "$pf_val" ] && match=0 && break
        done

        [ "$match" -eq 1 ] && rule_exists=1
    }

    config_load port_forward
    config_foreach handle_pf_redirect redirect

    if [ "$rule_exists" -eq 0 ]; then
        new_sec=$(uci add port_forward redirect)
        for opt in $(uci show firewall.$sec | cut -d. -f3 | cut -d= -f1); do
            [ "$opt" = "idx" ] && continue
            val=$(uci -q get firewall.$sec.$opt)
            uci set port_forward.$new_sec.$opt="$val"
        done
        uci set port_forward.$new_sec.enabled="$enabled"
        changed=1
    fi
}

config_load firewall
config_foreach handle_fw_redirect redirect

for sec in $(echo $GL_SECS | awk '{for(i=NF;i>=1;i--) printf "%s ", $i}'); do
    uci delete firewall.$sec
    changed=1
done

if [ "$changed" -eq 1 ]; then
    uci commit firewall
    uci commit port_forward
fi

exit 0
