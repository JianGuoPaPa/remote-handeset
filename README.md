# 新 Mac 远控项目交接

此副本用于另一台 Apple 芯片 Mac、另一网络和两台新 Android。现有七台手机和香港现网保持运行；三路视频实验未包含、未启用。

1. 克隆此仓库，先阅读 `Handoff/notes-service.txt` 与 `Handoff/notes-app.txt`。
2. 执行 `bash Credentials/decrypt.command`，输入单独交付的口令。解密文件仅放在 Git 忽略的 `.private/credentials/`。
3. 安装 Go 和 Android platform-tools，连接新两台手机，用 `bash Setup/inspect-android.sh` 记录新的 serial。首次 USB 调试授权要在手机上确认。
4. 用 `bash Setup/build-android-gateway.sh` 在目标 Mac 构建服务。该入口面向 Android，不启用 iPhone 原生 USB 桥。
5. 按 `Setup/new-site.example.env` 准备新站点配置。现有 `Operations` 脚本及守护仍包含旧用户路径和设备 serial，只作部署参考，不能直接整套运行。旧网络运行快照已移除，守护的初始无线地址和可信 BSSID 已清空，需按新网络重新核验配置。
6. 新站点必须使用独立香港隧道端口、独立授权和独立公网入口，或实现按设备路由。现网远端 `127.0.0.1:18079` 已占用，不可覆盖。不要直接覆盖加密包里的原站点服务器配置。
7. 修改 `RemoteHandset/App/AppConfiguration.swift` 的新设备清单、入口、解锁与登录密码；移植无线守护和 Gateway 的设备映射，再构建发布新版 App。两部新手机不会自动出现在当前 build 33 中。

仓库包含 Gateway 服务源码、定制 scrcpy server、Swift App/Xcode 工程、iPhone 桥依赖、部署参考及加密的香港管理员登录资料。App 签名私钥、描述文件及 App Store Connect 私钥在当前 Mac 上不可用；成功上传流程见 `Handoff/TestFlight-upload-reference.md`，需沿用有签名环境的 MacBook 或重新配置签名。

明文源码中的三个现网秘密已替换为占位值；原始值仅在加密包的 `reference-source` 中备查，不会自动回填。GitHub 私有性不能替代对登录私钥的加密保护。既有隧道私钥仅供核对旧部署，新站点应生成自己的受限隧道身份。

香港 Portal 当前只有部署运行目录，未在此机发现原始 Next.js 工程。可用加密包中的管理员 SSH 访问 `/opt/remote-handset/portal` 查看现有运行版本；本仓库不声称包含缺失的 Portal 原始开发工程。

以下为原项目说明。

---

# 远程手机 iOS

面向个人设备的原生 iPhone 远控客户端。客户端复用现有 Remote Handset
认证与网关协议，Android 端和现有网页端不需要为了安装 App 而停机或迁移。

## 当前能力

- 原生 SwiftUI/UIKit 客户端，不使用 WebView。
- WebRTC H.264 硬件解码；真机使用 Metal 显示，模拟器使用可截图的
  Core Image 预览渲染。
- 原生多点触控、返回、主页、最近任务、旋转、电源和音量。
- 文字输入、远端剪贴板读取和粘贴。
- Keychain 保存可选密码；TURN 凭据和网关票据仅在内存中短期使用。
- Wi-Fi/蜂窝网络变化自动恢复，重连采用退避策略。
- 先建立稳定的 TURN 连接，再后台探测直连；直连至少降低 20 ms，
  且画面、三条控制通道、连续帧和 RTT 样本全部就绪后才切换。
- 根据增量丢包、排队延迟、画面停顿和接收缓冲，在 2 Mbps / 30 fps、
  1.4 Mbps / 30 fps、1 Mbps / 24 fps 三档之间调整；档位变化使用受控
  主连接重建，避免“候选失败但共享编码器已经切档”的状态错位。硬件
  编码器无法恢复关键帧时可临时回退到软件编码。
- 只有同画质的直连路由候选在后台预热并原子切换；触控手势尚未结束时
  延迟切换，旧连接在新连接接管后再关闭。
- 移动与滚动使用无重传、低积压控制通道，按下、抬起和按键使用有序通道。
- 控制协议支持序号、设备写入 ACK 和下一编码帧反馈；旧网关会自动回退
  到 Legacy 控制，不会出现“画面正常但所有操作静默失效”。
- 内置 RTT、抖动、接收缓冲、增量丢包、帧率、码率、分辨率、画质档位、
  ICE 候选/UDP/TCP 以及分段控制延迟诊断。
- 已配置无线 ADB 的 Android 手机显示“连接方式”，可切换无线，或恢复
  自动连接（有线优先）。能力与可用状态由网关核实；未配置的手机隐藏入口。
  正在连接或 USB 无法连接时也能查询无线状态并切换。这里的连接方式指
  Mac mini 与被控手机之间的链路。
- 切换前核验硬件序列号，单独重建该手机的采集通道；失败后尝试恢复原
  通道，其他手机保持原连接。App 只在网关确认后更新连接结果。

## 低延迟网关

iOS 端在 WebRTC 初始化前启用低延迟解码队列。配套 Pion 网关需要协商
`playout-delay` RTP 扩展，并按每条连接实际协商的扩展 ID 写入 0–100 ms
播放窗口。网关写包前会克隆共享 RTP Header，且扩展失败时保持视频包继续
发送，避免多客户端之间串包或因可选提示导致画面中断。

网关为同一台 Android 设备维护一个共享 scrcpy 编码源。本机 Dock 预览使用
独立的回环监听 `127.0.0.1:8080` 订阅同一条 WebRTC Track，不经过香港节点，
也不会再启动第二个 scrcpy。对应 macOS 应用源码与构建脚本位于
`MacPreview`。

## 打开工程

直接打开 `RemoteHandset.xcodeproj`。工程由 XcodeGen 的 `project.yml`
生成，WebRTC 依赖精确锁定为 `150.0.0`。

## 签名与分发

- Bundle ID：`com.dltengwen.remotehandset`
- Team：`232AW49Q9J`
- 最低系统：iOS 17

`Distribution` 目录分别包含 TestFlight 和 Ad Hoc 的导出配置。
TestFlight 用于日常长期安装；Ad Hoc 需要目标 iPhone 的 UDID 已登记在开发者账号。

## 连接方式协议与验证

管理请求复用已有 `/api/gateway/session` 短期票据及 `/screen/ws`，首包
`type` 为 `transport_status` 或 `transport_switch`。客户端不提交无线 IP，
切换携带 `expected_instance_id` / `expected_generation`，以拒绝过期状态。
每个管理请求使用独立短连接，因此不依赖视频连接是否成功。

Swift 协议回归检查：

```sh
swiftc RemoteHandset/Core/API/APIModels.swift Tests/DeviceConnectionContractTests.swift -o /tmp/remotehandset-connection-tests
/tmp/remotehandset-connection-tests
```

网关回归检查在 `Gateway` 目录执行 `go test ./...`，并执行
`go test -race ./webservice ./sdriver/scrcpy ./streamAgent`。
