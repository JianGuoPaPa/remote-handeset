#!/bin/zsh

set -euo pipefail
source "${0:A:h}/common.zsh"

require_caddy_version

root="$(deploy_root)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/iphone-usb-console-caddy-validate.XXXXXX")"
cleanup() {
	[[ -n "$scratch" && -d "$scratch" ]] && find "$scratch" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT INT TERM

export PUBLIC_IP="203.0.113.10"
export CADDY_ACCESS_LOG="${scratch}/access.log"
export CADDY_RUNTIME_LOG="${scratch}/runtime.log"
export XDG_CONFIG_HOME="${scratch}/xdg-config"
export XDG_DATA_HOME="${scratch}/xdg-data"

for config in Caddyfile.local Caddyfile.manual-forward Caddyfile.public-staging Caddyfile.public; do
	json="${scratch}/${config}.json"
	caddy adapt --config "${root}/${config}" --adapter caddyfile --pretty >"$json"
	caddy validate --config "${root}/${config}" --adapter caddyfile >/dev/null
	/usr/bin/python3 - "$json" "$config" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    config = json.load(handle)
config_name = sys.argv[2]


def walk(value):
    yield value
    if isinstance(value, dict):
        for child in value.values():
            yield from walk(child)
    elif isinstance(value, list):
        for child in value:
            yield from walk(child)

admin = config.get("admin", {}).get("listen")
if admin != "127.0.0.1:2019":
    raise SystemExit(f"admin endpoint is not loopback-only: {admin!r}")

servers = config.get("apps", {}).get("http", {}).get("servers", {})
listens = [address for server in servers.values() for address in server.get("listen", [])]
if listens != ["192.168.31.112:18443"]:
    raise SystemExit(f"unexpected HTTP server listeners: {listens!r}")
if any(address.endswith(":80") for address in listens):
    raise SystemExit(f"unexpected HTTP listener: {listens!r}")
if any(not server.get("automatic_https", {}).get("disable_redirects") for server in servers.values()):
    raise SystemExit("automatic HTTP redirects are not disabled")
if any(server.get("protocols") != ["h1", "h2"] for server in servers.values()):
    raise SystemExit("HTTP/3 is not disabled or the TCP protocols are incomplete")

proxies = [item for item in walk(config) if isinstance(item, dict) and item.get("handler") == "reverse_proxy"]
if len(proxies) != 1 or proxies[0].get("upstreams") != [{"dial": "127.0.0.1:18765"}]:
    raise SystemExit(f"unexpected reverse proxy definition: {proxies!r}")
auth_handlers = [item for item in walk(config) if isinstance(item, dict) and item.get("handler") == "authentication"]
if auth_handlers:
    raise SystemExit("unexpected edge authentication would create a second login prompt")

header_handlers = [item for item in walk(config) if isinstance(item, dict) and item.get("handler") == "headers"]
if len(header_handlers) != 1:
    raise SystemExit(f"unexpected response-header handlers: {header_handlers!r}")
csp_values = header_handlers[0].get("response", {}).get("set", {}).get("Content-Security-Policy", [])
if len(csp_values) != 1:
    raise SystemExit("Content-Security-Policy is missing")
csp_directives = {part.strip().split(maxsplit=1)[0]: part.strip() for part in csp_values[0].split(";") if part.strip()}
if any("'unsafe-inline'" in directive for directive in csp_directives.values()):
    raise SystemExit("inline scripts or styles are unexpectedly allowed")
if csp_directives.get("script-src") != "script-src 'self'":
    raise SystemExit("script-src is not same-origin only")
if csp_directives.get("style-src") != "style-src 'self'":
    raise SystemExit("style-src is not same-origin only")
if csp_directives.get("connect-src") != "connect-src 'self'":
    raise SystemExit("connect-src is not same-origin only")
if csp_directives.get("media-src") != "media-src 'none'":
    raise SystemExit("unused media loading is not disabled")
if csp_directives.get("worker-src") != "worker-src 'self'":
    raise SystemExit("AudioWorklet modules are not restricted to same-origin")
if "blob:" in csp_directives.get("media-src", "") or "blob:" in csp_directives.get("worker-src", ""):
    raise SystemExit("unused media/worker blob sources remain enabled")

edge_header_sets = header_handlers[0].get("response", {}).get("set", {})
permissions_values = edge_header_sets.get("Permissions-Policy", [])
if len(permissions_values) != 1 or not all(
    token in permissions_values[0]
    for token in ("camera=()", "microphone=(self)", "geolocation=()")
):
    raise SystemExit(f"unexpected Permissions-Policy: {permissions_values!r}")
if "Cache-Control" in edge_header_sets:
    raise SystemExit("edge must preserve the backend's immutable cache headers for hashed assets")

hsts_values = header_handlers[0].get("response", {}).get("set", {}).get("Strict-Transport-Security", [])
if config_name == "Caddyfile.public":
    if hsts_values != ["max-age=31536000"]:
        raise SystemExit(f"public HSTS policy is missing or unexpected: {hsts_values!r}")
elif hsts_values:
    raise SystemExit(f"local QA must not emit HSTS: {hsts_values!r}")

log_encoders = config.get("logging", {}).get("logs", {})
access_logs = [entry for entry in log_encoders.values() if entry.get("include")]
if len(access_logs) != 1:
    raise SystemExit(f"unexpected access logger definitions: {access_logs!r}")
required_filters = {
    "request>uri",
    "request>headers>Authorization",
    "request>headers>Proxy-Authorization",
    "request>headers>Cookie",
    "request>headers>X-CSRF-Token",
    "resp_headers>Set-Cookie",
}
for logger_name, logger in log_encoders.items():
    fields = logger.get("encoder", {}).get("fields", {})
    filtered_fields = set(fields)
    if not required_filters.issubset(filtered_fields):
        raise SystemExit(f"logger {logger_name!r} does not remove all sensitive fields: {filtered_fields!r}")
    invalid_filters = {
        field: fields[field]
        for field in required_filters
        if fields[field] != {"filter": "delete"}
    }
    if invalid_filters:
        raise SystemExit(f"logger {logger_name!r} does not delete all sensitive fields: {invalid_filters!r}")
    if logger.get("writer", {}).get("mode") != "0600":
        raise SystemExit(f"logger {logger_name!r} does not create private log files")

policies = config.get("apps", {}).get("tls", {}).get("automation", {}).get("policies", [])
if config_name in {"Caddyfile.public", "Caddyfile.public-staging"}:
    if len(policies) != 1 or policies[0].get("subjects") != ["203.0.113.10"]:
        raise SystemExit(f"unexpected public certificate policy: {policies!r}")
    issuers = policies[0].get("issuers", [])
    if len(issuers) != 1:
        raise SystemExit(f"unexpected public issuers: {issuers!r}")
    issuer = issuers[0]
    expected_ca = (
        "https://acme-v02.api.letsencrypt.org/directory"
        if config_name == "Caddyfile.public"
        else "https://acme-staging-v02.api.letsencrypt.org/directory"
    )
    if issuer.get("ca") != expected_ca:
        raise SystemExit(f"unexpected ACME directory: {issuer.get('ca')!r}")
    challenges = issuer.get("challenges", {})
    if issuer.get("profile") != "shortlived":
        raise SystemExit("public issuer does not require the shortlived profile")
    if challenges.get("http", {}).get("disabled") is not True:
        raise SystemExit("HTTP-01 is not disabled")
    if challenges.get("tls-alpn", {}).get("alternate_port") != 18443:
        raise SystemExit("TLS-ALPN is not fixed to local port 18443")
    if challenges.get("bind_host") != "192.168.31.112":
        raise SystemExit("ACME challenge is not bound to the expected LAN address")
elif config_name == "Caddyfile.manual-forward":
    if len(policies) != 1 or policies[0].get("subjects") != ["203.0.113.10"]:
        raise SystemExit(f"unexpected manual-forward certificate policy: {policies!r}")
    issuers = policies[0].get("issuers", [])
    if len(issuers) != 1 or issuers[0].get("module") != "internal":
        raise SystemExit(f"unexpected manual-forward certificate issuer: {issuers!r}")
    connection_policies = [
        policy
        for server in servers.values()
        for policy in server.get("tls_connection_policies", [])
    ]
    if not connection_policies or any(policy.get("default_sni") != "203.0.113.10" for policy in connection_policies):
        raise SystemExit(f"manual-forward default SNI is missing or unexpected: {connection_policies!r}")
    if not any(policy.get("match", {}).get("sni") == ["", "203.0.113.10"] for policy in connection_policies):
        raise SystemExit("manual-forward does not support clients that omit SNI")
    local_ca = config.get("apps", {}).get("pki", {}).get("certificate_authorities", {}).get("local", {})
    if local_ca.get("install_trust") is not False:
        raise SystemExit("manual-forward unexpectedly installs its local CA into system trust")
else:
    issuers = [issuer for policy in policies for issuer in policy.get("issuers", [])]
    if len(issuers) != 1 or issuers[0].get("module") != "internal":
        raise SystemExit(f"unexpected local certificate issuer: {issuers!r}")
PY
	print -r -- "validated: ${config}"
done

for script in "${root}"/scripts/*.zsh; do
	zsh -n "$script"
	[[ -x "$script" ]] || die "script is not executable: ${script}"
done
plutil -lint "${root}/launchd/com.local.iphone-usb-console-natpmp.plist.template" >/dev/null
print -r -- "validated: shell syntax"

/usr/bin/python3 - "$root" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
nat = (root / "scripts" / "natpmp-renew.zsh").read_text(encoding="utf-8")
stop = (root / "scripts" / "stop-public.zsh").read_text(encoding="utf-8")
run = (root / "scripts" / "run-public.zsh").read_text(encoding="utf-8")
required_nat_fragments = (
    'require_nonempty_env EXPECTED_PUBLIC_IP',
    '--remove',
    'tcp 0',
    'compensate_failed_mapping',
    'require_public_caddy_runtime',
    'require_public_route_ready',
    'assert_no_nonloopback_tcp_listener 5901',
    'assert_no_nonloopback_tcp_listener 15901',
)
missing = [fragment for fragment in required_nat_fragments if fragment not in nat]
if missing:
    raise SystemExit(f"NAT-PMP safety controls are incomplete: {missing!r}")
required_stop_fragments = (
    'bootout',
    'natpmp-renew.zsh" --remove',
    'kill -TERM',
    'Caddyfile.public-staging',
)
missing = [fragment for fragment in required_stop_fragments if fragment not in stop]
if missing:
    raise SystemExit(f"safe-stop controls are incomplete: {missing!r}")
if 'CONFIRM_PRODUCTION_ACME' not in run or 'staging-verified.json' not in run:
    raise SystemExit("production ACME is not gated by the staging verification path")
PY
print -r -- "validated: deployment safety invariants"
