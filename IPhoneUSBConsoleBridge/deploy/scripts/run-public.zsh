#!/bin/zsh

set -euo pipefail
source "${0:A:h}/common.zsh"

case "${1:-}" in
	--staging) public_mode="staging" ;;
	--production) public_mode="production" ;;
	*) die "usage: ${0:t} --staging|--production" ;;
esac

require_nonempty_env PUBLIC_IP
is_global_ipv4 "$PUBLIC_IP" || die "PUBLIC_IP must be a globally routable IPv4 address"

root="$(deploy_root)"
config="$(public_config_for_mode "$public_mode")"
runtime="${root}/runtime/public-${public_mode}"
install -d -m 0700 "$runtime" "${runtime}/logs" "${runtime}/xdg-config" "${runtime}/xdg-data"

if [[ "$public_mode" == "production" ]]; then
	[[ "${CONFIRM_PRODUCTION_ACME:-}" == "YES" ]] || die "production ACME is locked. Complete and mark the staging path first, then set CONFIRM_PRODUCTION_ACME=YES for this invocation"
	marker="${root}/runtime/staging-verified.json"
	[[ -f "$marker" ]] || die "staging verification marker is missing; run verify-public-staging.zsh after an external staging test"
	/usr/bin/python3 - "$marker" "$PUBLIC_IP" <<'PY'
import json
import os
import stat
import sys

path, expected_ip = sys.argv[1:]
metadata = os.lstat(path)
if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
    raise SystemExit("staging marker must be a regular, non-symlink file")
if metadata.st_uid != os.getuid():
    raise SystemExit("staging marker is not owned by the current user")
mode = stat.S_IMODE(metadata.st_mode)
if mode != 0o600:
    raise SystemExit(f"staging marker permissions must be 0600, found {mode:04o}")
with open(path, encoding="utf-8") as handle:
    value = json.load(handle)
if value.get("publicIP") != expected_ip or value.get("externallyConfirmed") is not True:
    raise SystemExit("staging marker does not authorize this public IP")
PY
fi

export CADDY_ACCESS_LOG="${runtime}/logs/access.jsonl"
export CADDY_RUNTIME_LOG="${runtime}/logs/runtime.jsonl"
export XDG_CONFIG_HOME="${runtime}/xdg-config"
export XDG_DATA_HOME="${runtime}/xdg-data"

"${root}/scripts/preflight.zsh" public
caddy validate --config "$config" --adapter caddyfile
print -r -- "starting designated ${public_mode} edge; NAT-PMP apply must use PUBLIC_EDGE_MODE=${public_mode}"
exec caddy run --config "$config" --adapter caddyfile
