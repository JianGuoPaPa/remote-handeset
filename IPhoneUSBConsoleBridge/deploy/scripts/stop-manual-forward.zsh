#!/bin/zsh

set -euo pipefail
source "${0:A:h}/common.zsh"

root="$(deploy_root)"
config="${root}/Caddyfile.manual-forward"
caddy_path="$(command -v caddy 2>/dev/null || true)"

edge_pid="$(/usr/bin/python3 - "$EDGE_PORT" <<'PY'
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
)" || die "unable to determine a unique TCP ${EDGE_PORT} listener"

if [[ -z "$edge_pid" ]]; then
	print -r -- "manual-forward edge was not running"
	exit 0
fi
[[ -n "$caddy_path" ]] || die "Caddy is unavailable, so the listener identity cannot be verified"

command_line="$(ps -ww -p "$edge_pid" -o command= 2>/dev/null || true)"
/usr/bin/python3 - "$command_line" "$caddy_path" "$config" <<'PY' || \
	die "TCP 18443 is not the designated manual-forward Caddy process and was left untouched"
import os
import shlex
import sys

command_line, caddy_path, expected_config = sys.argv[1:]
arguments = shlex.split(command_line)
if len(arguments) != 6:
    raise SystemExit(1)
if arguments[0] != "caddy" and os.path.realpath(arguments[0]) != os.path.realpath(caddy_path):
    raise SystemExit(1)
if arguments[1:] != ["run", "--config", expected_config, "--adapter", "caddyfile"]:
    raise SystemExit(1)
PY

kill -TERM "$edge_pid"
for attempt in {1..50}; do
	kill -0 "$edge_pid" 2>/dev/null || break
	sleep 0.1
done
kill -0 "$edge_pid" 2>/dev/null && die "designated manual-forward Caddy did not exit"
if /usr/sbin/lsof -a -nP -iTCP:"$EDGE_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
	die "TCP ${EDGE_PORT} still has a listener after shutdown"
fi
print -r -- "stopped manual-forward Caddy; router mapping and native app were not modified"
