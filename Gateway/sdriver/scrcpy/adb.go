package scrcpy

import (
	"context"
	"fmt"
	"log"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync/atomic"
	"time"
	"webscreen/utils"
)

type ADBClient struct {
	deviceSerial string // 设备的IP地址或序列号
	transportID  string // Immutable ADB transport selected for this driver generation.
	scid         string
	remotePath   string
	ctx          context.Context
	cancel       context.CancelFunc
	setupCtx     context.Context // Only pinned drivers impose a setup deadline.
	setupDone    atomic.Bool
}

func (c *ADBClient) operationContext() context.Context {
	if c.setupCtx != nil && !c.setupDone.Load() {
		return c.setupCtx
	}
	return c.ctx
}

func (c *ADBClient) probeCommand(adbPath string, args ...string) *exec.Cmd {
	cmd := exec.CommandContext(c.operationContext(), adbPath, args...)
	if c.setupCtx != nil && !c.setupDone.Load() {
		// A wrapper's child must not keep Output/CombinedOutput pipes open
		// indefinitely after the bounded setup command has been cancelled.
		cmd.WaitDelay = 100 * time.Millisecond
	}
	return cmd
}

// parseADBTransportID accepts only a positive decimal ID. Empty retains the
// legacy serial selector; this internal option must never become a shell token.
func parseADBTransportID(value string) (string, error) {
	if value == "" {
		return "", nil
	}
	for _, digit := range value {
		if digit < '0' || digit > '9' {
			return "", fmt.Errorf("invalid adb_transport_id: expected a positive decimal integer")
		}
	}
	id, err := strconv.ParseUint(value, 10, 64)
	if err != nil || id == 0 {
		return "", fmt.Errorf("invalid adb_transport_id: expected a positive decimal integer")
	}
	return strconv.FormatUint(id, 10), nil
}

// commandArgs is shared by probes, setup, the long-running shell, and cleanup.
// A disappeared pinned transport must fail, never fall back to a different one.
func (c *ADBClient) commandArgs(args ...string) []string {
	selected := make([]string, 0, len(args)+2)
	if c.transportID != "" {
		selected = append(selected, "-t", c.transportID)
	} else if c.deviceSerial != "" {
		selected = append(selected, "-s", c.deviceSerial)
	}
	return append(selected, args...)
}

// NewClient 创建一个新的 ADB 客户端结构体.
// 如果 address 为空字符串，则表示使用默认设备.
func NewADBClient(deviceSerial string, scid string, parentCtx context.Context) *ADBClient {
	ctx, cancel := context.WithCancel(parentCtx)
	return &ADBClient{deviceSerial: deviceSerial, scid: scid, ctx: ctx, cancel: cancel}
}

// 显式停止服务的方法
func (c *ADBClient) Stop() {
	c.cancel()
	if c.scid != "" || c.remotePath != "" {
		releaseCleanupLease := utils.BeginADBServerCleanup()
		defer releaseCleanupLease()
		cleanupCtx, cleanupCancel := context.WithTimeout(
			context.Background(),
			2*time.Second,
		)
		defer cleanupCancel()
		if c.scid != "" {
			_ = c.adbWithContext(
				cleanupCtx,
				"reverse",
				"--remove",
				fmt.Sprintf("localabstract:scrcpy_%s", c.scid),
			)
		}
		if c.remotePath != "" {
			_ = c.adbWithContext(cleanupCtx, "shell", "rm -f "+c.remotePath)
		}
	}
}

// Push 将本地文件推送到设备上
func (c *ADBClient) PushScrcpyServer(localPath string, remotePath string) error {
	if remotePath != "" {
		c.remotePath = remotePath
	} else if c.remotePath == "" {
		c.remotePath = "/data/local/tmp/scrcpy-server"
	}
	// Avoid a multi-second push when a byte-identical driver-local server file
	// is already present (for example after a short-lived gateway restart).
	if localInfo, statErr := os.Stat(localPath); statErr == nil {
		args := c.commandArgs("shell", "stat -c %s "+c.remotePath+" 2>/dev/null")
		adbPath, resolveErr := utils.GetADBPath()
		if resolveErr != nil {
			log.Printf("Failed to resolve adb for remote server probe: %v", resolveErr)
		} else if out, probeErr := c.probeCommand(adbPath, args...).Output(); probeErr == nil {
			remoteSize := strings.TrimSpace(string(out))
			if remoteSize == fmt.Sprintf("%d", localInfo.Size()) {
				log.Printf("[scrcpy] server already present (%s bytes), skipping push", remoteSize)
				return nil
			}
		}
	}
	err := c.adb("push", localPath, c.remotePath)
	if err != nil {
		return fmt.Errorf("ADB Push failed: %v", err)
	}
	// c.ScrcpyParams.CLASSPATH = remotePath
	return nil
}

func (c *ADBClient) Reverse(local, remote string) error {
	// c.ReverseRemove(local)
	err := c.adb("reverse", local, remote)
	if err != nil {
		return fmt.Errorf("ADB Reverse failed: %v", err)
	}
	return nil
}

func (c *ADBClient) ReverseRemove(local string) error {
	c.adb("reverse", "--remove", local)
	// if err != nil {
	// 	return fmt.Errorf("ADB Reverse Remove failed: %v", err)
	// }
	return nil
}

func (c *ADBClient) StartScrcpyServer(
	options map[string]string,
	onUnexpectedExit func(error),
) error {
	cmdStr := toScrcpyCommand(options)

	go func() {
		time.Sleep(time.Second * 2) // 给一点时间让 reverse tunnel 生效
		log.Printf("Starting scrcpy server with command: %s", cmdStr)
		// This process owns the capture for the driver's entire lifetime. A
		// successful setup cancels setupCtx, which must not stop this shell.
		err := c.adbWithContext(c.ctx, "shell", cmdStr)
		if c.ctx.Err() != nil {
			return
		}
		if err != nil {
			log.Printf("Failed to run adb shell command: %v", err)
			if onUnexpectedExit != nil {
				onUnexpectedExit(err)
			}
		} else {
			unexpectedExit := fmt.Errorf("scrcpy server exited without an error")
			log.Printf("Scrcpy server exited unexpectedly: %v", unexpectedExit)
			if onUnexpectedExit != nil {
				onUnexpectedExit(unexpectedExit)
			}
		}
	}()

	// 这里我们无法立即知道是否成功，因为 Shell 命令会阻塞
	// 真正的“成功”标志是我们的 Listener Accept 到了连接
	return nil
}

func (c *ADBClient) adb(args ...string) error {
	ctx := c.operationContext()
	err := c.adbWithContext(ctx, args...)
	if ctx.Err() != nil {
		return ctx.Err()
	}
	return err
}

func (c *ADBClient) adbWithContext(
	ctx context.Context,
	args ...string,
) error {
	log.Printf("Executing on device %s transport=%s: %s", c.deviceSerial, c.transportID, args)
	return ExecADB(ctx, c.commandArgs(args...)...)
}

func (c *ADBClient) SupportOpusAudio() bool {
	// 1. 构造 shell 命令
	cmdStr := "grep -i 'opus.encoder' " +
		"/system/etc/media_codecs*.xml " +
		"/system_ext/etc/media_codecs*.xml " +
		"/vendor/etc/media_codecs*.xml " + //常见安卓真机
		"/vendor/odm/etc/media_codecs*.xml " +
		"/odm/etc/media_codecs*.xml " +
		"/product/etc/media_codecs*.xml " +
		"/apex/com.android.media.swcodec/etc/media_codecs*.xml " + //通用
		"/apex/com.android.media/etc/media_codecs*.xml " +
		" 2>/dev/null || true"
	//扩展路径，编码器的参数文件路径不同设备不同，不添加"||true" 会导致返回状态码2无法正常返回stdout

	// 2. 准备 adb 参数
	args := c.commandArgs("shell", cmdStr)

	// 3. 执行命令并捕获输出
	// The pinned driver's setup context also bounds encoder discovery.
	adbPath, pathErr := utils.GetADBPath()
	if pathErr != nil {
		log.Printf("Failed to resolve adb while checking audio encoders: %v", pathErr)
		return false
	}
	cmd := c.probeCommand(adbPath, args...)

	output, err := cmd.CombinedOutput() // 同时获取 stdout 和 stderr
	if err != nil {
		// 命令执行失败（可能是 adb 没连接，或者 app_process 报错）
		log.Printf("Failed to check audio encoders: %v", err)
		return false
	}

	// 4. 检查输出中是否包含 "opus.encoder"
	outputStr := string(output)

	// 调试日志：可选，查看设备实际返回了什么
	log.Printf("opus Encoder : %s", outputStr)

	return strings.Contains(outputStr, "opus.encoder")
}

func (c *ADBClient) SupportedVideoEncoderList() []string {
	// 1. 构造 shell 命令
	cmdStr := "grep -Ei '<MediaCodec name=\"[^\"]*encoder[^\"]*\"' " +
		"/system/etc/media_codecs*.xml " +
		"/system_ext/etc/media_codecs*.xml " +
		"/vendor/etc/media_codecs*.xml " +
		"/vendor/odm/etc/media_codecs*.xml " +
		"/odm/etc/media_codecs*.xml " +
		"/product/etc/media_codecs*.xml " +
		"/apex/com.android.media.swcodec/etc/media_codecs*.xml " +
		"/apex/com.android.media/etc/media_codecs*.xml " +
		" 2>/dev/null || true"

	args := c.commandArgs("shell", cmdStr)

	adbPath, pathErr := utils.GetADBPath()
	if pathErr != nil {
		log.Printf("Failed to resolve adb while checking video encoders: %v", pathErr)
		return nil
	}
	cmd := c.probeCommand(adbPath, args...)
	output, err := cmd.CombinedOutput()
	if err != nil {
		log.Printf("Failed to get supported encoders: %v", err)
		return nil
	}

	outputStr := string(output)
	var encoders []string
	lines := strings.Split(outputStr, "\n")
	for _, line := range lines {
		// Example: <MediaCodec name="c2.rk.hevc.encoder" type="video/hevc" ...>
		if idx := strings.Index(line, "name=\""); idx != -1 {
			start := idx + 6
			if end := strings.Index(line[start:], "\""); end != -1 {
				name := line[start : start+end]
				// 这里只保留 video 相关的 encoder，避免混入 audio 等其他 encoder
				found := false
				for _, e := range encoders {
					if e == name {
						found = true
						break
					}
				}
				if !found && strings.Contains(strings.ToLower(name), "encoder") && strings.Contains(strings.ToLower(line), "video") {
					encoders = append(encoders, name)
				}
			}
		}
	}
	return encoders
}

// ResolveVideoEncoder keeps a client-requested encoder when the device
// supports it, and otherwise selects the best available H.264 encoder for
// that specific phone. The gateway serves a mixed USB fleet, so a Qualcomm
// encoder cannot be assumed for MediaTek or older devices.
func (c *ADBClient) ResolveVideoEncoder(requested string) string {
	supported := c.SupportedVideoEncoderList()
	for _, encoder := range supported {
		if encoder == requested {
			return requested
		}
	}

	// Prefer vendor hardware encoders over software fallbacks. Android's
	// software encoders are retained as the final compatible option.
	for _, preferSoftware := range []bool{false, true} {
		for _, encoder := range supported {
			lower := strings.ToLower(encoder)
			isAVC := strings.Contains(lower, "avc") || strings.Contains(lower, "h264")
			if !isAVC {
				continue
			}
			isSoftware := strings.Contains(lower, "android") || strings.Contains(lower, "google")
			if isSoftware == preferSoftware {
				if requested != encoder {
					log.Printf(
						"[scrcpy] video encoder fallback device=%s requested=%s selected=%s",
						c.deviceSerial,
						requested,
						encoder,
					)
				}
				return encoder
			}
		}
	}

	return requested
}
