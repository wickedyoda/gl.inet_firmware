#!/bin/sh
. /lib/functions.sh
. /lib/functions/gl_util.sh

TMP_DOMAINLIST_PATH=/tmp/tmp_vpn_domainlist.txt

check_file_changed() {
    local method="$1"
    local url="$2"
    local current_value=""
    local saved_value=""
    local updated=false

    TMP_FILE="/tmp/vpn_check_${method}.txt"

    url=$(echo "$url" | sed 's/[\%\?&;#]/\\&/g')

    current_value=$(curl -k -s -L -D - -o /dev/null --connect-timeout 1 -m 5 "$url" | grep -i "$method")
    [ -f "$TMP_FILE" ] && {
        saved_value=$(head -n 1 "$TMP_FILE")
    }

    [ "$current_value" != "$saved_value" ] && {
        echo "$current_value" > "$TMP_FILE"
        updated=true
    }

    echo "$updated"
}

check_curl_update_value_not_exit() {
    local url=$(echo "$1" | sed 's/[\%\?&;#]/\\&/g')
    local curl_value=$(curl -k -s -L -D - -o /dev/null --connect-timeout 1 -m 5 "$url")
    local etag_present=$(echo "$curl_value" | grep -i "ETag:" | wc -l)
    local last_modified_present=$(echo "$curl_value" | grep -i "Last-Modified:" | wc -l)
    local content_length_present=$(echo "$curl_value" | grep -i "Content-Length:" | wc -l)
    if [ "$etag_present" -eq 0 ] && [ "$last_modified_present" -eq 0 ] && [ "$content_length_present" -eq 0 ]; then
        echo "true"
    fi
}

update_domain()
{
    local url=$1
    local manual=$2
    local file_name=$3

    [ "$manual" != "0" ] || [ "$url" = "" ] && return

    local etag_changed=$(check_file_changed "ETag" "$url")
    local last_modified_changed=$(check_file_changed "Last-Modified" "$url")
    local content_length_changed=$(check_file_changed "Content-Length" "$url")
    local check_url_value_not_exit=$(check_curl_update_value_not_exit "$url")

    if [ "$etag_changed" = "true" ] || [ "$last_modified_changed" = "true" ] || [ "$content_length_changed" = "true" ] || [ "$check_url_value_not_exit" = "true" ]; then
        local response=$(ubus call gl-session call "{\"module\":\"vpn-client\",\"func\":\"check_domain_online\",\"params\":{\"url\":\"$url\"}}")
        success=$(echo $response | jsonfilter -e @.result | jsonfilter -e @.success)
        rm "$file_name" -rf
        [ $success ] && {
            mkdir -p "/etc/domain_mac_list/"
            mv "$TMP_DOMAINLIST_PATH" $file_name
        }
    fi
}

update()
{
    config_get url "$1" to_url
    config_get manual "$1" to_manual
    [ "$manual" != "0" ] || [ "$url" = "" ] && return

    config_get file_name "$1" to_list_external
    [ "$file_name" = "" ] && {
         config_get tunnel_id "$1" tunnel_id
         file_name="/etc/domain_mac_list/dst_net"$tunnel_id
    }

    update_domain $url $manual $file_name
    echo "url=$url"
    echo "manual=$manual"
    echo "file_name=$file_name"
}

config_load route_policy
config_foreach update rule


uci commit route_policy
sync
/usr/bin/rtp2.sh&

exit $?
