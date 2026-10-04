#!/bin/zsh

set -euo pipefail
source "${0:A:h}/common.zsh"

require_nonempty_env PUBLIC_IP
is_global_ipv4 "$PUBLIC_IP" || die "PUBLIC_IP must be a globally routable IPv4 address"
[[ "${CONFIRM_EXTERNAL_STAGING:-}" == "YES" ]] || die "first confirm from a cellular/external network that the staging endpoint reaches this Mac, then set CONFIRM_EXTERNAL_STAGING=YES for this invocation"
require_public_route_ready
require_public_caddy_runtime staging "$PUBLIC_IP"
assert_no_nonloopback_tcp_listener 5901
assert_no_nonloopback_tcp_listener 15901

require_command curl
require_command openssl
scratch="$(mktemp -d "${TMPDIR:-/tmp}/iphone-usb-console-staging-verify.XXXXXX")"
cleanup() {
	[[ -n "${scratch:-}" && -d "$scratch" ]] && find "$scratch" -depth -delete 2>/dev/null || true
	[[ -n "${temporary_marker:-}" && -f "$temporary_marker" ]] && rm -f -- "$temporary_marker" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

headers="${scratch}/headers"
body="${scratch}/body"
status="$(curl --insecure --silent --show-error --max-time 5 \
	--resolve "${PUBLIC_IP}:${EDGE_PORT}:${EXPECTED_LAN_IP}" \
	--dump-header "$headers" \
	--output "$body" \
	--write-out '%{http_code}' \
	"https://${PUBLIC_IP}:${EDGE_PORT}/api/session")" || die "staging HTTPS endpoint probe failed"

/usr/bin/python3 - "$headers" "$body" "$status" <<'PY'
import json
import sys

header_path, body_path, status = sys.argv[1:]
if status != "401":
    raise SystemExit(f"staging /api/session returned HTTP {status}; expected 401")
with open(header_path, encoding="iso-8859-1") as handle:
    lines = handle.read().replace("\r\n", "\n").splitlines()
headers = {}
for line in lines[1:]:
    if ":" in line:
        name, value = line.split(":", 1)
        headers.setdefault(name.strip().lower(), []).append(value.strip())
required = {
    "cache-control": "no-store",
    "x-content-type-options": "nosniff",
    "x-frame-options": "DENY",
    "cross-origin-opener-policy": "same-origin",
    "cross-origin-resource-policy": "same-origin",
}
for name, expected in required.items():
    if headers.get(name) != [expected]:
        raise SystemExit(f"unexpected staging {name}: {headers.get(name)!r}")
csp = headers.get("content-security-policy", [])
directives = {
    part.strip().split(maxsplit=1)[0]: part.strip()
    for part in (csp[0].split(";") if len(csp) == 1 else [])
    if part.strip()
}
if directives.get("media-src") != "media-src 'none'" or directives.get("worker-src") != "worker-src 'self'":
    raise SystemExit(f"unexpected staging CSP: {csp!r}")
permissions = headers.get("permissions-policy", [])
if len(permissions) != 1 or not all(
    token in permissions[0] for token in ("camera=()", "microphone=(self)", "geolocation=()")
):
    raise SystemExit(f"unexpected staging permissions-policy: {permissions!r}")
with open(body_path, "rb") as handle:
    payload = json.load(handle)
if not isinstance(payload, dict) or payload.get("code") != "unauthorized":
    raise SystemExit(f"unexpected staging JSON: {payload!r}")
PY

certificate_pem="${scratch}/leaf.pem"
openssl s_client -connect "${EXPECTED_LAN_IP}:${EDGE_PORT}" -servername "$PUBLIC_IP" -showcerts </dev/null 2>/dev/null \
	| awk '/-----BEGIN CERTIFICATE-----/{capture=1} capture{print} /-----END CERTIFICATE-----/{exit}' >"$certificate_pem"
[[ -s "$certificate_pem" ]] || die "unable to read the staging leaf certificate"
certificate_text="$(openssl x509 -in "$certificate_pem" -noout -issuer -ext subjectAltName 2>/dev/null)" || die "unable to inspect the staging leaf certificate"
print -r -- "$certificate_text" | grep -Fq "IP Address:${PUBLIC_IP}" || die "staging certificate does not contain the expected IP SAN"
print -r -- "$certificate_text" | grep -Fqi "STAGING" || die "the served certificate is not visibly issued by the staging hierarchy"

root="$(deploy_root)"
install -d -m 0700 "${root}/runtime"
marker="${root}/runtime/staging-verified.json"
temporary_marker="${root}/runtime/.staging-verified.$$.tmp"
umask 077
print -r -- "{\"publicIP\":\"${PUBLIC_IP}\",\"externallyConfirmed\":true,\"verifiedAt\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" >"$temporary_marker"
chmod 0600 "$temporary_marker"
mv -f "$temporary_marker" "$marker"
print -r -- "staging path verified and marked for this public IP; production ACME remains locked until explicitly invoked"
