#!/bin/sh

# shellcheck disable=SC3048

. /lib/functions/gl_util.sh

group_id=$1
peer_id=$2

try_connect()
{
    local peer=$1
    config_get peer_group_id "$peer" group_id

    [ "$peer_group_id" != "$group_id" ] && return

    local peer_id=$(echo "$peer" | sed -E 's/peer_([0-9]+)/\1/')
    
    ubus call gl-session call "{\"module\":\"wg-client\",\"func\":\"start\",\"params\":{\"group_id\":$group_id,\"peer_id\":$peer_id}}" > /dev/null

    trap 'return' SIGUSR1

    local count=0
    while [ $count -lt 30 ]; do
        sleep 1   
        state=$(cat /tmp/wireguard/wgclient_state 2>/dev/null)
        [ "$state" = "connected" ] && echo "connect success" && exit 0

        count=$((count+1))
    done

    return
}

config_load wireguard
if [ "$peer_id" = "" ]; then
    config_foreach try_connect peers
else
    try_connect "peer_"$peer_id
fi

echo "connect failed"
ubus call gl-session call "{\"module\":\"wg-client\",\"func\":\"stop\",\"params\":{}}" > /dev/null
