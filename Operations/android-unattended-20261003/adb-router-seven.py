#!/usr/bin/env python3
"""Staged ADB CLI aliases for seven explicitly configured Android phones.

The ADB server is unchanged. Only explicit global ``-s`` selections for the
seven configured IDs are routed. A usable USB transport wins; otherwise a
guard-verified, currently connected Wi-Fi transport must
pass a fresh serial check. The selected transport_id is pinned for execution
so an address reassignment cannot silently select another connection.

Normal commands are exec'd exactly once, retaining stdio and signals. This
adapter never connects, changes phone settings, or retries a user command.
Bare ``devices`` / ``devices -l`` output presents one stable hardware alias
per configured phone.
All other device selections and global commands bypass routing entirely.
"""

from concurrent.futures import ThreadPoolExecutor
import ipaddress
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time


ADB = "/opt/homebrew/bin/adb"
SERIAL = "ZY22HN3ZS4"
WHITE_SERIAL = "ZY22F68DH8"
BASE = Path(__file__).resolve().parent.parent
TARGETS = {
    SERIAL: BASE / "backup3-unattended" / "status.json",
    WHITE_SERIAL: BASE / "white-motorola-unattended" / "status.json",
}
ADDITIONAL_SERIALS = (
    "10AD6F2LSY0017B", "31629594940010K", "ZY22GDWXSZ", "ZY22GHBP48", "ZY22K2SXMK",
)
TARGETS.update({serial: BASE / "android-unattended" / serial / "status.json"
                for serial in ADDITIONAL_SERIALS})
STATUS = TARGETS[SERIAL]
PROBE_TIMEOUT = 0.9
TOTAL_TIMEOUT = 4.5
GLOBAL_COMMANDS = {
    "devices", "help", "version", "server-status", "start-server", "kill-server",
    "connect", "disconnect", "pair", "mdns", "track-devices", "host-features",
    "keygen", "server",
}


def capture(argv, timeout):
    # Identity probes must not consume stdin belonging to the eventual command.
    return subprocess.run(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, timeout=timeout, check=False)


def read_candidates(path, serial=SERIAL):
    """Read only guard-verified endpoint history; USB IP hints are not trust."""
    try:
        state = json.loads(path.read_text())
    except (OSError, ValueError):
        return []
    if not isinstance(state, dict) or state.get("serial") != serial:
        return []
    verified = state.get("verified_endpoints", [])
    rejected = state.get("rejected_endpoints", [])
    if not isinstance(verified, list):
        return []
    if not isinstance(rejected, list):
        rejected = []
    candidates = []
    for endpoint in verified[:8]:
        if not isinstance(endpoint, str) or endpoint in rejected or endpoint in candidates:
            continue
        match = re.fullmatch(r"(\d+\.\d+\.\d+\.\d+):(\d+)", endpoint)
        if not match or not 1 <= int(match[2]) <= 65535:
            continue
        try:
            address = ipaddress.IPv4Address(match[1])
        except ValueError:
            continue
        if address.is_loopback or address.is_multicast or address.is_unspecified:
            continue
        candidates.append(endpoint)
    return candidates


def parse_rows(output):
    """Keep original bytes separate; parsing never reformats unrelated rows."""
    rows = {}
    for line in output.splitlines():
        fields = line.split()
        if len(fields) < 2 or fields[1] not in (b"device", b"offline", b"unauthorized",
                                                b"recovery", b"sideload", b"bootloader",
                                                b"no", b"connecting", b"authorizing"):
            continue
        name = fields[0].decode("utf-8", "replace")
        transport = re.search(rb"(?:^|\s)transport_id:([0-9]+)(?:\s|$)", line)
        rows[name] = {"state": fields[1],
                      "transport_id": transport[1].decode() if transport else None}
    return rows


def selector_index(argv):
    """Conservative parser: ambiguous/custom-server invocations stay untouched."""
    index, selection = 0, None
    while index < len(argv):
        token = argv[index]
        if token in ("-a", "--exit-on-write-error"):
            index += 1
        elif token == "-s":
            if selection is not None or index + 1 >= len(argv):
                return None
            selection = index
            index += 2
        elif token.startswith("-"):
            return None
        else:
            if token in GLOBAL_COMMANDS:
                return None
            return selection if selection is not None and argv[selection + 1] in TARGETS else None
    return None


class Router:
    def __init__(self, path=None, runner=capture, clock=time.monotonic, targets=None):
        # A path argument retains the single-phone test/integration interface.
        configured = ({SERIAL: path} if path is not None else TARGETS) if targets is None else targets
        self.targets = {serial: Path(value) for serial, value in configured.items()
                        if serial in TARGETS}
        self.runner, self.clock = runner, clock
        self.deadline = clock() + TOTAL_TIMEOUT
        # Cache the actual identity, not a target-specific boolean: stale endpoint
        # histories for the configured phones may overlap after DHCP reassignment.
        self.identities = {}

    def run(self, args, maximum=PROBE_TIMEOUT):
        timeout = min(maximum, self.deadline - self.clock())
        if timeout <= 0:
            return None
        try:
            return self.runner([ADB, *args], timeout)
        except (OSError, subprocess.TimeoutExpired):
            return None

    def identity(self, name, rows, serial=SERIAL):
        row = rows.get(name)
        if not row or row["state"] != b"device" or not row["transport_id"]:
            return False
        transport = row["transport_id"]
        if transport not in self.identities:
            probe = self.run(["-t", transport, "shell", "getprop", "ro.serialno"])
            self.identities[transport] = (probe.stdout.strip()
                                          if probe and probe.returncode == 0 else None)
        return self.identities[transport] == serial.encode()

    def route(self, argv, index):
        listing = self.run(["devices", "-l"], maximum=1.5)
        if not listing or listing.returncode != 0:
            return None
        serial = argv[index + 1]
        if serial not in self.targets:
            return None
        rows = parse_rows(listing.stdout)
        for name in [serial, *read_candidates(self.targets[serial], serial)]:
            if self.identity(name, rows, serial):
                return argv[:index] + ["-t", rows[name]["transport_id"]] + argv[index + 2:]
        return None

    def prefetch_identities(self, names, rows):
        """Bound fleet listing latency without trusting unverified aliases.

        Seven workers give every phone a first probe before stale endpoints
        consume the shared deadline. Each transport is probed at most once;
        only this calling thread writes the identity cache.
        """
        transports = list(dict.fromkeys(
            rows[name]["transport_id"] for name in names
            if name in rows and rows[name]["state"] == b"device"
            and rows[name]["transport_id"] and rows[name]["transport_id"] not in self.identities))
        def probe(transport):
            result = self.run(["-t", transport, "shell", "getprop", "ro.serialno"])
            return result.stdout.strip() if result and result.returncode == 0 else None
        with ThreadPoolExecutor(max_workers=7) as pool:
            for transport, value in zip(transports, pool.map(probe, transports)):
                self.identities[transport] = value

    def devices(self, argv):
        original = self.run(argv, maximum=1.5)
        if not original or original.returncode != 0:
            return original
        rich = original if argv == ["devices", "-l"] else self.run(["devices", "-l"], maximum=1.5)
        if not rich or rich.returncode != 0:
            return original
        rows = parse_rows(rich.stdout)
        original_rows = parse_rows(original.stdout)
        candidates = {serial: [endpoint for endpoint in read_candidates(path, serial)
                               if endpoint in original_rows]
                      for serial, path in self.targets.items()}
        if len(self.targets) > 2:
            # Probe USB first, then each phone's first wireless endpoint, then
            # second endpoints, etc. Do not spend the budget on one phone.
            names = [serial for serial in self.targets if serial in original_rows]
            for index in range(max((len(v) for v in candidates.values()), default=0)):
                names.extend(values[index] for values in candidates.values() if index < len(values))
            self.prefetch_identities(names, rows)
        usb = {serial: serial in original_rows and self.identity(serial, rows, serial)
               for serial in self.targets}
        wireless = {serial: [] for serial in self.targets}
        # Round-robin attempts preserve fairness within one shared budget.
        for index in range(max((len(values) for values in candidates.values()), default=0)):
            for serial, endpoints in candidates.items():
                if index < len(endpoints) and self.identity(endpoints[index], rows, serial):
                    wireless[serial].append(endpoints[index])
        aliases, remove_usb = {}, set()
        for serial, endpoints in wireless.items():
            if not endpoints:
                continue
            chosen = None if usb[serial] else endpoints[0]
            if chosen:
                remove_usb.add(serial)
            for endpoint in endpoints:
                aliases[endpoint] = serial if endpoint == chosen else None
        if not aliases:
            return original
        # Apply all verified aliases in one pass over the original output. Never
        # rebuild a second target from a fresh real listing and lose the first.
        output = []
        for line in original.stdout.splitlines(keepends=True):
            fields = line.split(None, 1)
            name = fields[0].decode("utf-8", "replace") if fields else ""
            if name in aliases:
                if aliases[name] is not None:
                    output.append(aliases[name].encode() + line[len(fields[0]):])
            elif name not in remove_usb:
                output.append(line)
        return subprocess.CompletedProcess(original.args, original.returncode,
                                           b"".join(output), original.stderr)


def dispatch(argv, router_factory=Router, exec_fn=os.execv, stdout=None, stderr=None):
    stdout = sys.stdout.buffer if stdout is None else stdout
    stderr = sys.stderr.buffer if stderr is None else stderr
    if argv in (["devices"], ["devices", "-l"]):
        result = router_factory().devices(argv)
        if result is not None:
            stdout.write(result.stdout)
            stderr.write(result.stderr)
            return result.returncode
        # No requested command has run successfully; let real ADB report its error.
    else:
        index = selector_index(argv)
        if index is not None:
            selected = router_factory().route(argv, index)
            if selected is None:
                stderr.write(b"adb: no verified USB or Wi-Fi transport for " + argv[index + 1].encode() + b"\n")
                return 1
            argv = selected
    exec_fn(ADB, [ADB, *argv])
    return 0  # Only reached by a test double for exec_fn.


if __name__ == "__main__":
    raise SystemExit(dispatch(sys.argv[1:]))
