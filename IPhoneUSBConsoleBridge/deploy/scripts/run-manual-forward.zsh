#!/bin/zsh

set -euo pipefail
source "${0:A:h}/common.zsh"

require_nonempty_env PUBLIC_IP
is_global_ipv4 "$PUBLIC_IP" || die "PUBLIC_IP must be a globally routable IPv4 address"

root="$(deploy_root)"
config="${root}/Caddyfile.manual-forward"
runtime="${root}/runtime/manual-forward"
install -d -m 0700 "$runtime" "${runtime}/logs" "${runtime}/xdg-config" "${runtime}/xdg-data"

export CADDY_ACCESS_LOG="${runtime}/logs/access.jsonl"
export CADDY_RUNTIME_LOG="${runtime}/logs/runtime.jsonl"
export XDG_CONFIG_HOME="${runtime}/xdg-config"
export XDG_DATA_HOME="${runtime}/xdg-data"

# This mode deliberately permits an active VPN because it uses Caddy's local
# CA and never contacts ACME. The existing router rule remains user-managed.
"${root}/scripts/preflight.zsh" local
caddy validate --config "$config" --adapter caddyfile
print -r -- "starting manual-forward HTTPS edge on ${EXPECTED_LAN_IP}:${EDGE_PORT}; router mapping is not modified"
exec caddy run --config "$config" --adapter caddyfile
