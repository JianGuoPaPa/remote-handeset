#!/usr/bin/env python3
"""Sequential local wireless acceptance. Default is a plan; --run performs it.

Read-only browser media/telemetry, except one permitted 0x10 keyframe request.
The management API changes the named phone's connection preference only.
No ADB commands, service restarts, business input or remote URLs are used.
"""
import argparse
import fcntl
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parent
CLI = Path.home() / '.npm/_npx/6de2aa2fded2970c/node_modules/agent-browser/bin/agent-browser-darwin-arm64'
SESSION = 'handset-seven-wireless'
MANAGEMENT = 'http://127.0.0.1:8079/api/device/connection'
# A JSON page creates no automatic default-phone preview connection.
PREVIEW = 'http://127.0.0.1:8080/preview/config'
DEVICES = ('ZY22GHBP48', 'ZY22K2SXMK', 'ZY22GDWXSZ', 'ZY22HN3ZS4',
           '31629594940010K', '10AD6F2LSY0017B', 'ZY22F68DH8')


def emit(event, **details):
    print(json.dumps({'event': event, **details}, ensure_ascii=False), flush=True)


def save(path, value):
    temporary = path.with_suffix(path.suffix + '.tmp')
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')
    os.replace(temporary, path)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args):
        raise RuntimeError('management_redirect_refused')


class GatewayInstanceChanged(RuntimeError):
    pass


class Gateway:
    def __init__(self):
        secret = (Path.home() / '.remote-handset/origin-secret').read_text().strip()
        if not secret:
            raise RuntimeError('origin_secret_unavailable')
        self.headers = {'X-Webscreen-Origin-Secret': secret}
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
        self.instance_id = None

    def check_instance(self, state):
        instance_id = state.get('instance_id')
        if not instance_id:
            raise GatewayInstanceChanged('gateway_instance_missing')
        if self.instance_id is None:
            self.instance_id = instance_id
        elif self.instance_id != instance_id:
            raise GatewayInstanceChanged('gateway_instance_changed_stop')

    def request(self, device, payload=None):
        if device not in DEVICES:
            raise RuntimeError('device_not_in_acceptance_allowlist')
        url = MANAGEMENT + ('?' + urllib.parse.urlencode({'device_id': device}) if payload is None else '')
        headers = dict(self.headers)
        if payload is not None:
            headers['Content-Type'] = 'application/json'
        request = urllib.request.Request(url, headers=headers,
            data=json.dumps(payload).encode() if payload is not None else None,
            method='POST' if payload is not None else 'GET')
        try:
            with self.opener.open(request, timeout=12) as response:
                state = json.load(response)
        except urllib.error.HTTPError as error:
            raise RuntimeError('management_http_' + str(error.code)) from None
        except (OSError, ValueError):
            raise RuntimeError('management_request_failed') from None
        if not isinstance(state, dict) or state.get('device_id') != device:
            raise RuntimeError('management_device_mismatch')
        self.check_instance(state)
        return state

    def settled(self, device, timeout=100):
        deadline, last_report, last = time.monotonic() + timeout, 0, None
        while time.monotonic() < deadline:
            try:
                last = self.request(device)
                if last.get('state') != 'switching':
                    return last
            except GatewayInstanceChanged:
                raise
            except RuntimeError:
                pass
            now = time.monotonic()
            if now - last_report >= 10:
                emit('awaiting_switch', device=device, remaining_seconds=max(0, round(deadline-now)))
                last_report = now
            time.sleep(2)
        raise RuntimeError('switch_settle_timeout')

    def switch(self, device, preference):
        if preference not in ('wifi', 'auto'):
            raise RuntimeError('unsupported_preference')
        initial = self.settled(device)
        if not initial.get('wireless_configured'):
            raise RuntimeError('wireless_not_configured')
        payload = {'device_id': device, 'preference': preference,
                   'expected_generation': initial['generation'],
                   'expected_instance_id': initial['instance_id']}
        # Never repeat an uncertain POST. Caller reconciles with GET and restores auto.
        accepted = self.request(device, payload)
        final = self.settled(device)
        record = {'before': initial, 'accepted': accepted, 'final': final}
        if final.get('state') != 'ready' or final.get('preference') != preference:
            raise RuntimeError('switch_did_not_complete_' + preference)
        expected = 'wifi' if preference == 'wifi' else 'usb'
        if final.get('active_transport') != expected:
            raise RuntimeError('unexpected_active_transport_' + preference)
        return record

    def recover_auto(self, device):
        state = self.settled(device)
        if state.get('preference') == 'auto' and state.get('state') == 'ready' and state.get('active_transport') == 'usb':
            return {'already_auto_usb': True, 'final': state}
        return self.switch(device, 'auto')


class Browser:
    def command(self, *args, stdin=None, timeout=32):
        try:
            result = subprocess.run([str(CLI), '--session', SESSION, '--json', *args],
                input=stdin, text=True, capture_output=True, timeout=timeout)
        except (OSError, subprocess.TimeoutExpired):
            raise RuntimeError('browser_command_failed_' + args[0]) from None
        try:
            envelope = json.loads(result.stdout)
        except ValueError:
            raise RuntimeError('browser_invalid_json_' + args[0]) from None
        if result.returncode or envelope.get('success') is False:
            raise RuntimeError('browser_command_rejected_' + args[0])
        data = envelope.get('data', envelope)
        return data.get('result', data) if isinstance(data, dict) else data

    def open(self):
        self.command('open', PREVIEW)
        self.command('snapshot', '-i')

    def probe(self, device):
        script = (ROOT / 'wireless-video-probe.js').read_text().replace('__DEVICE_ID_JSON__', json.dumps(device))
        result = self.command('eval', '--stdin', stdin=script)
        if isinstance(result, str):
            result = json.loads(result)
        if not isinstance(result, dict) or result.get('device') != device:
            raise RuntimeError('browser_probe_device_mismatch')
        return result

    def close(self):
        self.command('close', timeout=12)


def run_fleet(api, browser, directory, devices=DEVICES):
    report = {'started_at': int(time.time()), 'session': SESSION, 'devices': [], 'ok': False}
    current, touched, browser_started = None, False, False
    try:
        for device in devices:
            state = api.request(device)
            if not all(state.get(key) for key in ('wireless_configured', 'wifi_available', 'usb_available')):
                raise RuntimeError('preflight_missing_usb_or_wifi_' + device)
            if state.get('state') == 'switching':
                raise RuntimeError('preflight_device_already_switching_' + device)
        browser_started = True
        browser.open()
        for device in devices:
            current, touched = device, False
            row = {'device': device}
            report['devices'].append(row)
            emit('device_begin', device=device)
            touched = True  # POST can succeed even if its response is lost.
            row['wifi_switch'] = api.switch(device, 'wifi')
            emit('wifi_active', device=device)
            row['wifi_video'] = browser.probe(device)
            if not row['wifi_video'].get('ok'):
                raise RuntimeError('wireless_video_or_control_failed')
            emit('wifi_video_ok', device=device, video=row['wifi_video']['video'])
            row['auto_switch'] = api.switch(device, 'auto')
            emit('auto_usb_active', device=device)
            row['auto_video'] = browser.probe(device)
            if not row['auto_video'].get('ok'):
                raise RuntimeError('auto_usb_video_or_control_failed')
            row['ok'] = True
            touched = False
            save(directory / (device + '.json'), row)
            save(directory / 'summary.json', report)
            emit('device_pass', device=device, video=row['auto_video']['video'])
        report['ok'] = True
    except (Exception, KeyboardInterrupt) as error:
        report['error'] = str(error)[:180] if isinstance(error, RuntimeError) else type(error).__name__
        emit('acceptance_stopped', device=current, reason=report['error'])
        if current and touched:
            try:
                report['auto_recovery'] = api.recover_auto(current)
                emit('failure_recovered_auto_usb', device=current)
            except Exception as recovery_error:
                report['auto_recovery_error'] = str(recovery_error)[:180] if isinstance(recovery_error, RuntimeError) else type(recovery_error).__name__
                emit('auto_recovery_unconfirmed', device=current)
    finally:
        if browser_started:
            try:
                browser.close()
            except Exception:
                report['browser_close_error'] = True
                report['ok'] = False
        report['completed_at'] = int(time.time())
        save(directory / 'summary.json', report)
    return report


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run', action='store_true', help='execute only after gateway deployment')
    parser.add_argument('--devices', nargs='+', choices=DEVICES, default=list(DEVICES),
                        help='ordered subset of the seven enrolled phones')
    args = parser.parse_args(argv)
    if len(set(args.devices)) != len(args.devices):
        parser.error('--devices must not contain duplicate serials')
    return args


def main():
    args = parse_args()
    if not args.run:
        emit('plan_only_no_connections', devices=args.devices, session=SESSION, browser_url=PREVIEW,
             sequence='each phone: wifi + decoded video/control; auto/USB + decoded video/control')
        return 0
    os.umask(0o077)
    with (ROOT / 'acceptance.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        directory = ROOT / time.strftime('run-%Y%m%d-%H%M%S')
        directory.mkdir()
        def interrupted(*_):
            raise KeyboardInterrupt()
        signal.signal(signal.SIGTERM, interrupted)
        emit('run_started', directory=str(directory))
        result = run_fleet(Gateway(), Browser(), directory, devices=args.devices)
        emit('run_complete', ok=result['ok'], directory=str(directory))
        return 0 if result['ok'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
