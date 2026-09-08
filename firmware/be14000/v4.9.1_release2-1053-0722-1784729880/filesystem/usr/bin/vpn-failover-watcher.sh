#!/bin/sh

WATCHER_TAG="vpn-failover-watcher"
WATCHER_RUNTIME_DIR="${VPN_FAILOVER_WATCHER_RUNTIME_DIR:-/tmp/run/vpn-failover-watcher}"
TRIGGER_BIN="${VPN_FAILOVER_TRIGGER_BIN:-/usr/bin/vpn-failover-trigger.sh}"
WATCHER_TIMEOUT_DEFAULT="${VPN_FAILOVER_WATCHER_TIMEOUT:-30}"
WATCHER_SOURCE="setup-timeout"
WATCHER_REASON="startup-connecting-timeout"
WATCHER_TRAP_IFACE=""

ensure_runtime_dir() {
	[ -d "$WATCHER_RUNTIME_DIR" ] || mkdir -p "$WATCHER_RUNTIME_DIR"
}

lockfile_for_iface() {
	echo "$WATCHER_RUNTIME_DIR/$1.pid"
}

acquire_iface_lock() {
	local iface="$1"
	local lockfile pid cmdline

	lockfile="$(lockfile_for_iface "$iface")"
	if [ -f "$lockfile" ]; then
		pid=$(cat "$lockfile" 2>/dev/null | tr -d '[:space:]')
		if [ -n "$pid" ] && echo "$pid" | grep -Eq '^[0-9]+$' && kill -0 "$pid" 2>/dev/null; then
			cmdline=$(tr '\000' ' ' < "/proc/$pid/cmdline" 2>/dev/null)
			case "$cmdline" in
				*vpn-failover-watcher.sh*) return 1 ;;
			esac
		fi
		rm -f "$lockfile"
	fi

	if (set -C; echo $$ > "$lockfile") 2>/dev/null; then
		return 0
	fi

	return 1
}

release_iface_lock() {
	local iface="$1"
	local lockfile owner

	lockfile="$(lockfile_for_iface "$iface")"
	owner=$(cat "$lockfile" 2>/dev/null | tr -d '[:space:]')
	[ "$owner" = "$$" ] && rm -f "$lockfile"
}

cleanup_watcher_lock() {
	release_iface_lock "$WATCHER_TRAP_IFACE"
}

now_epoch() {
	date +%s
}

log_watcher() {
	logger -p user.notice -t "$WATCHER_TAG" "$*"
}

log_watcher_debug() {
	[ "${VPN_FAILOVER_DEBUG:-0}" = "1" ] || return 0
	logger -p user.debug -t "$WATCHER_TAG" "$*"
}

sleep_seconds() {
	sleep "$1"
}

read_state_file() {
	local state_file="$1"
	local state=""

	[ -r "$state_file" ] || return 0
	IFS= read -r state < "$state_file" || return 0
	printf '%s' "$state"
}

watcher_should_continue() {
	local iface="$1"

	"$TRIGGER_BIN" check "$iface" >/dev/null 2>&1
}

invoke_failover_trigger() {
	local iface="$1"

	"$TRIGGER_BIN" trigger "$iface" "$WATCHER_SOURCE" "$WATCHER_REASON"
}

watch_iface_until_timeout() {
	local iface="$1"
	local state_file="$2"
	local timeout="$3"
	local start now state

	start="$(now_epoch)"

	while true; do
		watcher_should_continue "$iface" || {
			log_watcher "action=exit iface=$iface source=$WATCHER_SOURCE reason=$WATCHER_REASON result=not_eligible"
			return 0
		}

		state="$(read_state_file "$state_file")"
		[ "$state" = "connected" ] && {
			log_watcher "action=exit iface=$iface source=$WATCHER_SOURCE reason=$WATCHER_REASON result=connected"
			return 0
		}

		now="$(now_epoch)"
		log_watcher_debug "action=check iface=$iface source=$WATCHER_SOURCE reason=$WATCHER_REASON elapsed=$((now - start)) state=${state:-missing}"
		if [ $((now - start)) -ge "$timeout" ]; then
			log_watcher "action=trigger iface=$iface source=$WATCHER_SOURCE reason=$WATCHER_REASON elapsed=$((now - start))"
			invoke_failover_trigger "$iface"
			return 0
		fi

		sleep_seconds 1
	done
}

main() {
	local iface="$1"
	local state_file="$2"
	local timeout="${3:-$WATCHER_TIMEOUT_DEFAULT}"

	[ -n "$iface" ] && [ -n "$state_file" ] || return 1

	ensure_runtime_dir
	acquire_iface_lock "$iface" || return 0
	WATCHER_TRAP_IFACE="$iface"
	trap 'cleanup_watcher_lock' EXIT INT TERM

	watch_iface_until_timeout "$iface" "$state_file" "$timeout"
}

main "$@"
