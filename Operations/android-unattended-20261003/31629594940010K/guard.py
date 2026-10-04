#!/usr/bin/env python3
"""One conservative recovery pass for a configured Android phone; never restart shared ADB.

The initial address is only a hint for an ALREADY connected transport. New
connections require a verified USB wlan0 address, verified cache, or target
mDNS advertisement. All candidate addresses must be on an active local subnet.
"""
import argparse
import fcntl
import ipaddress
import json
import os
from pathlib import Path
import re
import subprocess
import time

ADB = "/opt/homebrew/bin/adb"
SERIAL = '31629594940010K'
INITIAL = ""  # Populate from the new phone after USB identity verification.
COOLDOWN = 300
SYSTEM_TRUST_GATE = True
TRUSTED_BSSIDS = set()  # Populate with the new site's explicitly trusted Wi-Fi BSSIDs.
SETTINGS = {"adb_allowed_connection_time": "0", "stay_on_while_plugged_in": "7", "wifi_sleep_policy": "2"}


def execute(argv):
    try:
        result = subprocess.run(argv, capture_output=True, text=True, timeout=8)
    except subprocess.TimeoutExpired:
        raise RuntimeError("command_timeout") from None
    if result.returncode:
        raise RuntimeError("command_failed")
    return result.stdout.strip()


def read_json(path):
    try:
        value = json.loads(path.read_text())
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}


def atomic_json(path, value):
    temporary = path.with_name(path.name + ".tmp")
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as stream:
        json.dump(value, stream, ensure_ascii=False, indent=2)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)


def local_networks(text):
    networks = []
    for block in re.split(r"(?m)(?=^\S+: flags=)", text):
        header = block.splitlines()[0] if block.splitlines() else ""
        if not re.search(r"[<,]UP[,>]", header):
            continue
        if "LOOPBACK" in header or "POINTOPOINT" in header or "status: inactive" in block:
            continue
        for address, mask in re.findall(r"\binet (\S+) netmask (\S+)", block):
            try:
                if mask.startswith("0x"):
                    mask = str(ipaddress.IPv4Address(int(mask, 16)))
                networks.append(ipaddress.IPv4Network(address + "/" + mask, strict=False))
            except ValueError:
                pass
    return networks


def local_endpoint(endpoint, networks):
    match = re.fullmatch(r"(\d+\.\d+\.\d+\.\d+):(\d+)", endpoint)
    if not match or not 1 <= int(match[2]) <= 65535:
        return False
    try:
        address = ipaddress.IPv4Address(match[1])
        return not address.is_loopback and any(address in network for network in networks)
    except ValueError:
        return False


def candidate_plan(candidates, known, devices, networks, cursor, skip_tcp=False):
    # Keep three bounded probes, but reserve both recovery and exploration.
    # An already-connected, previously verified link is cheap and dependable.
    ordered = list(dict.fromkeys(e for e in candidates if local_endpoint(e, networks)
                                and not (skip_tcp and e.endswith(":5555"))))
    if not ordered:
        return [], 0
    cursor = cursor if isinstance(cursor, int) and not isinstance(cursor, bool) and cursor >= 0 else 0
    connected = [e for e in known if e in ordered and devices.get(e) == "device"]
    plan = connected[:1]
    rotated = ordered[cursor % len(ordered):] + ordered[:cursor % len(ordered)]
    explored = 0
    if not plan:
        plan.append(rotated[0])
        explored += 1
    tcp = [e for e in ordered if e.endswith(":5555")]
    if tcp and not any(e.endswith(":5555") for e in plan):
        plan.append(tcp[cursor % len(tcp)])
    for endpoint in rotated:
        if endpoint not in plan:
            plan.append(endpoint)
            explored += 1
        if len(plan) == 3:
            break
    return plan, cursor + max(1, explored)


def wifi_network_observation(status):
    # This fingerprint only suppresses repeated Android approval prompts. It
    # never grants network trust or bypasses the platform's trusted-AP check.
    ssid = re.search(r"\bSSID:\s*(.*?),\s*BSSID:", status)
    frequency = re.search(r"\bFrequency:\s*(\d+)\s*(?:MHz)?", status, re.I)
    network_id = re.search(r"\bNet\s*ID:\s*(-?\d+)", status, re.I)
    if not (ssid and frequency and network_id):
        return None
    name = ssid[1].strip().strip('"')
    if not name or name.lower() in {"<unknown ssid>", "unknown"}:
        return None
    return {"ssid": name, "frequency": frequency[1], "net_id": network_id[1]}


class Guard:
    def __init__(self, directory, runner=execute, clock=time.time):
        self.directory, self.runner, self.clock = Path(directory), runner, clock
        self.path = self.directory / "status.json"
        self.state = read_json(self.path)
        self.verified = set()

    def adb(self, *args):
        return self.runner([ADB, *args])

    def shell(self, transport, *args):
        return self.adb("-s", transport, "shell", *args)

    def verify(self, transport):
        if self.shell(transport, "getprop", "ro.serialno") != SERIAL:
            self.state["last_error"] = "serial_mismatch:" + transport
            return False
        self.verified.add(transport)
        return True

    def settings(self, transport):
        if transport not in self.verified:
            raise RuntimeError("unverified_transport")
        for name, value in SETTINGS.items():
            if self.shell(transport, "settings", "get", "global", name) != value:
                self.shell(transport, "settings", "put", "global", name, value)
                if self.shell(transport, "settings", "get", "global", name) != value:
                    raise RuntimeError("setting_verification_failed:" + name)
        enabled = self.shell(transport, "settings", "get", "global", "adb_wifi_enabled")
        if enabled == "1":
            if self.state["native_restore_pending"] and any(
                    not endpoint.endswith(":5555") for endpoint in self.state["live_verified_endpoints"]):
                self.state["native_restore_pending"] = False
                self.state["native_restored"] = True
            return
        if enabled != "0":
            self.state["tls_restore_deferred"] = "native_setting_unavailable"
            return
        status = self.shell(transport, "cmd", "wifi", "status")
        match = re.search(r"\bBSSID:\s*([0-9a-fA-F]{2}(?::[0-9a-fA-F]{2}){5})\b", status)
        trusted = bool(match and match[1].lower() in TRUSTED_BSSIDS)
        token = re.search(r"\bBSSID:\s*([^,\s]+)", status)
        masked = bool(token and ("*" in token[1] or token[1].lower() in {"02:00:00:00:00:00", "<unknown>"}))
        observation = wifi_network_observation(status)
        if trusted:
            # Retain the existing full-BSSID allowlist path. A complete BSSID
            # also supplies a stable prompt fingerprint on older OEM output.
            observation = observation or {"bssid": match[1].lower()}
        elif SYSTEM_TRUST_GATE and masked:
            if self.shell(transport, "getprop", "sys.boot_completed") != "1":
                self.state["tls_restore_deferred"] = "phone_booting"
                return
            addresses = self.shell(transport, "ip", "-o", "-4", "addr", "show", "dev", "wlan0")
            wlan = re.findall(r"\binet (\d+\.\d+\.\d+\.\d+)/", addresses)
            valid_wlan = False
            for address in wlan:
                try:
                    parsed = ipaddress.IPv4Address(address)
                    valid_wlan |= not (parsed.is_loopback or parsed.is_unspecified or parsed.is_multicast)
                except ValueError:
                    pass
            if not valid_wlan or observation is None:
                self.state["tls_restore_deferred"] = "network_observation_unavailable"
                return
        else:
            self.state["tls_restore_deferred"] = "network_not_previously_approved"
            return
        if self.state["native_restore_pending"] and self.state["network_observation"] == observation:
            self.state["tls_restore_deferred"] = "awaiting_android_network_approval"
            return
        now = self.clock()
        if self.state["last_native_enable_at"] and now - self.state["last_native_enable_at"] < COOLDOWN:
            self.state["tls_restore_deferred"] = "native_enable_cooldown"
            return
        # Persist before Android is asked to use its own trusted-BSSID store.
        # Unknown networks may show the normal device approval UI and reset 0;
        # neither that response nor a slow asynchronous result blocks TCP repair.
        self.state["last_native_enable_at"] = now
        self.state["native_restore_pending"] = True
        self.state["network_observation"] = observation
        self.state["tls_restore_requested"] = True
        atomic_json(self.path, self.state)
        try:
            self.shell(transport, "settings", "put", "global", "adb_wifi_enabled", "1")
            if self.shell(transport, "settings", "get", "global", "adb_wifi_enabled") != "1":
                self.state["tls_restore_deferred"] = "awaiting_android_network_approval"
        except RuntimeError as error:
            # A timed-out write has an uncertain outcome: retain the persisted
            # pending marker to avoid another prompt, and let TCP repair proceed.
            self.state["tls_restore_deferred"] = "native_enable_request_failed"
            self.state["native_restore_error"] = str(error)

    def tick(self):
        # A copied/misplaced status file must not transfer another phone's
        # address evidence, retry cooldowns, or candidate cursor.
        old = self.state if self.state.get("serial") == SERIAL else {}
        cache = old.get("verified_endpoints", [])
        cache = [item for item in cache if isinstance(item, str)][:8] if isinstance(cache, list) else []
        usb_cache = old.get("usb_endpoints", [])
        usb_cache = [e for e in usb_cache if isinstance(e, str)][:4] if isinstance(usb_cache, list) else []
        wifi_details = old.get("wifi_endpoints", [])
        wifi_details = [e for e in wifi_details if isinstance(e, dict) and e.get("verified_serial") == SERIAL][:8] if isinstance(wifi_details, list) else []
        last_attempt = old.get("last_tcpip_at", 0)
        last_attempt = last_attempt if isinstance(last_attempt, (int, float)) else 0
        last_native = old.get("last_native_enable_at", 0)
        last_native = last_native if isinstance(last_native, (int, float)) and not isinstance(last_native, bool) and last_native > 0 else 0
        observation = old.get("network_observation")
        observation = observation if isinstance(observation, dict) else None
        self.state = {"checked_at": int(self.clock()), "serial": SERIAL, "enabled": True,
                      "usb": "missing", "wifi": "disconnected", "endpoint": None,
                      "last_error": None, "last_tcpip_at": last_attempt,
                      "tcp_enabled": False, "tcp_restored": False,
                      "tcp_recovery_requested": False, "verified_endpoints": cache,
                      "usb_endpoints": usb_cache, "rejected_endpoints": [],
                      "tls_restore_requested": False, "wifi_endpoints": wifi_details,
                      "live_verified_endpoints": [], "failed_endpoints": [],
                      "candidate_cursor": old.get("candidate_cursor", 0),
                      "last_native_enable_at": last_native,
                      "native_restore_pending": old.get("native_restore_pending") is True,
                      "network_observation": observation, "native_restored": False}
        self.verified.clear()
        try:
            self.inspect(cache)
        except (RuntimeError, OSError) as error:
            self.state["last_error"] = str(error) if isinstance(error, RuntimeError) else "local_io_failed"
        atomic_json(self.path, self.state)
        self.log()
        return self.state

    def inspect_usb(self, devices):
        usb_ready, tcp, candidates = False, "", []
        if SERIAL in devices:
            self.state["usb"] = devices[SERIAL]
            if devices[SERIAL] == "device":
                if not self.verify(SERIAL):
                    self.state["usb"] = "serial_mismatch"
                elif self.shell(SERIAL, "getprop", "sys.boot_completed") != "1":
                    self.state["usb"] = "booting"
                else:
                    usb_ready = True
                    self.state["usb"] = "verified"
                    tcp = self.shell(SERIAL, "getprop", "service.adb.tcp.port")
                    tls = self.shell(SERIAL, "getprop", "service.adb.tls.port")
                    address_text = self.shell(SERIAL, "ip", "-o", "-4", "addr", "show", "dev", "wlan0")
                    addresses = re.findall(r"\binet (\d+\.\d+\.\d+\.\d+)/", address_text)
                    self.state["usb_endpoints"] = []
                    for address in addresses[:2]:
                        # An authenticated USB read establishes a safe address association.
                        self.state["usb_endpoints"].append(address + ":5555")
                        if tcp == "5555":
                            candidates += [address + ":5555"]
                        if tls.isdigit() and 1 <= int(tls) <= 65535:
                            candidates.insert(0, address + ":" + tls)
        return usb_ready, tcp, candidates

    def inspect(self, cache):
        networks = local_networks(self.runner(["/sbin/ifconfig", "-a"]))
        devices = dict(re.findall(r"(?m)^(\S+)\s+(device|offline|unauthorized)\s*$", self.adb("devices")))
        try:
            usb_ready, tcp, candidates = self.inspect_usb(devices)
        except (RuntimeError, OSError):
            self.state.update(usb="unresponsive", last_error="usb_unresponsive")
            usb_ready, tcp, candidates = False, "", []
        known = list(dict.fromkeys(cache + self.state["usb_endpoints"] + candidates))
        # Historical addresses authorize a probe, never a settings mutation.
        # Pair only identity-backed historical Wi-Fi IPs (or authenticated USB
        # addresses) with a newly advertised port belonging to this serial.
        historical = [e.get("serial") for e in self.state["wifi_endpoints"]
                      if e.get("serial") in cache
                      and isinstance(e.get("verified_at"), (int, float))
                      and not isinstance(e.get("verified_at"), bool)
                      and e["verified_at"] > 0]
        historical += self.state["usb_endpoints"]
        ips = list(dict.fromkeys(e.rsplit(":", 1)[0] for e in historical
                                 if isinstance(e, str) and local_endpoint(e, networks)))
        try:
            mdns = self.adb("mdns", "services")
            for line in mdns.splitlines():
                if re.search(r"(?<![A-Za-z0-9])" + SERIAL + r"(?![A-Za-z0-9])", line) and re.search(r"_adb(?:-tls-connect)?\._tcp", line):
                    found = re.findall(r"\b\d+\.\d+\.\d+\.\d+:\d+\b", line)
                    # Some OEMs advertise colliding mDNS hostnames, so the IP
                    # attached to a serial-specific service can be another phone.
                    # An authenticated USB IP is authoritative; all resulting
                    # transport identities must still be verified before use.
                    authoritative_ips = ([e.rsplit(":", 1)[0] for e in self.state["usb_endpoints"]]
                                         if usb_ready else ips)
                    corrected = [ip + ":" + e.rsplit(":", 1)[1] for ip in authoritative_ips for e in found]
                    # Without USB the real IP might have moved. Preserve the
                    # advertisement as another live-verified candidate as well.
                    found = corrected if usb_ready else list(dict.fromkeys(corrected + found))
                    candidates = found + candidates if "_adb-tls-connect" in line else candidates + found
        except RuntimeError:
            self.state["mdns_available"] = False
        candidates += cache
        if not usb_ready:
            candidates += self.state["usb_endpoints"]
        if devices.get(INITIAL) == "device":
            candidates.append(INITIAL)
        candidates, cursor = candidate_plan(candidates, known, devices, networks,
                                             self.state["candidate_cursor"],
                                             skip_tcp=usb_ready and tcp != "5555")
        self.state["candidate_cursor"] = cursor
        for endpoint in candidates:
            try:
                if devices.get(endpoint) != "device":
                    self.adb("connect", endpoint)
                if not self.verify(endpoint):
                    if not self.state["endpoint"]:
                        self.state["wifi"] = "serial_mismatch"
                    self.state["rejected_endpoints"].append(endpoint)
                    self.state["verified_endpoints"] = [e for e in self.state["verified_endpoints"] if e != endpoint]
                    self.state["wifi_endpoints"] = [e for e in self.state["wifi_endpoints"] if e.get("serial") != endpoint]
                    continue
                self.state["wifi"] = "verified"
                self.state["endpoint"] = self.state["endpoint"] or endpoint
                self.state["live_verified_endpoints"].append(endpoint)
                if str(self.state["last_error"]).startswith("wireless_unavailable:"):
                    self.state["last_error"] = None
                rejected = self.state["rejected_endpoints"]
                self.state["verified_endpoints"] = list(dict.fromkeys([endpoint] + [e for e in self.state["verified_endpoints"] if e not in rejected]))[:8]
                detail = {"serial": endpoint, "verified_serial": SERIAL, "verified_at": int(self.clock())}
                self.state["wifi_endpoints"] = [detail] + [e for e in self.state["wifi_endpoints"] if e.get("serial") != endpoint][:7]
            except RuntimeError:
                self.state["failed_endpoints"].append(endpoint)
                if not self.state["endpoint"]:
                    self.state["last_error"] = "wireless_unavailable:" + endpoint
        if self.state["live_verified_endpoints"]:
            failed = set(self.state["failed_endpoints"])
            self.state["verified_endpoints"] = [e for e in self.state["verified_endpoints"] if e not in failed]
            self.state["wifi_endpoints"] = [e for e in self.state["wifi_endpoints"] if e.get("serial") not in failed]
        endpoint = self.state["endpoint"]
        chosen = SERIAL if usb_ready else endpoint
        if chosen:
            if usb_ready or self.shell(chosen, "getprop", "sys.boot_completed") == "1":
                self.settings(chosen)
            if not usb_ready:
                tcp = self.shell(chosen, "getprop", "service.adb.tcp.port")
        self.state["tcp_enabled"] = tcp == "5555"
        self.state["tcp_restored"] = tcp == "5555" and bool(self.state["last_tcpip_at"])
        if usb_ready and tcp != "5555":
            now = self.clock()
            if now - self.state["last_tcpip_at"] >= COOLDOWN:
                # Persist BEFORE the potentially disconnecting command, including failed attempts.
                self.state["last_tcpip_at"] = now
                self.state["tcp_recovery_requested"] = True
                atomic_json(self.path, self.state)
                self.adb("-s", SERIAL, "tcpip", "5555")
            else:
                self.state["tcp_recovery_deferred"] = "cooldown"
        elif not usb_ready and tcp != "5555":
            self.state["tcp_recovery_deferred"] = "needs_verified_usb"
        if not chosen and self.state["last_error"] is None:
            self.state["last_error"] = "no_verified_channel"

    def log(self):
        path = self.directory / "guard.log"
        event = {key: self.state[key] for key in
                 ("checked_at", "usb", "wifi", "endpoint", "last_error", "tcp_recovery_requested")}
        try:
            with path.open("rb") as stream:
                stream.seek(max(0, path.stat().st_size - 48000))
                previous = stream.read().decode("utf-8", errors="replace").splitlines()[-199:]
        except FileNotFoundError:
            previous = []
        path.write_text("\n".join(previous + [json.dumps(event, ensure_ascii=False)]) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--status", action="store_true", help="read saved status; no device commands")
    args = parser.parse_args()
    directory = Path(__file__).resolve().parent
    if args.status:
        print(json.dumps(read_json(directory / "status.json"), ensure_ascii=False, indent=2))
        return
    os.umask(0o077)
    directory.mkdir(parents=True, exist_ok=True)
    with (directory / "guard.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return
        Guard(directory).tick()


if __name__ == "__main__":
    main()
