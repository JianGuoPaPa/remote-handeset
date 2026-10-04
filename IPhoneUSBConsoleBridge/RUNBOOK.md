# iPhone USB Console 全链路运行手册

## 1. 结论与边界

`iPhone USB Console` 是本工作区内构建并安装到这台 Mac 的原生应用。它把画面、声音与控制拆成独立链路：

- 画面不经过 TrollVNC。iPhone 通过 USB 向 macOS 的 `iOSScreenCapture` CoreMediaIO 插件提供系统屏幕流，应用用 AVFoundation 接收原始帧。
- 手机系统声音同样不经过 TrollVNC。它来自同一台 USB `iOSScreenCapture` 复合设备的音频轨道；原生窗口由 `AVCaptureAudioPreviewOutput` 直接播放。网页端优先共享一次 48 kHz 双声道 Opus 编码；浏览器因不受信任 HTTPS 等原因无法使用 WebCodecs/AudioWorklet 时，自动切到同一规范化 PCM 的低延迟备用流，不依赖第三方 CDN 或运行时解码库。
- 控制使用 TrollVNC 的 RFB 输入协议，但只发送指针、按键、Home 和电源键事件，不使用 TrollVNC 的低帧率画面。
- 网页或 Console 的“按住说话”使用 Mac/浏览器麦克风，转为 48 kHz 单声道 S16LE 后，经已认证的 TrollVNC RFB 控制连接送入手机端 `iPhone USB Microphone Bridge`。手机端 ElleKit 注入层在按住期间替换目标应用真正读到的麦克风采样；松开、断线或失焦立即恢复实体麦克风。
- 原生窗口直接显示同一条 USB 视频；网页端用一个共享的 VideoToolbox H.264 硬件编码器编码一次，再广播给所有观看者。
- 网页视频最多同时 16 路，Opus 与 PCM 两种网页音频端点合计最多同时 16 路。每个观看者有独立、有界的发送状态，慢客户端只会断开自己，不会阻塞其他观看者，也不能通过同时打开两种音频端点绕过容量限制。
- 网页控制仍是单租约：多个设备可以同时观看，但同一时刻只有一个网页会话获得控制权，避免两个操作者互相抢输入。
- 麦克风输入全局只有一个占用者：Console 和网页不能同时向手机说话，避免两路语音混合；观看手机声音不受此限制。

### 1.1 2026-08-27 最终冻结基线

| 层 | 最终版本/文件 | 字节数 | SHA-256 | 当前证据 |
| --- | --- | ---: | --- | --- |
| Mac 应用可执行文件 | `iPhone USB Console 1.1.0 (2)`，arm64 | 7,876,304 | `60dd4f852699cd51e0943055b371a4f0630d92fe055adaffbc13fc5a49316d7c` | `/Applications` 与 `build/Release` 相同，深度严格签名验证通过 |
| TrollVNC | `3.2-273-perf2-mic2` | 1,514,298 | `ba75b00407c383061d91cf98a97f3eccb8ef51d09132a5169293ac3ed71b7621` | 手机 `dpkg-query` 为 `ii`，进程两次稳定 |
| 手机 bridge | `local.iphone.usbmic 1.0.2` | 16,552 | `c76e8ea394af2eec9b548189033a5518c9cdf3b575ff7151643b0b3f98d28d73` | 手机 `dpkg-query` 为 `ii`，最终 postinst 哈希匹配，daemon 两次稳定 |

完整三件套与十个关键源码锚点已冻结到 `releases/2026-08-27-final/`，其中
`SHA256SUMS` 是二进制恢复身份基线，`SOURCE_SHA256SUMS` 只引用同一归档内的
`source-snapshot/`，整目录单独复制后仍可复验。bridge 依赖固定为
`com.82flex.trollvnc (>= 3.2-273-perf2-mic2)`；不能混用 `mic1` 或 bridge
1.0.0/1.0.1。任何密码、账号、设备唯一标识、HMAC 原始密钥或公网 IP 都不进入该归档和本文。

## 2. 数据流

```text
iPhone USB 屏幕
  -> macOS iOSScreenCapture / CoreMediaIO
  -> AVCaptureSession
       -> AVCaptureVideoDataOutput
            -> AVSampleBufferDisplayLayer（原生实时预览）
            -> VideoToolbox H.264（只编码一次）
                 -> WebVideoHub -> /ws/video（最多 16 路）
       -> AVCaptureAudioPreviewOutput（原生直接播放）
       -> AVCaptureAudioDataOutput
            -> AVAudioConverter / Opus（48 kHz、双声道、20 ms，只编码一次）
                 -> WebAudioHub -> /ws/audio（最多 16 路）
            -> 同一规范化 PCM（48 kHz、双声道、S16LE、20 ms）
                 -> WebAudioHub -> /ws/audio-pcm（仅兼容备用；与 Opus 合计 16 路）

网页/原生输入
  -> RFBInputClient
  -> usbmux 本机 USB 隧道
  -> iPhone TrollVNC
       -> 指针/按键/Home/电源输入
       -> IUMC 麦克风封包
            -> 手机本地 relay
            -> ElleKit 音频采集钩子
            -> 目标 App 实际读到的麦克风 PCM
```

## 3. 端口与发布

- 原生 Web 后端只监听 `127.0.0.1:18765`。
- Caddy 在当前手工转发模式监听 `192.168.31.112:18443`，反向代理到 `127.0.0.1:18765`。
- 路由器只需把用户选定的外部 HTTPS 端口转发到 `192.168.31.112:18443`。
- 不得把 TrollVNC/RFB 端口、历史 `15901` 或 `18765` 直接暴露到局域网或公网。
- HTTP 页面、API、视频 WebSocket 和控制 WebSocket 共用一个 HTTPS 源。网页登录密码只在应用内存中校验，不写入本手册、日志或配置文件。
- manual-forward 的本地 CA 证书未被客户端信任时，网页下行声音会自动使用普通 `AudioContext` 的 PCM 备用链；浏览器麦克风 `getUserMedia` 无法绕过 Secure Context 规则，网页向手机说话仍必须使用受信任 HTTPS，或在该客户端明确安装并信任当前 Caddy 本地 CA。

边缘部署、证书和 Caddy 的完整操作见 `deploy/README.md`。

## 4. 正常启动顺序

1. 保持越狱状态有效，确认 Sileo、ElleKit、TrollVNC 正常。
2. USB 连接 iPhone，解锁并完成“信任此电脑”。
3. 打开 `/Applications/iPhone USB Console.app`。
4. 确认原生画面开始变化，状态显示 USB 视频已连接，并在约一秒后出现实际 FPS。勾选“播放手机声音”后，当前 iPhone 系统声音应从 Mac 默认输出设备播放。
5. 在本机应用中输入 TrollVNC 密码并连接控制。密码最多 8 个 ASCII 字符；不要通过聊天传递。
6. 在本机应用中输入至少 12 个字符的网页访问密码并启动网页。该密码不会跨应用重启保存。
7. 保持 Caddy 的 manual-forward 运行；局域网或经用户现有路由器转发的外部设备访问 HTTPS 入口。

网页必须由用户点击“开启手机声音”后浏览器才会创建音频上下文，这是浏览器自动播放策略要求。应用第一次启用 USB 音频轨道时，macOS 可能请求音频采集权限；拒绝时视频与控制继续工作，只降级为无手机声音，之后在系统设置授权并点击“重新查找画面”即可重建音频图。第一次在 Console 按住说话时，macOS 会请求本机麦克风权限；第一次在网页启用语音输入时，浏览器会请求当前受信任 HTTPS 站点的麦克风权限。权限弹窗必须由用户本人选择，不由自动化代点。

应用更新或完整重启后，第 5、6 步需要重新执行。手机端 TrollVNC 配置不需要重做。

## 5. 多设备观看机制

- 只有一个 `H264VideoEncoder`，因此观看设备数量不会线性增加 iPhone 采集或 H.264 编码次数。
- 只有一个音频规范化/分包器和一个 Opus 编码器。可信浏览器的 `/ws/audio` 观看者共享相同 Opus 包；兼容浏览器的 `/ws/audio-pcm` 复用同一份 20 ms PCM 包，不重复 USB 采集或格式转换。
- 每个 `/ws/video` 连接只保留一个正在发送的访问单元和至多一个候选访问单元；不积压旧帧。
- NIO 写入超过 5 秒不完成时，只关闭该慢客户端。
- 新观看者会收到当前 H.264 配置并触发关键帧请求；全局强制关键帧最短间隔为 250 ms，避免多个客户端放大带宽。
- 网页收到视频后使用 WebCodecs 解码。2.5 秒无二进制帧或无解码帧会请求重同步，5 秒仍未恢复会重连自己的视频 WebSocket。
- 已有会话不会因为第 17 个登录而被静默淘汰；容量已满时拒绝新登录，现有观看者保持连接。

## 6. 双向音频协议与故障语义

### 手机声音下行

- USB 音频固定规范化为 48,000 Hz、双声道、16-bit PCM，再以 20 ms（960 帧）为一包编码为 Opus，目标码率 96 kbit/s。
- `/ws/audio` 的每个二进制消息由 24 字节 `IUAC` 头和一个原始 Opus 包组成。头中包含版本、断流标记、主机时钟时间戳、递增序号、每声道帧数和负载长度。
- 浏览器 Opus AudioWorklet ring 上限约 240 ms，约 60 ms 后起播；overflow 时只保留约 80 ms 新声音并重新 priming，避免累计旧声音。
- `/ws/audio-pcm` 复用同一个 24 字节 `IUAC` 头，负载固定为 960 帧、双声道交错 S16LE（每包 3,840 字节）。浏览器先缓存 60 ms，再用普通 `AudioContext`/`AudioBufferSourceNode` 调度；排队超过 240 ms、序号跳变或 discontinuity 时立即丢弃旧时间线重新起播。该兼容链约为每位听众 1.536 Mbit/s，只在 Opus/WebCodecs/AudioWorklet 不可用时启用。
- 每个网页音频连接最多积压 5 包。超过后只丢弃该客户端的旧包，并把下一包标记为 discontinuity；5 秒仍无法写出则关闭该客户端，使其他观看者继续播放。
- USB 音频交给格式转换/编码队列时，含正在处理的输入最多保留 3 个；过载只保留最新输入并切换 epoch，旧转换结果不能进入任一网页流。连续时间戳误差超过 8 ms 会标记新时间线，能识别单个 20 ms 缺口。
- 音频与视频都使用 `presentationHostTime ?? hostArrivalTime`，以同一主机时钟域对齐。USB 图重建时，视频输出、音频数据输出和原生音频预听输出必须一起重建。

### 麦克风上行

- Console 和网页都只在用户持续按住按钮时采集本地麦克风；松开、指针取消、窗口失焦、页面隐藏、WebSocket 关闭、控制断开或应用退出都会发送 STOP 并停止采集。
- Console 本机采集 handoff（含正在处理的输入）最多 3 个 buffer；过载时清除旧工作并切换 epoch。独立的 RFB 上行队列最多 12 个 20 ms 包（240 ms），用于容纳 macOS 正常约 100 ms 回调一次产生的 5 包。网页 WebSocket 的 `bufferedAmount` 软限制为 2 个包、硬限制为 3 个包。任何一层都保持有界，不无限排队旧语音。
- 上行固定为 48,000 Hz、单声道、S16LE、20 ms（960 样本）一包。28 字节 `IUMC` 头包括 START/STOP/DATA、流 ID、包序号、采集时间戳、样本数、声道和格式。
- `IUMC` 作为标准 RFB `ClientCutText` 二进制负载发送，因此复用现有 usbmux 隧道和 Classic VNC 认证，不增加手机公网或局域网监听端口。
- 修改版 TrollVNC 只在已认证、非 view-only 的连接上接受 `IUMC`，并在普通剪贴板解码前消费保留封包。断开拥有者时会合成 STOP，防止麦克风注入残留。
- TrollVNC 通过非阻塞 Unix datagram 把已校验封包交给仅在手机本机工作的 relay。relay 只在 `127.0.0.1` 接受带 HMAC challenge-response 的 tweak 消费者；慢消费者达到 64 KiB 有界队列后单独断开。
- 手机 relay 连续 1.5 秒收不到有效 PCM 会合成 STOP 并清空 stream；即使浏览器、Mac 或 TrollVNC 的 STOP 在异常断线中丢失，也会自动恢复实体麦克风。
- ElleKit 层覆盖 RemoteIO/VoiceProcessingIO 的 `AudioUnitRender` 输入、Audio Queue 输入和 `AVCaptureAudioDataOutput`。系统原始采集函数仍先执行，因此目标 App 自己的麦克风权限与 iOS 麦克风隐私指示保持有效。
- 未按住说话时，手机实体麦克风原样通过；按住期间若网络暂时欠载或遇到不支持的 PCM 布局，则输出静音，绝不混入实体麦克风。
- 原生 Console 按住说话时，手机声音本机预听强制静音，避免 Mac 扬声器回灌；网页占用麦克风时原生预听降低到 20%。网页自身在说话期间也把手机声音降低到 20%，松开后恢复。

手机端包的源代码、构建边界和协议细节位于 `PhoneMicBridge/README.md` 与 `PhoneMicBridge/PROTOCOL.md`。TrollVNC 和 bridge 是两个独立、互相约束版本的 DEB；先装 `mic2`，再装 bridge 1.0.2。bridge 的 `postinst` 只重启 `IPhoneUSBMicD`，不 reload/kill SpringBoard。包管理器完全退出后关闭并重新打开目标录音 App 即可加载新 tweak，正常安装不需要 Respring。

## 7. 自动恢复链

### 原生显示层

- `AVSampleBufferDisplayLayer` 连续 350 ms 不接受帧时主动 flush。
- flush 750 ms 不回调，或 flush 后再持续 1 秒不接受帧时，替换整块 display layer。
- 8 秒内新 display layer 再次失效两次，触发视频采集 `retry()`；控制和 Web 服务不被主动断开。

### USB 采集

- 启动后 4 秒没有首帧，进入恢复。
- 首帧后连续 3 秒没有 AVFoundation 样本回调，进入恢复。
- AVCapture 中断超过 8 秒没有结束通知，进入恢复。
- 每次恢复不再复用旧 `AVCaptureSession` 或旧 `AVCaptureVideoDataOutput`，而是完整释放并新建 session、input、output 和 CoreMediaIO 图。

### 网页编码器

- 同步 `frameDropped` 被当作失败处理，不再把编码器永久留在 in-flight 状态。
- VideoToolbox 接受一帧后 2 秒不回调，直接 invalidate 旧 compression session，使用最新采集帧重建编码器并重新发布配置和关键帧。
- 恢复时不调用会等待悬挂输出的 `VTCompressionSessionCompleteFrames`。

## 8. 2026-08-27 故障与修复证据

故障发生在 Mac 低电量休眠后。唤醒时 USB 设备重新枚举，旧 `iOSScreenCapture`/VideoToolbox 链路收到坏数据错误 `-12909`（本机 SDK 对应 `kVTVideoDecoderBadDataErr`）。AVFoundation 回调计数仍接近 60 fps，因此旧界面误报“健康”，但 CoreMedia 显示队列每 6 秒实际为 `0 frames enqueued`，画面保持旧帧；独立的 TrollVNC 输入仍可工作。

安装修复版并完整重启应用后：

- 原生预览从旧的冻结弹窗恢复为当前手机主屏幕；
- 状态恢复到约 60 fps；
- CoreMedia 连续记录每 6 秒 360 帧进入显示队列，不再是 0；
- QuickTime 当时未运行，排除了持续相机占用。

视频、音频和 PTT 迭代均保留了可恢复应用副本：

| 备份 | 可执行文件字节数 | SHA-256 |
| --- | ---: | --- |
| `deploy/runtime/iPhone USB Console.pre-20260827-0249.app` | 7,609,376 | `bfa539731e47268590650f17bff2ae426b5a8c2923a30e45cf3cbe542744cc7d` |
| `deploy/runtime/iPhone USB Console.pre-audio-20260827-040254.app` | 7,635,152 | `1a6e980634ca375a42f551c0d073288dc7f285553a16980f93c247aef2f7283d` |
| `deploy/runtime/iPhone USB Console.pre-ptt-fix-20260827-043317.app` | 7,853,184 | `0fe869e291ef10ea3fe157aae96d350d5b1e79caf151f288d280049aae37b947` |
| `deploy/runtime/iPhone USB Console.pre-mic-queue-fix-20260827-044817.app` | 7,872,272 | `450d84f01021278d388f9b622dfe7e7bc4554783e9b3ac99b574374a3cc4c6a2` |
| `deploy/runtime/iPhone USB Console.pre-mic-final-20260827-045202.app` | 7,876,240 | `0aafb1370c99a9206470150fbcacb9e27a573be3131d0d863fae71a628325972` |
| `deploy/runtime/iPhone USB Console.pre-no-truncation-20260827-050219.app` | 7,876,240 | `1b515c8c4d31bafbabf7f09a63f7b6fa285c59dab76d9837c5c77884d5c5cf91` |

当前已安装 `/Applications/iPhone USB Console.app` 与
`build/Release/iPhone USB Console.app` 的可执行文件均为 7,876,304 bytes，
SHA-256 均为
`60dd4f852699cd51e0943055b371a4f0630d92fe055adaffbc13fc5a49316d7c`；
深度严格签名验证通过，Designated Requirement 保持稳定。旧的
7,853,184-byte / `0fe869...` 文件是 `pre-ptt-fix` 历史备份，不再是最终版。

### 8.1 麦克风周期断音的四层根因与最终修复

现场听到的是均匀、周期性的断音，最终确认不是单一网络抖动，而是四个独立边界叠加：

1. macOS `AVAudioEngine` tap 实际按约 100 ms 回调。48 kHz 下一批约
   4,800 帧，会立即拆成 5 个 960-frame/20 ms 包；旧 RFB pending 上限 3
   会把正常首批误判为拥塞。最终明确请求合法的 100 ms tap，并把独立
   RFB packet 队列固定为 12 包/240 ms；本机 capture handoff 仍是 3
   buffer，二者不能混写。
2. 同为 48 kHz 时，旧 streaming converter 单次只返回 4,096/4,800 帧，
   每 100 ms 丢 704 帧，形成约 15 ms 的固定缺口。最终改用完整 buffer
   转换，并要求输出帧数与输入完全相等，否则失败关闭。
3. iPhone Unix datagram 默认约 4 KiB，只能容纳两个 1,948-byte DATA
   envelope；同批后三个 `sendto()` 返回 `ENOBUFS`，旧 ingress 未检查。
   最终 relay 在 bind 前强制并回读 `SO_RCVBUF >= 65,536`，不满足即退出；
   TrollVNC 检查发送结果并记录第一次错误。边界实验中旧配置 5 包仅
   2 成功/3 `ENOBUFS`，65,536-byte 配置可完整接收上游有界 12 包。
4. 手机目标 App 的 capture callback 可能远大于 120 ms。旧 tweak 无论
   callback 多大都只预缓冲 5,760 样本，导致“有效前半段 + 静音尾巴”。
   最终预缓冲改为
   `ceil(frameCount * 48000 / targetRate) + 2 + 5760`，ring 为 131,072
   samples，硬重同步余量为再加 48,000 samples；整 callback 预检，欠载、
   不支持布局或 START/STOP 代际改变时整块静音，不再输出半音频半零尾。

最终用户关闭并重开 Voice Memos，Console 重连控制并持续按住说话约
8–10 秒，回放后确认电脑端采集的声音连续可用。这只验证该真实 App 的
Console PTT 路径，不外推为网页 PTT、所有私有 API 或 watchdog 故障注入。

### 8.2 dpkg/Sileo 中断恢复实录

旧 bridge `postinst` 会在 dpkg 尚未记完状态时 reload SpringBoard，造成
bridge half-configured 与 Sileo trigger pending，后续安装反复回到同一中断。
最终 1.0.2 已删除 `sbreload`/SpringBoard kill。

本次恢复只临时开启 Dopamine iDownload，并以 USB
`iproxy 31337:1337` 进入 root 环境。现场步骤：

1. `dpkg --audit` 定位 half-configured bridge 与 pending trigger。
2. 将旧脚本备份到
   `/var/jb/var/lib/dpkg/info/local.iphone.usbmic.postinst.iusc-backup`，
   SHA-256 为
   `0af7f7320d17b5dccd2f039663b2e33e4df48524aaa75d9db75c5ed404820dac`。
3. 原子替换为临时 no-op postinst，SHA-256 为
   `306c6ca7407560340797866e077e053627ad409277d1b9da58106fce4cf717cb`。
4. 直接 `dpkg` 因 rootless PATH 缺 `sh/rm/tar/diff/dpkg-deb` 失败；成功命令是：

```sh
/var/jb/usr/bin/env PATH=/var/jb/usr/bin:/var/jb/usr/sbin:/var/jb/bin:/var/jb/sbin:/usr/bin:/usr/sbin:/bin:/sbin /var/jb/usr/bin/dpkg --configure -a
```

5. 上传文件哈希与本地匹配后，用同一 PATH 一次安装最终两包：

```sh
/var/jb/usr/bin/env PATH=/var/jb/usr/bin:/var/jb/usr/sbin:/var/jb/bin:/var/jb/sbin:/usr/bin:/usr/sbin:/bin:/sbin /var/jb/usr/bin/dpkg -i /var/mobile/Media/Downloads/IUSCRecovery/trollvnc-mic2.deb /var/mobile/Media/Downloads/IUSCRecovery/usbmic-1.0.2.deb
```

6. 最终证据为两个目标包 `dpkg-query` 状态 `ii`、已安装 postinst 匹配
   `6af743...08f`，以及 SpringBoard 7843、`trollvncserver` 8005、
   `IPhoneUSBMicD` 8014 两次间隔检查均稳定。没有把它扩写成“最终再次
   `dpkg --audit` 且全库为空”。
7. 用户关闭 iDownload 后，进程列表无 `idownloadd`，经 USB proxy 再连为
   `Connection refused`；Mac 31337/18766 均无监听，手机
   `IUSCRecovery` 上传目录、本地临时目录和临时 HTTP server 已清理。
   手机上的 `.iusc-backup` 仅保留为故障证据，不参与正常执行。

## 9. 构建与安装顺序

网页源码改动后必须先生成带哈希的生产资源，再构建原生应用：

```zsh
cd /Users/niechen/Documents/Codex/2026-08-25/files-pasted-by-the-user-mac/work/iphone-usb-console/WebConsole
npm run build

cd /Users/niechen/Documents/Codex/2026-08-25/files-pasted-by-the-user-mac/work/iphone-usb-console
./scripts/build.sh
```

`scripts/build.sh` 会生成 Xcode 工程、构建 Release、使用固定的有效 Apple 签名身份签名，并输出：

`build/Release/iPhone USB Console.app`

安装时先完整退出旧应用，保留可回滚副本，再把新 bundle 复制到 `/Applications/iPhone USB Console.app`。不要在旧进程仍运行时覆盖 bundle。

手机麦克风桥构建：

```zsh
cd /Users/niechen/Documents/Codex/2026-08-25/files-pasted-by-the-user-mac/work/iphone-usb-console/PhoneMicBridge
THEOS=/absolute/path/to/theos make clean package FINALPACKAGE=1
```

构建产物是 rootless `iphoneos-arm64.deb`。配套 TrollVNC 也必须从 `work/trollvnc-perf-fix` 构建；只安装其中一个不会形成可用的上行链路。最终配对是 TrollVNC `3.2-273-perf2-mic2` + bridge `1.0.2`，大小和哈希见 §1.1；bridge 的依赖会拒绝较旧 TrollVNC。

正常安装先装 TrollVNC，再装 bridge。bridge 的最终 postinst SHA-256 是
`6af743ade186c5fff8d7d9d182bbfcf1479242dca279c34ed33f011add94808f`；
它只重启 relay，不执行 Respring。安装后关闭并重开目标录音 App，再重连
Console。不要把 §8.2 的 iDownload/root 恢复流程当作日常安装方式；它只用于
已经出现 half-configured dpkg 状态的应急修复。

每次发布后把经过验签/验哈希的三件套复制到新的只增不改日期目录，并写
`SHA256SUMS` 与关键源码清单。当前冻结目录为 `releases/2026-08-27-final/`；
其中 `./verify-release.zsh` 已运行通过，可只读复核签名、哈希、包元数据、依赖、
架构、postinst 与协议标记，不连接手机也不安装包。

## 10. 当前验收状态与后续回归

| 项目 | 当前证据 |
| --- | --- |
| 原生 Apple USB 画面约 60 fps + TrollVNC 输入 | 已实机通过；用户确认最终效果好 |
| 点击、拖动、Home、锁屏/唤醒 | 已实机通过 |
| Console 播放手机系统声音 | 已实机通过 |
| 最终两个手机包、postinst、三进程 | 两包 `dpkg-query` 为 `ii`；postinst 哈希匹配；三 PID 两次稳定 |
| Console PTT → Voice Memos → 回放 | 已实机通过；持续按住约 8–10 秒后用户确认连续可用 |
| 网页历史视频/点击/滑动与多查看者不会抢占单一采集 | 历史现场链路有使用证据；最终音频版本未做完整多端回归 |
| `/ws/audio`、`/ws/audio-pcm` | 代码/构建已核对；尚未做最终浏览器实机验收 |
| 网页 PTT | 代码/构建已核对；尚未做受信任 HTTPS + 真实 App 实机验收 |
| 16-viewer 压力、慢客户端隔离 | 代码有界队列已核对；尚未做 16 客户端压力验收 |
| 单网页控制租约、native/web 单 mic owner 竞争 | 代码已核对；尚未做多端竞争验收 |
| 1.5 秒 watchdog、断线/失焦故障注入 | 代码已核对；尚未单独故障注入 |
| `127.0.0.1:29877` 单独 socket 探测 | 未单独验收；仅 daemon/真实 App 全链通过 |
| 受信任公网 HTTPS、蜂窝网络双向音频 | 未验收；manual-forward 本地 CA 不等于正式可信证书 |

后续每次更新至少回归：真实变化画面、CoreMedia 入队、点击/拖动/Home/Power、
Console 手机声音、Voice Memos 原生 PTT、松开恢复实体麦克风、网页声音/PTT、
多个 viewer、唯一 controller/owner、断线恢复、以及所有敏感端口仍为 loopback。

## 11. 安全操作原则

- 不记录、回显或代填 VNC/网页密码。
- 不绕过 macOS、浏览器或 iOS 的麦克风权限和隐私指示；不在未按住说话时采集 Mac/浏览器麦克风。
- iDownload 默认必须关闭。只有在明确的本机 USB root 恢复窗口才临时启用，`iproxy` 只能绑定本机，不得把 1337/31337 转发到 LAN/WAN；恢复后同时验证进程、连接和端口均已关闭。
- 不关闭或丢弃可能包含未保存录制的 QuickTime 窗口。
- 更新视频采集不应修改手机端越狱、TrollVNC 或 ElleKit 配置。
- 公网可达不等于已验收：必须从真正的外部网络分别验证登录、视频和控制，才能报告公网可用。
