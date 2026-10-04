#!/bin/zsh

set -euo pipefail
source "${0:A:h}/common.zsh"

root="$(deploy_root)"
runtime="${root}/runtime/local"
install -d -m 0700 "$runtime" "${runtime}/logs" "${runtime}/xdg-config" "${runtime}/xdg-data"

export CADDY_ACCESS_LOG="${runtime}/logs/access.jsonl"
export CADDY_RUNTIME_LOG="${runtime}/logs/runtime.jsonl"
export XDG_CONFIG_HOME="${runtime}/xdg-config"
export XDG_DATA_HOME="${runtime}/xdg-data"

"${root}/scripts/preflight.zsh" local
caddy validate --config "${root}/Caddyfile.local" --adapter caddyfile
exec caddy run --config "${root}/Caddyfile.local" --adapter caddyfile
