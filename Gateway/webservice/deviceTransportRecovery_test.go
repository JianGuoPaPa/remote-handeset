package webservice

import (
	"fmt"
	"reflect"
	"testing"
	"time"

	sagent "webscreen/streamAgent"

	"github.com/pion/webrtc/v4"
)

func missingRecoveryFixture() (*WebRTCManager, *DeviceBroadcaster, sagent.AgentConfig) {
	config := prewarmAgentConfig(testWhite)
	broadcaster := &DeviceBroadcaster{
		AgentConfig: config, AgentGeneration: 7, FinalCodec: prewarmFinalCodec(),
		// Keep an existing viewer to reproduce the case that prewarm skips.
		Subscribers:                map[uint32]*Subscriber{1: {}},
		transportRecoveryScheduled: true, transportRecoveryGeneration: 7,
	}
	manager := &WebRTCManager{broadcasters: map[string]*DeviceBroadcaster{
		"android_" + testWhite + "_0_0": broadcaster,
	}}
	return manager, broadcaster, config
}

func TestMissingTransportRecoveryRetriesWithExistingSubscriber(t *testing.T) {
	manager, target, config := missingRecoveryFixture()
	otherConfig := prewarmAgentConfig(testBackup)
	otherAgent := sagent.New(otherConfig, nil, nil)
	defer otherAgent.Close()
	other := &DeviceBroadcaster{Agent: otherAgent, AgentConfig: otherConfig, AgentGeneration: 8}
	manager.broadcasters["android_"+testBackup+"_0_0"] = other
	attempts := 0
	var delays []time.Duration
	start := func(b *DeviceBroadcaster, got sagent.AgentConfig, _ webrtc.RTPCodecParameters, reason string) error {
		attempts++
		if b != target || got.DeviceID != testWhite || reason != "auto_recovery" {
			t.Fatalf("recovery touched wrong capture: %p %#v %q", b, got, reason)
		}
		if len(b.Subscribers) != 1 {
			t.Fatal("recovery replaced existing subscribers")
		}
		if got.DriverConfig["mutation"] != "" {
			t.Fatal("failed initialization mutated the retry configuration")
		}
		got.DriverConfig["mutation"] = "private-to-this-attempt"
		switch attempts {
		case 1:
			return fmt.Errorf("no verified connection for device")
		case 2:
			return fmt.Errorf("initialize device driver: deadline exceeded")
		default:
			b.Agent = sagent.New(got, nil, nil)
			b.AgentConfig = got
			b.AgentGeneration++
			return nil
		}
	}
	manager.retryMissingTransportRecovery(testWhite, target, 7, config, prewarmFinalCodec(), start,
		func(delay time.Duration) bool {
			delays = append(delays, delay)
			return len(delays) <= 3
		})
	if attempts != 3 || target.Agent == nil || target.AgentGeneration != 8 {
		t.Fatalf("missing agent did not recover: attempts=%d generation=%d", attempts, target.AgentGeneration)
	}
	defer target.Agent.Close()
	if want := []time.Duration{time.Second, 5 * time.Second, 15 * time.Second}; !reflect.DeepEqual(delays, want) {
		t.Fatalf("retry delays = %v; want %v", delays, want)
	}
	if target.transportRecoveryScheduled {
		t.Fatal("completed recovery job stayed scheduled")
	}
	if other.Agent != otherAgent || other.AgentGeneration != 8 {
		t.Fatal("recovery changed another phone")
	}
	select {
	case <-otherAgent.Done():
		t.Fatal("recovery stopped another phone")
	default:
	}
}

func TestMissingTransportRecoveryRejectsStaleGenerationOrBroadcaster(t *testing.T) {
	for _, condition := range []string{"generation", "broadcaster", "live agent", "new recovery job"} {
		t.Run(condition, func(t *testing.T) {
			manager, target, config := missingRecoveryFixture()
			start := func(*DeviceBroadcaster, sagent.AgentConfig, webrtc.RTPCodecParameters, string) error {
				t.Fatal("stale recovery restarted a capture")
				return nil
			}
			manager.retryMissingTransportRecovery(testWhite, target, 7, config, prewarmFinalCodec(), start,
				func(time.Duration) bool {
					switch condition {
					case "generation":
						target.AgentGeneration++
					case "broadcaster":
						manager.broadcasters["android_"+testWhite+"_0_0"] = &DeviceBroadcaster{}
					case "live agent":
						target.Agent = sagent.New(config, nil, nil)
						t.Cleanup(target.Agent.Close)
					case "new recovery job":
						target.transportRecoveryGeneration = 8
					}
					return true
				})
			if condition == "new recovery job" && !target.transportRecoveryScheduled {
				t.Fatal("stale worker cleared a newer recovery job")
			}
		})
	}
}

func TestMissingTransportRecoveryBackoffStaysBounded(t *testing.T) {
	manager, target, config := missingRecoveryFixture()
	attempts := 0
	var delays []time.Duration
	manager.retryMissingTransportRecovery(testWhite, target, 7, config, prewarmFinalCodec(),
		func(*DeviceBroadcaster, sagent.AgentConfig, webrtc.RTPCodecParameters, string) error {
			attempts++
			return fmt.Errorf("no verified connection")
		}, func(delay time.Duration) bool {
			delays = append(delays, delay)
			return len(delays) < 6
		})
	want := []time.Duration{time.Second, 5 * time.Second, 15 * time.Second, 30 * time.Second, 30 * time.Second, 30 * time.Second}
	if attempts != 5 || !reflect.DeepEqual(delays, want) {
		t.Fatalf("unbounded recovery attempts=%d delays=%v", attempts, delays)
	}
}

func TestMissingTransportRecoveryScheduleDeduplicatesCurrentEpoch(t *testing.T) {
	manager, target, _ := missingRecoveryFixture()
	// A same-generation job is already registered; this call must neither
	// start another goroutine nor change the captured epoch.
	target.AgentLock.Lock()
	manager.scheduleMissingTransportRecovery(testWhite, target)
	if !target.transportRecoveryScheduled || target.transportRecoveryGeneration != 7 {
		t.Fatal("duplicate scheduling changed the active recovery job")
	}
	target.AgentLock.Unlock()
}

func TestMissingTransportRecoveryBusyDeviceDoesNotHoldManagerLock(t *testing.T) {
	manager, target, config := missingRecoveryFixture()
	target.AgentLock.Lock()
	locked := true
	defer func() {
		if locked {
			target.AgentLock.Unlock()
		}
	}()
	skipped := make(chan struct{})
	done := make(chan struct{})
	go func() {
		defer close(done)
		waits := 0
		manager.retryMissingTransportRecovery(testWhite, target, 7, config, prewarmFinalCodec(),
			func(*DeviceBroadcaster, sagent.AgentConfig, webrtc.RTPCodecParameters, string) error {
				t.Error("recovery started while another transaction owned the device lock")
				return nil
			}, func(time.Duration) bool {
				waits++
				if waits == 2 {
					close(skipped)
					return false
				}
				return true
			})
	}()
	select {
	case <-skipped:
	case <-time.After(time.Second):
		t.Fatal("recovery waited on the device lock while holding manager state")
	}
	if !manager.TryLock() {
		t.Fatal("busy device prevented unrelated manager updates")
	}
	manager.Unlock()
	target.AgentLock.Unlock()
	locked = false
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("recovery did not finish after device lock release")
	}
}
