#!/bin/sh

. /lib/functions/gl_log.sh
. /lib/functions/modem.sh

ERR_CODE_OK=0
ERR_CODE_NETWORK_FAIL=1
ERR_CODE_HTTP_REQUEST_FAIL=2
ERR_CODE_HTTP_RESP_ERR_CODE=3
ERR_CODE_NO_BODY_INFO=4
ERR_CODE_NEW_VERSION_OK=5
ERR_CODE_NO_NEW_VERSION=6
ERR_CODE_PROCESS_RUNNING=7
ERR_CODE_DOWNLOAD_FAILED=8
ERR_CODE_SIZE_MISMATCH=9
ERR_CODE_SHA256_MISMATCH=10
ERR_CODE_FILE_OPERATION_FAILED=11

apn_file=$(ls /www/js/apns-full-conf* 2>/dev/null)
apn_db_version=$(echo "$apn_file" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)

upgrade_available=""
apn_db_new_version=""
download_path=""
sha256=""
size=""

cleanup_pid() {
    rm -f /tmp/apn_update_pid
}

cleanup_apn_db() {
    rm -f /www/js/apns-full-conf-${apn_db_new_version}.json.gz
}

check_network() {
    log_info $LINENO "modem" "Network checking ..."
    local retry_count=0
    
    while [ $retry_count -lt 5 ]; do
        if grep -qE '^[^:]+:[[:space:]]*online[[:space:]]*$' "/proc/gl-kmwan/config" 2>/dev/null; then
            log_info $LINENO "modem" "Network is online"
            return 0
        else
            retry_count=$((retry_count+1))
            if [ $retry_count -lt 5 ]; then
                log_info $LINENO "modem" "Network is not ready, wait 1 seconds and retry $retry_count ..."
                sleep 1
            else
                log_info $LINENO "modem" "Network is not ready after 5 retries, exit ..."
		cleanup_pid
                exit $ERR_CODE_NETWORK_FAIL
            fi
        fi
    done
}
  

get_apn_database() {
    log_info $LINENO "modem" "Check apn database upgrade ......"
    local url_prefix=$(uci get glmodem.apn_config.apn_url 2>/dev/null)
    if [ -z "$url_prefix" ]; then
        url_prefix="https://firmware-api.gl-inet.com"
    fi

    local url="${url_prefix}/api/firmware/apn-db-check"

    local json_body="{\"apn_db_version\": \"$apn_db_version\"}"

    local response
    response=$(curl -s -w "\n%{http_code}" -X POST \
        -H "Content-Type: application/json" \
        --data "$json_body" \
        --insecure \
        --connect-timeout 5 \
        "$url")

    local http_code=$(echo "$response" | tail -1)
    local response_body=$(echo "$response" | head -n -1)

    if [ "$http_code" != "200" ]; then
        log_info $LINENO "modem" "HTTP response error code: $http_code"
	cleanup_pid
        exit $ERR_CODE_HTTP_RESP_ERR_CODE
    fi

    if [ -z "$response_body" ]; then
        log_info $LINENO "modem" "No response body"
	cleanup_pid
        exit $ERR_CODE_NO_BODY_INFO
    fi

    upgrade_available=$(echo "$response_body" | grep -o '"upgrade_available": *[^,}]*' | cut -d: -f2 | tr -d ' "')
    apn_db_new_version=$(echo "$response_body" | grep -o '"apn_db_new_version":"[^"]*' | cut -d'"' -f4)
    download_path=$(echo "$response_body" | grep -o '"download_path":"[^"]*' | cut -d'"' -f4)
    sha256=$(echo "$response_body" | grep -o '"sha256":"[^"]*' | cut -d'"' -f4)
    size=$(echo "$response_body" | grep -o '"size":"[^"]*' | cut -d'"' -f4)

    if [ "$upgrade_available" = "true" ]; then
        log_info $LINENO "modem" "apn database upgrade available, new version: $apn_db_new_version"
    else
        log_info $LINENO "modem" "apn database is up to date, no need to upgrade."
	cleanup_pid
        exit $ERR_CODE_NO_NEW_VERSION
    fi
}

download_apn_database() {
    [ -f /tmp/apn_update_pid ] && {
        log_info $LINENO "modem" "Only one apn_update process is allowed, exit......"
        exit $ERR_CODE_PROCESS_RUNNING
    }

    # kill one_click_upgrade if it is executing
    [ -f /tmp/apn_update_pid ] && {
        cat /tmp/apn_update_pid | xargs kill -9
        ps | grep "curl -C - -Ls --connect-timeout 5" | grep -v grep | xargs kill -9
        sleep 1
    }

    echo $$ > /tmp/apn_update_pid

    log_info $LINENO "modem" "Begin download apn database......"

    curl -C - -Ls --connect-timeout 5 $download_path -o /www/js/apns-full-conf-${apn_db_new_version}.json.gz >> /dev/null

    if [ $? -ne 0 ]; then
        log_info $LINENO "modem" "Download apn database failed"
        cleanup_pid
        exit $ERR_CODE_DOWNLOAD_FAILED
    fi

    actual_size=$(ls -l /www/js/apns-full-conf-${apn_db_new_version}.json.gz | awk '{print $5}')

    # check size
    if [ "$size" -eq "$actual_size" ]; then
        log_info $LINENO "modem" "Download apn database success."
    else
        log_info $LINENO "modem" "Download apn database size mismatch, exit..."
        cleanup_pid
        cleanup_apn_db
        exit $ERR_CODE_SIZE_MISMATCH
    fi

    # check sha256sum
    sha256sum=$(timeout 5 sha256sum /www/js/apns-full-conf-${apn_db_new_version}.json.gz | awk '{print $1}')
    if [ $? -eq 0 ]; then
        if [ "$sha256" != "$sha256sum" ]; then
            log_info $LINENO "modem" "Check apn database sha256sum failed, exit..."
            cleanup_pid
            cleanup_apn_db
            exit $ERR_CODE_SHA256_MISMATCH
        else
            log_info $LINENO "modem" "Check apn database sha256sum success."
        fi
    else
        log_info $LINENO "modem" "Check apn database sha256sum failed, exit..."
        cleanup_pid
        cleanup_apn_db
        exit $ERR_CODE_SHA256_MISMATCH
    fi
}

update_apn_database() {
    log_info $LINENO "modem" "Begin update apn database......"

    cp /www/js/apns-full-conf-${apn_db_new_version}.json.gz /var/run/modem/ >> /dev/null
    if [ $? -ne 0 ]; then
        log_info $LINENO "modem" "cp failed"
        cleanup_pid
        cleanup_apn_db
            exit $ERR_CODE_FILE_OPERATION_FAILED
    fi

    gzip -dc /var/run/modem/apns-full-conf-${apn_db_new_version}.json.gz > /var/run/modem/apns-full-conf.json
    rm -f /www/js/apns-full-conf-${apn_db_version}.json.gz
    rm -f /var/run/modem/apn_database_for_mccmnc.json
    log_info $LINENO "modem" "End update apn database......"
    cleanup_pid
}

main() {
    check_network
    get_apn_database
    download_apn_database
    update_apn_database
}

main
exit $ERR_CODE_OK
