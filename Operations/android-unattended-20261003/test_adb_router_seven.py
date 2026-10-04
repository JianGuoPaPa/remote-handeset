"""Offline-only routing and bounded seven-phone discovery regression tests."""
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parent
LEGACY = ROOT.parent / "backup3-unattended"

def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

router = load("router_seven_candidate", ROOT / "adb-router-seven.py")
single = load("router_seven_single_tests", LEGACY / "test_adb_router.py")
single.router = router
multi = load("router_seven_dual_tests", LEGACY / "test_adb_router_multi.py")
multi.router = router
multi._legacy.router = router

class ExistingSinglePhoneTests(single.RouterTests):
    pass

class ExistingDualPhoneTests(multi.MultiplePhoneTests):
    def test_two_explicit_ids_with_fixed_separate_status_paths(self):
        self.assertEqual(len(router.TARGETS), 7)
        self.assertEqual(router.TARGETS[router.SERIAL].parts[-2:], ("backup3-unattended", "status.json"))
        self.assertEqual(router.TARGETS[router.WHITE_SERIAL].parts[-2:], ("white-motorola-unattended", "status.json"))
        for serial in router.ADDITIONAL_SERIALS:
            self.assertEqual(router.TARGETS[serial].parts[-3:], ("android-unattended", serial, "status.json"))
            self.assertEqual(router.selector_index(["-s", serial, "shell"]), 0)

class SevenPhoneTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        root = Path(self.temporary.name)
        self.serials = list(router.TARGETS)
        self.targets = {s: root / (s + ".json") for s in self.serials}
        self.endpoints = {s: [f"192.168.1.{50+i}:5555", f"192.168.1.{50+i}:39001"]
                          for i, s in enumerate(self.serials)}
        self.identities = {}
        self.usb, self.wifi = [], []
        for i, serial in enumerate(self.serials):
            self.targets[serial].write_text(json.dumps({"serial": serial, "verified_endpoints": self.endpoints[serial]}))
            self.usb.append(f"{serial} device usb:{i} transport_id:{100+i}\n")
            self.identities[str(100+i)] = serial
            for j, endpoint in enumerate(self.endpoints[serial]):
                self.wifi.append(f"{endpoint} device transport_id:{200+10*i+j}\n")
                self.identities[str(200+10*i+j)] = serial

    def make(self, listing, identities=None):
        fake = single.FakeAdb(single.HEADER + single.OTHER + listing,
                              self.identities if identities is None else identities)
        return router.Router(targets=self.targets, runner=fake), fake

    def test_all_seven_usb_aliases_hide_all_fourteen_verified_wifi_duplicates(self):
        route, fake = self.make("".join(self.usb + self.wifi))
        output = route.devices(["devices", "-l"]).stdout
        self.assertEqual(output, (single.HEADER + single.OTHER + "".join(self.usb)).encode())
        self.assertEqual(len([c for c in fake.calls if c[1] == "-t"]), 21)

    def test_seven_wireless_aliases_are_unique_and_keep_the_selected_transport(self):
        route, fake = self.make("".join(self.wifi))
        output = route.devices(["devices", "-l"]).stdout
        for i, serial in enumerate(self.serials):
            self.assertEqual(output.count(serial.encode()), 1)
            self.assertIn(f"{serial} device transport_id:{200+10*i}\n".encode(), output)
        self.assertIn(single.OTHER.encode(), output)

    def test_each_new_serial_routes_command_once_to_its_own_verified_transport(self):
        for i, serial in enumerate(self.serials):
            route, fake = self.make("".join(self.wifi))
            args = ["-s", serial, "shell", "echo", "ok"]
            self.assertEqual(route.route(args, 0), ["-t", str(200+10*i), *args[2:]])
            self.assertFalse(any("echo" in c for c in fake.calls))

    def test_reassigned_cache_cannot_route_to_a_different_phone(self):
        serial = self.serials[-1]
        self.targets[serial].write_text(json.dumps({"serial": serial,
                                                   "verified_endpoints": self.endpoints[self.serials[0]]}))
        route, _ = self.make("".join(self.wifi))
        self.assertIsNone(route.route(["-s", serial, "reboot"], 0))
        route, fake = self.make("".join(self.wifi))
        output = route.devices(["devices", "-l"]).stdout
        self.assertNotIn(serial.encode(), output)
        self.assertEqual(output.count(self.serials[0].encode()), 1)
        probes = [c[2] for c in fake.calls if c[1] == "-t"]
        self.assertEqual(len(probes), len(set(probes)))

    def test_slow_usb_does_not_starve_seventh_phone_within_shared_deadline(self):
        listing = (single.HEADER + "".join(self.usb + self.wifi)).encode()
        lock = threading.Lock()
        running, maximum = [0], [0]
        calls = []
        def fake(argv, timeout):
            with lock:
                calls.append(argv)
                running[0] += 1
                maximum[0] = max(maximum[0], running[0])
            try:
                if argv[1:] == ["devices", "-l"]:
                    return subprocess.CompletedProcess(argv, 0, listing, b"")
                transport = argv[2]
                if transport.startswith("1"):
                    time.sleep(min(timeout, 0.12))
                    raise subprocess.TimeoutExpired(argv, timeout)
                return subprocess.CompletedProcess(argv, 0, self.identities[transport].encode(), b"")
            finally:
                with lock:
                    running[0] -= 1
        route = router.Router(targets=self.targets, runner=fake)
        route.deadline = time.monotonic() + 0.35
        started = time.monotonic()
        output = route.devices(["devices", "-l"]).stdout
        self.assertLess(time.monotonic() - started, 0.5)
        for serial in self.serials:
            self.assertIn(serial.encode(), output)
        self.assertLessEqual(maximum[0], 7)
        self.assertGreater(maximum[0], 1)
        self.assertTrue(all(c[1:] == ["devices", "-l"] or c[3:] == ["shell", "getprop", "ro.serialno"] for c in calls))

    def test_expired_budget_never_spawns_more_identity_probes(self):
        route, fake = self.make("".join(self.usb + self.wifi))
        route.deadline = time.monotonic() - 1
        self.assertIsNone(route.devices(["devices", "-l"]))
        self.assertEqual(fake.calls, [])

if __name__ == "__main__":
    unittest.main()
