#!/bin/sh
# ExpressVPN OIDC Device Code (RFC 8628) + token refresh + SRT fetch
# Usage: expressvpn_login.sh start        — initiate device code flow
#        expressvpn_login.sh poll         — poll token endpoint
#        expressvpn_login.sh cancel       — abort device code flow
#        expressvpn_login.sh refresh_oidc — use refresh_token to renew OIDC only
#        expressvpn_login.sh refresh      — use refresh_token to renew OIDC + SRT
#        expressvpn_login.sh fetch_srt    — exchange current access_token for SRT via CP
#
# Output contract:
#   error path: { "status": "error", "err_msg": "<string>" }
#   poll pending: { "status": "pending", "error": "authorization_pending" | "slow_down" }

XPV_DIR="/etc/expressvpn"
STATE_DIR="/tmp/expressvpn"
CRED="${XPV_DIR}/profile_data"
DC_FILE="${STATE_DIR}/device_code.bin"
CVE_FILE="${STATE_DIR}/code_verifier.bin"
TE_FILE="${STATE_DIR}/token_endpoint.txt"

mkdir -p "$STATE_DIR" "$XPV_DIR"

read_kv() {
	_k="$1"
	_d="$2"
	_v=$(grep -s "^${_k}=" "$CRED" 2>/dev/null | head -1 | cut -d= -f2-)
	[ -n "$_v" ] && echo "$_v" && return
	echo "$_d"
}

decode_b64() {
	_v="$1"
	[ -n "$_v" ] || return 1
	if command -v openssl >/dev/null 2>&1; then
		printf '%s' "$_v" | openssl enc -base64 -d -A 2>/dev/null && return 0
	fi
	printf '%s' "$_v" | base64 -d 2>/dev/null
}

OIDC_REALM=$(uci -q get expressvpn.global.oidc_realm)
[ -z "$OIDC_REALM" ] && OIDC_REALM="$(read_kv OIDC_REALM 'https://auth.expressvpn.com/realms/xvpn')"
OIDC_CLIENT_ID=$(uci -q get expressvpn.global.oidc_client_id)
[ -z "$OIDC_CLIENT_ID" ] && OIDC_CLIENT_ID="$(read_kv OIDC_CLIENT_ID 'xv_partner_gli_router')"
OIDC_CLIENT_DATA="$(read_kv data '')"
if [ -z "$OIDC_CLIENT_DATA" ]; then
	OIDC_CLIENT_DATA="$(read_kv data_1 '')$(read_kv data_2 '')"
fi
OIDC_CLIENT_SECRET="$(decode_b64 "$OIDC_CLIENT_DATA")"
OIDC_SCOPES=$(uci -q get expressvpn.global.oidc_scopes)
[ -z "$OIDC_SCOPES" ] && OIDC_SCOPES="$(read_kv OIDC_SCOPES 'openid')"

CP_BASE=$(uci -q get expressvpn.global.cp_base || true)
[ -z "$CP_BASE" ] && CP_BASE="https://cp.expressapisv2.net"
CP_BASE=$(echo "$CP_BASE" | sed 's|/$||')

if [ -z "$OIDC_CLIENT_SECRET" ]; then
	echo '{"status":"error","err_msg":"OIDC client secret not configured"}'
	exit 1
fi

cfg_fetch() {
	_out="$STATE_DIR/oidc_wellknown.json"
	curl -sf --max-time 8 "$OIDC_REALM/.well-known/openid-configuration" -o "$_out" || return 1
	jsonfilter -i "$_out" -e '@.token_endpoint' | head -1 >"$TE_FILE"
	jsonfilter -i "$_out" -e '@.device_authorization_endpoint' | head -1 >"${STATE_DIR}/device_auth_ep.txt"
	[ -s "$TE_FILE" ] && [ -s "${STATE_DIR}/device_auth_ep.txt" ]
}

# ─── JWT helpers (for SRT selection) ───

jwt_payload_json() {
	_jwt="$1"
	_mid=$(printf '%s' "$_jwt" | cut -d. -f2)
	[ "${#_mid}" -ge 8 ] || return 1
	_b64=$(printf '%s' "$_mid" | tr '_-' '+/')
	_pad=$(( (4 - (${#_b64} % 4)) % 4 ))
	_i=0
	while [ "$_i" -lt "$_pad" ]; do
		_b64="${_b64}="
		_i=$((_i + 1))
	done
	if command -v openssl >/dev/null 2>&1; then
		if _out=$(printf '%s' "$_b64" | openssl enc -base64 -d -A 2>/dev/null) && [ "${#_out}" -ge 2 ]; then
			printf '%s' "$_out"
			return 0
		fi
	fi
	printf '%s' "$_b64" | base64 -d 2>/dev/null
}

has_xv_vpn_entitlement() {
	_pl=$(jwt_payload_json "$1") || return 1
	printf '%s' "$_pl" | grep -Fq '"xv.vpn"' || return 1
	printf '%s' "$_pl" | grep -Fq '"entitlements"' || return 1
	return 0
}

# ─── SRT fetch via CP subscription_receipts ───

subs_receipt_post() {
	local bearer="$1"
	local out="$STATE_DIR/srt_new.json"
	local err="$STATE_DIR/srt_new.err"
	local http_code curl_rc

	rm -f "$out" "$err"
	http_code=$(curl -sS --max-time 20 -w '%{http_code}' -o "$out" -X POST "${CP_BASE}/srs2/subscription_receipts" \
		-H "Authorization: Bearer ${bearer}" \
		-H "Content-Type: application/json" \
		-d '{}' 2>"$err")
	curl_rc=$?
	[ "$curl_rc" = "0" ] || return 1
	case "$http_code" in
		2??) ;;
		401|403) return 3 ;;
		*) return 1 ;;
	esac

	local srt tok i
	srt=""
	if tok=$(jsonfilter -i "$out" -e '@.srts[0].srt' 2>/dev/null) && [ -n "$tok" ]; then
		i=0
		while [ "$i" -lt 64 ]; do
			tok=$(jsonfilter -i "$out" -e "@.srts[$i].srt" 2>/dev/null)
			[ -z "$tok" ] && break
			if has_xv_vpn_entitlement "$tok"; then
				srt="$tok"
				break
			fi
			i=$((i + 1))
		done
	fi
	if [ -z "$srt" ]; then
		tok=$(jsonfilter -i "$out" -e '@.srt' 2>/dev/null | head -1)
		if [ -n "$tok" ] && has_xv_vpn_entitlement "$tok"; then
			srt="$tok"
		fi
	fi
	[ -n "$srt" ] || return 2
	echo "$srt" >"${XPV_DIR}/srt"
	chmod 600 "${XPV_DIR}/srt"
}

# ─── Token refresh ───

refresh_tokens() {
	[ -f "${XPV_DIR}/oidc_token.json" ] || return 1
	RT=$(jsonfilter -i "${XPV_DIR}/oidc_token.json" -e '@.refresh_token' | head -1)
	[ -n "$RT" ] || return 1

	curl -sf --max-time 8 "${OIDC_REALM}/.well-known/openid-configuration" -o "${STATE_DIR}/oidc_wellknown.json" || return 1
	TE=$(jsonfilter -i "${STATE_DIR}/oidc_wellknown.json" -e '@.token_endpoint' | head -1)

	out="${STATE_DIR}/oidc_refresh.json"
	curl -s --max-time 15 -X POST "$TE" \
		-H "Content-Type: application/x-www-form-urlencoded" \
		--data-urlencode "grant_type=refresh_token" \
		--data-urlencode "refresh_token=${RT}" \
		--data-urlencode "client_id=${OIDC_CLIENT_ID}" \
		--data-urlencode "client_secret=${OIDC_CLIENT_SECRET}" \
		-o "$out" || return 1
	if ! grep -q '"access_token"' "$out"; then
		ERR=$(jsonfilter -i "$out" -e '@.error' 2>/dev/null)
		[ "$ERR" = "invalid_grant" ] && return 2
		return 1
	fi
	cp "$out" "${XPV_DIR}/oidc_token.json"
	chmod 600 "${XPV_DIR}/oidc_token.json"
}

# ─── Subcommands ───

cmd_start() {
	rm -f "$DC_FILE" "$CVE_FILE" "$TE_FILE" "${STATE_DIR}/device_auth_ep.txt"
	cfg_fetch || {
		echo '{"status":"error","err_msg":"OIDC configuration fetch failed"}'
		exit 1
	}

	CODE_VERIFIER=$(openssl rand -hex 32)
	CODE_CHALLENGE=$(printf '%s' "$CODE_VERIFIER" | openssl dgst -sha256 -binary | openssl base64 -A | tr '+/' '-_' | tr -d '=')
	printf '%s' "$CODE_VERIFIER" >"$CVE_FILE"

	DEVICE_AUTH_ENDPOINT=$(cat "${STATE_DIR}/device_auth_ep.txt")
	tmp="$STATE_DIR/device_code_raw.json"
	curl -s --max-time 10 -X POST "$DEVICE_AUTH_ENDPOINT" \
		-H "Content-Type: application/x-www-form-urlencoded" \
		--data-urlencode "client_id=$OIDC_CLIENT_ID" \
		--data-urlencode "client_secret=$OIDC_CLIENT_SECRET" \
		--data-urlencode "scope=$OIDC_SCOPES" \
		--data-urlencode "code_challenge=$CODE_CHALLENGE" \
		--data-urlencode "code_challenge_method=S256" \
		-o "$tmp" || {
		echo '{"status":"error","err_msg":"device code authorization request failed"}'
		exit 1
	}

	if grep -q '"error"' "$tmp" 2>/dev/null; then
		ERR=$(jsonfilter -i "$tmp" -e '@.error' 2>/dev/null)
		[ -n "$ERR" ] || ERR=$(jsonfilter -i "$tmp" -e '@.error_description' 2>/dev/null)
		[ -n "$ERR" ] || ERR="device code authorization request failed"
		printf '{"status":"error","err_msg":"%s"}\n' "$ERR"
		exit 1
	fi

	jsonfilter -i "$tmp" -e '@.device_code' | head -1 | tr -d '\n' >"$DC_FILE"
	USER_CODE=$(jsonfilter -i "$tmp" -e '@.user_code')
	VERIFICATION_URI=$(jsonfilter -i "$tmp" -e '@.verification_uri')
	VERIFICATION_URI_COMPLETE=$(jsonfilter -i "$tmp" -e '@.verification_uri_complete')
	EXPIRES_IN=$(jsonfilter -i "$tmp" -e '@.expires_in')
	INTERVAL=$(jsonfilter -i "$tmp" -e '@.interval')
	[ -z "$INTERVAL" ] && INTERVAL=5
	if [ ! -s "$DC_FILE" ] || [ -z "$USER_CODE" ] || [ -z "$VERIFICATION_URI_COMPLETE" ]; then
		rm -f "$DC_FILE" "$CVE_FILE" "$TE_FILE"
		echo '{"status":"error","err_msg":"device code authorization request failed"}'
		exit 1
	fi

	printf '{"status":"started","user_code":"%s","verification_uri":"%s","verification_uri_complete":"%s","expires_in":%s,"interval":%s}\n' \
		"${USER_CODE:-}" "${VERIFICATION_URI:-}" "${VERIFICATION_URI_COMPLETE:-}" "${EXPIRES_IN:-900}" "${INTERVAL}"
}

cmd_poll() {
	[ -f "$DC_FILE" ] && [ -f "$CVE_FILE" ] && [ -f "$TE_FILE" ] || {
		echo '{"status":"error","err_msg":"no active login session"}'
		exit 1
	}
	DEVICE_CODE=$(cat "$DC_FILE")
	CODE_VERIFIER=$(cat "$CVE_FILE")
	TOKEN_ENDPOINT=$(cat "$TE_FILE")

	tmp="$STATE_DIR/token_poll.json"
	curl -s --max-time 12 -X POST "$TOKEN_ENDPOINT" \
		-H "Content-Type: application/x-www-form-urlencoded" \
		--data-urlencode "grant_type=urn:ietf:params:oauth:grant-type:device_code" \
		--data-urlencode "device_code=$DEVICE_CODE" \
		--data-urlencode "client_id=$OIDC_CLIENT_ID" \
		--data-urlencode "client_secret=$OIDC_CLIENT_SECRET" \
		--data-urlencode "code_verifier=$CODE_VERIFIER" \
		-o "$tmp"
	CURL_RC=$?
	# curl exit 0 = got HTTP response (any status code); non-zero = network/timeout failure
	if [ "$CURL_RC" -ne 0 ] || [ ! -s "$tmp" ]; then
		echo '{"status":"error","err_msg":"token poll HTTP request failed"}'
		exit 1
	fi

	if grep -q '"access_token"' "$tmp" 2>/dev/null; then
		cp "$tmp" "${XPV_DIR}/oidc_token.json"
		chmod 600 "${XPV_DIR}/oidc_token.json"
		rm -f "$DC_FILE" "$CVE_FILE"
		echo '{"status":"success"}'
		exit 0
	fi

	ERR=$(jsonfilter -i "$tmp" -e '@.error' 2>/dev/null || echo "")
	case "$ERR" in
	authorization_pending|slow_down)
		printf '{"status":"pending","error":"%s"}\n' "$ERR"
		;;
	expired_token)
		echo '{"status":"error","err_msg":"device code has expired"}'
		rm -f "$DC_FILE" "$CVE_FILE"
		;;
	access_denied)
		echo '{"status":"error","err_msg":"user denied authorization"}'
		rm -f "$DC_FILE" "$CVE_FILE"
		;;
	*)
		echo '{"status":"error","err_msg":"token endpoint returned unknown error"}'
		;;
	esac
}

cmd_cancel() {
	rm -f "$DC_FILE" "$CVE_FILE" "$TE_FILE" \
		"${STATE_DIR}/device_auth_ep.txt" \
		"${STATE_DIR}/device_code_raw.json" \
		"${STATE_DIR}/token_poll.json" \
		"${STATE_DIR}/oidc_wellknown.json" \
		"${STATE_DIR}/oidc_refresh.json" \
		"${STATE_DIR}/srt_new.json"
	echo '{"status":"cancelled"}'
}

cmd_refresh() {
	refresh_tokens
	REFRESH_RC=$?
	if [ "$REFRESH_RC" -ne 0 ]; then
		if [ "$REFRESH_RC" -eq 2 ]; then
			echo '{"status":"error","err_msg":"refresh token invalid"}'
		else
			echo '{"status":"error","err_msg":"token refresh failed"}'
		fi
		exit 1
	fi
	AT=$(jsonfilter -i "${XPV_DIR}/oidc_token.json" -e '@.access_token' | head -1)
	subs_receipt_post "$AT"
	SRT_RC=$?
	if [ "$SRT_RC" -ne 0 ]; then
		if [ "$SRT_RC" -eq 2 ]; then
			echo '{"status":"error","err_msg":"no usable ExpressVPN subscription"}'
		elif [ "$SRT_RC" -eq 3 ]; then
			echo '{"status":"error","err_msg":"access token rejected by control plane"}'
		else
			echo '{"status":"error","err_msg":"SRT fetch from control plane failed"}'
		fi
		exit 1
	fi
	echo '{"status":"refreshed"}'
}

cmd_refresh_oidc() {
	refresh_tokens
	REFRESH_RC=$?
	if [ "$REFRESH_RC" -ne 0 ]; then
		if [ "$REFRESH_RC" -eq 2 ]; then
			echo '{"status":"error","err_msg":"refresh token invalid"}'
		else
			echo '{"status":"error","err_msg":"token refresh failed"}'
		fi
		exit 1
	fi
	echo '{"status":"oidc_refreshed"}'
}

cmd_fetch_srt() {
	[ -f "${XPV_DIR}/oidc_token.json" ] || {
		echo '{"status":"error","err_msg":"no OIDC tokens available"}'
		exit 1
	}
	AT=$(jsonfilter -i "${XPV_DIR}/oidc_token.json" -e '@.access_token' | head -1)
	[ -n "$AT" ] || {
		echo '{"status":"error","err_msg":"no valid access token"}'
		exit 1
	}
	subs_receipt_post "$AT"
	SRT_RC=$?
	if [ "$SRT_RC" -ne 0 ]; then
		if [ "$SRT_RC" -eq 2 ]; then
			echo '{"status":"error","err_msg":"no usable ExpressVPN subscription"}'
			exit 1
		fi
		if [ "$SRT_RC" -ne 3 ]; then
			echo '{"status":"error","err_msg":"SRT fetch from control plane failed"}'
			exit 1
		fi
		logger -t expressvpn "SRT fetch returned auth error; refreshing OIDC token and retrying once"
		refresh_tokens
		REFRESH_RC=$?
		if [ "$REFRESH_RC" -ne 0 ]; then
			if [ "$REFRESH_RC" -eq 2 ]; then
				echo '{"status":"error","err_msg":"refresh token invalid"}'
			else
				echo '{"status":"error","err_msg":"token refresh failed"}'
			fi
			exit 1
		fi
		AT=$(jsonfilter -i "${XPV_DIR}/oidc_token.json" -e '@.access_token' | head -1)
		[ -n "$AT" ] || {
			echo '{"status":"error","err_msg":"no valid access token after refresh"}'
			exit 1
		}
		subs_receipt_post "$AT"
		SRT_RC=$?
		if [ "$SRT_RC" -ne 0 ]; then
			if [ "$SRT_RC" -eq 2 ]; then
				echo '{"status":"error","err_msg":"no usable ExpressVPN subscription"}'
			elif [ "$SRT_RC" -eq 3 ]; then
				echo '{"status":"error","err_msg":"access token rejected by control plane"}'
			else
				echo '{"status":"error","err_msg":"SRT fetch from control plane failed"}'
			fi
			exit 1
		fi
	fi
	if [ ! -s "${XPV_DIR}/srt" ]; then
		echo '{"status":"error","err_msg":"SRT fetch from control plane failed"}'
		exit 1
	fi
	echo '{"status":"success","path":"fetch_srt"}'
}

# ─── Main dispatch ───

case "$1" in
start)      cmd_start ;;
poll)       cmd_poll ;;
cancel)     cmd_cancel ;;
refresh_oidc) cmd_refresh_oidc ;;
refresh)    cmd_refresh ;;
fetch_srt)  cmd_fetch_srt ;;
*)
	echo '{"status":"error","err_msg":"usage: expressvpn_login.sh start|poll|cancel|refresh_oidc|refresh|fetch_srt"}'
	exit 127
	;;
esac
