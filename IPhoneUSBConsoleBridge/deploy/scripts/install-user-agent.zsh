#!/bin/zsh
set -euo pipefail

SCRIPT_DIRECTORY="${0:A:h}"
PROJECT_DIRECTORY="${SCRIPT_DIRECTORY:h:h}"
SOURCE_APP="${1:-${PROJECT_DIRECTORY}/build/Release/iPhone USB Driver.app}"
INSTALL_DIRECTORY="${HOME}/Applications/RemoteHandset"
INSTALL_APP="${INSTALL_DIRECTORY}/iPhone USB Driver.app"
STATE_DIRECTORY="${HOME}/.remote-handset/iphone-console"
LOG_DIRECTORY="${STATE_DIRECTORY}/logs"
WATCHDOG_PATH="${STATE_DIRECTORY}/watchdog.zsh"
AGENT_DIRECTORY="${HOME}/Library/LaunchAgents"
CONSOLE_PLIST="${AGENT_DIRECTORY}/local.iphone.usbconsole.plist"
WATCHDOG_PLIST="${AGENT_DIRECTORY}/local.iphone.usbconsole-watchdog.plist"
DOMAIN="gui/${UID}"

if [[ ! -d "${SOURCE_APP}" ]]; then
  echo "Built application not found: ${SOURCE_APP}" >&2
  exit 1
fi
/usr/bin/codesign --verify --deep --strict "${SOURCE_APP}"

mkdir -p "${INSTALL_DIRECTORY}" "${AGENT_DIRECTORY}" "${LOG_DIRECTORY}"
/bin/chmod 700 "${STATE_DIRECTORY}" "${LOG_DIRECTORY}"
/usr/bin/ditto "${SOURCE_APP}" "${INSTALL_APP}.new"
/bin/rm -rf -- "${INSTALL_APP}.previous"
if [[ -d "${INSTALL_APP}" ]]; then
  /bin/mv "${INSTALL_APP}" "${INSTALL_APP}.previous"
fi
/bin/mv "${INSTALL_APP}.new" "${INSTALL_APP}"

/bin/cp "${SCRIPT_DIRECTORY}/watchdog.zsh" "${WATCHDOG_PATH}"
/bin/chmod 700 "${WATCHDOG_PATH}"

executable_path="${INSTALL_APP}/Contents/MacOS/IPhoneUSBDriver"
/usr/bin/sed \
  -e "s|__EXECUTABLE_PATH__|${executable_path}|g" \
  -e "s|__LOG_DIRECTORY__|${LOG_DIRECTORY}|g" \
  "${PROJECT_DIRECTORY}/deploy/launchd/local.iphone.usbconsole.plist.template" \
  > "${CONSOLE_PLIST}.new"
/usr/bin/sed \
  -e "s|__WATCHDOG_PATH__|${WATCHDOG_PATH}|g" \
  -e "s|__LOG_DIRECTORY__|${LOG_DIRECTORY}|g" \
  "${PROJECT_DIRECTORY}/deploy/launchd/local.iphone.usbconsole-watchdog.plist.template" \
  > "${WATCHDOG_PLIST}.new"
/bin/chmod 600 "${CONSOLE_PLIST}.new" "${WATCHDOG_PLIST}.new"
/bin/mv "${CONSOLE_PLIST}.new" "${CONSOLE_PLIST}"
/bin/mv "${WATCHDOG_PLIST}.new" "${WATCHDOG_PLIST}"
/usr/bin/plutil -lint "${CONSOLE_PLIST}" "${WATCHDOG_PLIST}"

/bin/launchctl bootout "${DOMAIN}/local.iphone.usbconsole-watchdog" 2>/dev/null || true
/bin/launchctl bootout "${DOMAIN}/local.iphone.usbconsole" 2>/dev/null || true
/bin/launchctl bootstrap "${DOMAIN}" "${CONSOLE_PLIST}"
/bin/launchctl bootstrap "${DOMAIN}" "${WATCHDOG_PLIST}"
/bin/launchctl enable "${DOMAIN}/local.iphone.usbconsole"
/bin/launchctl enable "${DOMAIN}/local.iphone.usbconsole-watchdog"
/bin/launchctl kickstart -k "${DOMAIN}/local.iphone.usbconsole"

echo "Installed ${INSTALL_APP}"
