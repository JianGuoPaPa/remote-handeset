#!/bin/zsh
set -euo pipefail

STATE_DIRECTORY="${HOME}/.remote-handset/iphone-console"
STATUS_PATH="${STATE_DIRECTORY}/status"
LAST_KICK_PATH="${STATE_DIRECTORY}/watchdog-last-kick"
MAX_STATUS_AGE_SECONDS=60
MIN_KICK_INTERVAL_SECONDS=60
SERVICE_LABEL="local.iphone.usbconsole"

mkdir -p -m 700 "${STATE_DIRECTORY}"
now="$(/bin/date +%s)"
status_mtime=0
if [[ -f "${STATUS_PATH}" ]]; then
  status_mtime="$(/usr/bin/stat -f %m "${STATUS_PATH}" 2>/dev/null || echo 0)"
fi
if (( now - status_mtime <= MAX_STATUS_AGE_SECONDS )); then
  exit 0
fi

last_kick=0
if [[ -f "${LAST_KICK_PATH}" ]]; then
  IFS= read -r last_kick < "${LAST_KICK_PATH}" || last_kick=0
fi
if [[ ! "${last_kick}" =~ '^[0-9]+$' ]] || (( now - last_kick < MIN_KICK_INTERVAL_SECONDS )); then
  exit 0
fi

/bin/launchctl kickstart -k "gui/${UID}/${SERVICE_LABEL}"
/usr/bin/printf '%s\n' "${now}" > "${LAST_KICK_PATH}"
/bin/chmod 600 "${LAST_KICK_PATH}"
