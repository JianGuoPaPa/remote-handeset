#!/bin/zsh

set -euo pipefail
source "${0:A:h}/common.zsh"

mode="${1:-local}"
[[ "$mode" == "local" || "$mode" == "public" ]] || die "usage: ${0:t} [local|public]"

require_caddy_version

lan_ip="$(ipconfig getifaddr en0 2>/dev/null || true)"
[[ "$lan_ip" == "$EXPECTED_LAN_IP" ]] || die "en0 is ${lan_ip:-unassigned}; expected ${EXPECTED_LAN_IP}. Reserve this address in DHCP before deployment"

gateway="$(physical_default_gateway)"
[[ "$gateway" == "$EXPECTED_GATEWAY" ]] || die "en0 gateway is ${gateway:-unknown}; expected ${EXPECTED_GATEWAY}"

default_interface="$(active_default_interface)"
if [[ "$mode" == "public" ]]; then
	require_public_route_ready
elif [[ "$default_interface" == utun* ]]; then
	warn "the active default route is ${default_interface}; local QA is allowed, but public mode will fail closed until DIRECT routing is explicitly confirmed"
fi

assert_exact_tcp_listener "$UPSTREAM_PORT" "127.0.0.1:${UPSTREAM_PORT}" >/dev/null || \
	die "web-console upstream must have exactly one listener, bound only to 127.0.0.1:${UPSTREAM_PORT}"
verify_loopback_session_endpoint
assert_no_nonloopback_tcp_listener 5901
assert_no_nonloopback_tcp_listener 15901

if lsof -nP -iTCP:"$EDGE_PORT" -sTCP:LISTEN 2>/dev/null | grep -q .; then
	die "TCP ${EDGE_PORT} is already in use; inspect with: lsof -nP -iTCP:${EDGE_PORT} -sTCP:LISTEN"
fi

if lsof -nP -iTCP:2019 -sTCP:LISTEN 2>/dev/null | grep -q .; then
	die "Caddy admin port 127.0.0.1:2019 is already in use; inspect with: lsof -nP -iTCP:2019 -sTCP:LISTEN"
fi

if lsof -nP -iTCP:80 -sTCP:LISTEN 2>/dev/null | grep -q .; then
	warn "TCP 80 is in use, but this deployment neither binds nor forwards it"
fi

if [[ "$mode" == "public" ]]; then
	require_nonempty_env PUBLIC_IP
	is_global_ipv4 "$PUBLIC_IP" || die "PUBLIC_IP must be a globally routable IPv4 address, not a LAN/CGNAT/reserved address"
	warn "before the selected public certificate order, external TCP 443 must reach ${EXPECTED_LAN_IP}:${EDGE_PORT}; UDP 443 is intentionally not mapped"
fi

print -r -- "preflight ok: mode=${mode}, en0=${lan_ip}, gateway=${gateway}, upstream contract=401 JSON with security headers, protected ports loopback-only"
