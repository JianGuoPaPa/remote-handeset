#!/bin/zsh

set -euo pipefail
source "${0:A:h}/common.zsh"

root="$(deploy_root)"
label="com.local.iphone-usb-console-natpmp"
service_target="gui/$(id -u)/${label}"
typeset -a failures
failures=()

if launchctl print "$service_target" >/dev/null 2>&1; then
	if launchctl bootout "$service_target" >/dev/null 2>&1; then
		for attempt in {1..50}; do
			launchctl print "$service_target" >/dev/null 2>&1 || break
			sleep 0.1
		done
		if launchctl print "$service_target" >/dev/null 2>&1; then
			warn "LaunchAgent accepted bootout but remained loaded: ${label}"
			failures+=("LaunchAgent renewal remained loaded")
		else
			print -r -- "stopped LaunchAgent renewal: ${label}"
		fi
	else
		warn "unable to stop LaunchAgent renewal: ${label}"
		failures+=("LaunchAgent renewal is still loaded")
	fi
else
	print -r -- "LaunchAgent renewal was not loaded"
fi

if "${root}/scripts/natpmp-renew.zsh" --remove; then
	print -r -- "public TCP 443 NAT-PMP lease removed"
else
	warn "public TCP 443 NAT-PMP lease removal could not be verified"
	failures+=("NAT-PMP lifetime-zero removal was not verified")
fi

edge_pid=""
if edge_pid="$(/usr/bin/python3 - "$EDGE_PORT" <<'PY'
import subprocess
import sys

port = sys.argv[1]
result = subprocess.run(
    ["/usr/sbin/lsof", "-a", "-nP", f"-iTCP:{port}", "-sTCP:LISTEN", "-Fp"],
    text=True,
    stdout=subprocess.PIPE,
    stderr=subprocess.DEVNULL,
)
pids = sorted({line[1:] for line in result.stdout.splitlines() if line.startswith("p")})
if len(pids) > 1:
    raise SystemExit(f"multiple processes listen on TCP {port}: {pids!r}")
if pids:
    print(pids[0])
PY
)"; then
	if [[ -n "$edge_pid" ]]; then
		command_line="$(ps -ww -p "$edge_pid" -o command= 2>/dev/null || true)"
		caddy_path="$(command -v caddy 2>/dev/null || true)"
		if [[ -z "$caddy_path" ]]; then
			warn "Caddy is unavailable, so the edge listener identity cannot be established safely"
			failures+=("edge listener was not stopped because Caddy is unavailable")
		elif /usr/bin/python3 - "$command_line" "$caddy_path" "$root" <<'PY'
import os
import shlex
import sys

command_line, caddy_path, root = sys.argv[1:]
arguments = shlex.split(command_line)
allowed_configs = {
    os.path.join(root, "Caddyfile.local"),
    os.path.join(root, "Caddyfile.public-staging"),
    os.path.join(root, "Caddyfile.public"),
}
if len(arguments) != 6:
    raise SystemExit(1)
if arguments[0] != "caddy" and os.path.realpath(arguments[0]) != os.path.realpath(caddy_path):
    raise SystemExit(1)
if arguments[1] != "run" or arguments[2] != "--config" or arguments[3] not in allowed_configs or arguments[4:] != ["--adapter", "caddyfile"]:
    raise SystemExit(1)
PY
		then
			kill -TERM "$edge_pid"
			for attempt in {1..50}; do
				kill -0 "$edge_pid" 2>/dev/null || break
				sleep 0.1
			done
			if kill -0 "$edge_pid" 2>/dev/null; then
				warn "designated Caddy did not exit after SIGTERM"
				failures+=("designated Caddy remained running")
			else
				print -r -- "stopped designated deployment Caddy (pid ${edge_pid})"
			fi
		else
			warn "TCP ${EDGE_PORT} listener is not an exact command line owned by this deployment; it was left untouched"
			failures+=("unknown edge listener was left untouched")
		fi
	else
		print -r -- "deployment Caddy edge was not running"
	fi
else
	warn "unable to determine a unique TCP ${EDGE_PORT} listener"
	failures+=("edge listener identity was ambiguous")
fi

if launchctl print "$service_target" >/dev/null 2>&1; then
	failures+=("LaunchAgent renewal remained loaded after shutdown")
fi
if /usr/sbin/lsof -a -nP -iTCP:"$EDGE_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
	failures+=("TCP ${EDGE_PORT} still has a listener after shutdown")
fi
assert_no_nonloopback_tcp_listener 5901 || failures+=("TCP 5901 has a non-loopback listener")
assert_no_nonloopback_tcp_listener 15901 || failures+=("TCP 15901 has a non-loopback listener")

if (( ${#failures[@]} > 0 )); then
	for failure in "${failures[@]}"; do
		warn "$failure"
	done
	die "safe shutdown did not fully verify; the native app and loopback backend were intentionally left untouched"
fi

print -r -- "safe shutdown verified: renewal stopped, NAT-PMP TCP 443 removed, deployment Caddy stopped; native app/backend untouched"
