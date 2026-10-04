#!/bin/zsh

set -euo pipefail

readonly EXPECTED_LAN_IP="192.168.31.112"
readonly EXPECTED_GATEWAY="192.168.31.1"
readonly EDGE_PORT="18443"
readonly UPSTREAM_PORT="18765"
readonly MIN_CADDY_VERSION="2.11.4"
readonly COMMON_SCRIPT_PATH="${${(%):-%N}:A}"
readonly DEPLOY_DIRECTORY="${COMMON_SCRIPT_PATH:h:h}"

deploy_root() {
	print -r -- "$DEPLOY_DIRECTORY"
}

die() {
	print -u2 -r -- "error: $*"
	exit 1
}

warn() {
	print -u2 -r -- "warning: $*"
}

require_command() {
	command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

require_nonempty_env() {
	local name="$1"
	[[ -n "${(P)name:-}" ]] || die "environment variable is required: ${name}"
}

require_caddy_version() {
	require_command caddy
	local raw version major minor patch
	raw="$(caddy version)"
	version="${${raw%% *}#v}"
	[[ "$version" == <->.<->.<->* ]] || die "unable to parse Caddy version: ${raw}"
	major="${version%%.*}"
	version="${version#*.}"
	minor="${version%%.*}"
	patch="${${version#*.}%%[^0-9]*}"
	if (( major < 2 || (major == 2 && minor < 11) || (major == 2 && minor == 11 && patch < 4) )); then
		die "Caddy ${MIN_CADDY_VERSION} or newer is required for the current IP-certificate/TLS-ALPN path; found ${raw}"
	fi
}

physical_default_gateway() {
	route -n get -ifscope en0 default 2>/dev/null | awk '/gateway:/{print $2; exit}'
}

active_default_interface() {
	route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}'
}

require_public_route_ready() {
	local default_interface
	default_interface="$(active_default_interface)"
	if [[ "$default_interface" == utun* ]]; then
		[[ "${PUBLIC_ROUTE_DIRECT_CONFIRMED:-}" == "YES" ]] || die "public mode is blocked because the active default route is ${default_interface}. Pause the VPN/Shadowrocket route or add and verify DIRECT rules, then set PUBLIC_ROUTE_DIRECT_CONFIRMED=YES for this invocation only"
	fi
}

is_global_ipv4() {
	local value="$1"
	/usr/bin/python3 - "$value" <<'PY'
import ipaddress
import sys

try:
    address = ipaddress.ip_address(sys.argv[1])
except ValueError:
    raise SystemExit(1)
raise SystemExit(0 if address.version == 4 and address.is_global else 1)
PY
}

public_config_for_mode() {
	case "$1" in
		staging) print -r -- "${DEPLOY_DIRECTORY}/Caddyfile.public-staging" ;;
		production) print -r -- "${DEPLOY_DIRECTORY}/Caddyfile.public" ;;
		*) die "PUBLIC_EDGE_MODE must be staging or production" ;;
	esac
}

assert_exact_tcp_listener() {
	local port="$1"
	local expected_name="$2"
	local expected_process="${3:-}"
	/usr/bin/python3 - "$port" "$expected_name" "$expected_process" <<'PY'
import subprocess
import sys

port, expected_name, expected_process = sys.argv[1:]
result = subprocess.run(
    ["/usr/sbin/lsof", "-a", "-nP", f"-iTCP:{port}", "-sTCP:LISTEN", "-Fpcn"],
    text=True,
    stdout=subprocess.PIPE,
    stderr=subprocess.DEVNULL,
)
current_pid = None
current_command = None
listeners = []
for raw_line in result.stdout.splitlines():
    if raw_line.startswith("p"):
        current_pid = raw_line[1:]
    elif raw_line.startswith("c"):
        current_command = raw_line[1:]
    elif raw_line.startswith("n"):
        listeners.append((current_pid, current_command, raw_line[1:]))

if len(listeners) != 1:
    raise SystemExit(
        f"TCP {port} must have exactly one listener; observed {listeners!r}"
    )
pid, command, name = listeners[0]
if name != expected_name:
    raise SystemExit(
        f"TCP {port} listener is {name!r}; expected only {expected_name!r}"
    )
if expected_process and command != expected_process:
    raise SystemExit(
        f"TCP {port} listener process is {command!r}; expected {expected_process!r}"
    )
print(pid)
PY
}

assert_no_nonloopback_tcp_listener() {
	local port="$1"
	/usr/bin/python3 - "$port" <<'PY'
import subprocess
import sys

port = sys.argv[1]
result = subprocess.run(
    ["/usr/sbin/lsof", "-a", "-nP", f"-iTCP:{port}", "-sTCP:LISTEN", "-Fn"],
    text=True,
    stdout=subprocess.PIPE,
    stderr=subprocess.DEVNULL,
)
allowed = {f"127.0.0.1:{port}", f"[::1]:{port}"}
listeners = [line[1:] for line in result.stdout.splitlines() if line.startswith("n")]
unsafe = [name for name in listeners if name not in allowed]
if unsafe:
    raise SystemExit(
        f"TCP {port} has a non-loopback listener and public deployment is refused: {unsafe!r}"
    )
PY
}

verify_loopback_session_endpoint() {
	require_command curl
	local scratch response_headers response_body response_code
	scratch="$(mktemp -d "${TMPDIR:-/tmp}/iphone-usb-console-session-check.XXXXXX")"
	response_headers="${scratch}/headers"
	response_body="${scratch}/body"
	response_code="$(curl --silent --show-error --max-time 3 \
		--dump-header "$response_headers" \
		--output "$response_body" \
		--write-out '%{http_code}' \
		"http://127.0.0.1:${UPSTREAM_PORT}/api/session")" || {
		find "$scratch" -depth -delete 2>/dev/null || true
		die "web-console /api/session probe failed"
	}
	if ! /usr/bin/python3 - "$response_headers" "$response_body" "$response_code" <<'PY'
import json
import sys

header_path, body_path, status = sys.argv[1:]
if status != "401":
    raise SystemExit(f"/api/session returned HTTP {status}; expected 401")

with open(header_path, "r", encoding="iso-8859-1") as handle:
    lines = handle.read().replace("\r\n", "\n").splitlines()
headers = {}
for line in lines[1:]:
    if not line or ":" not in line:
        continue
    name, value = line.split(":", 1)
    headers.setdefault(name.strip().lower(), []).append(value.strip())

def exact(name, expected):
    values = headers.get(name, [])
    if values != [expected]:
        raise SystemExit(f"unexpected {name} header: {values!r}")

content_types = headers.get("content-type", [])
if len(content_types) != 1 or not content_types[0].lower().startswith("application/json"):
    raise SystemExit(f"unexpected content-type header: {content_types!r}")
exact("cache-control", "no-store")
exact("x-content-type-options", "nosniff")
exact("referrer-policy", "no-referrer")
exact("x-frame-options", "DENY")
exact("cross-origin-opener-policy", "same-origin")
exact("cross-origin-resource-policy", "same-origin")

permissions = headers.get("permissions-policy", [])
if len(permissions) != 1 or not all(
    token in permissions[0] for token in ("camera=()", "microphone=(self)", "geolocation=()")
):
    raise SystemExit(f"unexpected permissions-policy header: {permissions!r}")

csp_values = headers.get("content-security-policy", [])
if len(csp_values) != 1:
    raise SystemExit(f"unexpected content-security-policy header: {csp_values!r}")
csp = csp_values[0]
required_csp = (
    "default-src 'self'",
    "script-src 'self'",
    "worker-src 'self'",
    "style-src 'self'",
    "connect-src 'self'",
    "object-src 'none'",
    "base-uri 'none'",
    "frame-ancestors 'none'",
    "form-action 'self'",
)
if not all(item in csp for item in required_csp) or "'unsafe-" in csp:
    raise SystemExit(f"unsafe or incomplete CSP: {csp!r}")

with open(body_path, "rb") as handle:
    try:
        body = json.load(handle)
    except Exception as error:
        raise SystemExit(f"/api/session body is not JSON: {error}")
if not isinstance(body, dict) or body.get("code") != "unauthorized":
    raise SystemExit(f"unexpected /api/session JSON: {body!r}")
PY
	then
		find "$scratch" -depth -delete 2>/dev/null || true
		die "web-console /api/session security contract validation failed"
	fi
	find "$scratch" -depth -delete 2>/dev/null || true
}

require_public_caddy_runtime() {
	local mode="$1"
	local public_ip="$2"
	local expected_config expected_ca edge_pid admin_pid command_line caddy_path runtime_json scratch
	expected_config="$(public_config_for_mode "$mode")"
	case "$mode" in
		staging) expected_ca="https://acme-staging-v02.api.letsencrypt.org/directory" ;;
		production) expected_ca="https://acme-v02.api.letsencrypt.org/directory" ;;
	esac

	edge_pid="$(assert_exact_tcp_listener "$EDGE_PORT" "${EXPECTED_LAN_IP}:${EDGE_PORT}" "caddy")" || die "the edge listener is not the expected Caddy process"
	admin_pid="$(assert_exact_tcp_listener "2019" "127.0.0.1:2019" "caddy")" || die "the Caddy admin listener is absent, shared, or non-loopback"
	[[ "$edge_pid" == "$admin_pid" ]] || die "edge and admin listeners belong to different processes"

	require_command caddy
	caddy_path="$(command -v caddy)"
	command_line="$(ps -ww -p "$edge_pid" -o command= 2>/dev/null || true)"
	/usr/bin/python3 - "$command_line" "$caddy_path" "$expected_config" <<'PY' || die "Caddy is not running the designated configuration command"
import os
import shlex
import sys

command_line, caddy_path, expected_config = sys.argv[1:]
try:
    arguments = shlex.split(command_line)
except ValueError as error:
    raise SystemExit(f"unable to parse Caddy command line: {error}")
expected_tail = ["run", "--config", expected_config, "--adapter", "caddyfile"]
if len(arguments) != 1 + len(expected_tail):
    raise SystemExit(f"unexpected Caddy command line: {arguments!r}")
executable_matches = arguments[0] == "caddy" or os.path.realpath(arguments[0]) == os.path.realpath(caddy_path)
if not executable_matches or arguments[1:] != expected_tail:
    raise SystemExit(f"Caddy is not running the designated config: {arguments!r}")
PY

	require_command curl
	scratch="$(mktemp -d "${TMPDIR:-/tmp}/iphone-usb-console-caddy-runtime.XXXXXX")"
	runtime_json="${scratch}/config.json"
	curl --fail --silent --show-error --max-time 3 \
		"http://127.0.0.1:2019/config/" >"$runtime_json" || {
		find "$scratch" -depth -delete 2>/dev/null || true
		die "unable to read the designated Caddy runtime through its loopback admin API"
	}
	if ! /usr/bin/python3 - "$runtime_json" "$public_ip" "$expected_ca" <<'PY'
import json
import sys

path, public_ip, expected_ca = sys.argv[1:]
with open(path, encoding="utf-8") as handle:
    config = json.load(handle)

def walk(value):
    yield value
    if isinstance(value, dict):
        for child in value.values():
            yield from walk(child)
    elif isinstance(value, list):
        for child in value:
            yield from walk(child)

if config.get("admin", {}).get("listen") != "127.0.0.1:2019":
    raise SystemExit("runtime admin endpoint is not loopback-only")
servers = config.get("apps", {}).get("http", {}).get("servers", {})
listeners = [entry for server in servers.values() for entry in server.get("listen", [])]
if listeners != ["192.168.31.112:18443"]:
    raise SystemExit(f"runtime listener mismatch: {listeners!r}")
proxies = [item for item in walk(config) if isinstance(item, dict) and item.get("handler") == "reverse_proxy"]
if len(proxies) != 1 or proxies[0].get("upstreams") != [{"dial": "127.0.0.1:18765"}]:
    raise SystemExit(f"runtime upstream mismatch: {proxies!r}")
policies = config.get("apps", {}).get("tls", {}).get("automation", {}).get("policies", [])
if len(policies) != 1 or policies[0].get("subjects") != [public_ip]:
    raise SystemExit(f"runtime certificate subject mismatch: {policies!r}")
issuers = policies[0].get("issuers", [])
if len(issuers) != 1 or issuers[0].get("ca") != expected_ca or issuers[0].get("profile") != "shortlived":
    raise SystemExit(f"runtime ACME issuer mismatch: {issuers!r}")
challenges = issuers[0].get("challenges", {})
if challenges.get("http", {}).get("disabled") is not True:
    raise SystemExit("runtime unexpectedly enables HTTP-01")
if challenges.get("tls-alpn", {}).get("alternate_port") != 18443:
    raise SystemExit("runtime TLS-ALPN port mismatch")
if challenges.get("bind_host") != "192.168.31.112":
    raise SystemExit("runtime ACME bind address mismatch")
PY
	then
		find "$scratch" -depth -delete 2>/dev/null || true
		die "the running Caddy configuration does not match the designated public deployment"
	fi
	find "$scratch" -depth -delete 2>/dev/null || true
}
