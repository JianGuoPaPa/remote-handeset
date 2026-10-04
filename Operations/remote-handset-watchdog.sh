#!/bin/zsh
set -u

umask 077

readonly TARGET_SERIAL="ZY22GHBP48"
readonly SECOND_SERIAL="ZY22K2SXMK"
readonly THIRD_SERIAL="ZY22F68DH8"
readonly THIRD_NAME="白摩托"
readonly FOURTH_SERIAL="31629594940010K"
readonly FOURTH_NAME="备用机1"
readonly FIFTH_SERIAL="ZY22GDWXSZ"
readonly FIFTH_NAME="备用机2"
readonly SIXTH_SERIAL="ZY22HN3ZS4"
readonly SIXTH_NAME="备用机3"
readonly SEVENTH_SERIAL="10AD6F2LSY0017B"
readonly SEVENTH_NAME="vivo V2248"
readonly ADB="/opt/homebrew/bin/adb"
readonly LAUNCHCTL="/bin/launchctl"
readonly CURL="/usr/bin/curl"
readonly EXECUTION_MODE="${REMOTE_HANDSET_EXECUTION_MODE:-user-agent}"
readonly SERVICE_USER="${REMOTE_HANDSET_SERVICE_USER:-zhaogongzi}"
readonly SERVICE_GROUP="${REMOTE_HANDSET_SERVICE_GROUP:-staff}"
readonly USER_HOME="${REMOTE_HANDSET_USER_HOME:-/Users/zhaogongzi}"
readonly USER_UID="$(/usr/bin/id -u "${SERVICE_USER}")"
readonly LAUNCH_DOMAIN="${REMOTE_HANDSET_LAUNCH_DOMAIN:-gui/${USER_UID}}"
readonly SERVICE_PLIST_DIR="${REMOTE_HANDSET_SERVICE_PLIST_DIR:-${USER_HOME}/Library/LaunchAgents}"
readonly ADB_RUN_AS_USER="${REMOTE_HANDSET_ADB_RUN_AS_USER:-}"

readonly WEBSCREEN_LABEL="com.remotehandset.webscreen"
readonly TUNNEL_LABEL="com.remotehandset.hk-tunnel"
readonly WEBSCREEN_PLIST="${SERVICE_PLIST_DIR}/${WEBSCREEN_LABEL}.plist"
readonly TUNNEL_PLIST="${SERVICE_PLIST_DIR}/${TUNNEL_LABEL}.plist"

readonly LOCAL_GATEWAY_URL="http://127.0.0.1:8079/"
readonly HONG_KONG_HEALTH_URL="https://70.39.202.192/healthz"
readonly REMOTE_GATEWAY_URL="https://70.39.202.192/screen/ws"

readonly STATE_DIR="${REMOTE_HANDSET_STATE_DIR:-${USER_HOME}/.remote-handset/watchdog}"
readonly LOCK_DIR="${STATE_DIR}/run.lock"
readonly LOCK_PID_FILE="${LOCK_DIR}/pid"
readonly LOG_FILE="${REMOTE_HANDSET_LOG_FILE:-${USER_HOME}/Library/Logs/remote-handset-watchdog.log}"
readonly LOG_DIR="${LOG_FILE%/*}"
readonly STATUS_FILE="${STATE_DIR}/status"
readonly PUBLIC_STATUS_FILE="${REMOTE_HANDSET_PUBLIC_STATUS_FILE:-${STATUS_FILE}}"
readonly PUBLIC_STATUS_DIR="${PUBLIC_STATUS_FILE%/*}"

readonly ADB_COMMAND_TIMEOUT=8
readonly ADB_RECOVERY_TIMEOUT=12
readonly ADB_FAILURES_BEFORE_SERVER_RESTART=3
readonly ADB_SERVER_RESTART_COOLDOWN=300
readonly SERVICE_FAILURES_BEFORE_RESTART=2
readonly WEBSCREEN_RESTART_COOLDOWN=60
readonly TUNNEL_FAILURES_BEFORE_RESTART=4
readonly TUNNEL_RESTART_COOLDOWN=600
readonly WAKE_COOLDOWN=60

PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export PATH

/bin/mkdir -p "${STATE_DIR}" "${LOG_DIR}"

acquire_lock() {
    if /bin/mkdir "${LOCK_DIR}" 2>/dev/null; then
        /usr/bin/printf '%s\n' "$$" > "${LOCK_PID_FILE}"
        return 0
    fi

    local owner_pid owner_command lock_mtime now
    owner_pid="$(/bin/cat "${LOCK_PID_FILE}" 2>/dev/null || true)"
    if [[ "${owner_pid}" == <-> ]] && /bin/kill -0 "${owner_pid}" 2>/dev/null; then
        owner_command="$(/bin/ps -p "${owner_pid}" -o command= 2>/dev/null || true)"
        if [[ "${owner_command}" == *remote-handset-watchdog.sh* ]]; then
            return 1
        fi
    elif [[ -z "${owner_pid}" ]]; then
        # Another instance may be between mkdir(2) and writing its PID.
        lock_mtime="$(/usr/bin/stat -f '%m' "${LOCK_DIR}" 2>/dev/null || print 0)"
        now="$(/bin/date +%s)"
        if (( now - lock_mtime <= 30 )); then
            return 1
        fi
    fi

    /bin/rm -f "${LOCK_PID_FILE}"
    /bin/rmdir "${LOCK_DIR}" 2>/dev/null || return 1
    if ! /bin/mkdir "${LOCK_DIR}" 2>/dev/null; then
        return 1
    fi
    /usr/bin/printf '%s\n' "$$" > "${LOCK_PID_FILE}"
}

release_lock() {
    local owner_pid
    owner_pid="$(/bin/cat "${LOCK_PID_FILE}" 2>/dev/null || true)"
    if [[ "${owner_pid}" == "$$" ]]; then
        /bin/rm -f "${LOCK_PID_FILE}"
        /bin/rmdir "${LOCK_DIR}" 2>/dev/null || true
    fi
}

handle_signal() {
    trap - EXIT
    release_lock
    exit 143
}

if ! acquire_lock; then
    exit 0
fi
trap release_lock EXIT
trap handle_signal INT TERM HUP

trim_log_if_needed() {
    local size
    size="$(/usr/bin/stat -f '%z' "${LOG_FILE}" 2>/dev/null || print 0)"
    if (( size > 1048576 )); then
        /usr/bin/tail -n 1000 "${LOG_FILE}" > "${LOG_FILE}.tmp.$$" 2>/dev/null || return
        /bin/mv -f "${LOG_FILE}.tmp.$$" "${LOG_FILE}"
        if [[ "${EXECUTION_MODE}" == "system-daemon" ]]; then
            /usr/sbin/chown root:"${SERVICE_GROUP}" "${LOG_FILE}" 2>/dev/null || true
            /bin/chmod 640 "${LOG_FILE}" 2>/dev/null || true
        fi
    fi
}

log_event() {
    trim_log_if_needed
    /usr/bin/printf '%s %s\n' "$(/bin/date '+%Y-%m-%d %H:%M:%S%z')" "$*" >> "${LOG_FILE}"
    if [[ "${EXECUTION_MODE}" == "system-daemon" ]]; then
        /usr/sbin/chown root:"${SERVICE_GROUP}" "${LOG_FILE}" 2>/dev/null || true
        /bin/chmod 640 "${LOG_FILE}" 2>/dev/null || true
    fi
}

state_path() {
    /usr/bin/printf '%s/%s' "${STATE_DIR}" "$1"
}

read_state() {
    local path
    path="$(state_path "$1")"
    if [[ -f "${path}" ]]; then
        /bin/cat "${path}" 2>/dev/null
    else
        /usr/bin/printf '%s' "${2:-}"
    fi
}

write_state() {
    local path tmp
    path="$(state_path "$1")"
    tmp="${path}.tmp.$$"
    /usr/bin/printf '%s\n' "$2" > "${tmp}"
    /bin/mv -f "${tmp}" "${path}"
}

increment_counter() {
    local current
    current="$(read_state "$1" 0)"
    [[ "${current}" == <-> ]] || current=0
    current=$(( current + 1 ))
    write_state "$1" "${current}"
    /usr/bin/printf '%s' "${current}"
}

cooldown_elapsed() {
    local last now
    last="$(read_state "$1" 0)"
    [[ "${last}" == <-> ]] || last=0
    now="$(/bin/date +%s)"
    (( now - last >= $2 ))
}

mark_action_time() {
    write_state "$1" "$(/bin/date +%s)"
}

run_with_timeout() {
    local seconds="$1"
    shift
    /usr/bin/perl -e 'alarm shift @ARGV; exec @ARGV or exit 127' "${seconds}" "$@"
}

run_adb_with_timeout() {
    local seconds="$1"
    shift
    if [[ -n "${ADB_RUN_AS_USER}" ]]; then
        /usr/bin/sudo -n -H -u "${ADB_RUN_AS_USER}" -- \
            /usr/bin/env \
            HOME="${USER_HOME}" \
            USER="${SERVICE_USER}" \
            LOGNAME="${SERVICE_USER}" \
            TMPDIR="/tmp" \
            PATH="${PATH}" \
            /usr/bin/perl -e 'alarm shift @ARGV; exec @ARGV or exit 127' \
            "${seconds}" "${ADB}" "$@"
        return
    fi
    run_with_timeout "${seconds}" "${ADB}" "$@"
}

adb_cmd() {
    run_adb_with_timeout "${ADB_COMMAND_TIMEOUT}" "$@"
}

adb_recovery_cmd() {
    run_adb_with_timeout "${ADB_RECOVERY_TIMEOUT}" "$@"
}

label_loaded() {
    "${LAUNCHCTL}" print "${LAUNCH_DOMAIN}/$1" >/dev/null 2>&1
}

label_running() {
    "${LAUNCHCTL}" print "${LAUNCH_DOMAIN}/$1" 2>/dev/null |
        /usr/bin/grep -q 'state = running'
}

ensure_label_loaded() {
    local label="$1"
    local plist="$2"

    if label_loaded "${label}"; then
        return 0
    fi
    if [[ ! -f "${plist}" ]]; then
        log_event "service=${label} state=missing-plist"
        return 1
    fi

    "${LAUNCHCTL}" enable "${LAUNCH_DOMAIN}/${label}" >/dev/null 2>&1 || true
    if "${LAUNCHCTL}" bootstrap "${LAUNCH_DOMAIN}" "${plist}" >/dev/null 2>&1; then
        log_event "service=${label} action=bootstrap result=ok"
        return 2
    fi

    log_event "service=${label} action=bootstrap result=failed"
    return 1
}

restart_label() {
    local label="$1"
    local plist="$2"
    local load_result

    ensure_label_loaded "${label}" "${plist}"
    load_result=$?
    if (( load_result == 1 )); then
        return 1
    fi
    if (( load_result == 2 )); then
        return 0
    fi
    if "${LAUNCHCTL}" kickstart -k "${LAUNCH_DOMAIN}/${label}" >/dev/null 2>&1; then
        log_event "service=${label} action=kickstart result=ok reason=$3"
        return 0
    fi

    log_event "service=${label} action=kickstart result=failed reason=$3"
    return 1
}

http_status() {
    local code
    code="$("${CURL}" -sS -o /dev/null -w '%{http_code}' \
        --connect-timeout 3 \
        --max-time 5 \
        "$1" 2>/dev/null || true)"
    if [[ "${code}" != <-> || "${#code}" -ne 3 ]]; then
        code="000"
    fi
    /usr/bin/printf '%s' "${code}"
}

write_status() {
    local tmp="${STATUS_FILE}.tmp.$$"
    local i
    {
        /usr/bin/printf 'checked_at=%s\n' "$(/bin/date '+%Y-%m-%dT%H:%M:%S%z')"
        /usr/bin/printf 'device_state=%s\n' "$1"
        /usr/bin/printf 'boot_completed=%s\n' "$2"
        /usr/bin/printf 'local_listener_http=%s\n' "$3"
        /usr/bin/printf 'hong_kong_health_http=%s\n' "$4"
        /usr/bin/printf 'proxy_path_http=%s\n' "$5"
        /usr/bin/printf 'last_action=%s\n' "$6"
        /usr/bin/printf 'device_count=%s\n' "${#DEVICE_SERIALS[@]}"
        for (( i = 1; i <= ${#DEVICE_SERIALS[@]}; i++ )); do
            /usr/bin/printf 'dev%s_serial=%s\n' "${i}" "${DEVICE_SERIALS[$i]:-}"
            if [[ -n "${DEVICE_NAMES[$i]:-}" ]]; then
                /usr/bin/printf 'dev%s_name=%s\n' "${i}" "${DEVICE_NAMES[$i]}"
            fi
            /usr/bin/printf 'dev%s_state=%s\n' "${i}" "${DEVICE_STATES[$i]:-unknown}"
            /usr/bin/printf 'dev%s_boot=%s\n' "${i}" "${DEVICE_BOOTS[$i]:-unknown}"
        done
    } > "${tmp}"
    /bin/mv -f "${tmp}" "${STATUS_FILE}"

    if [[ "${PUBLIC_STATUS_FILE}" != "${STATUS_FILE}" && -d "${PUBLIC_STATUS_DIR}" ]]; then
        local public_tmp="${PUBLIC_STATUS_FILE}.tmp.$$"
        if /usr/bin/install -m 644 -o "${SERVICE_USER}" -g "${SERVICE_GROUP}" \
            "${STATUS_FILE}" "${public_tmp}" 2>/dev/null; then
            /bin/mv -f "${public_tmp}" "${PUBLIC_STATUS_FILE}"
        else
            /bin/rm -f "${public_tmp}"
        fi
    fi
}

last_action="none"
previous_device_state="$(read_state device-state '')"
device_state="adb-unavailable"
boot_completed="unknown"

if [[ ! -x "${ADB}" ]]; then
    if [[ "${previous_device_state}" != "${device_state}" ]]; then
        log_event "device=${TARGET_SERIAL} state=${device_state}"
    fi
else
    if adb_output="$(adb_cmd devices 2>/dev/null)"; then
        device_state="$(/usr/bin/printf '%s\n' "${adb_output}" | /usr/bin/awk -v serial="${TARGET_SERIAL}" '$1 == serial { print $2; found=1; exit } END { if (!found) print "missing" }')"
    else
        adb_output=""
        device_state="adb-error"
    fi
    other_online_devices="$(/usr/bin/printf '%s\n' "${adb_output}" | /usr/bin/awk -v serial="${TARGET_SERIAL}" 'NR > 1 && $1 != serial && $2 == "device" { count++ } END { print count+0 }')"

    if [[ "${device_state}" == "device" ]]; then
        if boot_completed_raw="$(adb_cmd -s "${TARGET_SERIAL}" shell getprop sys.boot_completed 2>/dev/null)"; then
            boot_completed="$(/usr/bin/printf '%s' "${boot_completed_raw}" | /usr/bin/tr -d '\r\n')"
        else
            boot_completed="error"
            device_state="adb-shell-error"
        fi
        if [[ "${device_state}" == "device" && "${boot_completed}" != "1" ]]; then
            device_state="booting"
        fi
    fi

    if [[ "${device_state}" != "${previous_device_state}" ]]; then
        log_event "device=${TARGET_SERIAL} state=${device_state} previous=${previous_device_state:-unknown}"
    fi

    case "${device_state}" in
        device)
            write_state adb-failures 0

            if stay_on_raw="$(adb_cmd -s "${TARGET_SERIAL}" shell settings get global stay_on_while_plugged_in 2>/dev/null)"; then
                stay_on="$(/usr/bin/printf '%s' "${stay_on_raw}" | /usr/bin/tr -d '\r\n')"
                if [[ "${stay_on}" != "7" ]]; then
                    if adb_cmd -s "${TARGET_SERIAL}" shell settings put global stay_on_while_plugged_in 7 >/dev/null 2>&1; then
                        log_event "device=${TARGET_SERIAL} action=enforce-stay-awake result=ok previous=${stay_on:-unknown}"
                        last_action="enforce-stay-awake"
                    else
                        log_event "device=${TARGET_SERIAL} action=enforce-stay-awake result=failed"
                    fi
                fi
            fi

            battery_raw=""
            power_raw=""
            battery_ok=0
            power_ok=0
            if battery_raw="$(adb_cmd -s "${TARGET_SERIAL}" shell dumpsys battery 2>/dev/null)"; then
                battery_ok=1
            fi
            if power_raw="$(adb_cmd -s "${TARGET_SERIAL}" shell dumpsys power 2>/dev/null)"; then
                power_ok=1
            fi
            powered="$(/usr/bin/printf '%s\n' "${battery_raw}" | /usr/bin/awk '/(AC|USB|Wireless) powered: true/ { powered=1 } END { print powered+0 }')"
            wakefulness="$(/usr/bin/printf '%s\n' "${power_raw}" | /usr/bin/awk -F= '/mWakefulness=/ { gsub(/[[:space:]]/, "", $2); print $2; exit }')"
            if (( battery_ok == 1 && power_ok == 1 )) &&
                  [[ "${powered}" == "1" && "${wakefulness}" != "Awake" ]] &&
                  cooldown_elapsed last-wake "${WAKE_COOLDOWN}"; then
                if adb_cmd -s "${TARGET_SERIAL}" shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1; then
                    mark_action_time last-wake
                    log_event "device=${TARGET_SERIAL} action=wake result=ok previous=${wakefulness:-unknown}"
                    last_action="wake-device"
                else
                    log_event "device=${TARGET_SERIAL} action=wake result=failed previous=${wakefulness:-unknown}"
                fi
            fi

            if [[ -n "${previous_device_state}" &&
                  "${previous_device_state}" != "device" &&
                  "${previous_device_state}" != "booting" ]] &&
                  cooldown_elapsed last-webscreen-restart "${WEBSCREEN_RESTART_COOLDOWN}"; then
                if [[ "$(http_status 'http://127.0.0.1:8080/healthz/android-recovery')" == "204" ]]; then
                    log_event "device=${TARGET_SERIAL} action=restore-agent result=delegated-to-gateway reason=adb-recovered"
                    last_action="gateway-in-place-recovery"
                elif restart_label "${WEBSCREEN_LABEL}" "${WEBSCREEN_PLIST}" "adb-recovered"; then
                    mark_action_time last-webscreen-restart
                    last_action="restart-webscreen-after-adb-recovery"
                fi
            elif [[ "${previous_device_state}" == "booting" ]] &&
                  cooldown_elapsed last-webscreen-restart "${WEBSCREEN_RESTART_COOLDOWN}"; then
                if [[ "$(http_status 'http://127.0.0.1:8080/healthz/android-recovery')" == "204" ]]; then
                    log_event "device=${TARGET_SERIAL} action=restore-agent result=delegated-to-gateway reason=android-boot-completed"
                    last_action="gateway-in-place-recovery"
                elif restart_label "${WEBSCREEN_LABEL}" "${WEBSCREEN_PLIST}" "android-boot-completed"; then
                    mark_action_time last-webscreen-restart
                    last_action="restart-webscreen-after-boot"
                fi
            fi
            ;;

        booting)
            write_state adb-failures 0
            ;;

        unauthorized)
            increment_counter adb-failures >/dev/null
            ;;

        offline|missing|*)
            adb_failures="$(increment_counter adb-failures)"
            if [[ "${device_state}" == "offline" ]]; then
                adb_recovery_cmd -s "${TARGET_SERIAL}" reconnect >/dev/null 2>&1 || true
            else
                adb_recovery_cmd start-server >/dev/null 2>&1 || true
            fi

            if (( adb_failures >= ADB_FAILURES_BEFORE_SERVER_RESTART )) &&
                  cooldown_elapsed last-adb-server-restart "${ADB_SERVER_RESTART_COOLDOWN}"; then
                if (( other_online_devices == 0 )); then
                    adb_recovery_cmd kill-server >/dev/null 2>&1 || true
                    /bin/sleep 2
                    if adb_recovery_cmd start-server >/dev/null 2>&1; then
                        mark_action_time last-adb-server-restart
                        log_event "device=${TARGET_SERIAL} action=restart-adb-server result=ok failures=${adb_failures}"
                        last_action="restart-adb-server"
                    else
                        log_event "device=${TARGET_SERIAL} action=restart-adb-server result=failed failures=${adb_failures}"
                    fi
                else
                    log_event "device=${TARGET_SERIAL} action=restart-adb-server result=skipped other_online_devices=${other_online_devices}"
                    mark_action_time last-adb-server-restart
                fi
            fi
            ;;
    esac
fi

write_state device-state "${device_state}"

ensure_label_loaded "${WEBSCREEN_LABEL}" "${WEBSCREEN_PLIST}"
webscreen_load_result=$?
if (( webscreen_load_result == 2 )); then
    write_state local-gateway-failures 0
fi
local_http="$(http_status "${LOCAL_GATEWAY_URL}")"
if [[ "${local_http}" == "401" ]]; then
    write_state local-gateway-failures 0
elif (( webscreen_load_result == 0 )); then
    local_failures="$(increment_counter local-gateway-failures)"
    if (( local_failures >= SERVICE_FAILURES_BEFORE_RESTART )) &&
          cooldown_elapsed last-webscreen-restart "${WEBSCREEN_RESTART_COOLDOWN}"; then
        if restart_label "${WEBSCREEN_LABEL}" "${WEBSCREEN_PLIST}" "local-http-${local_http}"; then
            mark_action_time last-webscreen-restart
            last_action="restart-webscreen-local-health"
        fi
    fi
fi

ensure_label_loaded "${TUNNEL_LABEL}" "${TUNNEL_PLIST}"
tunnel_load_result=$?
if (( tunnel_load_result == 2 )); then
    write_state remote-gateway-failures 0
fi
hong_kong_http="skipped"
remote_http="skipped"
if [[ "${local_http}" == "401" && "${last_action}" != restart-webscreen-* ]]; then
    hong_kong_http="$(http_status "${HONG_KONG_HEALTH_URL}")"
    previous_hong_kong_http="$(read_state hong-kong-health-http '')"
    if [[ "${hong_kong_http}" != "${previous_hong_kong_http}" ]]; then
        log_event "endpoint=hong-kong-health state=http-${hong_kong_http} previous=http-${previous_hong_kong_http:-unknown}"
    fi
    write_state hong-kong-health-http "${hong_kong_http}"

    if [[ "${hong_kong_http}" == "204" ]]; then
        remote_http="$(http_status "${REMOTE_GATEWAY_URL}")"
        if [[ "${remote_http}" == "401" ]]; then
            write_state remote-gateway-failures 0
        elif (( tunnel_load_result == 0 )); then
            remote_failures="$(increment_counter remote-gateway-failures)"
            tunnel_is_running=0
            if label_running "${TUNNEL_LABEL}"; then
                tunnel_is_running=1
            fi
            if (( (tunnel_is_running == 0 && remote_failures >= SERVICE_FAILURES_BEFORE_RESTART) ||
                  remote_failures >= TUNNEL_FAILURES_BEFORE_RESTART )) &&
                  cooldown_elapsed last-tunnel-restart "${TUNNEL_RESTART_COOLDOWN}"; then
                if restart_label "${TUNNEL_LABEL}" "${TUNNEL_PLIST}" "proxy-http-${remote_http}"; then
                    mark_action_time last-tunnel-restart
                    last_action="restart-hk-tunnel"
                fi
            fi
        fi
    else
        remote_http="server-unreachable"
        write_state remote-gateway-failures 0
    fi
fi

# Record the primary phone and probe/maintain every auxiliary phone.
typeset -a DEVICE_SERIALS DEVICE_NAMES DEVICE_STATES DEVICE_BOOTS
DEVICE_SERIALS=(
    "${TARGET_SERIAL}"
    "${SECOND_SERIAL}"
    "${THIRD_SERIAL}"
    "${FOURTH_SERIAL}"
    "${FIFTH_SERIAL}"
    "${SIXTH_SERIAL}"
    "${SEVENTH_SERIAL}"
)
DEVICE_NAMES=(
    ""
    ""
    "${THIRD_NAME}"
    "${FOURTH_NAME}"
    "${FIFTH_NAME}"
    "${SIXTH_NAME}"
    "${SEVENTH_NAME}"
)
DEVICE_STATES=("${device_state}" "missing" "missing" "missing" "missing" "missing" "missing")
DEVICE_BOOTS=("${boot_completed}" "unknown" "unknown" "unknown" "unknown" "unknown" "unknown")

probe_auxiliary_device() {
    local index="$1"
    local serial="${DEVICE_SERIALS[$index]}"
    local state boot raw stay_on

    state="$(/usr/bin/printf '%s\n' "${adb_devices_output}" | /usr/bin/awk -v s="${serial}" '$1==s{print $2; f=1; exit} END{if(!f)print "missing"}')"
    boot="unknown"
    if [[ "${state}" == "device" ]]; then
        if raw="$(adb_cmd -s "${serial}" shell getprop sys.boot_completed 2>/dev/null)"; then
            boot="$(/usr/bin/printf '%s' "${raw}" | /usr/bin/tr -d '\r\n')"
        fi
        if [[ "${boot}" != "1" ]]; then
            state="booting"
        fi

        stay_on="$(adb_cmd -s "${serial}" shell settings get global stay_on_while_plugged_in 2>/dev/null | /usr/bin/tr -d '\r\n')"
        if [[ "${stay_on}" != "7" ]]; then
            if adb_cmd -s "${serial}" shell settings put global stay_on_while_plugged_in 7 >/dev/null 2>&1; then
                log_event "device=${serial} name=${DEVICE_NAMES[$index]} action=enforce-stay-awake result=ok previous=${stay_on:-unknown}"
            fi
        fi
    fi
    DEVICE_STATES[$index]="${state}"
    DEVICE_BOOTS[$index]="${boot}"
}

if [[ -x "${ADB}" ]]; then
    adb_devices_output="$(adb_cmd devices 2>/dev/null || true)"
    for (( i = 2; i <= ${#DEVICE_SERIALS[@]}; i++ )); do
        probe_auxiliary_device "${i}"
    done
fi

# Aggregate state is healthy only when all managed phones are connected and booted.
all_devices_ready=1
for (( i = 1; i <= ${#DEVICE_SERIALS[@]}; i++ )); do
    if [[ "${DEVICE_STATES[$i]}" != "device" || "${DEVICE_BOOTS[$i]}" != "1" ]]; then
        all_devices_ready=0
        break
    fi
done
if (( all_devices_ready == 0 )); then
    device_state="missing"
fi

write_status "${device_state}" "${boot_completed}" "${local_http}" "${hong_kong_http}" "${remote_http}" "${last_action}"
