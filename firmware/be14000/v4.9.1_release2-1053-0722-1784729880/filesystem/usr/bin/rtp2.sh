#!/bin/sh

# shellcheck disable=SC1083
# shellcheck disable=SC3037

[ -f /tmp/run/vpn-client-booted ] || exit 0

. /lib/functions/vpn_func/fw4_func.sh
. /lib/functions/vpn_func/route_policy_func.sh
. /lib/functions/vpn_func/global_leak_drop.sh

CONFIG="route_policy"

VPN_DIRECT_TABLE=9910

from_match_result=""
to_match_result=""
to_match_result_6=""

INIT_SERVICE_POLICY_EN=""
INIT_SERVICE_POLICY_VIA=""
INIT_SERVICE_POLICY_SET_DONE=0
INIT_ALWAYS_VPN_SET_DONE=0
NOT_RELOAD_NETWORK=0

VPN_TMP_DIR="/tmp/run/vpn_tmp_dir"
mkdir -p ${VPN_TMP_DIR}
FILE_VPN_DNS_RULE="${VPN_TMP_DIR}/vpn_dns_rule"

FW3_HOTPLUG_FILE_PATH="${VPN_TMP_DIR}/vpn_hotplug.ipt"
[ -f "${FW3_HOTPLUG_FILE_PATH}" ] || {
    echo '#!/bin/sh' > ${FW3_HOTPLUG_FILE_PATH}
    chmod 755 ${FW3_HOTPLUG_FILE_PATH}
}

VPN_TABLE_NAME="inet vpn_table"
VPN_FW4_FILE_PATH="${VPN_TMP_DIR}/vpn_fw4.nft"
VPN_FW4_HOTPLUG_FILE_PATH="${VPN_TMP_DIR}/vpn_hotplug.nft"

QUIET="${QUIET:-1}"
LOGFILE="${LOGFILE:-}"

[ "$QUIET" -eq 1 ] && {
    if [ -n "$LOGFILE" ]; then
        exec >>"$LOGFILE"
    else
        exec >/dev/null 2>&1
    fi
}

vpn_table_add_fw4_rule_directly() {
    fw4_add_member_directly "${VPN_TABLE_NAME}" "rule" "$1 $2"
}

vpn_table_insert_fw4_rule_directly() {
    fw4_insert_rule_directly "${VPN_TABLE_NAME}" "$1 $2" "$3"
}

fw4_set_add_hotplug_statement() {
    fw4_set_add_statement_to_file "$VPN_FW4_HOTPLUG_FILE_PATH" "$1"
}

fw4_set_delete_hotplug_statement() {
    fw4_set_delete_statement_from_file "$VPN_FW4_HOTPLUG_FILE_PATH" "$1"
}

fw4_vpn_table_set_context() {
    fw4_init_set_context "${VPN_FW4_FILE_PATH}" "${VPN_TABLE_NAME}"
}

fw4_vpn_set_finish_and_apply() {
    fw4_set_finish_and_apply
    nft -f $VPN_FW4_HOTPLUG_FILE_PATH
}

fw3_set_add_hotplug_statement() {
    local content=$1
    echo -e "
${content}" >> $FW3_HOTPLUG_FILE_PATH
}

fw3_set_delete_hotplug_statement() {
    local content="$1"
    [ -n "${content}" ] && sed -i "/${content}/d" $FW3_HOTPLUG_FILE_PATH
}

fw3_apply_hotplug_rule() {
    eval $FW3_HOTPLUG_FILE_PATH
}

# dst_net配置（名单内容和黑白属性）无变化时，先保存，后恢复
check_and_save_nft_sets() {
    rm -f /tmp/run/nft_sets_to_restore.sh 2>/dev/null
    nft_sets=$(nft list sets inet | grep -e "set dst_net" | awk '{print $2}')
    if [ -n "$nft_sets" ]; then
        for nft_set in $nft_sets; do
            tunnel_id=$(echo "$nft_set" | sed -e 's/^dst_net//' -e 's/_6$//')
            file_path="/etc/domain_mac_list/dst_net${tunnel_id}"

            if [ -f "$file_path" ]; then
                # 检查当前配置中的黑白名单属性
                current_to=""
                current_to=$(uci -q show route_policy | grep "to=.*dst_net${tunnel_id}" | cut -f2 -d= | tr -d "'")
                current_is_blacklist=0
                if echo "$current_to" | grep -q "^!dst_net"; then
                    current_is_blacklist=1
                fi

                md5_file="/tmp/run/nft_${nft_set}.md5"

                current_md5=$(echo "$(cat "$file_path") $current_is_blacklist" | md5sum | awk '{print $1}')

                if [ -f "$md5_file" ]; then
                    old_md5=$(cat "$md5_file")

                    if [ "$current_md5" = "$old_md5" ]; then
                        echo "Saving nft set $nft_set to /tmp/run/${nft_set}.nft"
                        nft list set inet vpn_table $nft_set > "/tmp/run/${nft_set}.nft"

                        echo "# Restore $nft_set" >> /tmp/run/nft_sets_to_restore.sh
                        echo "if [ -f \"/tmp/run/${nft_set}.nft\" ]; then" >> /tmp/run/nft_sets_to_restore.sh
                        echo "    nft -f \"/tmp/run/${nft_set}.nft\"" >> /tmp/run/nft_sets_to_restore.sh
                        echo "fi" >> /tmp/run/nft_sets_to_restore.sh
                    fi
                fi
                echo "$current_md5" > "$md5_file"
            fi
        done
    fi
}

restore_nft_sets() {
    if [ -f "/tmp/run/nft_sets_to_restore.sh" ]; then
        sh /tmp/run/nft_sets_to_restore.sh
        rm -f /tmp/run/nft_sets_to_restore.sh
        rm -f /tmp/run/dst_net*.nft
    fi
}

clean_local_direct_route() {
    ip route flush table ${VPN_DIRECT_TABLE}
    ip -6 route flush table ${VPN_DIRECT_TABLE}
}

copy_local_direct_route() {
    local wan_dev_list="$(get_wan_device_list)"
    wan_dev_list="${wan_dev_list} lo"
    ip route show table main | while read line; do
        for wan_dev in ${wan_dev_list} ;do
            line="$(echo "${line}" | grep -v "dev ${wan_dev}")"
        done
        line="$(echo "${line}" | sed 's/ linkdown//g')"
        [ -n "$line" ] && ip route add ${line} table ${VPN_DIRECT_TABLE}
    done

    if [ "$v6_enabled" = '1' ] ;then
        ip -6 route show table main | while read line; do
            for wan_dev in ${wan_dev_list} ;do
                line="$(echo "${line}" | grep -v "dev ${wan_dev}")"
            done
            line="$(echo "${line}" | grep -v "^fe80::/64")"
            line="$(echo "${line}" | grep -v " fe80::/64")"
            line="$(echo "${line}" | sed 's/ linkdown//g')"
            [ -n "$line" ] && ip -6 route add ${line} table ${VPN_DIRECT_TABLE}
        done
    fi
}

clean_dnsmasq_setting() {
    for file in /tmp/dnsmasq.d*/*; do
        if [ -n "$(echo "= File: $file =" | grep via_domain)" ]; then
            rm -f "$file"
        fi
    done
}

add_from_mac_entry() {
    local mac=$1
    local set_name=$2
    if [ "$use_fw4" = '1' ] ;then
       mac_set="${mac_set}${mac_set:+, }${mac}"
    else
        echo "add $set_name $mac" >>/tmp/tmp_mac_set 2>/dev/null
    fi
}

parse_from_mac() {
    local section=$1
    local from=$2
    local set_name="${from}"

    local mac_set=''
    if [ "$use_fw4" = '1' ] ;then
        fw4_set_create_member_of_table "set" "$set_name" "type ether_addr;flags dynamic;"
    else
        echo "create $set_name hash:mac" >/tmp/tmp_mac_set
    fi

    # Add MAC addresses from config file
    config_list_foreach "$section" from_mac add_from_mac_entry "$set_name"

    # Add MAC addresses from external file if specified
    local from_list_external
    config_get from_list_external "$section" from_list_external
    if [ -n "$from_list_external" ]; then
        local mac_file="$from_list_external"
        if [ -f "$mac_file" ]; then
            while read -r mac; do
                [ -n "$mac" ] && add_from_mac_entry "$mac" "$set_name"
            done < "$mac_file"
        fi
    fi

    if [ "$use_fw4" = '1' ] ;then
        [ -n "${mac_set}" ] && fw4_set_add_append_statement "add element $VPN_TABLE_NAME $set_name { ${mac_set} }"
    else
        ipset restore -exist -file /tmp/tmp_mac_set
        rm /tmp/tmp_mac_set
    fi
}

get_network_device() {
    local network="$1"
    local device

    case "$network" in
        "lan"|"guest")
            echo "br-$network"
            return
            ;;
        "wgserver"|"ovpnserver")
            echo "$network"
            return
            ;;
    esac

    device=$(uci get network."$network".device 2>/dev/null)
    if [ -n "$device" ]; then
        echo "$device"
        return
    fi
    device=$(uci get network."$network".ifname 2>/dev/null)
    if [ -n "$device" ]; then
        echo "$device"
        return
    fi
}

prepare_for_from_rule() {
    local from_type=$1
    local from=$2
    from_match_result=""

    case "$from_type" in
    "ipset")
        echo "$from" | grep -q "^!" && from=$(echo "$from" | cut -c 2-)
        parse_from_mac "$section" "$from"
        ;;
    esac
}

fw3_get_from_filter_option() {
    local from_type=$1
    local from=$2
    from_match_result=""

    case "$from_type" in
    "ipset")
        local negate=""
        echo "$from" | grep -q "^!" && negate="!" && from=$(echo "$from" | cut -c 2-)
        from_match_result="-m set $negate --match-set $from src"
        ;;
    "interface")
        local if_set=""
        for interface in $from; do
            if_set="${if_set}${if_set:+" "}$(get_network_device "$interface")"
        done
        from_match_result="${if_set:="noneif"} $from_match_result"
        ;;
    "device")
        from_match_result="$from"
        ;;
    "port")
        ebtables -t filter -A INPUT -i "$from" -j mark --mark-set "$mark"
        ;;
    "process_gid")
        from_match_result="$from"
        ;;
    esac
}

fw4_get_from_filter_option() {
    local from_type=$1
    local from=$2

    case "$from_type" in
    "ipset")
        local negate=""
        echo "$from" | grep -q "^!" && negate="!=" && from=$(echo "$from" | cut -c 2-)
        fw4_from_option="ether saddr ${negate} @${from}"
        ;;
    "interface")
	local if_set=''
        for interface in $from; do
            if_set="${if_set}${if_set:+, }$(get_network_device "$interface")"
        done
        fw4_from_option="iifname { ${if_set:="noneif"} }"
        ;;
    "device")
        fw4_from_option="$from"
        ;;
    "port")
        ebtables -t filter -A INPUT -i "$from" -j mark --mark-set "$mark"
        ;;
    "process_gid")
        fw4_from_option="$from"
        ;;
    esac
}

parse_to_list_ip() {
    local to=$1
    local domain_ip_file=$2
    local ipset_name="$to"

    local ip_set=''
    local ip_set_6=''

    if [ "$use_fw4" = '1' ] ;then
        fw4_set_create_member_of_table "set" "$ipset_name" "type ipv4_addr;flags dynamic;"
        fw4_set_create_member_of_table "set" "${ipset_name}_sta" "type ipv4_addr;flags interval;auto-merge"
        fw4_set_create_member_of_table "set" "${ipset_name}_6" "type ipv6_addr;flags dynamic;"
        fw4_set_create_member_of_table "set" "${ipset_name}_6_sta" "type ipv6_addr;flags interval;auto-merge"
    else
       echo "create $ipset_name hash:net" >/tmp/to_ip_tmp 2>/dev/null
       echo "create ${ipset_name}_6 hash:net family inet6" >>/tmp/to_ip_tmp 2>/dev/null
    fi

    [ -f "$domain_ip_file" ] && {
        local ip_list=$(cat "$domain_ip_file" | sed -e 's/\s*#.*$//' | grep -oE '\b([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?\b')
        for ip in ${ip_list}; do
            if [ "$use_fw4" = '1' ] ;then
                ip_set="${ip_set}${ip_set:+, }${ip}"
            else
                echo "add $ipset_name ${ip}" >>/tmp/to_ip_tmp 2>/dev/null
            fi
        done
        local ip_list_6=$(cat "$domain_ip_file" | sed -e 's/\s*#.*$//' | grep -oE '\b(:?[0-9a-fA-F]{0,4}:){1,7}[0-9a-fA-F]{0,4}(/[0-9]{1,3})?\b')
        for ip_6 in ${ip_list_6}; do
            if [ "$use_fw4" = '1' ] ;then
                ip_set_6="${ip_set_6}${ip_set_6:+, }${ip_6}"
            else
                echo "add ${ipset_name}_6 ${ip_6}" >>/tmp/to_ip_tmp 2>/dev/null
            fi
        done
    }

    if [ "$use_fw4" = '1' ] ;then
        [ -n "${ip_set}" ] && fw4_set_add_append_statement "add element $VPN_TABLE_NAME ${ipset_name}_sta { ${ip_set} }"
        [ -n "${ip_set_6}" ] && fw4_set_add_append_statement "add element $VPN_TABLE_NAME ${ipset_name}_6_sta { ${ip_set_6} }"
    else
        ipset restore -exist -file /tmp/to_ip_tmp
        rm /tmp/to_ip_tmp
    fi
}

prepare_for_to_rule() {
    local to_type=$1
    local to=$2

    if [ "$to_type" = "ipset" ]; then
        echo "$to" | grep -q "^!" && to=$(echo "$to" | cut -c 2-)

	local to_list_external
        config_get to_list_external "$section" to_list_external
        mkdir -p /tmp/run/domain_ips
        local tmp_domain_file="/tmp/run/domain_ips/$(basename "${to_list_external}")_tmp"

        local domain_ips=$(uci -q get route_policy.$section.to_domain_ip)
        [ -n "$domain_ips" ] && echo "$domain_ips" | tr ' ' '\n' > "$tmp_domain_file"

        [ -f "$to_list_external" ] && {
            cat "$to_list_external" >> "$tmp_domain_file"
        }

        parse_to_list_ip "$to" "$tmp_domain_file"

        rm -f "$tmp_domain_file"

    fi
}

fw3_get_to_filter_option() {
    local to_type=$1
    local to=$2
    to_match_result=""
    to_match_result_6=""

    if [ "$to_type" = "ipset" ]; then
        local negate=""
        echo "$to" | grep -q "^!" && negate="!" && to=$(echo "$to" | cut -c 2-)

        to_match_result="-m set $negate --match-set $to dst"
        to_match_result_6="-m set $negate --match-set ${to}_6 dst"
    fi
}

fw4_get_to_filter_option() {
    local to_type=$1
    local to=$2
    fw4_to_option=""

    if [ "$to_type" = "ipset" ]; then
        local negate=""
        echo "$to" | grep -q "^!" && negate="!=" && to=$(echo "$to" | cut -c 2-)

        local split=''
        [ -z "$negate" ] && split='#'

        fw4_to_option="ip daddr $negate @${to} ${split} ip daddr $negate @${to}_sta"
        fw4_to_option="${fw4_to_option}#ip6 daddr ${negate} @${to}_6 ${split} ip6 daddr ${negate} @${to}_6_sta"
    fi
}

get_mark_of_interface() {
        local interface="$1"
        local mark=""

        if [ "${interface}" = "novpn" ]; then
                mark="${nonevpn_mark}"
        else
                local mark_base
                case "$interface" in
                        wgclient*)
                                mark_base=$wg_mark_base
                                ;;
                        ovpnclient*)
                                mark_base=$ovpn_mark_base
                                ;;
                        *)
                                echo "Invalid interface: $interface"
                                return 1
                                ;;
                esac

				local index=$(echo "$interface" | awk '{print substr($0, length($0), 1)}')
                if [ "$index" -lt 1 -o "$index" -gt 5 ]; then
                        echo "Invalid instance index in interface: $interface"
                        return 1
                fi

				local mark_base_high=$(echo "$mark_base" | head -c 3)
                local mark_high=$(printf "%x" $(($mark_base_high+${index}-1)))
                mark=0x${mark_high}000
        fi
        echo "${mark}"
}

set_mark_from_via() {
    local via="$1"
    local section="$2"  # 添加section参数
    local mark=""

    mark="$(get_mark_of_interface "$via")"
    [ -n "${mark}" -a "$via" != novpn ] && {
        mkdir -p /tmp/dnsmasq.d.${via}
        echo "mark=${mark}" >/tmp/dnsmasq.d.${via}/mark
        echo 'no-dhcp-interface=*' >/tmp/dnsmasq.d.${via}/no-dhcp
    }

    # 将mark写入到uci配置
    if [ -n "$section" ]; then
        uci set ${CONFIG}.${section}.mark="$mark"
        uci commit ${CONFIG}
    fi
}

handle_service_policy() {
    local via="$1"
    local service_policy="$2"

    if [ "$service_policy" = 1 ]; then
        if [ "$INIT_SERVICE_POLICY_SET_DONE" = 0 ]; then
            uci set ${CONFIG}.global.service_policy_en=1
            uci set ${CONFIG}.gl_process.via="$via"
            uci commit ${CONFIG}
            INIT_SERVICE_POLICY_SET_DONE=1
        fi
    fi
}

handle_always_vpn_policy () {
    if [ "$INIT_ALWAYS_VPN_SET_DONE" = 0 -a "$via" != novpn ]; then
        uci set ${CONFIG}.gl_process_vpn.via="$via"
        uci commit ${CONFIG}
        INIT_ALWAYS_VPN_SET_DONE=1
    fi
}

fw3_mount_tunnel_chain() {
    if [ "$cfgtype" = "rule_process" ]; then
        iptables -w -t mangle -F TUNNEL${tunnel_id}_LOCAL_POLICY >/dev/null 2>&1
        iptables -w -t mangle -N TUNNEL${tunnel_id}_LOCAL_POLICY >/dev/null 2>&1
        iptables -w -t mangle -C LOCAL_POLICY -j TUNNEL${tunnel_id}_LOCAL_POLICY >/dev/null 2>&1 || \
            iptables -w -t mangle -A LOCAL_POLICY -j TUNNEL${tunnel_id}_LOCAL_POLICY
        [ "$v6_enabled" = '1' ] && {
            ip6tables -w -t mangle -F TUNNEL${tunnel_id}_LOCAL_POLICY >/dev/null 2>&1
            ip6tables -w -t mangle -N TUNNEL${tunnel_id}_LOCAL_POLICY >/dev/null 2>&1
            ip6tables -w -t mangle -C LOCAL_POLICY -j TUNNEL${tunnel_id}_LOCAL_POLICY >/dev/null 2>&1 || \
                ip6tables -w -t mangle -A LOCAL_POLICY -j TUNNEL${tunnel_id}_LOCAL_POLICY
        }
    else
        iptables -w -t mangle -F TUNNEL${tunnel_id}_ROUTE_POLICY >/dev/null 2>&1
        iptables -w -t mangle -N TUNNEL${tunnel_id}_ROUTE_POLICY >/dev/null 2>&1
        iptables -w -t mangle -C ROUTE_POLICY -m addrtype ! --dst-type LOCAL -j TUNNEL${tunnel_id}_ROUTE_POLICY >/dev/null 2>&1 || \
            iptables -w -t mangle -A ROUTE_POLICY -m addrtype ! --dst-type LOCAL -j TUNNEL${tunnel_id}_ROUTE_POLICY
        [ "$v6_enabled" = '1' ] && {
            ip6tables -w -t mangle -F TUNNEL${tunnel_id}_ROUTE_POLICY >/dev/null 2>&1
            ip6tables -w -t mangle -N TUNNEL${tunnel_id}_ROUTE_POLICY >/dev/null 2>&1
            ip6tables -w -t mangle -C ROUTE_POLICY -m addrtype ! --dst-type LOCAL -j TUNNEL${tunnel_id}_ROUTE_POLICY >/dev/null 2>&1 || \
                ip6tables -w -t mangle -A ROUTE_POLICY -m addrtype ! --dst-type LOCAL -j TUNNEL${tunnel_id}_ROUTE_POLICY
        }
    fi
}

fw4_mount_tunnel_chain() {
    if [ "$cfgtype" = "rule_process" ]; then
        fw4_set_create_chain "TUNNEL${tunnel_id}_LOCAL_POLICY"
        fw4_set_add_rule_to_chain "LOCAL_POLICY" "jump TUNNEL${tunnel_id}_LOCAL_POLICY"
    else
        fw4_set_create_chain "TUNNEL${tunnel_id}_ROUTE_POLICY"
        fw4_set_add_rule_to_chain "ROUTE_POLICY" "fib daddr type != { local, broadcast, multicast } jump TUNNEL${tunnel_id}_ROUTE_POLICY"
    fi
}

fw3_set_tunnel_rule() {
        local call_type="$1";shift
        local rule_type="$1";shift
        local target_type="$1";shift
        local mark="$1";shift
        local v6_match

        local write_way="-A"
        [ "${call_type}" = "hotplug" ] && [ "${rule_type}" != "rule_for_failover" ] && write_way="-I"

        local comment=''
        [ "${rule_type}" = "rule_for_use_vpn" ] && comment="TUNNEL${tunnel_id} rule for set mark"

        case "${target_type}" in
            'drop')
                target="-j DROP"
            ;;
            'set mark')
                target="-j MARK --set-xmark ${mark}/${vpn_mark_mask}"
            ;;
            *)
                target="-j MARK --set-xmark ${mark}/${vpn_mark_mask}"
            ;;
        esac

        case "$from_type" in
            ipset)
                match="${from_match_result}"
                match="-m mark --mark 0x0/${vpn_mark_mask} ${match}"
                [ -n "$to_match_result" ] && match="${match} ${to_match_result}"
                iptables -w -t mangle -C TUNNEL${tunnel_id}_ROUTE_POLICY ${comment:+-m comment --comment "${comment}"} $match ${target} >/dev/null 2>&1 || \
                    iptables -w -t mangle ${write_way} TUNNEL${tunnel_id}_ROUTE_POLICY ${comment:+-m comment --comment "${comment}"} $match ${target}
                [ "$v6_enabled" = '1' ] && {
                    v6_match="${from_match_result}"
                    v6_match="-m mark --mark 0x0/${vpn_mark_mask} ${v6_match}"
                    [ -n "$to_match_result_6" ] && v6_match="${v6_match} ${to_match_result_6}"
                    ip6tables -w -t mangle -C TUNNEL${tunnel_id}_ROUTE_POLICY ${comment:+-m comment --comment "${comment}"} $v6_match ${target}  >/dev/null 2>&1 || \
                        ip6tables -w -t mangle ${write_way} TUNNEL${tunnel_id}_ROUTE_POLICY ${comment:+-m comment --comment "${comment}"} $v6_match ${target}
                }
            ;;
            interface|device)
                if [ -z "$from_match_result" ];then
                    match="-m mark --mark 0x0/${vpn_mark_mask}"
                    [ -n "$to_match_result" ] && match="${match} ${to_match_result}"
                    iptables -w -t mangle -C TUNNEL${tunnel_id}_ROUTE_POLICY ${comment:+-m comment --comment "${comment}"} $match ${target} >/dev/null 2>&1 || \
                        iptables -w -t mangle ${write_way} TUNNEL${tunnel_id}_ROUTE_POLICY ${comment:+-m comment --comment "${comment}"} $match ${target}
                    [ "$v6_enabled" = '1' ] && {
                        v6_match="-m mark --mark 0x0/${vpn_mark_mask}"
                        [ -n "$to_match_result_6" ] && v6_match="${v6_match} ${to_match_result_6}"
                        ip6tables -w -t mangle -C TUNNEL${tunnel_id}_ROUTE_POLICY ${comment:+-m comment --comment "${comment}"} $v6_match ${target} >/dev/null 2>&1 || \
                            ip6tables -w -t mangle ${write_way} TUNNEL${tunnel_id}_ROUTE_POLICY ${comment:+-m comment --comment "${comment}"} $v6_match ${target}
                    }
                else
                    for device in $from_match_result; do
                        match="-m mark --mark 0x0/${vpn_mark_mask} -i ${device}"
                        [ -n "$to_match_result" ] && match="${match} ${to_match_result}"
                        iptables -w -t mangle -C TUNNEL${tunnel_id}_ROUTE_POLICY ${comment:+-m comment --comment "${comment}"} $match ${target} >/dev/null 2>&1 || \
                            iptables -w -t mangle ${write_way} TUNNEL${tunnel_id}_ROUTE_POLICY ${comment:+-m comment --comment "${comment}"} $match ${target}
                        [ "$v6_enabled" = '1' ] && {
                            v6_match="-m mark --mark 0x0/${vpn_mark_mask} -i ${device}"
                            [ -n "$to_match_result_6" ] && v6_match="${v6_match} ${to_match_result_6}"
                            ip6tables -w -t mangle -C TUNNEL${tunnel_id}_ROUTE_POLICY ${comment:+-m comment --comment "${comment}"} $v6_match ${target} >/dev/null 2>&1 || \
                                ip6tables -w -t mangle ${write_way} TUNNEL${tunnel_id}_ROUTE_POLICY ${comment:+-m comment --comment "${comment}"} $v6_match ${target}
                        }
                    done
                fi
            ;;
            process_gid)
                for gid in $from_match_result; do
                    match="-m connmark --mark 0x0/${vpn_mark_mask} -m mark --mark 0x0/${vpn_mark_mask} -m owner --gid-owner $gid"
                    [ -n "$to_match_result" ] && match="${match} ${to_match_result}"
                    iptables -w -t mangle -C TUNNEL${tunnel_id}_LOCAL_POLICY ${comment:+-m comment --comment "${comment}"} $match ${target} >/dev/null 2>&1 || \
                        iptables -w -t mangle ${write_way} TUNNEL${tunnel_id}_LOCAL_POLICY ${comment:+-m comment --comment "${comment}"} $match ${target}
                    [ "$v6_enabled" = '1' ] && {
                        v6_match="-m connmark --mark 0x0/${vpn_mark_mask} -m mark --mark 0x0/${vpn_mark_mask} -m owner --gid-owner $gid"
                        [ -n "$to_match_result_6" ] && v6_match="${v6_match} ${to_match_result_6}"
                        ip6tables -w -t mangle -C TUNNEL${tunnel_id}_LOCAL_POLICY ${comment:+-m comment --comment "${comment}"} $v6_match ${target} >/dev/null 2>&1 || \
                            ip6tables -w -t mangle ${write_way} TUNNEL${tunnel_id}_LOCAL_POLICY ${comment:+-m comment --comment "${comment}"} $v6_match ${target}
                    }
                done
            ;;
            *)
                # 处理其他情况
                ;;
        esac
}

fw4_set_tunnel_rule() {
        local call_type="$1";shift
        local rule_type="$1";shift
        local target_type="$1";shift
        local mark="$1";shift
        local v6_match
        local option=''
        local target=''
        local write_way="fw4_set_add_rule_to_chain"
        [ "${call_type}" = "hotplug" ] && write_way="vpn_table_insert_fw4_rule_directly"

        case "${target_type}" in
            'drop')
                target="drop"
            ;;
            'set mark')
                target="meta mark set meta mark and ${vpn_mask_reverse} xor ${mark}"
            ;;
            *)
                target="meta mark set meta mark and ${vpn_mask_reverse} xor ${mark}"
            ;;
        esac

        case "$from_type" in
            ipset|interface|device)
                option="meta mark and ${vpn_mark_mask} == 0x0"
                local old_IFS=$IFS
                IFS="#"

                # Make the loop run at least once
                fw4_from_option=" $fw4_from_option"
                fw4_to_option=" $fw4_to_option"
                for single_from_option in $fw4_from_option; do
                    local option_with_from=${option}
                    [ -n "$single_from_option" ] && option_with_from="${option_with_from} ${single_from_option}"
                    for single_to_option in $fw4_to_option; do
                        local option_with_fromto=${option_with_from}
                        [ -n "$single_to_option" ] && option_with_fromto="${option_with_fromto} ${single_to_option}"

                        local comment=''
                        [ "${rule_type}" = "rule_for_use_vpn" ] && comment="comment \\\"TUNNEL${tunnel_id} rule for set mark\\\""
                        eval ${write_way} "TUNNEL${tunnel_id}_ROUTE_POLICY" \""${option_with_fromto} ${target} ${comment}\""
                    done
                done
                IFS=${old_IFS}
            ;;
            process_gid)
                for gid in $fw4_from_option; do
                    option="ct mark and ${vpn_mark_mask} == 0x0 meta mark and ${vpn_mark_mask} == 0x0"
                    option="${option} skgid ${gid}"
                    [ -n "$fw4_to_option" ] && option="${option} ${fw4_to_option}"

                    local comment=''
                    [ "${rule_type}" = "rule_for_use_vpn" ] && comment="comment \\\"TUNNEL${tunnel_id}_local_policy rule for set mark\\\""
                    eval ${write_way} "\"TUNNEL${tunnel_id}_LOCAL_POLICY"\" "\"${option} ${target} ${comment}\""
                done
            ;;
            *)
                # 处理其他情况
                ;;
        esac
}

process_rule() {
    local section="$1"
    local action="$2"
    local v6_enabled="$(uci -q get glipv6.globals.enabled)"
    local enabled name from_type from to_type to via mark type tunnel_id

    config_get enabled "$section" enabled
    config_get name "$section" name
    config_get from_type "$section" from_type
    config_get from "$section" from
    config_get to_type "$section" to_type
    config_get to "$section" to
    config_get via "$section" via
    config_get mark "$section" mark
    config_get rule_type "$section" rule_type
    config_get service_policy "$section" service_policy

    config_get group_id "$section" group_id
    config_get peer_id "$section" peer_id
    config_get tunnel_id "$section" tunnel_id
    config_get killswitch "$section" killswitch

    [ "$enabled" -eq 0 ] && return
    handle_service_policy "$via" "$service_policy"
    handle_always_vpn_policy "$via"
    mark=$(get_mark_of_interface "$via")
    [ $? -ne 0 ] && return

    set_mark_from_via "$via" "$section"

    case "$via" in
    ovpnclient*)
        instance_type="ovpnclient"
        ;;
    wgclient*)
        instance_type="wgclient"
        ;;
    esac

    [ "$action" = 'load' ] && {
        prepare_for_from_rule "$from_type" "$from"
        prepare_for_to_rule "$to_type" "$to"

        if [ "$use_fw4" = '1' ] ;then
            fw4_mount_tunnel_chain
        else
            fw3_mount_tunnel_chain
        fi
    }

    local fw4_from_option
    if [ "$use_fw4" = '1' ] ;then
        fw4_get_from_filter_option "$from_type" "$from"
    else
        fw3_get_from_filter_option "$from_type" "$from"
    fi
    local fw4_to_option
    if [ "$use_fw4" = '1' ] ;then
        fw4_get_to_filter_option "$to_type" "$to"
    else
        fw3_get_to_filter_option "$to_type" "$to"
    fi

    [ -z "$from_type" ] && from_type=device

    local interface_up=$(check_interface_is_up "${via}")

    # only use delay check when loading rules for vpn interface without killswitch
    if [ "$action" = 'load' ] && [ "$via" != 'novpn' ] && [ "${killswitch}" != '1' ] && [ "$interface_up" != 'true' ]; then
        local sync_count=0
        while [ "$sync_count" -lt 3 ]; do
            sleep 1
            sync_count=$((sync_count + 1))
            interface_up=$(check_interface_is_up "${via}")
            if [ "$interface_up" = 'true' ]; then
                break
            fi
        done
    fi

    # when action is not load, always apply the rules (for hotplug), no vpn interface up check
    if [ "$action" != 'load' -o "$via" = 'novpn' -o "${killswitch}" = '1' -o "$interface_up" = 'true' ]; then
        if [ "$use_fw4" = '1' ]; then
            fw4_set_tunnel_rule "$action" 'rule_for_use_vpn' "set mark" "${mark}"
        else
            fw3_set_tunnel_rule "$action" 'rule_for_use_vpn' "set mark" "${mark}"
        fi
    fi
    if [ "$action" = 'load' ]; then
        if [ "$use_fw4" = '1' ]; then
                if [ "$via" != 'novpn' -a "${enable_failover}" = '1' -a "${killswitch}" != '1' ]; then
                    fw4_set_tunnel_rule "$action" 'rule_for_failover' "set mark" "${nonevpn_mark}"
                fi
                fw4_set_tunnel_rule "$action" 'rule_for_failover' 'drop'
            else
                if [ "$via" != 'novpn' -a "${enable_failover}" = '1' -a "${killswitch}" != '1' ]; then
                    fw3_set_tunnel_rule "$action" 'rule_for_failover' "set mark" "${nonevpn_mark}"
                fi
                fw3_set_tunnel_rule "$action" 'rule_for_failover' 'drop'
        fi
    fi
}

show_rules() {
    local v6_enabled="$(uci -q get glipv6.globals.enabled)"

    iptables-save -t nat | grep policy_redirect
    echo
    iptables-save -t mangle | grep -e ROUTE_POLICY -e LOCAL_POLICY
    echo
    [ "$v6_enabled" = '1' ] && {
        ip6tables-save -t nat | grep policy_redirect
        echo
        ip6tables-save -t mangle | grep -e ROUTE_POLICY -e LOCAL_POLICY
        echo
    }

    ipset sa
    echo
    #ebtables -t filter -L --Lc 2>/dev/null
    for file in /tmp/dnsmasq.d*/*; do
        if [ -z "$(echo "= File: $file =" | grep -e mark -e dhcp)" ]; then
            echo "= File: $file ="
            cat "$file"
            echo
        fi
    done
}

apply() {
    if [ "$use_fw4" = '1' ] ;then
        fw4_vpn_set_finish_and_apply
    else
        fw3_apply_hotplug_rule
    fi

    [ $NOT_RELOAD_NETWORK = 0 -a "$procdJ_V_name" != "firewall" ] && /etc/init.d/network reload

    /etc/init.d/firewall reload 2>/dev/null &
    #reload_config
    /etc/init.d/dnsmasq restart >/dev/null 2>&1 &
    clean_conntrack
    if [ "$(uci -q get gl-dns-v2.@dns[0].override_vpn)" = 1 ]; then
        /etc/init.d/stubby restart
        /etc/init.d/dnscrypt-proxy restart
        /etc/init.d/dnsproxy restart
    fi
    mkdir -p /tmp/hosts.vpn/
    awk '{print $3, $4}' /tmp/dhcp.leases >/tmp/hosts.vpn/lan_hosts
}

process_global() {
    local enabled=$(uci -q get route_policy.global.enabled)
    [ "$enabled" -eq 0 ] && show_rules
    [ "$enabled" -eq 0 ] && {
        clean_global_killswitch_rule
        lua /usr/bin/dns_mark_ctl.lua
        apply
        exit 0
    }
    echo conntrack >/tmp/dnsmasq.d/conntrack
}

clean_ipset() {
    #ipset_list=$(uci show route_policy |grep -e "from=" -e "to=" |grep -e dst -e src | cut -f2 -d= |tr -d "!")
    ipset_list=$(ipset sa |grep create |grep -e dst_net -e src_mac |cut -f2 -d" ")
    if [ -n "$ipset_list" ]; then
        for ipset in $ipset_list; do
            # dst_net配置（名单内容和黑白属性）有变化才清除对应的ipset
            if echo "$ipset" | grep -q "dst_net"; then
                tunnel_id=$(echo "$ipset" | sed -e 's/^dst_net//' -e 's/^!dst_net//' -e 's/_6$//')
                file_path="/etc/domain_mac_list/dst_net${tunnel_id}"

                if [ -f "$file_path" ]; then
                    # 检查当前配置中的黑白名单属性
                    current_to=""
                    current_to=$(uci -q show route_policy | grep "to=.*dst_net${tunnel_id}" | cut -f2 -d= | tr -d "'")
                    current_is_blacklist=0
                    if echo "$current_to" | grep -q "^!dst_net"; then
                        current_is_blacklist=1
                    fi

                    md5_file="/tmp/run/dst_net_${ipset}.md5"
                    current_md5=$(echo "$(cat "$file_path") $current_is_blacklist" | md5sum | awk '{print $1}')
                    if [ -f "$md5_file" ]; then
                        old_md5=$(cat "$md5_file")
                        if [ "$current_md5" = "$old_md5" ]; then
                            echo "Skipping ipset $ipset as file $file_path and blacklist status have not changed"
                            continue
                        fi
                    fi
                    echo "$current_md5" > "$md5_file"
                fi

                echo "Flushing and destroying ipset $ipset"
                /usr/sbin/ipset flush "$ipset" 2>/dev/null
                /usr/sbin/ipset destroy "$ipset" 2>/dev/null
            else
                /usr/sbin/ipset flush "$ipset" 2>/dev/null
                /usr/sbin/ipset destroy "$ipset" 2>/dev/null
            fi
        done
    fi
}

source_if_add_firewall_rule() {
    local interface="$1";shift
    local call_type="$1";shift
    local if_type="$1";shift

    local write_way="fw4_set_add_rule_to_chain"
    [ "${call_type}" = "hotplug" ] && write_way="vpn_table_add_fw4_rule_directly"

    local device="$(get_if_s_l3_device ${interface})"
    device="${device//[[:space:]]/}"
    if [ -n "${device}" ] ;then
        if [ "$use_fw4" = '1' ];then
            eval ${write_way} "PREROUTING" "\"iifname ${device} jump ROUTE_POLICY\""
            [ "${if_type}" = 'wan' ] && eval ${write_way} "POST_ROUTE_POLICY" "\"oifname ${device} mark and ${vpn_mark_mask} == ${nonevpn_mark} ct mark and ${vpn_mark_mask} != ${nonevpn_mark} jump mark_meta_to_ct\""
        else
            iptables -w -t mangle -C VPN_PREROUTING_HOOK -i ${device} -j ROUTE_POLICY 2>/dev/null || \
                iptables -w -t mangle -A VPN_PREROUTING_HOOK -i ${device} -j ROUTE_POLICY
            [ "${if_type}" = 'wan' ] && {
                iptables -w -t mangle -C POST_ROUTE_POLICY -o ${device} -m mark --mark ${nonevpn_mark}/${vpn_mark_mask} -m connmark ! --mark ${nonevpn_mark}/${vpn_mark_mask} -j CONNMARK --save-mark --nfmask ${vpn_mark_mask} --ctmask ${vpn_mark_mask} 2>/dev/null || \
                    iptables -w -t mangle -A POST_ROUTE_POLICY -o ${device} -m mark --mark ${nonevpn_mark}/${vpn_mark_mask} -m connmark ! --mark ${nonevpn_mark}/${vpn_mark_mask} -j CONNMARK --save-mark --nfmask ${vpn_mark_mask} --ctmask ${vpn_mark_mask}
            }
            [ "$v6_enabled" = '1' ] && {
                ip6tables -w -t mangle -C VPN_PREROUTING_HOOK -i ${device} -j ROUTE_POLICY 2>/dev/null || \
                    ip6tables -w -t mangle -A VPN_PREROUTING_HOOK -i ${device} -j ROUTE_POLICY
                [ "${if_type}" = 'wan' ] && {
                    ip6tables -w -t mangle -C POST_ROUTE_POLICY -o ${device} -m mark --mark ${nonevpn_mark}/${vpn_mark_mask} -m connmark ! --mark ${nonevpn_mark}/${vpn_mark_mask} -j CONNMARK --save-mark --nfmask ${vpn_mark_mask} --ctmask ${vpn_mark_mask} 2>/dev/null || \
                        ip6tables -w -t mangle -A POST_ROUTE_POLICY -o ${device} -m mark --mark ${nonevpn_mark}/${vpn_mark_mask} -m connmark ! --mark ${nonevpn_mark}/${vpn_mark_mask} -j CONNMARK --save-mark --nfmask ${vpn_mark_mask} --ctmask ${vpn_mark_mask}
                }
            }
        fi
    fi
}

edge_router_mode_add_if_firewall_rule() {
    local call_type="$1";shift
    local wan_ifs="$EDGE_ROUTER_SOURCE_IFS"
    for wan_if in $wan_ifs ;do
        source_if_add_firewall_rule "${wan_if}" "$call_type" "wan"
        [ "${call_type}" = "hotplug" ] && deal_per_if_rlbr "${wan_if}" '1'
    done
}

fw4_add_in_new_mark_rule() {
    local wan_device_list="$(get_wan_device_list)"
    for device in $wan_device_list ;do
        fw4_set_add_rule_to_chain "wan_in_new_mark" "iifname \"${device}\" meta l4proto { tcp, udp, icmp, ipv6-icmp } ct state new ct mark and ${vpn_mark_mask} != ${nonevpn_mark} ct mark set ct mark and ${vpn_mask_reverse} xor ${nonevpn_mark} comment \"${device}_in_new_connmark\""
    done
}

fw4_vpn_create_primary_chain() {
    local edge_r_enabled="$(uci -q get edgerouter.global.enabled)"

    fw4_set_create_chain "mark_ct_to_meta"
    fw4_set_add_rule_to_chain "mark_ct_to_meta" "ct mark and ${vpn_mark_mask} == ${nonevpn_mark} meta mark set meta mark and ${vpn_mask_reverse} or ${nonevpn_mark} comment \"nonevpn_mark_ct_to_meta\""
    fw4_set_create_chain "mark_meta_to_ct"
    fw4_set_add_rule_to_chain "mark_meta_to_ct" "meta mark and ${vpn_mark_mask} == ${nonevpn_mark} ct mark set ct mark and ${vpn_mask_reverse} or ${nonevpn_mark} comment \"nonevpn_mark_meta_to_ct\""

    fw4_set_create_chain "vpn_in_new_mark"
    fw4_set_create_chain "wan_in_new_mark"
    fw4_add_in_new_mark_rule

    fw4_set_create_chain "ROUTE_POLICY"
    fw4_set_add_rule_to_chain "ROUTE_POLICY" "ct mark and ${vpn_mark_mask} != 0x0 jump mark_ct_to_meta"
    fw4_set_add_rule_to_chain "ROUTE_POLICY" "meta l4proto udp th dport 53 fib daddr type local counter return"

    fw4_set_create_chain "PREROUTING" "type filter hook prerouting priority mangle;"
    fw4_set_add_rule_to_chain "PREROUTING" "jump vpn_in_new_mark"
    [ "$edge_r_enabled" != '1' ] && fw4_set_add_rule_to_chain "PREROUTING" "jump wan_in_new_mark"

    for source_if in ${SOURCE_DATA_IF_LIST} ;do
        source_if_add_firewall_rule "${source_if}" "load" "inner"
    done

    fw4_set_create_chain "LOCAL_POLICY"
    fw4_set_create_chain "OUTPUT" "type route hook output priority mangle;"
    fw4_set_add_rule_to_chain "OUTPUT" "jump LOCAL_POLICY"
    fw4_set_add_rule_to_chain "LOCAL_POLICY" "ct mark and ${vpn_mark_mask} != 0x0 jump mark_ct_to_meta"

    fw4_set_create_chain "POST_ROUTE_POLICY"
    fw4_set_create_chain "POSTROUTING" "type filter hook postrouting priority mangle;"
    fw4_set_add_rule_to_chain "POSTROUTING" "jump POST_ROUTE_POLICY"

    #fw4_set_add_rule_to_chain "POSTROUTING" "meta l4proto tcp mark and ${vpn_mark_mask} != 0 tcp flags syn,ack syn tcp option maxseg size set rt mtu"
    fw4_set_add_rule_to_chain "POSTROUTING" "meta l4proto tcp mark and ${vpn_mark_mask} != 0 tcp flags syn tcp option maxseg size set rt mtu"

    if [ "$edge_r_enabled" = '1' ];then
        edge_router_mode_add_if_firewall_rule 'load'
    fi
}

fw3_add_wan_in_mark_rule() {
    local wan_device_list="$(get_wan_device_list)"
    for device in $wan_device_list ;do
        iptables -w -t mangle -C wan_in_new_mark -i ${device} -p tcp -m conntrack --ctstate NEW -m connmark ! --mark ${nonevpn_mark}/${vpn_mark_mask} -m comment --comment "${device}_in_new_connmark" -j CONNMARK --set-xmark ${nonevpn_mark}/${vpn_mark_mask} 2>/dev/null || \
            iptables -w -t mangle -A wan_in_new_mark -i ${device} -p tcp -m conntrack --ctstate NEW -m connmark ! --mark ${nonevpn_mark}/${vpn_mark_mask} -m comment --comment "${device}_in_new_connmark" -j CONNMARK --set-xmark ${nonevpn_mark}/${vpn_mark_mask}
        iptables -w -t mangle -C wan_in_new_mark -i ${device} -p udp -m conntrack --ctstate NEW -m connmark ! --mark ${nonevpn_mark}/${vpn_mark_mask} -m comment --comment "${device}_in_new_connmark" -j CONNMARK --set-xmark ${nonevpn_mark}/${vpn_mark_mask} 2>/dev/null || \
            iptables -w -t mangle -A wan_in_new_mark -i ${device} -p udp -m conntrack --ctstate NEW -m connmark ! --mark ${nonevpn_mark}/${vpn_mark_mask} -m comment --comment "${device}_in_new_connmark" -j CONNMARK --set-xmark ${nonevpn_mark}/${vpn_mark_mask}
        iptables -w -t mangle -C wan_in_new_mark -i ${device} -p icmp -m conntrack --ctstate NEW -m connmark ! --mark ${nonevpn_mark}/${vpn_mark_mask} -m comment --comment "${device}_in_new_connmark" -j CONNMARK --set-xmark ${nonevpn_mark}/${vpn_mark_mask} 2>/dev/null || \
            iptables -w -t mangle -A wan_in_new_mark -i ${device} -p icmp -m conntrack --ctstate NEW -m connmark ! --mark ${nonevpn_mark}/${vpn_mark_mask} -m comment --comment "${device}_in_new_connmark" -j CONNMARK --set-xmark ${nonevpn_mark}/${vpn_mark_mask}
        [ "$v6_enabled" = '1' ] && {
            ip6tables -w -t mangle -C wan_in_new_mark -i ${device} -p tcp -m conntrack --ctstate NEW -m connmark ! --mark ${nonevpn_mark}/${vpn_mark_mask} -m comment --comment "${device}_in_new_connmark" -j CONNMARK --set-xmark ${nonevpn_mark}/${vpn_mark_mask} 2>/dev/null || \
                ip6tables -w -t mangle -A wan_in_new_mark -i ${device} -p tcp -m conntrack --ctstate NEW -m connmark ! --mark ${nonevpn_mark}/${vpn_mark_mask} -m comment --comment "${device}_in_new_connmark" -j CONNMARK --set-xmark ${nonevpn_mark}/${vpn_mark_mask}
            ip6tables -w -t mangle -C wan_in_new_mark -i ${device} -p udp -m conntrack --ctstate NEW -m connmark ! --mark ${nonevpn_mark}/${vpn_mark_mask} -m comment --comment "${device}_in_new_connmark" -j CONNMARK --set-xmark ${nonevpn_mark}/${vpn_mark_mask} 2>/dev/null || \
                ip6tables -w -t mangle -A wan_in_new_mark -i ${device} -p udp -m conntrack --ctstate NEW -m connmark ! --mark ${nonevpn_mark}/${vpn_mark_mask} -m comment --comment "${device}_in_new_connmark" -j CONNMARK --set-xmark ${nonevpn_mark}/${vpn_mark_mask}
            ip6tables -w -t mangle -C wan_in_new_mark -i ${device} -p ipv6-icmp -m conntrack --ctstate NEW -m connmark ! --mark ${nonevpn_mark}/${vpn_mark_mask} -m comment --comment "${device}_in_new_connmark" -j CONNMARK --set-xmark ${nonevpn_mark}/${vpn_mark_mask} 2>/dev/null || \
                ip6tables -w -t mangle -A wan_in_new_mark -i ${device} -p ipv6-icmp -m conntrack --ctstate NEW -m connmark ! --mark ${nonevpn_mark}/${vpn_mark_mask} -m comment --comment "${device}_in_new_connmark" -j CONNMARK --set-xmark ${nonevpn_mark}/${vpn_mark_mask}
        }
    done
}

create_chain() {
    local edge_r_enabled="$(uci -q get edgerouter.global.enabled)"

    iptables -w -t mangle -N VPN_PREROUTING_HOOK 2>/dev/null
    iptables -w -t mangle -C PREROUTING -j VPN_PREROUTING_HOOK 2>/dev/null || \
        iptables -w -t mangle -A PREROUTING -j VPN_PREROUTING_HOOK

    iptables -w -t mangle -N vpn_in_new_mark 2>/dev/null
    iptables -w -t mangle -C VPN_PREROUTING_HOOK -j vpn_in_new_mark 2>/dev/null || \
        iptables -w -t mangle -A VPN_PREROUTING_HOOK -j vpn_in_new_mark

    iptables -w -t mangle -N wan_in_new_mark 2>/dev/null
    [ "$edge_r_enabled" != '1' ] && {
        iptables -w -t mangle -C VPN_PREROUTING_HOOK -j wan_in_new_mark 2>/dev/null || \
            iptables -w -t mangle -A VPN_PREROUTING_HOOK -j wan_in_new_mark
    }

    iptables -w -t mangle -N ROUTE_POLICY 2>/dev/null
    iptables -w -t mangle -C ROUTE_POLICY -m connmark ! --mark 0x0/${vpn_mark_mask} -j CONNMARK --restore-mark --nfmask ${vpn_mark_mask} --ctmask ${vpn_mark_mask} 2>/dev/null || \
        iptables -w -t mangle -A ROUTE_POLICY -m connmark ! --mark 0x0/${vpn_mark_mask} -j CONNMARK --restore-mark --nfmask ${vpn_mark_mask} --ctmask ${vpn_mark_mask}

    iptables -w -t mangle -C ROUTE_POLICY -m addrtype --dst-type LOCAL -p udp -m udp --dport 53 -j RETURN  2>/dev/null || \
        iptables -w -t mangle -A ROUTE_POLICY -m addrtype --dst-type LOCAL -p udp -m udp --dport 53 -j RETURN

    iptables -w -t mangle -N LOCAL_POLICY 2>/dev/null
    iptables -w -t mangle -C OUTPUT -j LOCAL_POLICY 2>/dev/null || \
        iptables -w -t mangle -I OUTPUT -j LOCAL_POLICY
    iptables -w -t mangle -C LOCAL_POLICY -m connmark ! --mark 0x0/${vpn_mark_mask} -j CONNMARK --restore-mark --nfmask ${vpn_mark_mask} --ctmask ${vpn_mark_mask} 2>/dev/null || \
        iptables -w -t mangle -A LOCAL_POLICY -m connmark ! --mark 0x0/${vpn_mark_mask} -j CONNMARK --restore-mark --nfmask ${vpn_mark_mask} --ctmask ${vpn_mark_mask}

    iptables -w -t mangle -N POST_ROUTE_POLICY 2>/dev/null
    iptables -w -t mangle -C POSTROUTING -j POST_ROUTE_POLICY 2>/dev/null || \
        iptables -w -t mangle -I POSTROUTING -j POST_ROUTE_POLICY

    # Add MSS clamping rules for local process traffic go via VPN, to fix HTTPS issues with small MTU
    iptables -w -t mangle -C POSTROUTING -m mark ! --mark 0x0/0xf000 -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
        iptables -w -t mangle -A POSTROUTING -m mark ! --mark 0x0/0xf000 -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

    [ "$v6_enabled" = '1' ] && {
        ip6tables -w -t mangle -N VPN_PREROUTING_HOOK 2>/dev/null
        ip6tables -w -t mangle -C PREROUTING -j VPN_PREROUTING_HOOK 2>/dev/null || \
            ip6tables -w -t mangle -A PREROUTING -j VPN_PREROUTING_HOOK
	    ip6tables -w -t mangle -N vpn_in_new_mark 2>/dev/null
        ip6tables -w -t mangle -C VPN_PREROUTING_HOOK -j vpn_in_new_mark 2>/dev/null || \
            ip6tables -w -t mangle -A VPN_PREROUTING_HOOK -j vpn_in_new_mark

        ip6tables -w -t mangle -N wan_in_new_mark 2>/dev/null
        [ "$edge_r_enabled" != '1' ] && {
            ip6tables -w -t mangle -C VPN_PREROUTING_HOOK -j wan_in_new_mark 2>/dev/null || \
                ip6tables -w -t mangle -A VPN_PREROUTING_HOOK -j wan_in_new_mark
        }

        ip6tables -w -t mangle -N ROUTE_POLICY 2>/dev/null
        ip6tables -w -t mangle -C ROUTE_POLICY -m connmark ! --mark 0x0/${vpn_mark_mask} -j CONNMARK --restore-mark --nfmask ${vpn_mark_mask} --ctmask ${vpn_mark_mask} 2>/dev/null || \
            ip6tables -w -t mangle -A ROUTE_POLICY -m connmark ! --mark 0x0/${vpn_mark_mask} -j CONNMARK --restore-mark --nfmask ${vpn_mark_mask} --ctmask ${vpn_mark_mask}

        ip6tables -w -t mangle -C ROUTE_POLICY -m addrtype --dst-type LOCAL -p udp -m udp --dport 53 -j RETURN  2>/dev/null || \
            ip6tables -w -t mangle -A ROUTE_POLICY -m addrtype --dst-type LOCAL -p udp -m udp --dport 53 -j RETURN

        ip6tables -w -t mangle -N LOCAL_POLICY 2>/dev/null
        ip6tables -w -t mangle -C OUTPUT -j LOCAL_POLICY 2>/dev/null || \
            ip6tables -w -t mangle -I OUTPUT -j LOCAL_POLICY
        ip6tables -w -t mangle -C LOCAL_POLICY -m connmark ! --mark 0x0/${vpn_mark_mask} -j CONNMARK --restore-mark --nfmask ${vpn_mark_mask} --ctmask ${vpn_mark_mask} 2>/dev/null || \
            ip6tables -w -t mangle -A LOCAL_POLICY -m connmark ! --mark 0x0/${vpn_mark_mask} -j CONNMARK --restore-mark --nfmask ${vpn_mark_mask} --ctmask ${vpn_mark_mask}

        ip6tables -w -t mangle -N POST_ROUTE_POLICY 2>/dev/null
        ip6tables -w -t mangle -C POSTROUTING -j POST_ROUTE_POLICY 2>/dev/null || \
            ip6tables -w -t mangle -I POSTROUTING -j POST_ROUTE_POLICY

        ip6tables -w -t mangle -C POSTROUTING -m mark ! --mark 0x0/0xf000 -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
            ip6tables -w -t mangle -A POSTROUTING -m mark ! --mark 0x0/0xf000 -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
    }

    for source_if in ${SOURCE_DATA_IF_LIST} ;do
        source_if_add_firewall_rule "${source_if}" "load" "inner"
    done

    fw3_add_wan_in_mark_rule

    if [ "$edge_r_enabled" = '1' ];then
        edge_router_mode_add_if_firewall_rule 'load'
    fi
}

clean_tunnel_mark_rules() {
    local chains="$(iptables-save -t mangle | grep -oE '\b\-A TUNNEL[0-9]+_(ROUTE|LOCAL)_POLICY' | awk -F ' ' '{print$2}')"
    for line in $chains ;do
        [ -n $line ] && {
            iptables -w -t mangle -F $line >/dev/null 2>&1
            iptables -w -t mangle -X $line >/dev/null 2>&1
        }
    done

    chains="$(ip6tables-save -t mangle | grep -oE '\b\-A TUNNEL[0-9]+_(ROUTE|LOCAL)_POLICY' | awk -F ' ' '{print$2}')"
    for line in $chains ;do
        [ -n $line ] && {
            ip6tables -w -t mangle -F $line >/dev/null 2>&1
            ip6tables -w -t mangle -X $line >/dev/null 2>&1
        }
    done
}

remove_chain() {
    iptables -w -t mangle -D PREROUTING -j VPN_PREROUTING_HOOK
    iptables -w -t mangle -F VPN_PREROUTING_HOOK 2>/dev/null
    iptables -w -t mangle -X VPN_PREROUTING_HOOK 2>/dev/null

    iptables -w -t mangle -F ROUTE_POLICY 2>/dev/null
    iptables -w -t mangle -X ROUTE_POLICY 2>/dev/null
    iptables -w -t mangle -D OUTPUT -j LOCAL_POLICY 2>/dev/null
    iptables -w -t mangle -F LOCAL_POLICY 2>/dev/null
    iptables -w -t mangle -X LOCAL_POLICY 2>/dev/null
    iptables -w -t mangle -F POST_ROUTE_POLICY 2>/dev/null
    iptables -w -t mangle -X POST_ROUTE_POLICY 2>/dev/null
    iptables -w -t mangle -D POSTROUTING -j POST_ROUTE_POLICY 2>/dev/null
    iptables -w -t mangle -D POSTROUTING -m mark ! --mark 0x0/0xf000 -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null

    ip6tables -w -t mangle -D PREROUTING -j VPN_PREROUTING_HOOK
    ip6tables -w -t mangle -F VPN_PREROUTING_HOOK 2>/dev/null
    ip6tables -w -t mangle -X VPN_PREROUTING_HOOK 2>/dev/null

    ip6tables -w -t mangle -F ROUTE_POLICY >/dev/null 2>&1
    ip6tables -w -t mangle -X ROUTE_POLICY >/dev/null 2>&1
    ip6tables -w -t mangle -D OUTPUT -j LOCAL_POLICY >/dev/null 2>&1
    ip6tables -w -t mangle -F LOCAL_POLICY >/dev/null 2>&1
    ip6tables -w -t mangle -X LOCAL_POLICY >/dev/null 2>&1
    ip6tables -w -t mangle -F POST_ROUTE_POLICY >/dev/null 2>&1
    ip6tables -w -t mangle -X POST_ROUTE_POLICY >/dev/null 2>&1
    ip6tables -w -t mangle -D POSTROUTING -j POST_ROUTE_POLICY >/dev/null 2>&1
    ip6tables -w -t mangle -D POSTROUTING -m mark ! --mark 0x0/0xf000 -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null

    ebtables -t filter -F INPUT 2>/dev/null

    iptables -w -t mangle -F vpn_in_new_mark >/dev/null 2>&1
    iptables -w -t mangle -X vpn_in_new_mark >/dev/null 2>&1
    ip6tables -w -t mangle -F vpn_in_new_mark >/dev/null 2>&1
    ip6tables -w -t mangle -X vpn_in_new_mark >/dev/null 2>&1
    iptables -w -t mangle -F wan_in_new_mark >/dev/null 2>&1
    iptables -w -t mangle -X wan_in_new_mark >/dev/null 2>&1
    ip6tables -w -t mangle -F wan_in_new_mark >/dev/null 2>&1
    ip6tables -w -t mangle -X wan_in_new_mark >/dev/null 2>&1

    clean_tunnel_mark_rules
}

pause_tunnel_s_dns_mark_rule() {
    local tunnel_id="$1"
    [ -f "/proc/dns_mark/rule${tunnel_id}/mark" ] && echo "${nonevpn_mark}" >/proc/dns_mark/rule${tunnel_id}/mark
}

resume_tunnel_s_dns_mark_rule() {
    local tunnel_id="$1";shift
    local mark="$1";shift
    [ -f "/proc/dns_mark/rule${tunnel_id}/mark" ] && echo "${mark}" >/proc/dns_mark/rule${tunnel_id}/mark
    return 0
}

clean_tunnel_s_mark_rules() {
    local tunnel_id="$1"
    pause_tunnel_s_dns_mark_rule ${tunnel_id}

    if [ "$use_fw4" = '1' ] ;then
        local rule_num="$(nft -a list table ${VPN_TABLE_NAME} | grep "TUNNEL${tunnel_id} rule for set mark" | wc -l)"
        while [ "$rule_num" -gt 0 ] ;do
            local per_handle="$(nft -a list table ${VPN_TABLE_NAME} | grep "TUNNEL${tunnel_id} rule for set mark" | head -n 1 | awk -F ' ' '{print $NF}')"
            [ -n "${per_handle}" ] && {
                nft delete rule ${VPN_TABLE_NAME} TUNNEL${tunnel_id}_ROUTE_POLICY handle "${per_handle}"
            }
            rule_num="$(nft -a list table ${VPN_TABLE_NAME} | grep "TUNNEL${tunnel_id} rule for set mark" | wc -l)"
        done

        local rule_num="$(nft -a list table ${VPN_TABLE_NAME} | grep "TUNNEL${tunnel_id}_local_policy rule for set mark" | wc -l)"
        while [ "$rule_num" -gt 0 ] ;do
            local per_handle="$(nft -a list table ${VPN_TABLE_NAME} | grep "TUNNEL${tunnel_id}_local_policy rule for set mark" | head -n 1 | awk -F ' ' '{print $NF}')"
            [ -n "${per_handle}" ] && {
                nft delete rule ${VPN_TABLE_NAME} TUNNEL${tunnel_id}_LOCAL_POLICY handle "${per_handle}"
            }
            rule_num="$(nft -a list table ${VPN_TABLE_NAME} | grep "TUNNEL${tunnel_id}_local_policy rule for set mark" | wc -l)"
        done
    else
        local rule_num="$(iptables-save -t mangle | grep "TUNNEL${tunnel_id} rule for set mark" | wc -l)"
        while [ "$rule_num" -gt 0 ] ;do
            local per_rule="$(iptables-save -t mangle | grep "TUNNEL${tunnel_id} rule for set mark" | head -n 1 | sed 's/^-A[[:space:]]\+//')"
            [ -n "${per_rule}" ] && {
                eval iptables -t mangle -D "${per_rule}"
            }
            rule_num="$(iptables-save -t mangle | grep "TUNNEL${tunnel_id} rule for set mark" | wc -l)"
        done
    fi
}

control_tunnels_which_via_spec_if_s_mark_rules() {
    local section="$1"
    local interface="$2"
    local action="$3"

    local via tunnel_id killswitch mark

    config_get via "$section" via
    config_get killswitch "$section" killswitch
    config_get mark "$section" mark

    [ "${via}" = "${interface}" ] && {
        config_get tunnel_id "$section" tunnel_id
        [ "${killswitch}" != '1' ] && {
            case "$action" in
                pause)
                        clean_tunnel_s_mark_rules "${tunnel_id}"
                ;;
                resume)
                    resume_tunnel_s_dns_mark_rule "${tunnel_id}" "${mark}"
                    process_rule ${section} 'hotplug'
                ;;
            esac
        }
    }
}

control_rules_that_bound_interface() {
    local interface="$1"
    local action="$2"

    config_load "$CONFIG"
    config_foreach control_tunnels_which_via_spec_if_s_mark_rules rule ${interface} ${action}
    config_foreach control_tunnels_which_via_spec_if_s_mark_rules rule_process ${interface} ${action}
}

hotplug_fw3_deal_in_new_rule() {
    local interface="$1"
    local action="$2"
    local mark="$3"
    local flag="$4"
    local chain=''
    local v6_enabled="$(uci -q get glipv6.globals.enabled)"

    case "$flag" in
        'wan')
            chain='wan_in_new_mark'
        ;;
        *)
            chain='vpn_in_new_mark'
        ;;
    esac

    case "$action" in
        'add')
            iptables -w -t mangle -C ${chain} -i ${interface} -p tcp -m conntrack --ctstate NEW -m connmark ! --mark ${mark}/${vpn_mark_mask} -m comment --comment "${interface}_in_new_connmark" -j CONNMARK --set-xmark ${mark}/${vpn_mark_mask} 2>/dev/null || \
                iptables -w -t mangle -A ${chain} -i ${interface} -p tcp -m conntrack --ctstate NEW -m connmark ! --mark ${mark}/${vpn_mark_mask} -m comment --comment "${interface}_in_new_connmark" -j CONNMARK --set-xmark ${mark}/${vpn_mark_mask}
            [ "$flag" = "vpn" ] && fw3_set_add_hotplug_statement "iptables -w -t mangle -A ${chain} -i ${interface} -p tcp -m conntrack --ctstate NEW -m connmark ! --mark ${mark}/${vpn_mark_mask} -m comment --comment \"${interface}_in_new_connmark\" -j CONNMARK --set-xmark ${mark}/${vpn_mark_mask}"
            iptables -w -t mangle -C ${chain} -i ${interface} -p udp -m conntrack --ctstate NEW -m connmark ! --mark ${mark}/${vpn_mark_mask} -m comment --comment "${interface}_in_new_connmark" -j CONNMARK --set-xmark ${mark}/${vpn_mark_mask} 2>/dev/null || \
                iptables -w -t mangle -A ${chain} -i ${interface} -p udp -m conntrack --ctstate NEW -m connmark ! --mark ${mark}/${vpn_mark_mask} -m comment --comment "${interface}_in_new_connmark"  -j CONNMARK --set-xmark ${mark}/${vpn_mark_mask}
	    [ "$flag" = "vpn" ] && fw3_set_add_hotplug_statement "iptables -w -t mangle -A ${chain} -i ${interface} -p udp -m conntrack --ctstate NEW -m connmark ! --mark ${mark}/${vpn_mark_mask} -m comment --comment \"${interface}_in_new_connmark\"  -j CONNMARK --set-xmark ${mark}/${vpn_mark_mask}"
            iptables -w -t mangle -C ${chain} -i ${interface} -p icmp -m conntrack --ctstate NEW -m connmark ! --mark ${mark}/${vpn_mark_mask} -m comment --comment "${interface}_in_new_connmark" -j CONNMARK --set-xmark ${mark}/${vpn_mark_mask} 2>/dev/null || \
                iptables -w -t mangle -A ${chain} -i ${interface} -p icmp -m conntrack --ctstate NEW -m connmark ! --mark ${mark}/${vpn_mark_mask} -m comment --comment "${interface}_in_new_connmark" -j CONNMARK --set-xmark ${mark}/${vpn_mark_mask}
	    [ "$flag" = "vpn" ] && fw3_set_add_hotplug_statement "iptables -w -t mangle -A ${chain} -i ${interface} -p icmp -m conntrack --ctstate NEW -m connmark ! --mark ${mark}/${vpn_mark_mask} -m comment --comment \"${interface}_in_new_connmark\" -j CONNMARK --set-xmark ${mark}/${vpn_mark_mask}"
            [ "$v6_enabled" = '1' ] && {
                ip6tables -w -t mangle -C ${chain} -i ${interface} -p tcp -m conntrack --ctstate NEW -m connmark ! --mark ${mark}/${vpn_mark_mask} -m comment --comment "${interface}_in_new_connmark" -j CONNMARK --set-xmark ${mark}/${vpn_mark_mask} 2>/dev/null || \
                    ip6tables -w -t mangle -A ${chain} -i ${interface} -p tcp -m conntrack --ctstate NEW -m connmark ! --mark ${mark}/${vpn_mark_mask} -m comment --comment "${interface}_in_new_connmark" -j CONNMARK --set-xmark ${mark}/${vpn_mark_mask}
                [ "$flag" = "vpn" ] && fw3_set_add_hotplug_statement "ip6tables -w -t mangle -A ${chain} -i ${interface} -p tcp -m conntrack --ctstate NEW -m connmark ! --mark ${mark}/${vpn_mark_mask} -m comment --comment \"${interface}_in_new_connmark\" -j CONNMARK --set-xmark ${mark}/${vpn_mark_mask}"
                ip6tables -w -t mangle -C ${chain} -i ${interface} -p udp -m conntrack --ctstate NEW -m connmark ! --mark ${mark}/${vpn_mark_mask} -m comment --comment "${interface}_in_new_connmark" -j CONNMARK --set-xmark ${mark}/${vpn_mark_mask} 2>/dev/null || \
                    ip6tables -w -t mangle -A ${chain} -i ${interface} -p udp -m conntrack --ctstate NEW -m connmark ! --mark ${mark}/${vpn_mark_mask} -m comment --comment "${interface}_in_new_connmark" -j CONNMARK --set-xmark ${mark}/${vpn_mark_mask}
                [ "$flag" = "vpn" ] && fw3_set_add_hotplug_statement "ip6tables -w -t mangle -A ${chain} -i ${interface} -p udp -m conntrack --ctstate NEW -m connmark ! --mark ${mark}/${vpn_mark_mask} -m comment --comment \"${interface}_in_new_connmark\" -j CONNMARK --set-xmark ${mark}/${vpn_mark_mask}"
                ip6tables -w -t mangle -C ${chain} -i ${interface} -p ipv6-icmp -m conntrack --ctstate NEW -m connmark ! --mark ${mark}/${vpn_mark_mask} -m comment --comment "${interface}_in_new_connmark" -j CONNMARK --set-xmark ${mark}/${vpn_mark_mask} 2>/dev/null || \
                    ip6tables -w -t mangle -A ${chain} -i ${interface} -p ipv6-icmp -m conntrack --ctstate NEW -m connmark ! --mark ${mark}/${vpn_mark_mask} -m comment --comment "${interface}_in_new_connmark" -j CONNMARK --set-xmark ${mark}/${vpn_mark_mask}
                [ "$flag" = "vpn" ] && fw3_set_add_hotplug_statement "ip6tables -w -t mangle -A ${chain} -i ${interface} -p ipv6-icmp -m conntrack --ctstate NEW -m connmark ! --mark ${mark}/${vpn_mark_mask} -m comment --comment \"${interface}_in_new_connmark\" -j CONNMARK --set-xmark ${mark}/${vpn_mark_mask}"
            }
        ;;
        'del')
            iptables -w -t mangle -D ${chain} -i ${interface} -p tcp -m conntrack --ctstate NEW -m connmark ! --mark ${mark}/${vpn_mark_mask} -m comment --comment "${interface}_in_new_connmark" -j CONNMARK --set-xmark ${mark}/${vpn_mark_mask} 2>/dev/null
            iptables -w -t mangle -D ${chain} -i ${interface} -p udp -m conntrack --ctstate NEW -m connmark ! --mark ${mark}/${vpn_mark_mask} -m comment --comment "${interface}_in_new_connmark" -j CONNMARK --set-xmark ${mark}/${vpn_mark_mask} 2>/dev/null
            iptables -w -t mangle -D ${chain} -i ${interface} -p icmp -m conntrack --ctstate NEW -m connmark ! --mark ${mark}/${vpn_mark_mask} -m comment --comment "${interface}_in_new_connmark" -j CONNMARK --set-xmark ${mark}/${vpn_mark_mask} 2>/dev/null
            [ "$v6_enabled" = '1' ] && {
                ip6tables -w -t mangle -D ${chain} -i ${interface} -p tcp -m conntrack --ctstate NEW -m connmark ! --mark ${mark}/${vpn_mark_mask} -m comment --comment "${interface}_in_new_connmark" -j CONNMARK --set-xmark ${mark}/${vpn_mark_mask} 2>/dev/null
                ip6tables -w -t mangle -D ${chain} -i ${interface} -p udp -m conntrack --ctstate NEW -m connmark ! --mark ${mark}/${vpn_mark_mask} -m comment --comment "${interface}_in_new_connmark" -j CONNMARK --set-xmark ${mark}/${vpn_mark_mask} 2>/dev/null
                ip6tables -w -t mangle -D ${chain} -i ${interface} -p ipv6-icmp -m conntrack --ctstate NEW -m connmark ! --mark ${mark}/${vpn_mark_mask} -m comment --comment "${interface}_in_new_connmark" -j CONNMARK --set-xmark ${mark}/${vpn_mark_mask} 2>/dev/null
            }
            [ "$flag" = "vpn" ] && fw3_set_delete_hotplug_statement "${interface}_in_new_connmark"
        ;;
        *)
        ;;
    esac
}

hotplug_fw3_deal_rules_for_instance() {
    local interface="$1"
    local action="$2"
    local mark="$(get_mark_of_interface "${interface}")"


    case "$action" in
        'up')
            hotplug_fw3_deal_in_new_rule "${interface}" "add" "${mark}" "vpn"
        ;;
        'down')
            hotplug_fw3_deal_in_new_rule "${interface}" "del" "${mark}" "vpn"
        ;;
        *)
        ;;
    esac
}

hotplug_fw4_deal_in_new_rule(){
    local interface="$1"
    local action="$2"
    local mark="$3"
    local flag="$4"
    local chain=''

    case "$flag" in
        'wan')
            chain='wan_in_new_mark'
        ;;
        *)
            chain='vpn_in_new_mark'
        ;;
    esac

    case "$action" in
        'add')
            nft add rule ${VPN_TABLE_NAME} ${chain} iifname ${interface} meta l4proto { tcp, udp, icmp, ipv6-icmp } ct state new ct mark and ${vpn_mark_mask} != ${mark} ct mark set ct mark and ${vpn_mask_reverse} xor ${mark} comment "${interface}_in_new_connmark"
	        [ "$flag" = "vpn" ] && fw4_set_add_hotplug_statement "add rule ${VPN_TABLE_NAME} ${chain} iifname ${interface} meta l4proto { tcp, udp, icmp, ipv6-icmp } ct state new ct mark and ${vpn_mark_mask} != ${mark} ct mark set ct mark and ${vpn_mask_reverse} xor ${mark} comment \"${interface}_in_new_connmark\""
        ;;
        'del')
            nft delete rule ${VPN_TABLE_NAME} ${chain} handle $(nft -a list table ${VPN_TABLE_NAME} | grep "${interface}_in_new_connmark" | awk -F ' ' '{print $NF}')
            [ "$flag" = "vpn" ] && fw4_set_delete_hotplug_statement "${interface}_in_new_connmark"
        ;;
        *)
        ;;
    esac
}

hotplug_fw4_deal_rules_for_instance() {
    local interface="$1"
    local action="$2"
    local mark="$(get_mark_of_interface "${interface}")"

    local v6_enabled="$(uci -q get glipv6.globals.enabled)"

    case "$action" in
        'up')
            hotplug_fw4_deal_in_new_rule "${interface}" "add" "${mark}" 'vpn'
        ;;
        'down')
            hotplug_fw4_deal_in_new_rule "${interface}" "del" "${mark}" 'vpn'
        ;;
        *)
        ;;
    esac
}

deal_vpn_interface_status_change() {
    local interface="$1"
    local action="$2"
    case "$action" in
        'up')
            control_rules_that_bound_interface "${interface}" "resume"
        ;;
        'down')
            control_rules_that_bound_interface "${interface}" "pause"
        ;;
        *)
        ;;
    esac

    if [ "$use_fw4" = '1' ] ;then
        hotplug_fw4_deal_rules_for_instance "${interface}" "$action"
    else
        hotplug_fw3_deal_rules_for_instance "${interface}" "$action"
    fi
}

hotplug_source_if_set_firewall() {
    local interface="$1";shift

    set_instance_forward_with_source_if() {
        local section="$1";shift
        local source_if_name="$1";shift
        local vpn_instance
        local local_access

        config_get vpn_instance "$section" gl_vpn_instance '0'
        config_get local_access "$section" modified_local_access '0'
        [ "${vpn_instance}" = '1' ] && {
            local forward_type='uplink-only'
            [ -n "${local_access}" -a "${local_access}" = '1' ] && forward_type='both-directions'
            instance_set_forwarding_with_per_source_if "$section" "$source_if_name" "${forward_type}"
        }
    }
    config_load network
    config_foreach set_instance_forward_with_source_if 'interface' "${interface}"

    source_if_add_firewall_rule "${interface}" 'hotplug' 'inner'
}

deal_normal_interface_status_change() {
    local interface="$1"
    local action="$2"
    local if_type="$3"
    local devices="$(get_if_s_l3_device ${interface})"

    case "${if_type}" in
        'wan')
            case "${action}" in
                'up')
                    local edge_r_enabled="$(uci -q get edgerouter.global.enabled)"
                    if [ "$edge_r_enabled" != '1' ];then
                        for device in ${devices} ;do
                            if [ "$use_fw4" = '1' ] ;then
                                hotplug_fw4_deal_in_new_rule "${device}" "add" "${nonevpn_mark}" 'wan'
                            else
                                hotplug_fw3_deal_in_new_rule "${device}" "add" "${nonevpn_mark}" "wan"
                            fi
                        done
                    else
                        edge_router_mode_add_if_firewall_rule 'hotplug'
                    fi
                ;;
                *)
                ;;
            esac
        ;;
        *)
            [ "$(is_vpn_source_if "${interface}")" = '1' ] && {
                [ "${action}" = 'up' ] && {
                    deal_per_if_drop_dns_leak_rule "${interface}"
                    deal_per_if_rlbr "${interface}" '1'
                    hotplug_source_if_set_firewall "${interface}"
                }
            }

            clean_local_direct_route
            copy_local_direct_route
        ;;
    esac
}

deal_interface_status_change() {
    export GL_SERVICE_QUEUE='1'
    local interface="$1"
    local action="$2"
    local append="$3"

    eval "${append}"

    case "${if_type}" in
        'wan' | 'inner')
            deal_normal_interface_status_change "${interface}" "${action}" "${if_type}"
        ;;
        *)
            deal_vpn_interface_status_change "${interface}" "${action}"
        ;;
    esac

    create_reload_service /etc/init.d/firewall
    create_reload_service /etc/init.d/network

    reload_modified_service

    #reload_config

    clean_conntrack
}

restart_cloud(){
    #ToDo put into gl-util
    (/etc/init.d/gl-cloud stop; sleep 2; /etc/init.d/gl-cloud start) >/dev/null 2>&1 &
    kill $(pgrep -f /usr/sbin/rtty) >/dev/null 2>&1
    pgrep -f '/usr/lib/gl_ddns/dynamic_dns_updater.sh' >/dev/null && /etc/init.d/gl_ddns restart >/dev/null 2>&1 &
}

process_policy_init_state() {
    INIT_SERVICE_POLICY_EN=$(uci -q get ${CONFIG}.global.service_policy_en)
    INIT_SERVICE_POLICY_VIA=$(uci -q get ${CONFIG}.gl_process.via)
}

process_policy_check_changed() {
    local final_service_policy_en=$(uci -q get ${CONFIG}.global.service_policy_en)
    local final_via=$(uci -q get ${CONFIG}.gl_process.via)

    if [ "$INIT_SERVICE_POLICY_EN" != "$final_service_policy_en" -o "$INIT_SERVICE_POLICY_VIA" != "$final_via" ]; then
        restart_cloud
    fi
}

process_policy_set_default() {
    if [ "$INIT_SERVICE_POLICY_SET_DONE" = 0 ]; then
        uci set ${CONFIG}.global.service_policy_en=0
        uci set ${CONFIG}.gl_process.via="novpn"
        uci set ${CONFIG}.gl_process.mark="${nonevpn_mark}"
        uci commit ${CONFIG}
    fi
}

fw3_dns_save_mark() {
    local v6_enabled="$(uci -q get glipv6.globals.enabled)"

    iptables -w -t mangle -C VPN_PREROUTING_HOOK -m connmark --mark 0/0xf000 -p udp -m udp --dport 3053 -j CONNMARK --save-mark --nfmask ${vpn_mark_mask} --ctmask ${vpn_mark_mask} 2>/dev/null || \
    iptables -w -t mangle -A VPN_PREROUTING_HOOK -m connmark --mark 0/0xf000 -p udp -m udp --dport 3053 -j CONNMARK --save-mark --nfmask ${vpn_mark_mask} --ctmask ${vpn_mark_mask}
    iptables -w -t mangle -C VPN_PREROUTING_HOOK -m connmark --mark 0/0xf000 -p udp -m udp --dport 53 -j CONNMARK --save-mark --nfmask ${vpn_mark_mask} --ctmask ${vpn_mark_mask} 2>/dev/null || \
    iptables -w -t mangle -A VPN_PREROUTING_HOOK -m connmark --mark 0/0xf000 -p udp -m udp --dport 53 -j CONNMARK --save-mark --nfmask ${vpn_mark_mask} --ctmask ${vpn_mark_mask}

    [ "$v6_enabled" = '1' ] && {

        ip6tables -w -t mangle -C VPN_PREROUTING_HOOK -m connmark --mark 0/0xf000 -p udp -m udp --dport 3053 -j CONNMARK --save-mark --nfmask ${vpn_mark_mask} --ctmask ${vpn_mark_mask} 2>/dev/null || \
        ip6tables -w -t mangle -A VPN_PREROUTING_HOOK -m connmark --mark 0/0xf000 -p udp -m udp --dport 3053 -j CONNMARK --save-mark --nfmask ${vpn_mark_mask} --ctmask ${vpn_mark_mask}
        ip6tables -w -t mangle -C VPN_PREROUTING_HOOK -m connmark --mark 0/0xf000 -p udp -m udp --dport 53 -j CONNMARK --save-mark --nfmask ${vpn_mark_mask} --ctmask ${vpn_mark_mask} 2>/dev/null || \
        ip6tables -w -t mangle -A VPN_PREROUTING_HOOK -m connmark --mark 0/0xf000 -p udp -m udp --dport 53 -j CONNMARK --save-mark --nfmask ${vpn_mark_mask} --ctmask ${vpn_mark_mask}
    }
}

fw4_dns_save_mark() {
    fw4_set_add_append_statement "insert rule $VPN_TABLE_NAME PREROUTING udp dport { 53, 3053 } meta mark and ${vpn_mark_mask} != 0x0 ct mark and 0xf000 == 0x0 jump mark_meta_to_ct"
}

instance_set_mark_trans_rule() {
    local interface="$1";shift
    local mark="$1";shift

    if [ "$use_fw4" = '1' ] ;then
        fw4_set_add_rule_to_chain "mark_ct_to_meta" "ct mark and ${vpn_mark_mask} == ${mark} meta mark set meta mark and ${vpn_mask_reverse} or ${mark} comment \"${interface}_mark_ct_to_meta\""
        fw4_set_add_rule_to_chain "mark_meta_to_ct" " meta mark and ${vpn_mark_mask} == ${mark} ct mark set ct mark and ${vpn_mask_reverse} or ${mark} comment \"${interface}_mark_copy\""
    fi
}

set_forwarding_sourceifs_with_instance() {
    local vpn_if_name="$1";shift
    local source_if_list="$SOURCE_DATA_IF_LIST"
    [ "$(uci -q get edgerouter.global.enabled)" = '1' ] && {
        local source_if_list="${source_if_list} ${EDGE_ROUTER_SOURCE_IFS}"
    }

    local local_access="$(uci -q get network.${interface}.modified_local_access)"
    local forward_type='uplink-only'
    [ -n "${local_access}" -a "${local_access}" = '1' ] && forward_type='both-directions'

    for per_source_if in $source_if_list; do
        instance_set_forwarding_with_per_source_if "$vpn_if_name" "$per_source_if" "${forward_type}"
    done
}

instance_set_firewall_main_rule(){
    local interface="$1";shift
    local masq="$(uci -q get network.${interface}.modified_masq_value)"
    local local_access="$(uci -q get network.${interface}.modified_local_access)"

    uci set firewall.${interface}=zone
    uci set firewall.${interface}.name="${interface}"
    uci set firewall.${interface}.forward='ACCEPT'
    uci set firewall.${interface}.output='ACCEPT'
    uci set firewall.${interface}.mtu_fix='1'
    uci set firewall.${interface}.network="${interface}"
    uci set firewall.${interface}.input='DROP'
    uci set firewall.${interface}.masq='1'
    uci set firewall.${interface}.masq6='1'
    uci set firewall.${interface}.enabled='1'
    uci set firewall.${interface}.gl_vpn_rules='1'

    [ -n "${local_access}" -a "${local_access}" = '1' ] && uci set firewall.${interface}.input='ACCEPT'
    [ -n "${masq}" ] && {
        uci set firewall.${interface}.masq="${masq}"
        uci set firewall.${interface}.masq6="${masq}"
    }

    set_forwarding_sourceifs_with_instance "${interface}"

    uci commit firewall
}

instance_mark_default_group(){
    local interface="$1"
    local mark="$2"
    local gid

    gid=$(grep "^${interface}:" /etc/group | cut -d: -f3)
    if [ -z "$gid" ]; then
        return 1
    fi
    #if [ "$(uci -q get gl-dns.@dns[0].override_vpn)" = 1 ]; then
        if [ "$use_fw4" = '1' ] ;then
            fw4_set_add_rule_to_chain "LOCAL_POLICY" "meta mark and ${vpn_mark_mask} == 0x0 skgid ${gid} meta mark set meta mark and ${vpn_mask_reverse} xor ${mark}"
        else
            iptables -w -t mangle -C LOCAL_POLICY -m mark --mark 0x0/${vpn_mark_mask} -m owner --gid-owner $gid -j MARK --set-xmark ${mark}/${vpn_mark_mask} 2>/dev/null || \
            iptables -w -t mangle -A LOCAL_POLICY -m mark --mark 0x0/${vpn_mark_mask} -m owner --gid-owner $gid -j MARK --set-xmark ${mark}/${vpn_mark_mask}
            [ "$v6_enabled" = '1' ] && {
                ip6tables -w -t mangle -C LOCAL_POLICY -m mark --mark 0x0/${vpn_mark_mask} -m owner --gid-owner $gid -j MARK --set-xmark ${mark}/${vpn_mark_mask} 2>/dev/null || \
                    ip6tables -w -t mangle -A LOCAL_POLICY -m mark --mark 0x0/${vpn_mark_mask} -m owner --gid-owner $gid -j MARK --set-xmark ${mark}/${vpn_mark_mask}
            }
        fi
    #fi
}

instance_set_dns_rule() {
    local interface="$1"
    local mark="$2"

    [ -z "$interface" ] && return
    [ -z "$mark" ] && return

    local redirect_port=$(uci -q get dhcp.${interface}.port)
    [ -n "$redirect_port" ] && {
        local upstream_ports="53"
        local server_ports
        server_ports=$(uci -q get dhcp.@dnsmasq[0].server | grep -o '#[0-9]*' | sed 's/#//' | sort -u | tr '\n' ' ')
        [ -n "$server_ports" ] && upstream_ports="$server_ports"

        local option target
        if [ "${use_fw4}" = '1' ] ;then
            echo "chain=\"policy_output\";option=\"tcp dport { $upstream_ports } meta mark and $vpn_mark_mask == $mark skuid == dnsmasq\";target=\"redirect to :$redirect_port\"" >> "${FILE_VPN_DNS_RULE}"
            echo "chain=\"policy_output\";option=\"udp dport 53 meta mark and $vpn_mark_mask == $mark skgid == usevpn\";target=\"redirect to :$redirect_port\"" >> "${FILE_VPN_DNS_RULE}"

            echo "chain=\"policy_redirect\";option=\"meta l4proto udp meta mark and $vpn_mark_mask == $mark\";target=\"redirect to :$redirect_port\"" >> "${FILE_VPN_DNS_RULE}"
            echo "chain=\"dns_accept\";option=\"tcp dport $redirect_port meta mark and $vpn_mark_mask == $mark\";target=\"accept\"" >> "${FILE_VPN_DNS_RULE}"
            echo "chain=\"dns_accept\";option=\"udp dport $redirect_port meta mark and $vpn_mark_mask == $mark\";target=\"accept\"" >> "${FILE_VPN_DNS_RULE}"
            echo "chain=\"prerouting_vpn_deal_conn_zone\";option=\"udp dport 53 meta mark and $vpn_mark_mask == $mark iifname != lo\";target=\"ct zone set $mark\"" >> "${FILE_VPN_DNS_RULE}"
            echo "chain=\"output_vpn_deal_conn_zone\";option=\"udp sport $redirect_port oifname != lo\";target=\"ct zone set $mark\"" >> "${FILE_VPN_DNS_RULE}"
        else
            for port in $upstream_ports; do
                echo "table=\"nat\";chain=\"policy_output\";option=\"-p tcp -m mark --mark $mark/$vpn_mark_mask -m owner --uid-owner dnsmasq -m tcp --dport $port\";target=\"-j REDIRECT --to-ports $redirect_port\"" >> "${FILE_VPN_DNS_RULE}"
            done
            echo "table=\"nat\";chain=\"policy_output\";option=\"-p udp -m mark --mark $mark/$vpn_mark_mask -m owner --gid-owner usevpn -m udp --dport 53\";target=\"-j REDIRECT --to-ports $redirect_port\"" >> "${FILE_VPN_DNS_RULE}"

            echo "chain=\"policy_redirect\";option=\"-p udp -m mark --mark $mark/$vpn_mark_mask\";target=\"-j REDIRECT --to-ports $redirect_port\"" >> "${FILE_VPN_DNS_RULE}"
            echo "table=\"raw\";chain=\"pre_dns_deal_conn_zone\";option=\"-p udp -m mark --mark $mark/$vpn_mark_mask ! -i lo\";target=\"-j CT --zone $mark\"" >> "${FILE_VPN_DNS_RULE}"
            echo "table=\"raw\";chain=\"out_dns_deal_conn_zone\";option=\"-p udp --sport $redirect_port ! -o lo\";target=\"-j CT --zone $mark\"" >> "${FILE_VPN_DNS_RULE}"
        fi
    }
}

nitify_status() {
    /etc/init.d/vpn-client enabled || return 0
    status=$(ubus call gl-session call '{"module":"vpn-client", "func":"get_status"}' | jsonfilter -e '@.result')
    ubus call gl-session notify "{\"name\": \"vpnclient.status\", \"data\":$status}"
}

load_vpn_instance_rule() {
    local section="$1"
    local interface="${section}"
    local disabled proto mark


    config_get disabled "$section" disabled
    config_get proto "$section" proto

    [ "${disabled}" = '1' ] && return 0
    [ "${proto}" != 'ovpnclient' -a "${proto}" != 'wgclient' ] && return 0

    mark=$(get_mark_of_interface "$interface")

    # set zone and forwarding of vpn instance
    instance_set_firewall_main_rule "$interface"

    # default Process group of vpn instance add mark rule. now, just for stubby and dnscrypt-proxy
    instance_mark_default_group "$interface" "$mark"

    instance_set_dns_rule "$interface" "$mark"

    instance_set_mark_trans_rule "$interface" "$mark"
    # allow dnsmasq to resolve AAAA.
    if [ "$v6_enabled" = '1' ] ;then
        uci -q set dhcp.${interface}.filter_aaaa='0'
    else
        uci -q set dhcp.${interface}.filter_aaaa='1'
    fi
    uci commit dhcp
}

deal_instance() {
    config_load network
    config_foreach load_vpn_instance_rule "interface"
}

main() {
    process_policy_init_state
    config_load "$CONFIG"
    config_foreach process_rule rule 'load'
    config_foreach process_rule default 'load'
    process_policy_set_default
    config_load "$CONFIG"
    process_policy_check_changed
    config_foreach process_rule rule_process 'load'

    if [ "$use_fw4" = '1' ] ;then
        fw4_dns_save_mark
    else
        fw3_dns_save_mark
    fi
}

clean_vpn_s_firewall_section() {
    clean_gl_firewall_section() {
        local section="$1"
        local vpn_rules

        config_get vpn_rules "$section" gl_vpn_rules '0'
        [ "${vpn_rules}" = '1' ] && uci -q delete firewall."${section}"
    }

    config_load firewall
    config_foreach clean_gl_firewall_section zone
    config_foreach clean_gl_firewall_section forwarding
    config_foreach clean_gl_firewall_section rule
    uci commit firewall
}


do_clean() {
    rm -f "$FILE_VPN_DNS_RULE"

    if [ "$use_fw4" = '1' ] ;then
        #fw4_vpn_clean_all_rule
        fw4_vpn_table_set_context
    else
        remove_chain
        clean_ipset
    fi

    clean_vpn_s_firewall_section

    clean_dnsmasq_setting

    clean_local_direct_route
}

do_prepare() {
    if [ "$use_fw4" = '1' ] ;then
        uci -q set route_policy.global.use_fw4='1'
        uci commit

        check_and_save_nft_sets
        fw4_vpn_create_primary_chain
    else
        create_chain
    fi
}

fw4_integrate_rule() {
    [ "${v6_enabled}" != '1' ] && {
        fw4_set_add_append_statement "insert rule $VPN_TABLE_NAME PREROUTING meta nfproto ipv6 drop"
        fw4_set_add_append_statement "insert rule $VPN_TABLE_NAME OUTPUT meta nfproto ipv6 drop"
        fw4_set_add_append_statement "insert rule $VPN_TABLE_NAME POSTROUTING meta nfproto ipv6 drop"
    }
}

do_integrate_settings() {
    if [ "$use_fw4" = '1' ] ;then
        fw4_integrate_rule
    fi
}

do_restore_old_setting() {
    if [ "$use_fw4" = '1' ] ;then
        echo "Restoring saved dst_net set elements"
        restore_nft_sets
    fi
}

LOCKFILE=/tmp/run/rtp2.lock

[ "$1" = "not_reload_network" ] && NOT_RELOAD_NETWORK=1

cmd="$1";shift
case "$cmd" in
    interface_status_change)
        vpn_func_enabled=$(uci -q get route_policy.global.enabled)
        [ "$vpn_func_enabled" -eq 0 ] && exit 0
        deal_interface_status_change "$1" "$2" "$3"
    ;;
    *)
        count=1
        while [ -f "${LOCKFILE}" ] && [ $count -le 30 ]; do
            echo "Wait $count seconds for lock to be released..."
            sleep 1
            count=$(($count+1))
        done
        rm -f "$LOCKFILE"
        echo $$ > ${LOCKFILE}
        trap 'rm -f "$LOCKFILE"; exit' EXIT INT TERM

        echo -e "= Configuring instance:"
        lua /usr/bin/setup_instance_via.lua

        do_clean
        process_global
        do_prepare

        set_global_killswitch_rule

        deal_instance

        echo -e "\n\n\n= Configuring tunnel's rules:"
        main

        echo -e "\n\n\n= Configuring dnsmasq ipset/nftset:"
        lua /usr/bin/domain_ipset_config.lua

        echo -e "\n\n\n= Configuring dns-mark:"
        lua /usr/bin/dns_mark_ctl.lua

        do_integrate_settings

        apply

        do_restore_old_setting

        copy_local_direct_route

        rm -f ${LOCKFILE}

        if [ "$QUIET" -eq 0 ]; then
            echo -e "\n\n\= Show rules:"
            show_rules
        fi
    ;;
esac

nitify_status
