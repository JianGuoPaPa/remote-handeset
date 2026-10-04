package scrcpy

import (
	"errors"
	"fmt"
	"log"
	"net"
)

func (sd *ScrcpyDriver) Done() <-chan struct{} {
	return sd.lifecycleDone
}

// VideoReady closes after this driver receives its first real captured video
// slice. Initialization, codec metadata, cached replays, and Stop do not close
// it. Callers must also select on Done and their own deadline.
func (sd *ScrcpyDriver) VideoReady() <-chan struct{} {
	return sd.videoReady
}

func (sd *ScrcpyDriver) Err() error {
	sd.lifecycleErrMutex.RLock()
	defer sd.lifecycleErrMutex.RUnlock()
	return sd.lifecycleErr
}

func (sd *ScrcpyDriver) reportFailure(component string, err error) {
	if sd.stopping.Load() {
		return
	}
	if err == nil {
		err = errors.New("transport exited unexpectedly")
	}
	if errors.Is(err, net.ErrClosed) && sd.ctx.Err() != nil {
		return
	}
	sd.finish(fmt.Errorf("scrcpy %s failure: %w", component, err))
}

func (sd *ScrcpyDriver) finish(terminalErr error) {
	sd.lifecycleOnce.Do(func() {
		sd.lifecycleErrMutex.Lock()
		sd.lifecycleErr = terminalErr
		sd.lifecycleErrMutex.Unlock()

		if terminalErr != nil {
			log.Printf("scrcpy_driver_failed error=%q", terminalErr)
		}

		// Close all transports, stop the long-running adb shell, then remove
		// the reverse mapping with ADBClient's independent cleanup context.
		// lifecycleDone closes only after cleanup and is therefore a restart
		// barrier for the shared Agent.
		closeNetworkConnection(sd.videoConn)
		closeNetworkConnection(sd.audioConn)
		closeNetworkConnection(sd.controlConn)
		if sd.adbClient != nil {
			sd.adbClient.Stop()
		}
		sd.cancel()
		close(sd.lifecycleDone)
	})
}

func closeNetworkConnection(connection net.Conn) {
	if connection != nil {
		_ = connection.Close()
	}
}
