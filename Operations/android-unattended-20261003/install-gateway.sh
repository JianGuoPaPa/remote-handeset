#!/bin/zsh
set -euo pipefail
readonly release_dir="${0:A:h}"
readonly bin_path="/Users/zhaogongzi/.local/bin/webscreen-secure"
readonly old_hash="a8a16203be917949ffb2d46b16895a41df43b95ba5a3d3e261a5989daff42ec8"
readonly new_hash="bccdb2c3c9f4fd1a7972e6b10ad943a1d50eda82c43d1e22d491c69ca5765d1a"
[[ "$(/usr/bin/id -un)" == zhaogongzi ]]
[[ $# -eq 0 || ( $# -eq 1 && "$1" == --allow-active-reconnect ) ]]
readonly allow_active="${1:-}"

check_hash() {
    [[ -f "$1" && ! -L "$1" && "$(/usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}')" == "$2" ]]
}

ensure_idle() {
    [[ "${allow_active}" == --allow-active-reconnect ]] && return 0
    local connections
    # An SSH-forwarded WebSocket or another preview client is a live session.
    # The desktop status widget alone is not a handset user.
    connections="$(/usr/sbin/lsof -nP -iTCP:8079 -iTCP:8080 -sTCP:ESTABLISHED -Fpc || true)"
    if ! /usr/bin/printf '%s\n' "${connections}" | /usr/bin/awk '
        /^c/ && $0 != "cwebscreen-secure" && $0 != "cServiceStatusWidget" {bad=1}
        END {exit bad}'; then
        print -u2 'DEPLOYMENT_DEFERRED_ACTIVE_SESSION'
        return 1
    fi
}

check_hash "${release_dir}/webscreen-secure" "${new_hash}"
check_hash "${bin_path}" "${old_hash}"
gateway_pid="$(/bin/launchctl print system/com.remotehandset.webscreen | /usr/bin/awk '/^[[:space:]]*pid = / {print $3; exit}')"
[[ "${gateway_pid}" == <-> ]]
[[ "$(/bin/ps -p "${gateway_pid}" -o comm=)" == "${bin_path}" ]]
ensure_idle
backup_dir="$(/usr/bin/mktemp -d /Users/zhaogongzi/.remote-handset/backups/seven-wireless-20261003.XXXXXX)"
/usr/bin/install -m 700 "${bin_path}" "${backup_dir}/webscreen-secure"
check_hash "${backup_dir}/webscreen-secure" "${old_hash}"
gateway_stage="$(/usr/bin/mktemp /Users/zhaogongzi/.local/bin/webscreen-secure.new.XXXXXX)"
/usr/bin/install -m 700 "${release_dir}/webscreen-secure" "${gateway_stage}"
check_hash "${gateway_stage}" "${new_hash}"
ensure_idle
[[ "$(/bin/ps -p "${gateway_pid}" -o comm=)" == "${bin_path}" ]]
check_hash "${bin_path}" "${old_hash}"
/bin/mv -f "${gateway_stage}" "${bin_path}"
/bin/kill -TERM "${gateway_pid}"
print "GATEWAY_INSTALLED previous_pid=${gateway_pid} backup=${backup_dir} sha256=${new_hash}"
