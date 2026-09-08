#!/bin/sh
# GL cloud ExpressVPN activation: device sign + eligibility / apply / order status.
#
# Usage:
#   expressvpn_activate.sh payload
#   expressvpn_activate.sh eligibility
#   expressvpn_activate.sh apply <orderId> [purchase_source] [order_email]
#   expressvpn_activate.sh order_status [orderId] [purchase_source] [order_email]
#
# orderId for apply / order_status defaults to uci expressvpn.global.order_id when omitted.
# eligibility writes UCI expressvpn.global.eligibility; other subcommands print upstream JSON.
#
# Output contract (aligned with expressvpn_login.sh):
#   error: { "status": "error", "err_msg": "<string>" }

emit_error() {
	printf '{"status":"error","err_msg":"%s"}\n' "$1"
}

json_escape() {
	printf '%s' "$1" | sed 's/\\/\\\\/g;s/"/\\"/g'
}

normalize_purchase_source() {
	_src=$(printf '%s' "$1" | tr 'A-Z' 'a-z' | sed 's/[ .-]/_/g')
	case "$_src" in
	amazon) printf 'amazon' ;;
	glinet|gli_net|gl_inet|glinet_store|gl_inet_store) printf 'glinet_store' ;;
	"") return 1 ;;
	*) return 2 ;;
	esac
}

gl_order_source() {
	case "$1" in
	amazon) printf 'AMAZON' ;;
	glinet_store) printf 'SHOPIFY' ;;
	*) return 1 ;;
	esac
}

json_get_first() {
	_v=$(jsonfilter -i "$1" -e "$2" 2>/dev/null | head -1)
	[ "$_v" = "null" ] && return 0
	printf '%s' "$_v"
}

GL_PATH_ELIGIBILITY="/cloud-api/cloud/v2/expressVpn/activations/devices/eligibility"
GL_PATH_APPLY="/cloud-api/cloud/v2/expressVpn/activations/apply"
GL_PATH_ORDER_STATUS="/cloud-api/cloud/v2/expressVpn/activations/order/status"

MAC=""
SN=""
DDNS=""
SN2=""
TS=""
SIGN=""

mkdir -p /tmp/expressvpn

read_device_identity() {
	MAC=$(cat /proc/gl-hw-info/device_mac 2>/dev/null | tr -d ':' | tr 'A-F' 'a-f')
	SN=$(cat /proc/gl-hw-info/device_sn 2>/dev/null | tr -d ' \n')
	DDNS=$(cat /proc/gl-hw-info/device_ddns 2>/dev/null | tr -d ' \n')
	SN2=$(cat /proc/gl-hw-info/device_sn_bak 2>/dev/null | tr -d ' \n' | sha256sum | awk '{print $1}')
}

make_sign_fields() {
	read_device_identity
	[ -n "$MAC" ] && [ -n "$SN" ] || return 1
	TS="$(date +%s)000"
	SIGN=$(printf '%s%s%s%s_expressVpn' "$MAC" "$DDNS" "$TS" "$SN2" \
		| openssl dgst -sha256 -hmac "$SN" -hex 2>/dev/null | awk '{print $2}')
	[ -n "$SIGN" ] || return 1
	return 0
}

gl_activation_base_url() {
	_base=$(uci -q get expressvpn.global.gl_activation_base)
	_base=$(echo "$_base" | sed 's|^https\?://||;s|/*$||')
	[ -n "$_base" ] || return 1
	printf 'https://%s' "$_base"
}

signed_json_body() {
	_order_id="$1"
	_purchase_source="$2"
	_order_email="$3"
	if ! make_sign_fields; then
		return 1
	fi
	if [ -n "$_order_id" ]; then
		printf '{"mac":"%s","timestamp":%s,"sign":"%s","orderId":"%s"' \
			"$MAC" "$TS" "$SIGN" "$(json_escape "$_order_id")"
		if [ -n "$_purchase_source" ]; then
			_order_source=$(gl_order_source "$_purchase_source") || return 1
			printf ',"orderSource":"%s"' "$_order_source"
		fi
		if [ -n "$_order_email" ]; then
			printf ',"email":"%s"' "$(json_escape "$_order_email")"
		fi
		printf '}'
	else
		printf '{"mac":"%s","timestamp":%s,"sign":"%s"}' "$MAC" "$TS" "$SIGN"
	fi
}

resolve_order_id() {
	_oid="$1"
	if [ -z "$_oid" ]; then
		_oid=$(uci -q get expressvpn.global.order_id)
	fi
	if [ -z "$_oid" ]; then
		emit_error "orderId required: pass as argv or set expressvpn.global.order_id"
		return 1
	fi
	printf '%s' "$_oid"
}

cmd_payload() {
	_body=$(signed_json_body) || {
		emit_error "device identity or sign failed"
		exit 1
	}
	printf '%s\n' "$_body"
}

cmd_eligibility() {
	_base=$(gl_activation_base_url) || {
		emit_error "gl_activation_base not configured"
		uci -q set expressvpn.global.eligibility='unknown' && uci -q commit expressvpn || true
		exit 1
	}
	_body=$(signed_json_body) || {
		emit_error "device identity or sign failed"
		exit 1
	}
	_url="${_base}${GL_PATH_ELIGIBILITY}"

	HTTP_OK=1
	curl -sf --max-time 8 -X POST "$_url" \
		-H 'Content-Type: application/json' \
		-d "$_body" \
		-o /tmp/expressvpn/eligible_raw.json 2>/dev/null || HTTP_OK=0

	if [ "$HTTP_OK" = "0" ]; then
		ELIGIBILITY="probe_failed"
	else
		CODE=$(json_get_first /tmp/expressvpn/eligible_raw.json '@.code')
		INFO=$(json_get_first /tmp/expressvpn/eligible_raw.json '@.info')
		ELIGIBLE=$(json_get_first /tmp/expressvpn/eligible_raw.json '@.eligible')
		ACTIVATION_STATUS=$(json_get_first /tmp/expressvpn/eligible_raw.json '@.activationStatus')
		ORDER_ID=$(json_get_first /tmp/expressvpn/eligible_raw.json '@.orderId')
		ORDER_EMAIL=$(json_get_first /tmp/expressvpn/eligible_raw.json '@.email')
		ORDER_SOURCE=$(json_get_first /tmp/expressvpn/eligible_raw.json '@.orderSource')
		if [ "$CODE" = "0" ]; then
			INFO_ELIGIBLE=$(json_get_first /tmp/expressvpn/eligible_raw.json '@.info.eligible')
			[ -n "$INFO_ELIGIBLE" ] && ELIGIBLE="$INFO_ELIGIBLE"
			[ -z "$ACTIVATION_STATUS" ] && ACTIVATION_STATUS=$(json_get_first /tmp/expressvpn/eligible_raw.json '@.info.activationStatus')
			[ -z "$ORDER_ID" ] && ORDER_ID=$(json_get_first /tmp/expressvpn/eligible_raw.json '@.info.orderId')
			[ -z "$ORDER_EMAIL" ] && ORDER_EMAIL=$(json_get_first /tmp/expressvpn/eligible_raw.json '@.info.email')
			[ -z "$ORDER_SOURCE" ] && ORDER_SOURCE=$(json_get_first /tmp/expressvpn/eligible_raw.json '@.info.orderSource')
			case "${ELIGIBLE:-$INFO}" in
			true) ELIGIBILITY="eligible" ;;
			false) ELIGIBILITY="ineligible" ;;
			*) ELIGIBILITY="probe_failed" ;;
			esac
		elif [ -z "$CODE" ]; then
			case "$ELIGIBLE" in
			true) ELIGIBILITY="eligible" ;;
			false) ELIGIBILITY="ineligible" ;;
			*) ELIGIBILITY="probe_failed" ;;
			esac
		else
			ELIGIBILITY="probe_failed"
		fi
	fi

	printf '{"eligibility":"%s","source":"cloud"' "$ELIGIBILITY"
	[ -n "$ACTIVATION_STATUS" ] && printf ',"activation_status":"%s"' "$(json_escape "$ACTIVATION_STATUS")"
	[ -n "$ORDER_ID" ] && printf ',"order_id":"%s"' "$(json_escape "$ORDER_ID")"
	[ -n "$ORDER_SOURCE" ] && printf ',"order_source":"%s"' "$(json_escape "$ORDER_SOURCE")"
	[ -n "$ORDER_EMAIL" ] && printf ',"order_email":"%s"' "$(json_escape "$ORDER_EMAIL")"
	printf '}\n'
	uci -q set expressvpn.global.eligibility="$ELIGIBILITY"
	uci -q commit expressvpn || true
}

cmd_apply() {
	_oid=$(resolve_order_id "$1") || exit 1
	_src="amazon"
	_email="$3"
	if [ -n "$2" ]; then
		_src=$(normalize_purchase_source "$2") || {
			emit_error "purchase_source is invalid"
			exit 1
		}
	fi
	if [ "$_src" = "glinet_store" ] && [ -z "$_email" ]; then
		emit_error "order_email is required for glinet_store"
		exit 1
	fi
	_base=$(gl_activation_base_url) || {
		emit_error "gl_activation_base not configured"
		exit 1
	}
	_body=$(signed_json_body "$_oid" "$_src" "$_email") || {
		emit_error "device identity or sign failed"
		exit 1
	}
	_url="${_base}${GL_PATH_APPLY}"
	_out="/tmp/expressvpn/apply_raw.json"
	if ! curl -sf --max-time 20 -X POST "$_url" \
		-H 'Content-Type: application/json' \
		-d "$_body" \
		-o "$_out"; then
		emit_error "HTTP request failed (orderId: ${_oid})"
		exit 1
	fi
	cat "$_out"
	printf '\n'
}

cmd_order_status() {
	_oid=$(resolve_order_id "$1") || exit 1
	_stored_oid=$(uci -q get expressvpn.global.order_id)
	if [ -n "$2" ]; then
		_src=$(normalize_purchase_source "$2") || {
			emit_error "purchase_source is invalid"
			exit 1
		}
	elif [ "$_oid" = "$_stored_oid" ]; then
		_src=$(normalize_purchase_source "$(uci -q get expressvpn.global.purchase_source)") || _src="amazon"
	else
		_src="amazon"
	fi
	if [ -n "$3" ]; then
		_email="$3"
	elif [ "$_oid" = "$_stored_oid" ]; then
		_email=$(uci -q get expressvpn.global.order_email)
	else
		_email=""
	fi
	_base=$(gl_activation_base_url) || {
		emit_error "gl_activation_base not configured"
		exit 1
	}
	_body=$(signed_json_body "$_oid" "$_src" "$_email") || {
		emit_error "device identity or sign failed"
		exit 1
	}
	_url="${_base}${GL_PATH_ORDER_STATUS}"
	_out="/tmp/expressvpn/order_status_raw.json"
	if ! curl -sf --max-time 12 -X POST "$_url" \
		-H 'Content-Type: application/json' \
		-d "$_body" \
		-o "$_out"; then
		emit_error "HTTP request failed (orderId: ${_oid})"
		exit 1
	fi
	cat "$_out"
	printf '\n'
}

usage() {
	emit_error "usage: expressvpn_activate.sh payload|eligibility|apply|order_status [orderId] [purchase_source] [order_email]"
	exit 127
}

case "$1" in
payload) cmd_payload ;;
eligibility) cmd_eligibility ;;
apply) cmd_apply "$2" "$3" "$4" ;;
order-status|order_status|status) cmd_order_status "$2" "$3" "$4" ;;
*) usage ;;
esac
