package scrcpy

import (
	"context"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestADBCommandArgs(t *testing.T) {
	for _, test := range []struct {
		name, serial, transport string
		want                    []string
	}{
		{"pinned overrides serial", "hardware-id", "47", []string{"-t", "47", "shell", "getprop ro.serialno"}},
		{"serial fallback", "hardware-id", "", []string{"-s", "hardware-id", "shell", "getprop ro.serialno"}},
		{"default fallback", "", "", []string{"shell", "getprop ro.serialno"}},
	} {
		t.Run(test.name, func(t *testing.T) {
			client := &ADBClient{deviceSerial: test.serial, transportID: test.transport}
			input := []string{"shell", "getprop ro.serialno"}
			got := client.commandArgs(input...)
			if !reflect.DeepEqual(got, test.want) {
				t.Fatalf("arguments = %q; want %q", got, test.want)
			}
			got[len(got)-1] = "changed"
			if input[1] != "getprop ro.serialno" {
				t.Fatal("selector mutated caller arguments")
			}
		})
	}
}

func fakeTransportADB(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, "fake-adb")
	logPath := filepath.Join(dir, "calls")
	script := `#!/bin/sh
printf '<%s>' "$@" >> "$HANDSET_TEST_ADB_LOG"
printf '\n' >> "$HANDSET_TEST_ADB_LOG"
if [ "$HANDSET_TEST_ADB_FAIL" = '1' ]; then exit 1; fi
printf '%s\n' '<MediaCodec name="c2.test.avc.encoder" type="video/avc"> opus.encoder'
`
	if err := os.WriteFile(path, []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("WEBSCREEN_ADB_PATH", path)
	t.Setenv("HANDSET_TEST_ADB_LOG", logPath)
	t.Setenv("HANDSET_TEST_ADB_FAIL", "")
	return logPath
}

func TestInvalidTransportRejectedBeforeADB(t *testing.T) {
	logPath := fakeTransportADB(t)
	for _, value := range []string{"0", "-1", "+1", " 1", "1 ", "1;reboot", "1\n", "18446744073709551616"} {
		config := map[string]string{"deviceID": "hardware-id", "adb_transport_id": value}
		if driver, err := New(config); err == nil || driver != nil {
			t.Errorf("New accepted transport %q", value)
		}
		if config["adb_transport_id"] != value {
			t.Fatal("New mutated caller configuration")
		}
	}
	if _, err := os.Stat(logPath); !os.IsNotExist(err) {
		t.Fatalf("invalid configuration invoked adb: %v", err)
	}
	for value, want := range map[string]string{"": "", "1": "1", "0047": "47", "18446744073709551615": "18446744073709551615"} {
		if got, err := parseADBTransportID(value); err != nil || got != want {
			t.Errorf("parse %q = %q, %v; want %q", value, got, err, want)
		}
	}
}

func TestPinnedADBHelpersAndCleanup(t *testing.T) {
	logPath := fakeTransportADB(t)
	localServer := filepath.Join(t.TempDir(), "server")
	if err := os.WriteFile(localServer, []byte("test server"), 0o600); err != nil {
		t.Fatal(err)
	}
	client := NewADBClient("hardware-id", "abcd1234", context.Background())
	client.transportID = "47"
	if err := client.PushScrcpyServer(localServer, "/data/local/tmp/scrcpy-test"); err != nil {
		t.Fatal(err)
	}
	if !client.SupportOpusAudio() {
		t.Fatal("audio probe did not read fake encoder result")
	}
	if got := client.SupportedVideoEncoderList(); !reflect.DeepEqual(got, []string{"c2.test.avc.encoder"}) {
		t.Fatalf("video probe = %q", got)
	}
	if err := client.Reverse("localabstract:scrcpy_abcd1234", "tcp:12345"); err != nil {
		t.Fatal(err)
	}
	if err := client.ReverseRemove("localabstract:scrcpy_abcd1234"); err != nil {
		t.Fatal(err)
	}
	if err := client.adb("shell", "fake-scrcpy-server"); err != nil {
		t.Fatal(err)
	}
	// Stop cancels the ordinary context before cleanup. Its independent context
	// must still issue both cleanup commands with the original pinned selector.
	client.Stop()
	data, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSpace(string(data)), "\n")
	if len(lines) != 9 {
		t.Fatalf("adb calls = %d; want 9: %s", len(lines), data)
	}
	for _, line := range lines {
		if !strings.HasPrefix(line, "<-t><47>") || strings.Contains(line, "<-s>") {
			t.Errorf("unpinned helper: %s", line)
		}
	}
	if !strings.Contains(lines[7], "<reverse><--remove>") || !strings.Contains(lines[8], "<shell><rm -f /data/local/tmp/scrcpy-test>") {
		t.Fatalf("missing pinned cleanup commands: %q", lines[7:])
	}
}

func TestPinnedADBFailureDoesNotRetry(t *testing.T) {
	logPath := fakeTransportADB(t)
	t.Setenv("HANDSET_TEST_ADB_FAIL", "1")
	client := NewADBClient("hardware-id", "", context.Background())
	defer client.Stop()
	client.transportID = "47"
	if err := client.adb("shell", "input keyevent 4"); err == nil {
		t.Fatal("expected fake adb failure")
	}
	data, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatal(err)
	}
	if got, want := string(data), "<-t><47><shell><input keyevent 4>\n"; got != want {
		t.Fatalf("command retried or changed transport: %q", got)
	}
}
