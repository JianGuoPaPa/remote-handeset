package scrcpy

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"webscreen/utils"
)

func ExecADB(ctx context.Context, args ...string) error {
	adbPath, err := utils.GetADBPath()
	if err != nil {
		return err
	}
	cmd := exec.CommandContext(ctx, adbPath, args...)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	err = cmd.Run()
	return err
}

func GenerateSCID() string {
	var value [4]byte
	if _, err := rand.Read(value[:]); err != nil {
		panic(fmt.Sprintf("generate scrcpy scid: %v", err))
	}
	// The Android server parses scid with Integer.parseInt(..., 16), so the
	// highest bit must stay clear even though the wire form is eight hex digits.
	value[0] &= 0x7f
	if value == [4]byte{} {
		value[3] = 1
	}
	return hex.EncodeToString(value[:])
}

// 将ScrcpyParams转为 key=value 格式的参数列表
func scrcpyParamsToArgs(params map[string]string) []string {
	var args []string
	keys := []string{
		"scid",
		"max_fps",
		"video",
		"video_codec",
		"video_bit_rate",
		"video_codec_options",
		"video_encoder",
		"audio",
		"audio_bit_rate",
		"audio_source",
		"audio_codec_options",
		"control",
		"new_display",
		"max_size",
		"log_level",
		"cleanup",
	}
	for _, key := range keys {
		if v, ok := params[key]; ok && v != "" {
			args = append(args, fmt.Sprintf("%s=%s", key, v))
		}
	}
	return args
}

func toScrcpyCommand(options map[string]string) string {
	classpath := options["CLASSPATH"]
	version := options["Version"]
	base := fmt.Sprintf("CLASSPATH=%s app_process / com.genymobile.scrcpy.Server %s ",
		classpath, version)
	args := scrcpyParamsToArgs(options)
	return strings.Join(append([]string{base}, args...), " ")
}

// Global ADB Helper Functions

// GetConnectedDevices returns a list of connected device serials/IPs
func GetConnectedDevices() ([]string, error) {
	adbPath, err := utils.GetADBPath()
	if err != nil {
		return nil, err
	}
	cmd := exec.Command(adbPath, "devices")
	output, err := cmd.Output()
	if err != nil {
		return nil, err
	}

	var devices []string
	lines := strings.Split(string(output), "\n")
	for _, line := range lines {
		if strings.TrimSpace(line) == "" || strings.HasPrefix(line, "List of devices attached") {
			continue
		}
		parts := strings.Fields(line)
		if len(parts) >= 2 && parts[1] == "device" {
			devices = append(devices, parts[0])
		}
	}
	return devices, nil
}

// ConnectDevice connects to a device via TCP/IP
func ConnectDevice(address string) error {
	adbPath, err := utils.GetADBPath()
	if err != nil {
		return err
	}
	cmd := exec.Command(adbPath, "connect", address)
	output, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("adb connect failed: %v, output: %s", err, string(output))
	}
	if strings.Contains(string(output), "unable to connect") || strings.Contains(string(output), "failed to connect") {
		return fmt.Errorf("adb connect failed: %s", string(output))
	}
	return nil
}

// PairDevice pairs with a device using a pairing code
func PairDevice(address, code string) error {
	adbPath, err := utils.GetADBPath()
	if err != nil {
		return err
	}
	cmd := exec.Command(adbPath, "pair", address, code)
	output, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("adb pair failed: %v, output: %s", err, string(output))
	}
	if !strings.Contains(string(output), "Successfully paired") {
		return fmt.Errorf("adb pair failed: %s", string(output))
	}
	return nil
}
