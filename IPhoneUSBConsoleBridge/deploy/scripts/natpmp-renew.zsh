#!/bin/zsh

set -euo pipefail
source "${0:A:h}/common.zsh"

readonly PUBLIC_PORT="443"
readonly MAPPING_LIFETIME="3600"
readonly MINIMUM_SAFE_LIFETIME="900"

mode="dry-run"
case "${1:-}" in
	"") ;;
	--apply) mode="apply" ;;
	--remove) mode="remove" ;;
	*) die "usage: ${0:t} [--apply|--remove]" ;;
esac

parse_mapping_response() {
	local response="$1"
	/usr/bin/python3 - "$response" <<'PY'
import re
import sys

pattern = re.compile(
    r"^Mapped public port ([0-9]+) protocol ([Tt][Cc][Pp]) "
    r"to local port ([0-9]+) lifetime ([0-9]+)$"
)
matches = []
for line in sys.argv[1].splitlines():
    match = pattern.fullmatch(line.strip())
    if match:
        public_port = int(match.group(1))
        private_port = int(match.group(3))
        lifetime = int(match.group(4))
        if not 1 <= public_port <= 65535 or not 1 <= private_port <= 65535:
            raise SystemExit("NAT-PMP response contains an out-of-range port")
        matches.append((public_port, private_port, lifetime))
if len(matches) != 1:
    raise SystemExit(f"expected exactly one mapping confirmation, received {len(matches)}")
print(":".join(str(value) for value in matches[0]))
PY
}

mapping_candidates() {
	local response="$1"
	/usr/bin/python3 - "$response" <<'PY'
import re
import sys

pattern = re.compile(
    r"Mapped public port\s+([0-9]+).*?to local port\s+([0-9]+)",
    re.IGNORECASE,
)
seen = set()
for public_text, private_text in pattern.findall(sys.argv[1]):
    public_port = int(public_text)
    private_port = int(private_text)
    pair = (public_port, private_port)
    if 1 <= public_port <= 65535 and 1 <= private_port <= 65535 and pair not in seen:
        seen.add(pair)
        print(f"{public_port}:{private_port}")
PY
}

remove_mapping_verified() {
	local public_port="$1"
	local private_port="$2"
	local deletion parsed actual_public actual_private actual_lifetime
	if ! deletion="$(natpmpc -g "$gateway" -a "$public_port" "$private_port" tcp 0 2>&1)"; then
		warn "NAT-PMP refused deletion of TCP ${public_port} -> local ${private_port}"
		return 1
	fi
	if ! parsed="$(parse_mapping_response "$deletion")"; then
		warn "NAT-PMP deletion response could not be verified for TCP ${public_port} -> local ${private_port}"
		return 1
	fi
	IFS=: read -r actual_public actual_private actual_lifetime <<<"$parsed"
	if [[ "$actual_public" != "$public_port" || "$actual_private" != "$private_port" || "$actual_lifetime" != "0" ]]; then
		warn "NAT-PMP deletion did not confirm the exact lifetime-zero target TCP ${public_port} -> local ${private_port}"
		return 1
	fi
	return 0
}

compensate_failed_mapping() {
	local candidates_text="$1"
	local pair public_port private_port compensation_failed=0
	local -a pairs
	typeset -A seen
	pairs=("${PUBLIC_PORT}:${EDGE_PORT}")
	while IFS= read -r pair; do
		if [[ -n "$pair" ]]; then
			pairs+=("$pair")
		fi
	done <<<"$candidates_text"

	for pair in "${pairs[@]}"; do
		if [[ -n "${seen[$pair]:-}" ]]; then
			continue
		fi
		seen[$pair]=1
		public_port="${pair%%:*}"
		private_port="${pair#*:}"
		if ! remove_mapping_verified "$public_port" "$private_port"; then
			compensation_failed=1
		fi
	done
	if (( compensation_failed )); then
		warn "one or more compensation deletions could not be verified; keep Caddy stopped and inspect the router before retrying"
		return 1
	fi
	return 0
}

fail_after_mapping_request() {
	local reason="$1"
	local candidates_text="$2"
	if compensate_failed_mapping "$candidates_text"; then
		die "${reason}; the requested public 443 mapping and every identified substitute were removed with verified lifetime zero"
	fi
	die "${reason}; compensation was attempted but could not be fully verified"
}

require_command natpmpc

lan_ip="$(ipconfig getifaddr en0 2>/dev/null || true)"
[[ "$lan_ip" == "$EXPECTED_LAN_IP" ]] || die "refusing NAT-PMP operation: en0 is ${lan_ip:-unassigned}, expected ${EXPECTED_LAN_IP}"

gateway="$(physical_default_gateway)"
[[ "$gateway" == "$EXPECTED_GATEWAY" ]] || die "refusing NAT-PMP operation: en0 gateway is ${gateway:-unknown}, expected ${EXPECTED_GATEWAY}"

if [[ "$mode" == "remove" ]]; then
	remove_mapping_verified "$PUBLIC_PORT" "$EDGE_PORT" || die "unable to verify removal of TCP ${PUBLIC_PORT} -> ${EXPECTED_LAN_IP}:${EDGE_PORT}"
	print -r -- "removed: TCP ${PUBLIC_PORT} -> ${EXPECTED_LAN_IP}:${EDGE_PORT}, lifetime=0 (idempotent)"
	exit 0
fi

if [[ "$mode" == "apply" ]]; then
	require_nonempty_env EXPECTED_PUBLIC_IP
	is_global_ipv4 "$EXPECTED_PUBLIC_IP" || die "EXPECTED_PUBLIC_IP must be a globally routable IPv4 address"
fi

public_probe="$(natpmpc -g "$gateway" 2>&1)" || die "router did not answer NAT-PMP public-address request"
router_public_ip="$(print -r -- "$public_probe" | awk -F': ' '/Public IP address/{print $2; exit}')"
[[ -n "$router_public_ip" ]] || die "NAT-PMP response did not contain a public IPv4 address"
is_global_ipv4 "$router_public_ip" || die "router reports a non-global WAN address; double NAT/CGNAT is likely"

if [[ -n "${EXPECTED_PUBLIC_IP:-}" && "$router_public_ip" != "$EXPECTED_PUBLIC_IP" ]]; then
	die "router WAN IP changed and does not match EXPECTED_PUBLIC_IP; reissue the IP certificate/config before reopening the port"
fi

if [[ "$mode" == "dry-run" ]]; then
	print -r -- "dry run only: would request TCP ${PUBLIC_PORT} -> ${EXPECTED_LAN_IP}:${EDGE_PORT} for ${MAPPING_LIFETIME}s via ${gateway}"
	print -r -- "--apply additionally requires EXPECTED_PUBLIC_IP, PUBLIC_EDGE_MODE, a designated live Caddy runtime, and explicit DIRECT-route confirmation when utun is default"
	exit 0
fi

require_public_route_ready
require_nonempty_env PUBLIC_EDGE_MODE
[[ "$PUBLIC_EDGE_MODE" == "staging" || "$PUBLIC_EDGE_MODE" == "production" ]] || die "PUBLIC_EDGE_MODE must be staging or production"
require_public_caddy_runtime "$PUBLIC_EDGE_MODE" "$EXPECTED_PUBLIC_IP"
assert_no_nonloopback_tcp_listener 5901
assert_no_nonloopback_tcp_listener 15901

mapping_result=""
mapping_status=0
if mapping_result="$(natpmpc -g "$gateway" -a "$PUBLIC_PORT" "$EDGE_PORT" tcp "$MAPPING_LIFETIME" 2>&1)"; then
	mapping_status=0
else
	mapping_status=$?
fi
candidates_text="$(mapping_candidates "$mapping_result" 2>/dev/null || true)"
if (( mapping_status != 0 )); then
	fail_after_mapping_request "NAT-PMP mapping request failed after it was sent" "$candidates_text"
fi

if ! parsed_mapping="$(parse_mapping_response "$mapping_result")"; then
	fail_after_mapping_request "NAT-PMP mapping confirmation could not be parsed unambiguously" "$candidates_text"
fi
IFS=: read -r actual_public actual_private actual_lifetime <<<"$parsed_mapping"

if [[ "$actual_public" != "$PUBLIC_PORT" || "$actual_private" != "$EDGE_PORT" ]]; then
	fail_after_mapping_request "router substituted an unexpected public or private port" "$candidates_text"
fi
if (( actual_lifetime < MINIMUM_SAFE_LIFETIME || actual_lifetime > MAPPING_LIFETIME )); then
	fail_after_mapping_request "router granted a mapping lifetime outside ${MINIMUM_SAFE_LIFETIME}-${MAPPING_LIFETIME}s" "$candidates_text"
fi

print -r -- "renewed: TCP ${PUBLIC_PORT} -> ${EXPECTED_LAN_IP}:${EDGE_PORT}, lifetime=${actual_lifetime}s, edge=${PUBLIC_EDGE_MODE}"
