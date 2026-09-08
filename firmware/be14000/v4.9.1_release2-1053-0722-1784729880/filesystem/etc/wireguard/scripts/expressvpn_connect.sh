#!/bin/sh
# pre_setup_script for proto wgclient: invoked as: <script> <peer_section>
PEER="$1"
[ -n "$PEER" ] || exit 1

LOCATION_ID=$(uci -q get "wireguard.${PEER}.expressvpn_location_id")
[ -n "$LOCATION_ID" ] || exit 1

mkdir -p /tmp/expressvpn

CP_BASE=$(uci -q get expressvpn.global.cp_base)
[ -n "$CP_BASE" ] || CP_BASE="https://cp.expressapisv2.net"
CP_BASE=$(echo "$CP_BASE" | sed 's|/$||')

SRT=$(cat /etc/expressvpn/srt 2>/dev/null)
[ -n "$SRT" ] || exit 1

ENDPOINT_MODE=$(uci -q get expressvpn.global.endpoint_mode)
[ "$ENDPOINT_MODE" = "obfuscated" ] || ENDPOINT_MODE="auto"
CAT_REFRESHED=0
INSTANCES_REFRESHED=0
ENDPOINT_STATE="/tmp/expressvpn/endpoint_state_${PEER}"
SRT_REFRESH_WINDOW=3600

is_success_http_status() {
	case "$1" in
		2??) return 0 ;;
	esac
	return 1
}

is_auth_http_status() {
	[ "$1" = "401" ] || [ "$1" = "403" ]
}

system_time_is_sane() {
	local now

	now=$(date +%s 2>/dev/null)
	echo "$now" | grep -Eq '^[0-9]+$' || return 1
	[ "$now" -ge 1735689600 ]
}

jwt_payload_json() {
	local jwt mid b64 pad i out

	jwt="$1"
	mid=$(printf '%s' "$jwt" | cut -d. -f2)
	[ "${#mid}" -ge 8 ] || return 1
	b64=$(printf '%s' "$mid" | tr '_-' '+/')
	pad=$(( (4 - (${#b64} % 4)) % 4 ))
	i=0
	while [ "$i" -lt "$pad" ]; do
		b64="${b64}="
		i=$((i + 1))
	done
	if command -v openssl >/dev/null 2>&1; then
		if out=$(printf '%s' "$b64" | openssl enc -base64 -d -A 2>/dev/null) && [ "${#out}" -ge 2 ]; then
			printf '%s' "$out"
			return 0
		fi
	fi
	printf '%s' "$b64" | base64 -d 2>/dev/null
}

srt_should_refresh() {
	local now payload exp

	if ! system_time_is_sane; then
		return 0
	fi
	now=$(date +%s 2>/dev/null)
	payload=$(jwt_payload_json "$SRT") || return 0
	exp=$(printf '%s' "$payload" | jsonfilter -e '@.exp' 2>/dev/null | head -n1)
	echo "$exp" | grep -Eq '^[0-9]+$' || return 0
	[ "$exp" -le $((now + SRT_REFRESH_WINDOW)) ]
}

refresh_srt_once() {
	/etc/wireguard/scripts/expressvpn_login.sh refresh >/dev/null 2>&1 || return 1
	SRT=$(cat /etc/expressvpn/srt 2>/dev/null)
	[ -n "$SRT" ]
}

req_cat_once() {
	local out err

	out="/tmp/expressvpn/cat_${PEER}.json"
	err="/tmp/expressvpn/cat_${PEER}.err"
	rm -f "$out" "$err"
	CAT_HTTP_CODE=$(curl -sS --max-time 3 -w '%{http_code}' -o "$out" \
		-H "Authorization: Bearer ${SRT}" \
		"${CP_BASE}/srs2/connection_token" 2>"$err")
	CAT_CURL_RC=$?
	CAT=""
	if [ "$CAT_CURL_RC" = "0" ] && is_success_http_status "$CAT_HTTP_CODE"; then
		CAT=$(jsonfilter -i "$out" -e '@.cat' 2>/dev/null)
	fi
}

get_cat() {
	CAT=""
	req_cat_once

	if [ -n "$CAT" ]; then
		return 0
	fi

	if is_auth_http_status "$CAT_HTTP_CODE" && [ "$CAT_REFRESHED" != "1" ]; then
		CAT_REFRESHED=1
		if srt_should_refresh; then
			logger -t expressvpn "SRS2 CAT fetch returned HTTP ${CAT_HTTP_CODE}; refreshing SRT and retrying once"
			refresh_srt_once || return 1
		else
			logger -t expressvpn "SRS2 CAT fetch returned HTTP ${CAT_HTTP_CODE}; SRT not near expiry, retrying once without SRT refresh"
		fi
		req_cat_once
	elif [ "$CAT_REFRESHED" != "1" ]; then
		logger -t expressvpn "SRS2 CAT fetch failed http=${CAT_HTTP_CODE:-000} rc=${CAT_CURL_RC}; retrying once without SRT refresh"
		CAT_REFRESHED=1
		req_cat_once
	fi

	[ -n "$CAT" ]
}

INSTANCES_JSON="/tmp/expressvpn/instances_${LOCATION_ID}.json"

req_instances_once() {
	local err

	err="/tmp/expressvpn/instances_${LOCATION_ID}.err"
	rm -f "$INSTANCES_JSON" "$err"
	INSTANCES_HTTP_CODE=$(curl -sS --max-time 3 -w '%{http_code}' -o "$INSTANCES_JSON" -X POST \
		"${CP_BASE}/ids2/locations/${LOCATION_ID}/instances?protocols=wireguard" \
		-H "Authorization: Bearer ${SRT}" \
		-H "Content-Type: application/json" \
		-d '{"os":"linux","location":{"latitude":0,"longitude":0}}' 2>"$err")
	INSTANCES_CURL_RC=$?
	[ "$INSTANCES_CURL_RC" = "0" ] && is_success_http_status "$INSTANCES_HTTP_CODE"
}

get_instances() {
	req_instances_once && return 0

	if is_auth_http_status "$INSTANCES_HTTP_CODE" && [ "$INSTANCES_REFRESHED" != "1" ]; then
		INSTANCES_REFRESHED=1
		if srt_should_refresh; then
			logger -t expressvpn "IDS2 instances fetch returned HTTP ${INSTANCES_HTTP_CODE} for location ${LOCATION_ID}; refreshing SRT and retrying once"
			refresh_srt_once || return 1
		else
			logger -t expressvpn "IDS2 instances fetch returned HTTP ${INSTANCES_HTTP_CODE} for location ${LOCATION_ID}; SRT not near expiry, retrying once without SRT refresh"
		fi
		req_instances_once && return 0
	elif [ "$INSTANCES_REFRESHED" != "1" ]; then
		logger -t expressvpn "IDS2 instances fetch failed for location ${LOCATION_ID} http=${INSTANCES_HTTP_CODE:-000} rc=${INSTANCES_CURL_RC}; retrying once without SRT refresh"
		INSTANCES_REFRESHED=1
		req_instances_once && return 0
	fi

	return 1
}

get_instances || exit 1

# ─── WAS TLS trust bundle ───
WAS_CA="/tmp/expressvpn/was_ca.pem"
cat > "$WAS_CA" << 'CERTEOF'
-----BEGIN CERTIFICATE-----
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
-----END CERTIFICATE-----
-----BEGIN CERTIFICATE-----
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
-----END CERTIFICATE-----
-----BEGIN CERTIFICATE-----
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
-----END CERTIFICATE-----
CERTEOF

endpoint_ip_field() {
	local idx="$1"
	local field="$2"
	local val
	val=$(jsonfilter -i "$INSTANCES_JSON" -e "@.endpoints[${idx}].${field}.v4" 2>/dev/null)
	[ -z "$val" ] && val=$(jsonfilter -i "$INSTANCES_JSON" -e "@.endpoints[${idx}].${field}.ipv4" 2>/dev/null)
	[ -z "$val" ] && val=$(jsonfilter -i "$INSTANCES_JSON" -e "@.endpoints[${idx}].${field}" 2>/dev/null)
	printf '%s' "$val"
}

endpoint_exists() {
	local idx="$1"
	local ep_type ep_ip
	ep_type=$(jsonfilter -i "$INSTANCES_JSON" -e "@.endpoints[${idx}].type" 2>/dev/null)
	ep_ip=$(endpoint_ip_field "$idx" "ip")
	[ -n "$ep_type" ] || [ -n "$ep_ip" ]
}

count_endpoints() {
	local i=0

	while [ "$i" -lt 24 ]; do
		endpoint_exists "$i" || break
		i=$((i + 1))
	done

	echo "$i"
}

read_auto_endpoint_offset() {
	local state_location state_offset

	[ "$ENDPOINT_MODE" = "auto" ] || {
		echo 0
		return
	}
	[ -r "$ENDPOINT_STATE" ] || {
		echo 0
		return
	}

	state_location=$(sed -n 's/^location_id=//p' "$ENDPOINT_STATE" | head -n1)
	state_offset=$(sed -n 's/^offset=//p' "$ENDPOINT_STATE" | head -n1)
	[ "$state_location" = "$LOCATION_ID" ] || {
		echo 0
		return
	}
	echo "$state_offset" | grep -Eq '^[0-9]+$' || {
		echo 0
		return
	}

	echo "$state_offset"
}

record_selected_auto_endpoint() {
	[ "$ENDPOINT_MODE" = "auto" ] || return 0

	{
		echo "location_id=${LOCATION_ID}"
		echo "selected_index=${EP_IDX}"
		echo "selected_endpoint=${WG_SERVER_IP}:${WG_SERVER_PORT}"
		echo "attempt_id=${PEER}-$$-${EP_IDX}"
	} > "$ENDPOINT_STATE"
}

write_awg_profile() {
	local group_id profile_dir profile
	group_id=$(uci -q get "wireguard.${PEER}.group_id")
	[ -n "$group_id" ] || return 1
	profile_dir="/etc/wireguard/profile/${group_id}"
	profile="${profile_dir}/${PEER}"
	mkdir -p "$profile_dir"
	{
		echo "Jc = ${OBF_JC}"
		echo "Jmin = ${OBF_JMIN}"
		echo "Jmax = ${OBF_JMAX}"
		echo "S1 = ${OBF_S1}"
		echo "S2 = ${OBF_S2}"
		[ -n "$OBF_S3" ] && echo "S3 = ${OBF_S3}"
		[ -n "$OBF_S4" ] && echo "S4 = ${OBF_S4}"
		echo "H1 = ${OBF_H1}"
		echo "H2 = ${OBF_H2}"
		echo "H3 = ${OBF_H3}"
		echo "H4 = ${OBF_H4}"
	} > "$profile"
}

clear_awg_profile() {
	local group_id
	group_id=$(uci -q get "wireguard.${PEER}.group_id")
	[ -n "$group_id" ] && rm -f "/etc/wireguard/profile/${group_id}/${PEER}"
}

was_auth_request() {
	local body body_len raw_out err_out

	body="{\"client_public_key\":\"${WG_PUBLIC_KEY}\",\"psk\":\"${WG_PSK}\"}"
	body_len=${#body}
	raw_out="/tmp/expressvpn/was_auth_${PEER}_${EP_IDX}.raw"
	err_out="/tmp/expressvpn/was_auth_${PEER}_${EP_IDX}.err"

	{
		printf 'POST /was/auth HTTP/1.1\r\n'
		printf 'Host: %s:%s\r\n' "$AUTH_IP" "$AUTH_PORT"
		printf 'Authorization: Bearer %s\r\n' "$CAT"
		printf 'Content-Type: application/json\r\n'
		printf 'Content-Length: %s\r\n' "$body_len"
		printf 'Connection: close\r\n'
		printf '\r\n'
		printf '%s' "$body"
	} | timeout 8 openssl s_client -quiet -noservername \
		-connect "${AUTH_IP}:${AUTH_PORT}" \
		-CAfile "$WAS_CA" \
		-verify_return_error \
		-verify_hostname "$CERT_DN" \
		>"$raw_out" 2>"$err_out" || {
		logger -t expressvpn "WAS auth TLS request failed for endpoint ${EP_IDX} ${CERT_DN}@${AUTH_IP}:${AUTH_PORT}"
		return 1
	}

	awk 'body{print; next} {p=index($0, "{"); if (p) {print substr($0, p); body=1}}' \
		"$raw_out" > "$WG_AUTH_JSON"
	if [ ! -s "$WG_AUTH_JSON" ]; then
		logger -t expressvpn "WAS auth response missing JSON for endpoint ${EP_IDX} ${CERT_DN}@${AUTH_IP}:${AUTH_PORT}"
		return 1
	fi
}

try_endpoint() {
	EP_IDX="$1"
	OBF_TYPE=$(jsonfilter -i "$INSTANCES_JSON" -e "@.endpoints[${EP_IDX}].obfuscation.type" 2>/dev/null)

	WG_SERVER_IP=$(endpoint_ip_field "$EP_IDX" "ip")
	WG_SERVER_PORT=$(jsonfilter -i "$INSTANCES_JSON" -e "@.endpoints[${EP_IDX}].port" 2>/dev/null)
	AUTH_IP=$(endpoint_ip_field "$EP_IDX" "auth_ip")
	AUTH_PORT=$(jsonfilter -i "$INSTANCES_JSON" -e "@.endpoints[${EP_IDX}].auth_port" 2>/dev/null)
	[ -n "$AUTH_IP" ] || AUTH_IP="$WG_SERVER_IP"
	CERT_DN=$(jsonfilter -i "$INSTANCES_JSON" -e "@.endpoints[${EP_IDX}].cert_dn" 2>/dev/null)

	if [ -z "$WG_SERVER_IP" ] || [ -z "$WG_SERVER_PORT" ] || [ -z "$AUTH_PORT" ] || [ -z "$CERT_DN" ]; then
		logger -t expressvpn "Skipping incomplete IDS2 endpoint ${EP_IDX}"
		return 1
	fi

	IS_OBF=0
	if [ -n "$OBF_TYPE" ]; then
		if [ "$OBF_TYPE" != "amnezia" ]; then
			logger -t expressvpn "Skipping unsupported obfuscation '${OBF_TYPE}' on endpoint ${EP_IDX}"
			return 1
		fi
		IS_OBF=1
		OBF_JC=$(jsonfilter -i "$INSTANCES_JSON" -e "@.endpoints[${EP_IDX}].obfuscation.jc" 2>/dev/null)
		OBF_JMIN=$(jsonfilter -i "$INSTANCES_JSON" -e "@.endpoints[${EP_IDX}].obfuscation.jmin" 2>/dev/null)
		OBF_JMAX=$(jsonfilter -i "$INSTANCES_JSON" -e "@.endpoints[${EP_IDX}].obfuscation.jmax" 2>/dev/null)
		OBF_S1=$(jsonfilter -i "$INSTANCES_JSON" -e "@.endpoints[${EP_IDX}].obfuscation.s1" 2>/dev/null)
		OBF_S2=$(jsonfilter -i "$INSTANCES_JSON" -e "@.endpoints[${EP_IDX}].obfuscation.s2" 2>/dev/null)
		OBF_S3=$(jsonfilter -i "$INSTANCES_JSON" -e "@.endpoints[${EP_IDX}].obfuscation.s3" 2>/dev/null)
		OBF_S4=$(jsonfilter -i "$INSTANCES_JSON" -e "@.endpoints[${EP_IDX}].obfuscation.s4" 2>/dev/null)
		OBF_H1=$(jsonfilter -i "$INSTANCES_JSON" -e "@.endpoints[${EP_IDX}].obfuscation.h1" 2>/dev/null)
		OBF_H2=$(jsonfilter -i "$INSTANCES_JSON" -e "@.endpoints[${EP_IDX}].obfuscation.h2" 2>/dev/null)
		OBF_H3=$(jsonfilter -i "$INSTANCES_JSON" -e "@.endpoints[${EP_IDX}].obfuscation.h3" 2>/dev/null)
		OBF_H4=$(jsonfilter -i "$INSTANCES_JSON" -e "@.endpoints[${EP_IDX}].obfuscation.h4" 2>/dev/null)
		if [ -z "$OBF_JC" ] || [ -z "$OBF_JMIN" ] || [ -z "$OBF_JMAX" ] \
			|| [ -z "$OBF_S1" ] || [ -z "$OBF_S2" ] \
			|| [ -z "$OBF_H1" ] || [ -z "$OBF_H2" ] || [ -z "$OBF_H3" ] || [ -z "$OBF_H4" ]; then
			logger -t expressvpn "Skipping incomplete Amnezia endpoint ${EP_IDX}"
			return 1
		fi
	fi

	WG_PRIVATE_KEY=$(wg genkey)
	WG_PUBLIC_KEY=$(echo "$WG_PRIVATE_KEY" | wg pubkey)
	WG_PSK=$(wg genpsk)
	get_cat || {
		logger -t expressvpn "CAT fetch failed before endpoint ${EP_IDX}"
		return 1
	}

	WG_AUTH_JSON="/tmp/expressvpn/wg_auth_${PEER}_${EP_IDX}.json"
	was_auth_request || {
		logger -t expressvpn "WAS auth failed for endpoint ${EP_IDX} ${CERT_DN}@${AUTH_IP}:${AUTH_PORT}"
		return 1
	}

	WG_SERVER_PUBLIC=$(jsonfilter -i "$WG_AUTH_JSON" -e '@.Success.server_public_key' 2>/dev/null)
	WG_INTERNAL_IP=$(jsonfilter -i "$WG_AUTH_JSON" -e '@.Success.internal_ip' 2>/dev/null)

	if [ -z "$WG_SERVER_PUBLIC" ] || [ -z "$WG_INTERNAL_IP" ]; then
		logger -t expressvpn "WAS auth response incomplete for endpoint ${EP_IDX}"
		return 1
	fi

	if [ "$IS_OBF" = "1" ]; then
		write_awg_profile || {
			logger -t expressvpn "Failed to write Amnezia profile for endpoint ${EP_IDX}"
			return 1
		}
		WG_TYPE=1
	else
		clear_awg_profile
		WG_TYPE=0
	fi

	uci -q batch <<-EOF
		set wireguard.${PEER}.private_key='${WG_PRIVATE_KEY}'
		set wireguard.${PEER}.public_key='${WG_SERVER_PUBLIC}'
		set wireguard.${PEER}.preshared_key='${WG_PSK}'
		set wireguard.${PEER}.presharedkey_enable='1'
		set wireguard.${PEER}.end_point='${WG_SERVER_IP}:${WG_SERVER_PORT}'
		set wireguard.${PEER}.end_point_ip='${WG_SERVER_IP}:${WG_SERVER_PORT}'
		set wireguard.${PEER}.address_v4='${WG_INTERNAL_IP}'
		set wireguard.${PEER}.persistent_keepalive='25'
		set wireguard.${PEER}.listen_port='0'
		set wireguard.${PEER}.allowed_ips='0.0.0.0/0,::/0'
		set wireguard.${PEER}.type='${WG_TYPE}'
	EOF
	uci -q commit wireguard
	record_selected_auto_endpoint
	logger -t expressvpn "Selected endpoint ${EP_IDX} mode=${ENDPOINT_MODE} obfuscated=${IS_OBF}"
	return 0
}

try_endpoints() {
	local selector="$1"
	local start="${2:-0}"
	local count tried=0 i obf_type
	echo "$start" | grep -Eq '^[0-9]+$' || start=0
	count=$(count_endpoints)
	[ "$count" -gt 0 ] || return 1
	start=$((start % count))

	while [ "$tried" -lt "$count" ]; do
		i=$(((start + tried) % count))
		obf_type=$(jsonfilter -i "$INSTANCES_JSON" -e "@.endpoints[${i}].obfuscation.type" 2>/dev/null)
		case "$selector" in
			any)
				try_endpoint "$i" && return 0
				;;
			obfuscated)
				[ "$obf_type" = "amnezia" ] && try_endpoint "$i" && return 0
				;;
			plain)
				[ -z "$obf_type" ] && try_endpoint "$i" && return 0
				;;
		esac
		tried=$((tried + 1))
	done
	return 1
}

if [ "$ENDPOINT_MODE" = "obfuscated" ]; then
	try_endpoints obfuscated && exit 0
	try_endpoints plain && exit 0
else
	AUTO_ENDPOINT_OFFSET=$(read_auto_endpoint_offset)
	logger -t expressvpn "Auto endpoint offset for ${PEER}/${LOCATION_ID}: ${AUTO_ENDPOINT_OFFSET}"
	try_endpoints any "$AUTO_ENDPOINT_OFFSET" && exit 0
fi

exit 1
