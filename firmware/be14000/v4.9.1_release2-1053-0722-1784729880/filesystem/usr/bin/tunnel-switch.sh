#!/bin/sh
. /lib/functions.sh
. /lib/functions/gl_util.sh
command -v check_interface_is_up >/dev/null 2>&1 || . /lib/functions/vpn_func.sh
. /lib/functions/gl_log.sh

# log setup
LOG_LEVEL="DEBUG" # TODO: change to info or error in release
set_log_level "$LOG_LEVEL"
LOG_MODULE="tunnel_id_$1"

log_debug() { local line=$1; shift; log_message "DEBUG" "$line" "$LOG_MODULE" "$*"; }
log_info() { local line=$1; shift; log_message "INFO" "$line" "$LOG_MODULE" "$*"; }
log_error() { local line=$1; shift; log_message "ERROR" "$line" "$LOG_MODULE" "$*"; }

# ============================================================================
# lock management
# ============================================================================

acquire_lockfile() {
    local lockfile=$1
    local lock_name=$2

    # check for stale lock first
    if [ -f "$lockfile" ]; then
        local pid
        pid=$(cat "$lockfile" 2>/dev/null | tr -d '[:space:]')

        if [ -z "$pid" ] || ! echo "$pid" | grep -Eq '^[0-9]+$'; then
            log_info "$LINENO" "removing invalid lock ${lock_name} (bad pid='${pid}')"
            rm -f "$lockfile"
        elif ! kill -0 "$pid" 2>/dev/null; then
            log_info "$LINENO" "removing stale lock ${lock_name} (dead pid=$pid)"
            rm -f "$lockfile"
        # verify process is actually tunnel-switch.sh
        else
            local cmdline
            cmdline=$(tr '\000' ' ' < "/proc/$pid/cmdline" 2>/dev/null)
            case "$cmdline" in
                *tunnel-switch.sh*) ;;
                *)
                    log_info "$LINENO" "removing stale lock ${lock_name} (pid=$pid cmdline='$cmdline')"
                    rm -f "$lockfile"
                    ;;
            esac
        fi
    fi

    # atomic lock acquisition using noclobber (set -C)
    # if file exists, redirection will fail, ensuring atomicity
    if (set -C; echo $$ > "$lockfile") 2>/dev/null; then
        log_debug "$LINENO" "acquired lock ${lock_name} (pid=$$)"
        return 0
    fi

    # lock is held by another process
    local lock_holder
    lock_holder=$(cat "$lockfile" 2>/dev/null)
    [ -n "$lock_holder" ] && log_debug "$LINENO" "Lock ${lock_name} is held by process $lock_holder"
    return 1
}

# acquire lock with optional timeout (0 = infinite wait)
acquire_lockfile_wait() {
    local lockfile=$1
    local lock_name=$2
    local timeout=${3:-30}
    local interval=${4:-1}
    local waited=0

    # infinite wait mode
    if [ "$timeout" -le 0 ]; then
        while true; do
            acquire_lockfile "$lockfile" "$lock_name" && return 0
            sleep "$interval"
        done
    fi

    # timed wait mode
    while [ "$waited" -lt "$timeout" ]; do
        acquire_lockfile "$lockfile" "$lock_name" && return 0
        sleep "$interval"
        waited=$((waited + interval))
    done

    log_error "$LINENO" "timeout waiting for lock ${lock_name} (${timeout}s)"
    return 1
}

release_lockfile() {
    local lockfile=$1
    local lock_name=$2
    local current_pid=$(cat "$lockfile" 2>/dev/null)

    # only release by proc owner or if lock is already gone
    if [ "$current_pid" = "$$" ] || [ -z "$current_pid" ]; then
        rm -f "$lockfile"
        [ -n "$lock_name" ] && log_debug "$LINENO" "released lock ${lock_name}"
    else
        log_error "$LINENO" "cannot release lock $lockfile (owned by $current_pid, not $$)"
    fi
}

acquire_lock() {
    local tunnel_id=$1
    acquire_lockfile "/var/run/tunnel-switch-tid-${tunnel_id}.lock" "tunnel_id=${tunnel_id}"
}

release_lock() {
    local tunnel_id=$1
    release_lockfile "/var/run/tunnel-switch-tid-${tunnel_id}.lock" "tunnel_id=${tunnel_id}"
}

release_alloc_lock() {
    [ -n "$CURRENT_ALLOC_LOCK" ] && {
        release_lockfile "$CURRENT_ALLOC_LOCK" "iface-allocation"
        CURRENT_ALLOC_LOCK=""
    }
}

release_config_lock() {
    [ -n "$CURRENT_CONFIG_LOCK" ] && {
        release_lockfile "$CURRENT_CONFIG_LOCK" "network-switch"
        CURRENT_CONFIG_LOCK=""
    }
}

# ============================================================================
# utility functions - state management and parsing
# ============================================================================

get_state_dir() {
    case "$1" in
        openvpn) echo "/tmp/ovpnclient" ;;
        wireguard) echo "/tmp/wireguard" ;;
        *) echo "/tmp/$1" ;;
    esac
}

wait_for_connection() {
    local state_file=$1
    local timeout=${2:-15}
    local interval=${3:-2}
    local waited=0

    while [ "$waited" -lt "$timeout" ]; do
        [ "$(cat "$state_file" 2>/dev/null)" = "connected" ] && return 0
        sleep "$interval"
        waited=$((waited + interval))
    done
    return 1
}

build_config_name() {
    local via_type=$1
    local group_id=$2
    local profile_id=$3
    [ "$via_type" = "openvpn" ] && echo "${group_id}_${profile_id}" || echo "peer_${profile_id}"
}

# parse profile line format: [proto:]group_id_profile_id
# usage:
#   parse_profile_line "line" var_group_id var_profile_id
#   parse_profile_line "line" var_proto var_group_id var_profile_id
# proto output variable is optional
parse_profile_line() {
    local line="$1"
    local out_proto=$2
    local out_group_id=$3
    local out_profile_id=$4
    local proto="" group_id="" profile_id=""

    # support 3-arg mode where proto output is omitted
    if [ -z "$out_profile_id" ]; then
        out_profile_id="$out_group_id"
        out_group_id="$out_proto"
        out_proto=""
    fi

    case "$line" in
        *:*) proto="${line%%:*}"; line="${line#*:}" ;;
    esac

    group_id="${line%%_*}"
    profile_id="${line#*_}"
    [ "$group_id" = "$line" ] && { group_id=""; profile_id="$line"; }

    [ -n "$out_proto" ] && eval "$out_proto='$proto'"
    [ -n "$out_group_id" ] && eval "$out_group_id='$group_id'"
    [ -n "$out_profile_id" ] && eval "$out_profile_id='$profile_id'"
}

# normalize profile line:
# - strip CR
# - trim leading/trailing whitespace
# - skip empty lines and comments
normalize_profile_line() {
    local line="$1"
    line=$(printf '%s' "$line" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [ -z "$line" ] && return 1
    case "$line" in
        \#*) return 1 ;;
    esac
    printf '%s' "$line"
}

# ============================================================================
# uci configuration functions
# ============================================================================

# get all route_policy sections using the given interface
get_sections_for_iface() {
    local iface=$1
    local sections=""

    config_load route_policy
    _collect_section() {
        local section=$1
        local via=$(uci -q get route_policy."$section".via)
        [ "$via" = "$iface" ] && sections="${sections}${sections:+ }$section"
    }
    config_foreach _collect_section rule

    echo "$sections"
}

# find route_policy section by tunnel_id
get_section_for_tunnel_id() {
    local tunnel_id=$1
    local found=""

    config_load route_policy
    _collect_tunnel_section() {
        local section=$1
        [ -n "$found" ] && return
        local sec_tunnel_id=$(uci -q get route_policy."$section".tunnel_id)
        [ "$sec_tunnel_id" = "$tunnel_id" ] && found="$section"
    }
    config_foreach _collect_tunnel_section rule

    echo "$found"
}

resolve_route_policy_section() {
    local tunnel_id=$1
    local section

    section=$(get_section_for_tunnel_id "$tunnel_id")
    [ -n "$section" ] || {
        log_error "$LINENO" "ERROR: no section for tunnel_id=$tunnel_id"
        return 1
    }

    echo "$section"
}

route_policy_get() {
    local tunnel_id=$1
    local option=$2
    local section

    section=$(resolve_route_policy_section "$tunnel_id") || return 1
    uci -q get route_policy."$section"."$option"
}

route_policy_set() {
    local tunnel_id=$1
    local option=$2
    local value=$3
    local section

    section=$(resolve_route_policy_section "$tunnel_id") || return 1
    uci set route_policy."$section"."$option"="$value"
}

route_policy_delete() {
    local tunnel_id=$1
    local option=$2
    local section

    section=$(resolve_route_policy_section "$tunnel_id") || return 1
    uci -q delete route_policy."$section"."$option"
}

route_policy_clear_optional() {
    local tunnel_id=$1
    local option=$2

    route_policy_delete "$tunnel_id" "$option" >/dev/null 2>&1 || true
}

# count enabled route_policy sections for interface
count_enabled_sections_for_iface() {
    local iface=$1
    local count=0

    config_load route_policy
    _count_enabled_section() {
        local section=$1
        local via=$(uci -q get route_policy."$section".via)
        local enabled=$(uci -q get route_policy."$section".enabled)
        [ "$via" = "$iface" ] && [ "$enabled" = "1" ] && count=$((count + 1))
    }
    config_foreach _count_enabled_section rule

    echo "$count"
}

# update route_policy section with new profile info
update_route_policy_profile() {
    local tunnel_id=$1
    local via_type=$2
    local profile_id=$3

    if [ "$via_type" = "openvpn" ]; then
        route_policy_set "$tunnel_id" client_id "$profile_id" || return 1
        route_policy_clear_optional "$tunnel_id" peer_id
    else
        route_policy_set "$tunnel_id" peer_id "$profile_id" || return 1
        route_policy_clear_optional "$tunnel_id" client_id
    fi
}

# find existing interface using specified config (excluding target interface)
# usage: find_iface_for_config "cfg_name" "proto" "exclude_iface" var_iface var_state
find_iface_for_config() {
    local target_cfg=$1
    local target_proto=$2
    local exclude_iface=$3
    local out_iface=$4
    local out_state=$5
    local found_iface="" found_state=""

    config_load network
    _find_iface() {
        local section=$1
        [ -n "$found_iface" ] && return
        [ "$section" = "$exclude_iface" ] && return

        local proto=$(uci -q get network."$section".proto)
        [ "$proto" != "$target_proto" ] && return

        local cfg=$(uci -q get network."$section".config)
        [ "$cfg" != "$target_cfg" ] && return

        local state="down"
        [ "$(check_interface_is_up "$section")" = "true" ] && state="up"
        found_iface="$section"
        found_state="$state"
    }
    config_foreach _find_iface interface

    eval "$out_iface='$found_iface'"
    eval "$out_state='$found_state'"
}

# ============================================================================
# interface management
# ============================================================================

# find an available interface name that's not in use
find_free_iface_name() {
    local prefix=$1
    local current_section=$2

    for i in $(seq 1 5); do
        local candidate="${prefix}${i}"
        uci -q show network."$candidate" >/dev/null && continue

        local used=$(get_sections_for_iface "$candidate")
        local skip=0
        for s in $used; do
            [ "$s" != "$current_section" ] && skip=1 && break
        done

        [ $skip -eq 0 ] && echo "$candidate" && return 0
    done
    return 1
}

# ============================================================================
# interface operations
# ============================================================================

# ensure network interface instance exists, create if needed
ensure_instance_exists() {
    local iface=$1
    local profile_id=$2
    local profile_group_id=$3
    local expected_proto=$4

    # check if interface already exists
    if uci -q get network."${iface}" >/dev/null; then
        local proto=$(uci -q get network."${iface}".proto)
        [ -n "$proto" ] && [ "$proto" != "$expected_proto" ] && {
            log_error "$LINENO" "interface ${iface} proto mismatch: got ${proto}, expected ${expected_proto}"
            return 1
        }
        return 0
    fi

    # validate required parameters
    [ -z "$profile_group_id" ] && {
        log_error "$LINENO" "missing group_id, cannot create interface ${iface}"
        return 1
    }

    log_info "$LINENO" "creating interface ${iface} for group ${profile_group_id} profile ${profile_id}"
    local gen_output gen_rc
    gen_output=$(/usr/bin/setup_instance generate "${iface}" "${profile_group_id}" "${profile_id}" 2>&1)
    gen_rc=$?
    [ "$gen_rc" -ne 0 ] && {
        log_error "$LINENO" "setup_instance generate failed: $gen_output"
        return 1
    }

    local start_output start_rc
    start_output=$(/usr/bin/setup_instance start "${iface}" 2>&1)
    start_rc=$?
    [ "$start_rc" -ne 0 ] && {
        log_error "$LINENO" "setup_instance start failed for ${iface}: $start_output"
        return 1
    }

    return 0
}

# update wireguard business provider config for specific providers
update_provider_config() {
    local group_id=$1
    local peer_id=$2
    local interface=$3

    local group_name=$(uci -q get wireguard.group_$group_id.group_name)
    case "$group_name" in
        Hideme)
            [ -n "$interface" ] && ubus call gl-session call "{\"module\":\"wg_client\",\"func\":\"update_provider_config\",\"params\":{\"group_id\":$group_id,\"peer_id\":$peer_id,\"instance\":\"$interface\",\"update_all\":false}}"
            ;;
        PIA|IPVanish|NordVPN)
            ubus call gl-session call "{\"module\":\"wg_client\",\"func\":\"update_provider_config\",\"params\":{\"group_id\":$group_id,\"peer_id\":$peer_id,\"update_all\":false}}"
            ;;
        # TODO: other import config files should clean the other options added by business providers
        # *) do it when cross group should be supported
    esac
}

# notify frontend of vpn status
notify_frontend() {
    (
        status=$(ubus -t 5 call gl-session call '{"module":"vpn-client", "func":"get_status"}' | jsonfilter -e '@.result')
        ubus -t 5 call gl-session notify "{\"name\": \"vpnclient.status\", \"data\":$status}"
    ) &
}

# repoint a route policy rule to an existing active interface without restarting
repoint_rule_to_iface() {
    local tunnel_id=$1
    local via_type=$2
    local profile_id=$3
    local iface=$4
    local group_id=$5
    local section

    section=$(resolve_route_policy_section "$tunnel_id") || return 1
    log_info "$LINENO" "repointing rule ${section} to existing interface ${iface}"
    update_route_policy_profile "$tunnel_id" "$via_type" "$profile_id" || return 1
    if [ -n "$group_id" ]; then
        route_policy_set "$tunnel_id" group_id "$group_id" || return 1
    fi
    route_policy_set "$tunnel_id" via "$iface" || return 1
    if ! uci commit route_policy; then
        log_error "$LINENO" "failed to commit route_policy when repointing section ${section}"
        return 1
    fi

    notify_frontend
    return 0
}

# switch tunnel to new profile
switch_tunnel() {
    local tunnel_id=$1
    local iface=$2
    local client_id=$3
    local config_name=$4
    local via_type=$5
    local group_id=$6
    local section
    local prev_config prev_disabled iface_up=0 restart=1

    section=$(resolve_route_policy_section "$tunnel_id") || return 1
    prev_config=$(uci -q get network."$iface".config)
    prev_disabled=$(uci -q get network."$iface".disabled)
    [ "$(check_interface_is_up "$iface")" = "true" ] && iface_up=1

    # skip restart if config unchanged and interface is up
    if [ "$prev_config" = "$config_name" ] && [ "${prev_disabled:-0}" != "1" ] && [ "$iface_up" -eq 1 ]; then
        restart=0
    fi

    update_route_policy_profile "$tunnel_id" "$via_type" "$client_id" || return 1
    if [ -n "$group_id" ]; then
        route_policy_set "$tunnel_id" group_id "$group_id" || return 1
    fi
    route_policy_set "$tunnel_id" via "$iface" || return 1

    uci set network."$iface".config="$config_name"
    uci set network."$iface".disabled='0'

    if ! uci commit route_policy; then
        log_error "$LINENO" "failed to commit route_policy for section ${section}"
        return 1
    fi

    if ! uci commit network; then
        log_error "$LINENO" "failed to commit network for interface ${iface}"
        return 1
    fi

    # update provider config for wireguard
    [ "$via_type" = "wireguard" ] && [ -n "$group_id" ] && [ -n "$client_id" ] && \
        update_provider_config "$group_id" "$client_id" "$iface"

    # restart interface if config changed
    if [ "$restart" -eq 1 ]; then
        log_info "$LINENO" "restarting interface ${iface}"
        command -v ifdown >/dev/null 2>&1 && ifdown "$iface" 2>/dev/null
        command -v ifup >/dev/null 2>&1 && ifup "$iface" 2>/dev/null
        local state_dir=$(get_state_dir "$via_type")
        rm -f "${state_dir}/${iface}_state"
    else
        log_debug "$LINENO" "skip ifdown/ifup for $iface (config unchanged and up)"
    fi

    notify_frontend
    return 0
}

# ============================================================================
# main logic
# ============================================================================

# poll iface up to grace_seconds; returns 0 if recovered (abort failover), 1 if still down.
wait_before_failover() {
    local iface=$1
    local grace_seconds=${2:-8}
    local waited=0

    while [ "$waited" -lt "$grace_seconds" ]; do
        sleep 1
        waited=$((waited + 1))
        if [ "$(check_interface_is_up "$iface")" = "true" ]; then
            log_info "$LINENO" "interface ${iface} recovered after ${waited}s, aborting tunnel-switch"
            return 0
        fi
    done

    log_info "$LINENO" "interface ${iface} still down after ${grace_seconds}s, proceeding with failover"
    return 1
}

# cleanup all locks on exit
cleanup_locks() {
    local tunnel_id=$1

    release_alloc_lock
    release_config_lock
    release_lock "$tunnel_id"
}

# validate input and acquire tunnel lock
validate_and_lock_tunnel() {
    local tunnel_id=$1

    [ -z "$tunnel_id" ] && {
        echo "Usage: $0 <tunnel_id>"
        log_error "$LINENO" "ERROR: no tunnel_id provided"
        return 1
    }

    case "$tunnel_id" in
        *[!0-9]*)
            echo "Error: tunnel_id must be numeric"
            log_error "$LINENO" "ERROR: invalid tunnel_id=$tunnel_id"
            return 1
            ;;
    esac

    acquire_lock "$tunnel_id" || {
        echo "Error: tunnel_id $tunnel_id is already being switched"
        return 1
    }

    trap 'cleanup_locks "$tunnel_id"' EXIT INT TERM
    return 0
}

# load route policy context for the target tunnel
load_tunnel_context() {
    local tunnel_id=$1
    local out_cfg_section=$2
    local out_via_type=$3
    local out_group_id=$4
    local out_current_iface=$5
    local out_shared_iface=$6
    local _cfg_section _via_type _group_id _current_iface
    local _shared_count=0 _shared_iface=0

    _cfg_section=$(resolve_route_policy_section "$tunnel_id")
    [ -z "$_cfg_section" ] && {
        echo "Error: no route_policy rule found for tunnel_id $tunnel_id"
        log_error "$LINENO" "ERROR: no section for tunnel_id=$tunnel_id"
        return 1
    }

    _via_type=$(route_policy_get "$tunnel_id" via_type)
    _group_id=$(route_policy_get "$tunnel_id" group_id)
    _current_iface=$(route_policy_get "$tunnel_id" via)

    { [ -z "$_via_type" ] || [ -z "$_current_iface" ]; } && {
        echo "Error: missing via_type or via for route_policy section $_cfg_section"
        log_error "$LINENO" "ERROR: invalid section config section=$_cfg_section"
        return 1
    }

    _shared_count=$(count_enabled_sections_for_iface "$_current_iface")
    [ "$_shared_count" -gt 1 ] && _shared_iface=1

    log_debug "$LINENO" "section=$_cfg_section, iface=$_current_iface, via_type=$_via_type, group_id=$_group_id, shared_count=$_shared_count"

    eval "$out_cfg_section='$_cfg_section'"
    eval "$out_via_type='$_via_type'"
    eval "$out_group_id='$_group_id'"
    eval "$out_current_iface='$_current_iface'"
    eval "$out_shared_iface='$_shared_iface'"
    return 0
}

# load profiles file path and total lines
load_profiles_context() {
    local tunnel_id=$1
    local out_profiles_path=$2
    local out_total_profiles=$3
    local _profiles_path _total_profiles

    _profiles_path=$(route_policy_get "$tunnel_id" profiles)
    _profiles_path=${_profiles_path:-"/etc/vpn_profiles.d/profile${tunnel_id}"}

    [ -f "$_profiles_path" ] || {
        echo "Error: profiles file not found at $_profiles_path"
        return 1
    }

    _total_profiles=$(wc -l < "$_profiles_path")
    [ "$_total_profiles" -gt 0 ] || {
        echo "Error: no profiles available in $_profiles_path"
        return 1
    }

    log_debug "$LINENO" "profiles_path=$_profiles_path, total_profiles=$_total_profiles"

    eval "$out_profiles_path='$_profiles_path'"
    eval "$out_total_profiles='$_total_profiles'"
    return 0
}

# detect current profile and resolve its index in profiles file
detect_current_profile_index() {
    local tunnel_id=$1
    local group_id=$2
    local current_iface=$3
    local profiles_path=$4
    local out_current_index=$5
    local _current_network_config _current_proto
    local _match_group_id="" _match_peer_id=""
    local _current_profile_id="" _current_index=0
    local _current_peer_id _current_client_id _cur_id

    _current_network_config=$(uci -q get network."$current_iface".config)
    _current_proto=$(uci -q get network."$current_iface".proto)

    case "$_current_proto" in
        wgclient)
            _match_peer_id=${_current_network_config#peer_}
            _match_group_id=$(uci -q get wireguard.${_current_network_config}.group_id)
            ;;
    esac

    _current_peer_id=$(route_policy_get "$tunnel_id" peer_id)
    _current_client_id=$(route_policy_get "$tunnel_id" client_id)

    if [ "$_current_proto" = "ovpnclient" ] && [ -n "$_current_network_config" ]; then
        _current_profile_id="$_current_network_config"
    elif [ "$_current_proto" = "wgclient" ] && [ -n "$_match_group_id" ] && [ -n "$_match_peer_id" ]; then
        _current_profile_id="${_match_group_id}_${_match_peer_id}"
    else
        _cur_id=${_current_peer_id:-$_current_client_id}
        [ -n "$_cur_id" ] && [ -n "$group_id" ] && _current_profile_id="${group_id}_${_cur_id}"
    fi

    if [ -n "$_current_profile_id" ]; then
        _current_index=$(sed -n "/^${_current_profile_id}\$/=" "$profiles_path" | head -n1)
    fi
    [ -z "$_current_index" ] && _current_index=0

    eval "$out_current_index='$_current_index'"
    return 0
}

# mark current profile candidate as skipped by moving current index to next index for next attempt
mark_candidate_skipped() {
    tsw_current_index=$tsw_next_index
}

# prepare next candidate profile in current attempt
prepare_next_profile_candidate() {
    tsw_next_index=$(( (tsw_current_index % tsw_total_profiles) + 1 ))
    tsw_next_line=$(sed -n "${tsw_next_index}p" "${tsw_profiles_path}")

    tsw_next_line=$(normalize_profile_line "$tsw_next_line") || {
        log_debug "$LINENO" "skipping empty/comment line at index ${tsw_next_index}"
        mark_candidate_skipped
        return 1
    }

    parse_profile_line "$tsw_next_line" tsw_next_group_id tsw_next_profile_id
    [ -z "$tsw_next_group_id" ] && tsw_next_group_id="$tsw_group_id"
    [ -z "$tsw_next_profile_id" ] && {
        log_debug "$LINENO" "invalid profile at index ${tsw_next_index}, skipping"
        mark_candidate_skipped
        return 1
    }

    tsw_profile_group_id="$tsw_next_group_id"
    tsw_next_client_id="$tsw_next_profile_id"
    tsw_config_name=$(build_config_name "$tsw_via_type" "$tsw_profile_group_id" "$tsw_next_client_id")
    tsw_target_iface="${tsw_dedicated_iface:-$tsw_current_iface}"
    return 0
}

# attempt reuse of an existing interface for current candidate
# returns:
#   1 - no existing iface found, caller should proceed with normal switch
#   0 + tsw_switch_success=1 - reuse succeeded, caller should stop
#   0 + mark_candidate_skipped - found but unusable (down/lock fail), caller should try next
attempt_reuse_existing_iface() {
    local existing_iface existing_state

    find_iface_for_config "$tsw_config_name" "$tsw_expected_proto" "$tsw_target_iface" existing_iface existing_state
    [ -z "$existing_iface" ] && return 1

    if [ "$existing_state" != "up" ]; then
        log_debug "$LINENO" "config $tsw_config_name exists on $existing_iface but interface is down, skipping"
        mark_candidate_skipped
        return 0
    fi

    CURRENT_CONFIG_LOCK="/var/run/tunnel-switch-network-switch.lock"
    if ! acquire_lockfile_wait "$CURRENT_CONFIG_LOCK" "network-switch"; then
        CURRENT_CONFIG_LOCK=""
        mark_candidate_skipped
        return 0
    fi

    log_info "$LINENO" "reusing active interface $existing_iface with config $tsw_config_name"
    if ! repoint_rule_to_iface "$tsw_tunnel_id" "$tsw_via_type" "$tsw_next_client_id" "$existing_iface" "$tsw_profile_group_id"; then
        release_config_lock
        mark_candidate_skipped
        return 0
    fi

    release_config_lock
    tsw_switch_success=1
    return 0
}

# ensure target interface is ready for current candidate
ensure_candidate_iface_ready() {
    local ensure_rc reuse_rc iface_prefix current_section

    if [ "$tsw_shared_iface" -eq 1 ] && [ -z "$tsw_dedicated_iface" ]; then
        iface_prefix=$([ "$tsw_via_type" = "openvpn" ] && echo "ovpnclient" || echo "wgclient")
        CURRENT_ALLOC_LOCK="/var/run/tunnel-switch-iface-alloc-${iface_prefix}.lock"
        if ! acquire_lockfile_wait "$CURRENT_ALLOC_LOCK" "iface-allocation" 0 1; then
            CURRENT_ALLOC_LOCK=""
            mark_candidate_skipped
            return 1
        fi

        current_section=$(resolve_route_policy_section "$tsw_tunnel_id") || {
            release_alloc_lock
            mark_candidate_skipped
            return 1
        }

        tsw_target_iface=$(find_free_iface_name "$iface_prefix" "$current_section")
        if [ -z "$tsw_target_iface" ]; then
            release_alloc_lock
            mark_candidate_skipped
            return 1
        fi

        ensure_instance_exists "$tsw_target_iface" "$tsw_next_client_id" "$tsw_profile_group_id" "$tsw_expected_proto"
        ensure_rc=$?
        if [ "$ensure_rc" -ne 0 ]; then
            release_alloc_lock
            # retry reuse once to absorb create-vs-reuse race
            attempt_reuse_existing_iface
            reuse_rc=$?
            [ "$reuse_rc" -eq 0 ] && return 1
            mark_candidate_skipped
            return 1
        fi

        tsw_dedicated_iface="$tsw_target_iface"
        tsw_current_iface="$tsw_target_iface"

        release_alloc_lock
    else
        ensure_instance_exists "$tsw_target_iface" "$tsw_next_client_id" "$tsw_profile_group_id" "$tsw_expected_proto"
        ensure_rc=$?
        if [ "$ensure_rc" -ne 0 ]; then
            # retry reuse once to absorb create-vs-reuse race
            attempt_reuse_existing_iface
            reuse_rc=$?
            [ "$reuse_rc" -eq 0 ] && return 1
            mark_candidate_skipped
            return 1
        fi
    fi

    log_debug "$LINENO" "Switching to client $tsw_next_client_id (index $tsw_next_index/$tsw_total_profiles) on $tsw_target_iface"
    return 0
}

# execute switch and wait connection result for current candidate
execute_candidate_switch() {
    local state_dir

    CURRENT_CONFIG_LOCK="/var/run/tunnel-switch-network-switch.lock"
    if ! acquire_lockfile_wait "$CURRENT_CONFIG_LOCK" "network-switch"; then
        CURRENT_CONFIG_LOCK=""
        mark_candidate_skipped
        return 0
    fi

    if ! switch_tunnel "$tsw_tunnel_id" "$tsw_target_iface" "$tsw_next_client_id" "$tsw_config_name" "$tsw_via_type" "$tsw_profile_group_id"; then
        release_config_lock
        mark_candidate_skipped
        return 0
    fi

    release_config_lock
    [ -n "$tsw_profile_group_id" ] && tsw_group_id="$tsw_profile_group_id"

    state_dir=$(get_state_dir "$tsw_via_type")
    if wait_for_connection "${state_dir}/${tsw_target_iface}_state"; then
        log_debug "$LINENO" "Tunnel switched successfully to $tsw_next_client_id"
        tsw_switch_success=1
        return 0
    fi

    log_debug "$LINENO" "Client $tsw_next_client_id failed to connect, trying next profile..."
    mark_candidate_skipped
    return 0
}

# process one profile attempt in failover loop
process_profile_attempt() {
    prepare_next_profile_candidate || return 0
    attempt_reuse_existing_iface && return 0
    ensure_candidate_iface_ready || return 0
    execute_candidate_switch || return 1
    return 0
}

main() {
    local tunnel_id=$1
    local cfg_section via_type group_id current_iface shared_iface
    local profiles_path total_profiles
    local current_index
    local expected_proto
    local attempt=0 max_attempts

    CURRENT_ALLOC_LOCK=""
    CURRENT_CONFIG_LOCK=""

    log_info "$LINENO" "========== tunnel-switch.sh started =========="
    log_debug "$LINENO" "Script: $0, tunnel_id: $tunnel_id, PID: $$"

    validate_and_lock_tunnel "$tunnel_id" || exit 1
    load_tunnel_context "$tunnel_id" cfg_section via_type group_id current_iface shared_iface || exit 1

    if wait_before_failover "$current_iface"; then
        log_info "$LINENO" "interface recovered during grace period, no failover needed"
        exit 0
    fi

    load_profiles_context "$tunnel_id" profiles_path total_profiles || exit 1
    if [ "$total_profiles" -le 1 ]; then
        log_info "$LINENO" "only one candidate profile found, skip tunnel switch"
        exit 0
    fi
    detect_current_profile_index \
        "$tunnel_id" "$group_id" "$current_iface" "$profiles_path" current_index || exit 1

    expected_proto=$([ "$via_type" = "openvpn" ] && echo "ovpnclient" || echo "wgclient")
    # tsw_ prefix means "tunnel switch worker" - variables used across the attempt loop
    tsw_tunnel_id="$tunnel_id"
    tsw_via_type="$via_type"
    tsw_shared_iface="$shared_iface"
    tsw_current_iface="$current_iface"
    tsw_dedicated_iface=""
    tsw_group_id="$group_id"
    tsw_expected_proto="$expected_proto"
    tsw_profiles_path="$profiles_path"
    tsw_current_index="$current_index"
    tsw_total_profiles="$total_profiles"
    tsw_switch_success=0
    max_attempts=$tsw_total_profiles

    while [ "$attempt" -lt "$max_attempts" ]; do
        process_profile_attempt || {
            log_error "$LINENO" "internal error during profile attempt"
            exit 1
        }

        [ "$tsw_switch_success" -eq 1 ] && break
        attempt=$((attempt + 1))
    done

    if [ "$tsw_switch_success" -eq 1 ]; then
        log_info "$LINENO" "tunnel switch completed successfully, reloading route policy"
        /usr/bin/rtp2.sh 2>/dev/null
        exit 0
    fi

    log_error "$LINENO" "no working tunnel found after $tsw_total_profiles attempts"
    log_error "$LINENO" "will retry on next ifdown event"
    exit 1
}

main "$@"
