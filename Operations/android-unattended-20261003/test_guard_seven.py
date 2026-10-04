import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import importlib.util
spec = importlib.util.spec_from_file_location("guard_candidate", Path(__file__).with_name("guard-template.py"))
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)
guard.SERIAL = "ZY22HN3ZS4"
guard.INITIAL = "192.168.1.39:5555"
ADB, COOLDOWN, Guard, INITIAL, SERIAL, SETTINGS, atomic_json = (getattr(guard, x) for x in ("ADB", "COOLDOWN", "Guard", "INITIAL", "SERIAL", "SETTINGS", "atomic_json"))
TRUSTED_BSSID = "66:20:e3:1d:e8:ce"

NETWORK = "en0: flags=8863<UP,BROADCAST,RUNNING,SIMPLEX,MULTICAST>\n\tinet 192.168.1.33 netmask 0xffffff00 broadcast 192.168.1.255\n\tstatus: active"


class FakeADB:
    def __init__(self, devices=None, tcp="5555", mdns=""):
        self.devices = devices if devices is not None else {SERIAL: "device"}
        self.serials = {}
        self.tcp, self.mdns = tcp, mdns
        self.values = dict(SETTINGS)
        self.values["adb_wifi_enabled"] = "1"
        self.bssid = TRUSTED_BSSID
        self.usb_failure = None
        self.wifi_status = None
        self.wlan_address = "192.168.1.39"
        self.boot_completed = "1"
        self.native_accept = True
        self.before_native_write = None
        self.failed_endpoints = set()
        self.calls = []

    def __call__(self, argv):
        self.calls.append(argv)
        if argv == ["/sbin/ifconfig", "-a"]:
            return NETWORK
        assert argv[0] == ADB
        args = argv[1:]
        if args == ["devices"]:
            return "List of devices attached\n" + "\n".join(k + "\t" + v for k, v in self.devices.items())
        if args == ["mdns", "services"]:
            return self.mdns
        if args[0] == "connect":
            if args[1] in self.failed_endpoints:
                raise RuntimeError("command_timeout")
            return "connected to " + args[1]
        assert args[:1] == ["-s"]
        transport, command = args[1], args[2:]
        if transport == SERIAL and self.usb_failure and self.usb_failure in command:
            raise RuntimeError("command_timeout")
        if command == ["tcpip", "5555"]:
            assert transport == SERIAL
            return "restarting in TCP mode port: 5555"
        assert command[0] == "shell"
        command = command[1:]
        if command[:1] == ["getprop"]:
            return {"ro.serialno": self.serials.get(transport, SERIAL),
                    "sys.boot_completed": self.boot_completed, "service.adb.tcp.port": self.tcp,
                    "service.adb.tls.port": ""}[command[1]]
        if command[:1] == ["ip"]:
            return ("7: wlan0 inet " + self.wlan_address + "/24 brd 192.168.1.255 scope global wlan0") if self.wlan_address else ""
        if command == ["cmd", "wifi", "status"]:
            return self.wifi_status or "Wi-Fi is enabled\nWifiInfo BSSID: " + self.bssid + ", RSSI: -40"
        if command[:3] == ["settings", "get", "global"]:
            return self.values[command[3]]
        if command[:3] == ["settings", "put", "global"]:
            assert self.serials.get(transport, SERIAL) == SERIAL
            if command[3] == "adb_wifi_enabled":
                if self.before_native_write:
                    self.before_native_write()
                if not self.native_accept:
                    return ""
            self.values[command[3]] = command[4]
            return ""
        raise AssertionError(command)

    def mutations(self):
        return [call for call in self.calls if "tcpip" in call or "put" in call]


class GuardTestBase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name)

    def run_guard(self, fake, now=1000, saved=None):
        if saved is not None:
            saved = dict(saved)
            saved.setdefault("serial", SERIAL)
            atomic_json(self.path / "status.json", saved)
        result = Guard(self.path, fake, lambda: now).tick()
        self.assertEqual(result, json.loads((self.path / "status.json").read_text()))
        return result


class GuardTests(GuardTestBase):
    def test_wrong_usb_serial_never_writes(self):
        fake = FakeADB(tcp="")
        fake.serials[SERIAL] = "SOME_OTHER_PHONE"
        result = self.run_guard(fake)
        self.assertEqual(result["usb"], "serial_mismatch")
        self.assertFalse(fake.mutations())

    def test_wrong_wireless_serial_never_writes(self):
        fake = FakeADB({INITIAL: "device"}, tcp="")
        fake.serials[INITIAL] = "SOME_OTHER_PHONE"
        result = self.run_guard(fake, saved={"verified_endpoints": [INITIAL]})
        self.assertEqual(result["wifi"], "serial_mismatch")
        self.assertEqual(result["verified_endpoints"], [])
        self.assertFalse(fake.mutations())

    def test_usb_missing_never_tcpip_on_only_wireless(self):
        fake = FakeADB({INITIAL: "device"}, tcp="")
        fake.values["adb_allowed_connection_time"] = "604800000"
        result = self.run_guard(fake)
        self.assertEqual(result["wifi"], "verified")
        self.assertEqual(result["tcp_recovery_deferred"], "needs_verified_usb")
        self.assertFalse(any("tcpip" in c for c in fake.calls))
        self.assertEqual(fake.values["adb_allowed_connection_time"], "0")

    def test_enabled_tcp_is_not_restarted(self):
        fake = FakeADB()
        result = self.run_guard(fake)
        self.assertTrue(result["tcp_enabled"])
        self.assertFalse(fake.mutations())

    def test_tcpip_cooldown_and_trusted_address_survive_next_round(self):
        fake = FakeADB(tcp="")
        result = self.run_guard(fake, now=1200, saved={"last_tcpip_at": 1000})
        self.assertEqual(result["tcp_recovery_deferred"], "cooldown")
        self.assertFalse(fake.mutations())
        result = self.run_guard(fake, now=1000 + COOLDOWN)
        self.assertTrue(result["tcp_recovery_requested"])
        self.assertEqual([c for c in fake.calls if "tcpip" in c], [[ADB, "-s", SERIAL, "tcpip", "5555"]])
        self.assertIn(INITIAL, result["usb_endpoints"])
        next_fake = FakeADB(devices={})
        result = self.run_guard(next_fake, now=1301)
        self.assertIn([ADB, "connect", INITIAL], next_fake.calls)
        self.assertEqual(result["wifi"], "verified")
        self.assertFalse(next_fake.mutations())

    def test_tls_mdns_works_with_empty_tls_property(self):
        endpoint = "192.168.1.39:33055"
        fake = FakeADB(mdns="adb-" + SERIAL + "-abcdef _adb-tls-connect._tcp " + endpoint)
        result = self.run_guard(fake)
        self.assertEqual(result["endpoint"], endpoint)
        self.assertIn({"serial": endpoint, "verified_serial": SERIAL, "verified_at": 1000}, result["wifi_endpoints"])
        self.assertEqual(result["live_verified_endpoints"], [endpoint, INITIAL])
        self.assertFalse(fake.mutations())

    def test_unresponsive_usb_does_not_block_verified_wireless_fallback(self):
        for failing_command in ["ro.serialno", "sys.boot_completed", "service.adb.tcp.port", "ip"]:
            with self.subTest(command=failing_command):
                fake = FakeADB()
                fake.usb_failure = failing_command
                fake.values["stay_on_while_plugged_in"] = "0"
                result = self.run_guard(fake, saved={"verified_endpoints": [INITIAL]})
                self.assertEqual(result["usb"], "unresponsive")
                self.assertEqual(result["wifi"], "verified")
                self.assertTrue(fake.mutations())
                self.assertTrue(all(c[2] == INITIAL for c in fake.mutations()))
                self.assertFalse(any("tcpip" in c for c in fake.calls))

    def test_off_subnet_cache_and_unverified_initial_are_not_connected(self):
        fake = FakeADB(devices={})
        self.run_guard(fake, saved={"verified_endpoints": ["192.168.2.39:5555"]})
        self.assertFalse(any("connect" in c for c in fake.calls))
        self.assertFalse(fake.mutations())

    def test_tls_restore_only_on_previously_approved_bssid(self):
        fake = FakeADB()
        fake.values["adb_wifi_enabled"] = "0"
        result = self.run_guard(fake)
        self.assertTrue(result["tls_restore_requested"])
        self.assertEqual(fake.mutations(), [[ADB, "-s", SERIAL, "shell", "settings", "put", "global", "adb_wifi_enabled", "1"]])
        fake = FakeADB()
        fake.values["adb_wifi_enabled"] = "0"
        fake.bssid = "66:20:e3:1d:e8:cf"
        result = self.run_guard(fake)
        self.assertFalse(result["tls_restore_requested"])
        self.assertFalse(fake.mutations())

    def test_failed_old_endpoint_is_pruned_only_if_wireless_is_healthy(self):
        old = "192.168.1.39:33055"
        new = "192.168.1.39:46153"
        saved = {"verified_endpoints": [old], "wifi_endpoints": [
            {"serial": old, "verified_serial": SERIAL, "verified_at": 500}]}
        fake = FakeADB(mdns="adb-" + SERIAL + "-abcdef _adb-tls-connect._tcp " + new)
        fake.failed_endpoints.add(old)
        result = self.run_guard(fake, saved=saved)
        self.assertEqual(result["failed_endpoints"], [old])
        self.assertEqual(result["live_verified_endpoints"], [new, INITIAL])
        self.assertNotIn(old, result["verified_endpoints"])
        self.assertNotIn(old, [e["serial"] for e in result["wifi_endpoints"]])
        fake = FakeADB(devices={})
        fake.failed_endpoints.add(old)
        result = self.run_guard(fake, saved=saved)
        self.assertEqual(result["failed_endpoints"], [old])
        self.assertEqual(result["live_verified_endpoints"], [])
        self.assertEqual(result["verified_endpoints"], [old])
        self.assertEqual(result["wifi_endpoints"], saved["wifi_endpoints"])
        self.assertFalse(any("disconnect" in c for c in fake.calls))


class GuardSevenTests(GuardTestBase):
    def test_colliding_mdns_ip_uses_authenticated_usb_address(self):
        fake = FakeADB(mdns="adb-" + SERIAL + "-abcdef _adb-tls-connect._tcp 192.168.1.44:33055")
        result = self.run_guard(fake)
        self.assertEqual(result["endpoint"], "192.168.1.39:33055")
        self.assertNotIn([ADB, "connect", "192.168.1.44:33055"], fake.calls)
        self.assertTrue(result["enabled"])



    def test_usb_missing_new_tls_port_uses_verified_historical_ip(self):
        old, new = "192.168.1.39:33055", "192.168.1.39:33111"
        fake = FakeADB(devices={}, mdns="adb-" + SERIAL + "-x _adb-tls-connect._tcp 192.168.1.44:33111")
        fake.failed_endpoints.update([old, INITIAL, "192.168.1.44:33111"])
        result = self.run_guard(fake, saved={"verified_endpoints": [old], "wifi_endpoints": [
            {"serial": old, "verified_serial": SERIAL, "verified_at": 500}]})
        self.assertEqual(result["endpoint"], new)
        self.assertIn([ADB, "-s", new, "shell", "getprop", "ro.serialno"], fake.calls)
        self.assertFalse(fake.mutations())

    def test_three_bad_mdns_services_do_not_starve_known_connected_tcp(self):
        wrong = ["192.168.1.44:33111", "192.168.1.45:33222", "192.168.1.46:33333"]
        fake = FakeADB(devices={INITIAL: "device"}, mdns="\n".join(
            "adb-"+SERIAL+"-"+str(i)+" _adb-tls-connect._tcp "+e for i, e in enumerate(wrong)))
        fake.failed_endpoints.update(wrong)
        result = self.run_guard(fake, saved={"verified_endpoints": [INITIAL], "wifi_endpoints": [
            {"serial": INITIAL, "verified_serial": SERIAL, "verified_at": 500}]})
        self.assertEqual(result["endpoint"], INITIAL)
        self.assertEqual(fake.calls[3], [ADB, "-s", INITIAL, "shell", "getprop", "ro.serialno"])
        self.assertLessEqual(len(result["live_verified_endpoints"])+len(result["failed_endpoints"]), 3)

    def test_candidate_budget_reserves_tcp_and_rotates_exploration(self):
        networks = guard.local_networks(NETWORK)
        tls = ["192.168.1.39:"+str(p) for p in range(33001, 33007)]
        tcp = [INITIAL, "192.168.1.48:5555"]
        candidates, cursor, probed = tls+tcp, 0, set()
        for _ in range(20):
            plan, cursor = guard.candidate_plan(candidates, tls[:3], dict.fromkeys(tls[:3], "device"), networks, cursor)
            self.assertLessEqual(len(plan), 3)
            self.assertEqual(len(plan), len(set(plan)))
            self.assertTrue(any(e.endswith(":5555") for e in plan))
            probed.update(plan)
        self.assertEqual(probed, set(candidates))

    def test_foreign_or_missing_serial_discards_all_history_and_cooldowns(self):
        for identity in [None, "OTHER_PHONE"]:
            with self.subTest(identity=identity):
                saved = {"verified_endpoints": [INITIAL], "usb_endpoints": [INITIAL],
                         "wifi_endpoints": [{"serial": INITIAL, "verified_serial": SERIAL, "verified_at": 500}],
                         "candidate_cursor": 55, "last_tcpip_at": 999, "last_native_enable_at": 999,
                         "native_restore_pending": True, "network_observation": {"ssid": "old"}}
                if identity is not None:
                    saved["serial"] = identity
                atomic_json(self.path / "status.json", saved)
                fake = FakeADB(devices={})
                result = Guard(self.path, fake, lambda: 1000).tick()
                self.assertEqual(result["verified_endpoints"], [])
                self.assertEqual(result["usb_endpoints"], [])
                self.assertEqual(result["wifi_endpoints"], [])
                self.assertEqual(result["candidate_cursor"], 0)
                self.assertEqual(result["last_native_enable_at"], 0)
                self.assertFalse(result["native_restore_pending"])
                self.assertFalse(any("connect" in c for c in fake.calls))

    def test_bad_history_identity_cannot_authorize_new_port_address(self):
        old = "192.168.1.39:33055"
        for identity, timestamp in [("OTHER", 500), (SERIAL, True), (SERIAL, 0), (SERIAL, "500")]:
            with self.subTest(identity=identity, timestamp=timestamp):
                fake = FakeADB(devices={}, mdns="adb-"+SERIAL+"-x _adb-tls-connect._tcp 192.168.1.44:33111")
                fake.failed_endpoints.update([old, "192.168.1.44:33111"])
                self.run_guard(fake, saved={"verified_endpoints": [old], "wifi_endpoints": [
                    {"serial": old, "verified_serial": identity, "verified_at": timestamp}]})
                self.assertNotIn([ADB, "connect", "192.168.1.39:33111"], fake.calls)


class NativeTrustGateTests(GuardTestBase):
    status = 'Wifi is enabled\nWifiInfo: SSID: "Adim_2.4G", BSSID: 66:**:**:**:e8:ce, Frequency: 2467MHz, Net ID: 3'

    def setUp(self):
        super().setUp()
        self.gate = patch.object(guard, "SYSTEM_TRUST_GATE", True)
        self.gate.start()
        self.addCleanup(self.gate.stop)

    def fake(self, accept=False, tcp="5555"):
        fake = FakeADB(tcp=tcp)
        fake.values["adb_wifi_enabled"] = "0"
        fake.native_accept = accept
        fake.wifi_status = self.status
        return fake

    def test_disabled_gate_never_requests_masked_bssid(self):
        fake = self.fake()
        with patch.object(guard, "SYSTEM_TRUST_GATE", False):
            result = self.run_guard(fake)
        self.assertFalse(result["tls_restore_requested"])
        self.assertFalse(fake.mutations())

    def test_native_request_is_persisted_before_write_and_zero_does_not_block_tcp(self):
        fake = self.fake(tcp="")
        def inspect_saved():
            saved = json.loads((self.path / "status.json").read_text())
            self.assertTrue(saved["native_restore_pending"])
            self.assertEqual(saved["last_native_enable_at"], 1000)
            self.assertEqual(saved["network_observation"], {"ssid": "Adim_2.4G", "frequency": "2467", "net_id": "3"})
        fake.before_native_write = inspect_saved
        result = self.run_guard(fake)
        self.assertTrue(result["tls_restore_requested"])
        self.assertTrue(result["tcp_recovery_requested"])
        self.assertEqual(result["tls_restore_deferred"], "awaiting_android_network_approval")
        self.assertIn([ADB, "-s", SERIAL, "tcpip", "5555"], fake.calls)
        self.assertTrue(result["native_restore_pending"])
        self.assertFalse(result["native_restored"])

    def test_native_write_error_does_not_skip_tcp_recovery(self):
        fake = self.fake(tcp="")
        def fail_write():
            raise RuntimeError("command_timeout")
        fake.before_native_write = fail_write
        result = self.run_guard(fake)
        self.assertEqual(result["tls_restore_deferred"], "native_enable_request_failed")
        self.assertEqual(result["native_restore_error"], "command_timeout")
        self.assertTrue(result["native_restore_pending"])
        self.assertTrue(result["tcp_recovery_requested"])
        self.assertIn([ADB, "-s", SERIAL, "tcpip", "5555"], fake.calls)

    def test_same_network_pending_never_repeats_even_after_cooldown(self):
        first = self.run_guard(self.fake())
        for now in [1100, 1400, 10000]:
            fake = self.fake()
            result = self.run_guard(fake, now=now)
            self.assertFalse(result["tls_restore_requested"])
            self.assertFalse(fake.mutations())
            self.assertEqual(result["last_native_enable_at"], first["last_native_enable_at"])
            self.assertEqual(result["tls_restore_deferred"], "awaiting_android_network_approval")

    def test_new_network_may_request_only_after_cooldown(self):
        self.run_guard(self.fake())
        for now, expected in [(1100, False), (1300, True)]:
            fake = self.fake()
            fake.wifi_status = self.status.replace("Adim_2.4G", "Other_AP").replace("2467MHz", "5785MHz")
            result = self.run_guard(fake, now=now)
            self.assertEqual(result["tls_restore_requested"], expected)
            self.assertEqual(any("put" in c for c in fake.calls), expected)

    def test_pending_requires_later_enabled_and_live_tls_identity_to_clear(self):
        first = self.run_guard(self.fake(accept=True))
        self.assertTrue(first["native_restore_pending"])
        self.assertFalse(first["native_restored"])
        fake = self.fake(accept=True)
        fake.values["adb_wifi_enabled"] = "1"
        second = self.run_guard(fake, now=1030)
        self.assertTrue(second["native_restore_pending"])
        self.assertFalse(second["native_restored"])
        endpoint = "192.168.1.39:33444"
        fake.mdns = "adb-"+SERIAL+"-x _adb-tls-connect._tcp "+endpoint
        fake.serials[endpoint] = "OTHER"
        wrong = self.run_guard(fake, now=1060)
        self.assertTrue(wrong["native_restore_pending"])
        self.assertFalse(wrong["native_restored"])
        fake.serials[endpoint] = SERIAL
        final = self.run_guard(fake, now=1090)
        self.assertFalse(final["native_restore_pending"])
        self.assertTrue(final["native_restored"])
        self.assertIn(endpoint, final["live_verified_endpoints"])

    def test_missing_wlan_or_unobservable_network_does_not_request(self):
        for condition in ["no wlan", "no observation", "full untrusted bssid"]:
            with self.subTest(condition=condition):
                fake = self.fake()
                if condition == "no wlan": fake.wlan_address = ""
                elif condition == "no observation": fake.wifi_status = "WifiInfo: BSSID: 66:**:**:**:e8:ce"
                else: fake.wifi_status = self.status.replace("66:**:**:**:e8:ce", "11:22:33:44:55:66")
                result = self.run_guard(fake, saved={})
                self.assertFalse(result["tls_restore_requested"])
                self.assertFalse(fake.mutations())

    def test_wrong_device_never_reaches_system_trust_gate(self):
        fake = self.fake()
        fake.serials[SERIAL] = "OTHER"
        result = self.run_guard(fake)
        self.assertFalse(result["tls_restore_requested"])
        self.assertFalse(fake.mutations())

    def test_only_adb_and_existing_global_settings_are_used(self):
        fake = self.fake(accept=True)
        self.run_guard(fake)
        self.assertFalse(any("kill-server" in c or "disconnect" in c or "root" in c for c in fake.calls))
        for call in fake.mutations():
            self.assertEqual(call[:4], [ADB, "-s", SERIAL, "shell"])
            self.assertEqual(call[4:7], ["settings", "put", "global"])
            self.assertIn(call[7], SETTINGS | {"adb_wifi_enabled": "1"})


if __name__ == "__main__":
    unittest.main()
