package scrcpy

import (
	"context"
	"errors"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestPinnedDriverNewUsesOneSetupDeadline(t *testing.T) {
	dir := t.TempDir()
	adbPath := filepath.Join(dir, "setup-adb")
	logPath := filepath.Join(dir, "calls")
	script := `#!/bin/sh
printf '<%s>' "$@" >> "$HANDSET_TEST_SETUP_LOG"
printf '\n' >> "$HANDSET_TEST_SETUP_LOG"
if [ "$3" = 'reverse' ]; then
  if [ "$4" = '--remove' ]; then exit 0; fi
  sleep 0.04
  exit 0
fi
exec sleep 60
`
	if err := os.WriteFile(adbPath, []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("WEBSCREEN_ADB_PATH", adbPath)
	t.Setenv("HANDSET_TEST_SETUP_LOG", logPath)
	done := make(chan error, 1)
	go func() {
		driver, err := newWithSetupTimeout(map[string]string{
			"deviceID": "offline-test", "adb_transport_id": "47",
		}, 100*time.Millisecond)
		if driver != nil {
			driver.Stop()
			done <- errors.New("stalled driver unexpectedly initialized")
			return
		}
		done <- err
	}()
	select {
	case err := <-done:
		if !errors.Is(err, context.DeadlineExceeded) {
			t.Fatalf("initialization error = %v; want setup deadline", err)
		}
	case <-time.After(time.Second):
		t.Fatal("New did not finish after its shared setup deadline")
	}
	data, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSpace(string(data)), "\n")
	if len(lines) != 3 || !strings.Contains(lines[2], "<reverse><--remove>") {
		t.Fatalf("timed out setup did not clean up: %q", data)
	}
	for _, line := range lines {
		if !strings.HasPrefix(line, "<-t><47>") {
			t.Fatalf("timed out setup changed transport: %q", line)
		}
	}
}

func TestPinnedSetupCommandsRespectSharedDeadline(t *testing.T) {
	dir := t.TempDir()
	adbPath := filepath.Join(dir, "stall-adb")
	if err := os.WriteFile(adbPath, []byte("#!/bin/sh\nexec sleep 60\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("WEBSCREEN_ADB_PATH", adbPath)
	localServer := filepath.Join(dir, "server")
	if err := os.WriteFile(localServer, []byte("test"), 0o600); err != nil {
		t.Fatal(err)
	}
	for _, operation := range []string{"reverse", "push", "push probe", "audio probe", "video probe"} {
		t.Run(operation, func(t *testing.T) {
			client := NewADBClient("offline-test", "", context.Background())
			client.transportID = "47"
			setupCtx, cancelSetup := context.WithTimeout(client.ctx, 50*time.Millisecond)
			client.setupCtx = setupCtx
			defer cancelSetup()
			defer client.cancel() // Avoid unrelated remote-file cleanup in this probe test.
			done := make(chan struct{})
			go func() {
				defer close(done)
				switch operation {
				case "reverse":
					_ = client.Reverse("localabstract:test", "tcp:12345")
				case "push":
					_ = client.PushScrcpyServer(filepath.Join(dir, "nonexistent"), "/data/local/tmp/test")
				case "push probe":
					_ = client.PushScrcpyServer(localServer, "/data/local/tmp/test")
				case "audio probe":
					client.SupportOpusAudio()
				case "video probe":
					client.SupportedVideoEncoderList()
				}
			}()
			select {
			case <-done:
			case <-time.After(2 * time.Second):
				client.cancel()
				t.Fatal("setup operation ignored its deadline")
			}
			if !errors.Is(setupCtx.Err(), context.DeadlineExceeded) || client.ctx.Err() != nil {
				t.Fatalf("setup context = %v; lifetime context = %v", setupCtx.Err(), client.ctx.Err())
			}
		})
	}
}

func TestPinnedSetupDeadlineDoesNotCancelLongShell(t *testing.T) {
	dir := t.TempDir()
	adbPath := filepath.Join(dir, "long-adb")
	logPath := filepath.Join(dir, "shell-log")
	script := `#!/bin/sh
printf 'started\n' >> "$HANDSET_TEST_SHELL_LOG"
sleep 0.15
printf 'survived\n' >> "$HANDSET_TEST_SHELL_LOG"
exec sleep 60
`
	if err := os.WriteFile(adbPath, []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("WEBSCREEN_ADB_PATH", adbPath)
	t.Setenv("HANDSET_TEST_SHELL_LOG", logPath)
	client := NewADBClient("offline-test", "", context.Background())
	client.transportID = "47"
	setupCtx, cancelSetup := context.WithCancel(client.ctx)
	client.setupCtx = setupCtx
	defer cancelSetup()
	defer client.Stop()
	exit := make(chan error, 1)
	if err := client.StartScrcpyServer(map[string]string{}, func(err error) { exit <- err }); err != nil {
		t.Fatal(err)
	}
	waitForMarker := func(marker string) {
		t.Helper()
		deadline := time.NewTimer(4 * time.Second)
		defer deadline.Stop()
		ticker := time.NewTicker(5 * time.Millisecond)
		defer ticker.Stop()
		for {
			data, _ := os.ReadFile(logPath)
			if strings.Contains(string(data), marker) {
				return
			}
			select {
			case err := <-exit:
				t.Fatalf("long shell exited during setup cancellation: %v", err)
			case <-deadline.C:
				t.Fatalf("long shell did not write %q", marker)
			case <-ticker.C:
			}
		}
	}
	waitForMarker("started")
	cancelSetup()
	waitForMarker("survived")
	if client.ctx.Err() != nil {
		t.Fatal("setup cancellation cancelled the lifetime context")
	}
	client.setupDone.Store(true)
	if client.operationContext() != client.ctx {
		t.Fatal("completed setup retained the cancelled operation context")
	}
}

func TestPinnedSetupCancellationKeepsIndependentCleanup(t *testing.T) {
	logPath := fakeTransportADB(t)
	client := NewADBClient("offline-test", "abc12345", context.Background())
	client.transportID = "47"
	client.remotePath = "/data/local/tmp/test-server"
	setupCtx, cancelSetup := context.WithCancel(client.ctx)
	client.setupCtx = setupCtx
	cancelSetup()
	client.Stop()
	data, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatal(err)
	}
	want := "<-t><47><reverse><--remove><localabstract:scrcpy_abc12345>\n<-t><47><shell><rm -f /data/local/tmp/test-server>\n"
	if string(data) != want {
		t.Fatalf("cleanup did not escape cancelled setup context: %q", data)
	}
}

func TestPinnedMetadataAndCodecReadsAreBounded(t *testing.T) {
	for _, phase := range []string{"metadata", "codec"} {
		for _, cancellation := range []string{"deadline", "early cancellation"} {
			t.Run(phase+"/"+cancellation, func(t *testing.T) {
				reader, writer := net.Pipe()
				defer reader.Close()
				defer writer.Close()
				var ctx context.Context
				var cancel context.CancelFunc
				if cancellation == "deadline" {
					ctx, cancel = context.WithTimeout(context.Background(), 50*time.Millisecond)
				} else {
					ctx, cancel = context.WithCancel(context.Background())
				}
				defer cancel()
				release, err := boundSetupConnection(ctx, reader)
				if err != nil {
					t.Fatal(err)
				}
				defer release()
				driver := &ScrcpyDriver{adbClient: &ADBClient{transportID: "47"}}
				done := make(chan error, 1)
				go func() {
					if phase == "metadata" {
						done <- driver.readDeviceMeta(reader)
					} else {
						done <- driver.assignConn(reader)
					}
				}()
				if cancellation == "early cancellation" {
					cancel()
				}
				select {
				case err := <-done:
					if err == nil {
						t.Fatal("stalled socket was accepted as initialized")
					}
				case <-time.After(time.Second):
					t.Fatal("stalled initialization read did not terminate")
				}
				if driver.videoConn != nil || driver.audioConn != nil {
					t.Fatal("invalid codec socket was installed")
				}
			})
		}
	}
}

func TestSuccessfulSetupReleasesSocketDeadline(t *testing.T) {
	reader, writer := net.Pipe()
	defer reader.Close()
	defer writer.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	release, err := boundSetupConnection(ctx, reader)
	if err != nil {
		t.Fatal(err)
	}
	if err := release(); err != nil {
		t.Fatal(err)
	}
	if err := release(); err != nil { // Deferred error cleanup may also release it.
		t.Fatal(err)
	}
	cancel()
	done := make(chan error, 1)
	go func() {
		time.Sleep(75 * time.Millisecond) // Past the former setup deadline.
		_ = writer.SetWriteDeadline(time.Now().Add(time.Second))
		_, err := writer.Write([]byte("h264"))
		done <- err
	}()
	driver := &ScrcpyDriver{adbClient: &ADBClient{transportID: "47"}}
	if err := driver.assignConn(reader); err != nil {
		t.Fatalf("completed setup left a socket deadline or callback: %v", err)
	}
	if err := <-done; err != nil {
		t.Fatal(err)
	}
}

func TestUnpinnedOperationContextRetainsLifetime(t *testing.T) {
	client := NewADBClient("offline-test", "", context.Background())
	defer client.Stop()
	if client.operationContext() != client.ctx {
		t.Fatal("legacy client did not retain lifetime context")
	}
	if _, bounded := client.operationContext().Deadline(); bounded {
		t.Fatal("legacy client unexpectedly acquired a setup deadline")
	}
}
