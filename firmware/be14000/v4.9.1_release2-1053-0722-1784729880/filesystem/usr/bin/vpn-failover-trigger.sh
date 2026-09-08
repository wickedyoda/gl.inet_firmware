#!/bin/sh

[ -f /lib/functions.sh ] && . /lib/functions.sh

TRIGGER_TAG="vpn-failover-trigger"
TUNNEL_SWITCH_BIN="${VPN_FAILOVER_TUNNEL_SWITCH_BIN:-/usr/bin/tunnel-switch.sh}"

is_supported_iface() {
	case "$1" in
		ovpnclient[0-9]*|wgclient*) return 0 ;;
		*) return 1 ;;
	esac
}

log_trigger() {
	logger -p user.notice -t "$TRIGGER_TAG" "$*"
}

is_vpn_client_enabled() {
	/etc/init.d/vpn-client enabled >/dev/null 2>&1
}

is_iface_enabled() {
	local iface="$1"
	local disabled

	uci -q get network."$iface" >/dev/null 2>&1 || return 1
	disabled="$(uci -q get network."$iface".disabled 2>/dev/null)"
	[ "${disabled:-0}" = "0" ]
}

collect_enabled_tunnel_ids_for_iface() {
	local iface="$1"
	local tunnel_ids=""

	config_load route_policy
	_collect_rule_tunnel_id() {
		local section="$1"
		local via enabled via_type tunnel_id

		config_get via "$section" via
		[ "$via" = "$iface" ] || return

		config_get enabled "$section" enabled
		[ "$enabled" = "1" ] || return

		config_get via_type "$section" via_type
		[ "$via_type" = "wireguard" ] || [ "$via_type" = "openvpn" ] || return

		config_get tunnel_id "$section" tunnel_id
		[ -n "$tunnel_id" ] || return

		case " $tunnel_ids " in
			*" $tunnel_id "*) ;;
			*) tunnel_ids="${tunnel_ids}${tunnel_ids:+ }${tunnel_id}" ;;
		esac
	}
	config_foreach _collect_rule_tunnel_id rule

	echo "$tunnel_ids"
}

is_tunnel_switch_running() {
	local tunnel_id="$1"
	local lock_path="/var/run/tunnel-switch-tid-${tunnel_id}.lock"
	local pid cmdline

	[ -f "$lock_path" ] || return 1

	pid=$(cat "$lock_path" 2>/dev/null | tr -d '[:space:]')
	if [ -z "$pid" ] || ! echo "$pid" | grep -Eq '^[0-9]+$'; then
		rm -f "$lock_path"
		return 1
	fi

	if ! kill -0 "$pid" 2>/dev/null; then
		rm -f "$lock_path"
		return 1
	fi

	cmdline=$(tr '\000' ' ' < "/proc/$pid/cmdline" 2>/dev/null)
	case "$cmdline" in
		*tunnel-switch.sh*) return 0 ;;
		*)
			rm -f "$lock_path"
			return 1
			;;
	esac
}

launch_tunnel_switch_async() {
	local tunnel_id="$1"
	local iface="$2"
	local delay_sec="$3"
	local source="$4"
	local reason="$5"

	(
		[ "$delay_sec" -gt 0 ] && sleep "$delay_sec"

		if is_tunnel_switch_running "$tunnel_id"; then
			log_trigger "action=skip iface=$iface source=$source reason=$reason tunnel_id=$tunnel_id cause=already_running_delayed"
			exit 0
		fi

		if ! is_iface_enabled "$iface"; then
			log_trigger "action=skip iface=$iface source=$source reason=$reason tunnel_id=$tunnel_id cause=iface_disabled_delayed"
			exit 0
		fi

		"$TUNNEL_SWITCH_BIN" "$tunnel_id" >/dev/null 2>&1
	) &

	log_trigger "action=schedule iface=$iface source=$source reason=$reason tunnel_id=$tunnel_id delay=${delay_sec}s pid=$!"
}

iface_is_failover_candidate() {
	local iface="$1"
	local tunnel_ids tunnel_id

	is_supported_iface "$iface" || return 1
	is_vpn_client_enabled || return 1
	is_iface_enabled "$iface" || return 1

	tunnel_ids="$(collect_enabled_tunnel_ids_for_iface "$iface")"
	[ -n "$tunnel_ids" ] || return 1

	for tunnel_id in $tunnel_ids; do
		is_tunnel_switch_running "$tunnel_id" && return 1
	done

	return 0
}

trigger_failover_for_iface() {
	local iface="$1"
	local source="${2:-unknown}"
	local reason="${3:-unknown}"
	local tunnel_ids launch_idx tunnel_id delay_sec

	if ! is_supported_iface "$iface"; then
		log_trigger "action=skip iface=$iface source=$source reason=$reason cause=unsupported_iface"
		return 1
	fi

	if ! is_vpn_client_enabled; then
		log_trigger "action=skip iface=$iface source=$source reason=$reason cause=vpn_client_disabled"
		return 1
	fi

	if ! is_iface_enabled "$iface"; then
		log_trigger "action=skip iface=$iface source=$source reason=$reason cause=iface_disabled"
		return 1
	fi

	tunnel_ids="$(collect_enabled_tunnel_ids_for_iface "$iface")"
	if [ -z "$tunnel_ids" ]; then
		log_trigger "action=skip iface=$iface source=$source reason=$reason cause=no_enabled_tunnel"
		return 1
	fi

	launch_idx=0
	for tunnel_id in $tunnel_ids; do
		if is_tunnel_switch_running "$tunnel_id"; then
			log_trigger "action=skip iface=$iface source=$source reason=$reason tunnel_id=$tunnel_id cause=already_running"
			continue
		fi

		delay_sec=$((launch_idx * 2))
		launch_idx=$((launch_idx + 1))
		launch_tunnel_switch_async "$tunnel_id" "$iface" "$delay_sec" "$source" "$reason"
	done

	return 0
}

main() {
	case "$1" in
		check)
			[ -n "$2" ] || return 1
			iface_is_failover_candidate "$2"
			;;
		trigger)
			[ -n "$2" ] || return 1
			trigger_failover_for_iface "$2" "${3:-manual}" "${4:-manual-trigger}"
			;;
		*)
			return 1
			;;
	esac
}

main "$@"
