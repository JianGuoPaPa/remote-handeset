package webservice

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// Persist action budgets before touching USB/ADB. A watchdog or host restart
// must not reset the cooldown, and re-enumeration must not grant a fresh budget
// just because it creates a new IORegistry generation.
type adbRecoveryBudget struct {
	Version       int                  `json:"version"`
	LastRestartAt time.Time            `json:"lastRestartAt"`
	LastAttempts  map[string]time.Time `json:"lastAttempts"`
}

func adbRecoveryBudgetPath() (string, error) {
	if configured := strings.TrimSpace(os.Getenv("WEBSCREEN_ADB_RECOVERY_STATE_FILE")); configured != "" {
		if !filepath.IsAbs(configured) {
			return "", fmt.Errorf("ADB recovery state path must be absolute")
		}
		return filepath.Clean(configured), nil
	}
	homeDir, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(homeDir, ".remote-handset", "adb-recovery-state.json"), nil
}

// Caller holds adbRecoveryMu. Invalid/unreadable state disables automatic
// disruptive actions rather than silently discarding their cooldowns.
func (manager *WebRTCManager) loadADBRecoveryBudgetLocked() {
	state := &manager.adbRecovery
	if state.budgetLoaded {
		return
	}
	state.budgetLoaded = true
	state.lastAttempts = make(map[string]time.Time)
	load := func() error {
		path, err := adbRecoveryBudgetPath()
		if err != nil {
			return err
		}
		file, err := os.Open(path)
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		if err != nil {
			return err
		}
		defer file.Close()
		data, err := io.ReadAll(io.LimitReader(file, 65537))
		if err != nil {
			return err
		}
		if len(data) > 65536 {
			return fmt.Errorf("ADB recovery budget exceeds size limit")
		}
		var budget adbRecoveryBudget
		if err := json.Unmarshal(data, &budget); err != nil {
			return err
		}
		if budget.Version != 1 || budget.LastAttempts == nil {
			return fmt.Errorf("invalid ADB recovery budget version or attempts")
		}
		state.lastRestartAt = budget.LastRestartAt
		state.lastAttempts = budget.LastAttempts
		return nil
	}
	state.budgetError = load()
	if state.budgetError != nil {
		log.Printf("adb_recovery_disabled reason=%q", state.budgetError)
	}
}

// Caller holds adbRecoveryMu. A failed write consumes the in-memory budget too
// and disables recovery until the underlying storage error is addressed.
func (manager *WebRTCManager) persistADBRecoveryBudgetLocked() error {
	state := &manager.adbRecovery
	if state.budgetError != nil {
		return state.budgetError
	}
	write := func() error {
		path, err := adbRecoveryBudgetPath()
		if err != nil {
			return err
		}
		data, err := json.Marshal(adbRecoveryBudget{1, state.lastRestartAt, state.lastAttempts})
		if err != nil {
			return err
		}
		if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
			return err
		}
		file, err := os.CreateTemp(filepath.Dir(path), ".adb-recovery-*")
		if err != nil {
			return err
		}
		temporary := file.Name()
		defer os.Remove(temporary)
		if _, err := file.Write(data); err != nil {
			file.Close()
			return err
		}
		if err := file.Sync(); err != nil {
			file.Close()
			return err
		}
		if err := file.Close(); err != nil {
			return err
		}
		if err := os.Rename(temporary, path); err != nil {
			return err
		}
		dir, err := os.Open(filepath.Dir(path))
		if err != nil {
			return err
		}
		defer dir.Close()
		return dir.Sync()
	}
	state.budgetError = write()
	return state.budgetError
}
