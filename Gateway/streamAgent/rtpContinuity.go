package sagent

import (
	"sync"
	"time"

	"github.com/pion/rtp"
)

const (
	videoClockRate              = uint64(90_000)
	maxRestartTimestampGapTicks = uint64(5 * videoClockRate)
	audioClockRate              = uint64(48_000)
	maxAudioTimestampGapTicks   = uint64(5 * audioClockRate)
	audioDriftCorrectionTicks   = int64(audioClockRate / 10)
)

// RTPContinuity belongs to one shared media track, not one scrcpy process.
// Reusing it across controlled Agent restarts keeps RTP sequence numbers and
// timestamps monotonic for already-connected receivers.
type RTPContinuity struct {
	videoSequencer rtp.Sequencer
	audioSequencer rtp.Sequencer

	videoMu          sync.Mutex
	videoInitialized bool
	lastVideoTime    time.Time
	lastVideoStamp   uint32

	audioMu          sync.Mutex
	audioInitialized bool
	lastAudioTime    time.Time
	lastAudioStamp   uint32
	audioDriftTicks  int64
}

func NewRTPContinuity() *RTPContinuity {
	return &RTPContinuity{
		videoSequencer: rtp.NewRandomSequencer(),
		audioSequencer: rtp.NewRandomSequencer(),
		lastVideoStamp: uint32(time.Now().UnixMicro() * 90 / 1_000),
		lastAudioStamp: uint32(time.Now().UnixMicro() * 48 / 1_000),
	}
}

func (continuity *RTPContinuity) VideoSequencer() rtp.Sequencer {
	return continuity.videoSequencer
}

func (continuity *RTPContinuity) AudioSequencer() rtp.Sequencer {
	return continuity.audioSequencer
}

func (continuity *RTPContinuity) AdvanceVideoTimestamp(
	requestedDeltaTicks uint64,
	samePresentationTime bool,
	now time.Time,
) uint32 {
	continuity.videoMu.Lock()
	defer continuity.videoMu.Unlock()

	if !continuity.videoInitialized {
		continuity.videoInitialized = true
		continuity.lastVideoTime = now
		return continuity.lastVideoStamp
	}
	if samePresentationTime {
		return continuity.lastVideoStamp
	}

	deltaTicks := requestedDeltaTicks
	if deltaTicks == 0 {
		elapsed := now.Sub(continuity.lastVideoTime)
		if elapsed <= 0 {
			deltaTicks = 1
		} else {
			deltaTicks = uint64(elapsed.Microseconds()) * 90 / 1_000
		}
	}
	if deltaTicks == 0 {
		deltaTicks = 1
	}
	if deltaTicks > maxRestartTimestampGapTicks {
		deltaTicks = maxRestartTimestampGapTicks
	}

	continuity.lastVideoStamp += uint32(deltaTicks)
	continuity.lastVideoTime = now
	return continuity.lastVideoStamp
}

// AdvanceAudioTimestamp keeps one monotonic 48 kHz clock for the lifetime of
// the shared WebRTC track. Agents may be replaced while subscribers remain
// bound to the same SSRC, so neither the RTP sequence nor timestamp may restart.
// A real capture gap is reflected in the clock, while short scheduling jitter
// and a drained backlog retain the codec's nominal packet duration.
func (continuity *RTPContinuity) AdvanceAudioTimestamp(
	nominalDeltaTicks uint64,
	now time.Time,
) uint32 {
	continuity.audioMu.Lock()
	defer continuity.audioMu.Unlock()

	if !continuity.audioInitialized {
		continuity.audioInitialized = true
		continuity.lastAudioTime = now
		return continuity.lastAudioStamp
	}
	if nominalDeltaTicks == 0 {
		nominalDeltaTicks = 1
	}

	elapsedTicks := int64(0)
	if elapsed := now.Sub(continuity.lastAudioTime); elapsed > 0 {
		elapsedTicks = elapsed.Microseconds() * int64(audioClockRate) / 1_000_000
	}
	continuity.lastAudioTime = now
	continuity.audioDriftTicks += elapsedTicks - int64(nominalDeltaTicks)

	deltaTicks := nominalDeltaTicks
	if continuity.audioDriftTicks > audioDriftCorrectionTicks {
		extra := uint64(continuity.audioDriftTicks)
		if nominalDeltaTicks >= maxAudioTimestampGapTicks {
			extra = 0
		} else if extra > maxAudioTimestampGapTicks-nominalDeltaTicks {
			extra = maxAudioTimestampGapTicks - nominalDeltaTicks
		}
		deltaTicks += extra
		continuity.audioDriftTicks = 0
	} else if continuity.audioDriftTicks < -audioDriftCorrectionTicks {
		// A temporarily drained backlog can be consumed faster than real time.
		// Never move the shared RTP clock backwards; discard that negative drift.
		continuity.audioDriftTicks = 0
	}

	continuity.lastAudioStamp += uint32(deltaTicks)
	return continuity.lastAudioStamp
}
