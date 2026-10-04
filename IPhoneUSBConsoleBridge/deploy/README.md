# iPhone USB Console 单端口 HTTPS/WSS 边缘部署

本目录只负责把原生应用的 loopback Web 后端 `127.0.0.1:18765` 安全地发布为一个 HTTPS/WSS 入口。视频、控制和登录都复用同一个 HTTPS 源；Caddy 不增加第二层登录。任何情况下都不得把 TrollVNC/RFB 的 `5901`、历史转发端口 `15901` 或后端 `18765` 暴露到局域网或公网。

## 固定链路

- 本机 QA：`https://192.168.31.112:18443` → `http://127.0.0.1:18765`。
- 公网：`https://PUBLIC_IP:443` → 路由器仅 TCP NAT → `192.168.31.112:18443` → `127.0.0.1:18765`。
- 不监听、不映射 TCP 80；ACME 只用 TLS-ALPN-01。不开 UDP 443，因此没有 HTTP/3。
- Caddy 管理端固定 `127.0.0.1:2019`，绝不反向代理。
- Caddy 只加安全响应头并删除敏感日志字段；它不覆盖后端 `Cache-Control`，因此 `index.html`/API 的 `no-store` 与带哈希静态资源的 `immutable` 均保持原值。

当前机器已经安装：Caddy `2.11.4` 和 Homebrew `libnatpmp 20230423`（提供 `/opt/homebrew/bin/natpmpc`）。安装软件本身不会创建映射。

### 已有手工端口转发且不暂停 VPN

如果路由器已经由用户手工配置 `PUBLIC_IP:18443` → `192.168.31.112:18443`，并且只需要受控临时测试，可在不修改路由器、不关闭 VPN 的情况下运行本地 CA 模式：

```zsh
export PATH="/opt/homebrew/bin:$PATH"
export PUBLIC_IP="当前路由器公网IPv4"
./scripts/run-manual-forward.zsh
```

此模式只监听 `192.168.31.112:18443`，后端仍保持 `127.0.0.1:18765`；它不会调用 NAT-PMP，也不会联系 ACME。外部设备第一次访问会因本地 CA 而提示证书不受信任。该模式适合临时测试，不应被描述为浏览器零警告的正式公网部署。停止时运行 `./scripts/stop-manual-forward.zsh`；停止脚本不会修改用户已有的路由器转发。

## 脚本的强制安全条件

`preflight.zsh` 在启动任何 Caddy 之前必须同时确认：

1. `en0` 仍为 `192.168.31.112`，物理网关仍为 `192.168.31.1`；
2. `18765` 恰好只有一个监听，且只能是 `127.0.0.1:18765`；
3. 匿名 `GET /api/session` 返回预期的 `401` JSON，并具备 CSP、禁止缓存、禁止 framing、COOP/CORP 等关键安全头；
4. `5901`、`15901` 没有任何非 loopback TCP 监听；
5. `18443` 和 loopback 管理端 `2019` 未被占用。

公网模式下，如果默认路由是 `utun*`（常见于 Shadowrocket/VPN），脚本默认拒绝启动和映射。只有已暂停代理，或已实际验证公网 IP、Let’s Encrypt 端点和入站回包全部走 DIRECT 后，才能对**当前一次命令**设置：

```zsh
export PUBLIC_ROUTE_DIRECT_CONFIRMED=YES
```

这不是绕过开关；未完成 DIRECT 验证时不要设置。

## 纯静态验证（不会启动、签发或映射）

```zsh
cd /Users/niechen/Documents/Codex/2026-08-25/files-pasted-by-the-user-mac/work/iphone-usb-console/deploy
export PATH="/opt/homebrew/bin:$PATH"
./scripts/validate.zsh
```

它会适配并验证 local、manual-forward、Let’s Encrypt staging、production 四份 Caddy 配置，检查唯一监听、loopback 上游、证书主体、ACME 目录/挑战端口、安全头、缓存透传、日志脱敏与权限、脚本语法及部署安全不变量。它不会访问 NAT-PMP 映射接口。

## 本机/局域网 QA

先在原生 iPhone USB Console 中启用网页共享，让后端在 `127.0.0.1:18765` 工作，然后：

```zsh
cd /Users/niechen/Documents/Codex/2026-08-25/files-pasted-by-the-user-mac/work/iphone-usb-console/deploy
export PATH="/opt/homebrew/bin:$PATH"
./scripts/run-local.zsh
```

访问 `https://192.168.31.112:18443`。证书来自 Caddy 本地 CA，本配置明确不写入系统信任库，因此首次 QA 出现证书警告属于预期。状态、证书和日志只存于 `deploy/runtime/local`。

## 首次公网：必须先 staging，再 production

先在路由器做 DHCP 保留，确保这台 Mac 始终取得 `192.168.31.112`。路由器 WAN 地址必须是全球可路由 IPv4；私网或 `100.64.0.0/10` 表示双重 NAT/CGNAT。关闭路由器 WAN 侧 443 管理入口。

下面的 `PUBLIC_IP` 必须取自 NAT-PMP/路由器 WAN 页面，不能使用 Shadowrocket 出口 IP。不要把它写入仓库或日志。

### 1. Staging Caddy

终端 A：

```zsh
cd /Users/niechen/Documents/Codex/2026-08-25/files-pasted-by-the-user-mac/work/iphone-usb-console/deploy
export PATH="/opt/homebrew/bin:$PATH"
export PUBLIC_IP="当前路由器公网IPv4"
export PUBLIC_ROUTE_DIRECT_CONFIRMED=YES  # 仅在已暂停代理或已验证 DIRECT 后
./scripts/run-public.zsh --staging
```

终端 B（Caddy 已监听后）：

```zsh
cd /Users/niechen/Documents/Codex/2026-08-25/files-pasted-by-the-user-mac/work/iphone-usb-console/deploy
export PATH="/opt/homebrew/bin:$PATH"
export PUBLIC_IP="当前路由器公网IPv4"
EXPECTED_PUBLIC_IP="$PUBLIC_IP" \
PUBLIC_EDGE_MODE=staging \
PUBLIC_ROUTE_DIRECT_CONFIRMED=YES \
./scripts/natpmp-renew.zsh --apply
```

`--apply` 强制要求 `EXPECTED_PUBLIC_IP`。它还会确认 `18443` 的唯一监听者确实是使用指定 staging 配置启动的 Caddy，校验 loopback 管理 API 中的实际运行态，再请求唯一映射 `TCP 443 → 18443`，租期 3600 秒。任何响应解析、端口替换或租期验证失败，脚本都会立即以 lifetime 0 补偿删除请求的公共 443 和所有已识别替代映射，然后失败关闭。

从手机蜂窝网络或独立云主机访问 `https://PUBLIC_IP/`，确认确实到达本机登录页。Staging 证书不受浏览器信任是预期；这一步验证的是公网 TCP 443、TLS-ALPN、WSS/HTTP 反代和回包路径。不要在同一 Wi-Fi 内用结果判断公网可达性，因为路由器可能不支持 NAT hairpin。

完成外部验证后，终端 B 标记本次公网 IP 的 staging 结果：

```zsh
CONFIRM_EXTERNAL_STAGING=YES \
PUBLIC_ROUTE_DIRECT_CONFIRMED=YES \
PUBLIC_IP="$PUBLIC_IP" \
./scripts/verify-public-staging.zsh
```

验证脚本会再次确认 Caddy 的 staging 运行态、匿名 401、安全头、证书 IP SAN 和 staging 颁发链，随后生成权限 `0600` 的 `runtime/staging-verified.json`。没有该标记，production 启动会拒绝。

### 2. 安全停掉 staging

```zsh
./scripts/stop-public.zsh
```

该脚本按顺序停掉已加载的续租 LaunchAgent、用精确 lifetime 0 删除 `TCP 443 → 18443`、只对命令行完全匹配本目录配置的 Caddy 发 SIGTERM，最后确认续租未加载且 `18443` 已无监听。它不会停止 iPhone USB Console、`127.0.0.1:18765` 后端、QuickTime 或原生 60 fps 基线。

### 3. Production Caddy

终端 A：

```zsh
export PATH="/opt/homebrew/bin:$PATH"
export PUBLIC_IP="当前路由器公网IPv4"
export PUBLIC_ROUTE_DIRECT_CONFIRMED=YES
export CONFIRM_PRODUCTION_ACME=YES
./scripts/run-public.zsh --production
```

终端 B：

```zsh
EXPECTED_PUBLIC_IP="$PUBLIC_IP" \
PUBLIC_EDGE_MODE=production \
PUBLIC_ROUTE_DIRECT_CONFIRMED=YES \
./scripts/natpmp-renew.zsh --apply
```

Production 与 staging 使用相同唯一外部 TCP 443 和内部 18443，但使用独立状态目录 `runtime/public-production`，避免 staging 证书或账户状态污染生产。生产配置请求 Let’s Encrypt `shortlived` IP 证书，只启用 TLS-ALPN-01；HSTS 仅在 production 响应中启用。

## NAT-PMP 干跑、幂等删除与续租

干跑只查询路由器地址，不创建映射：

```zsh
./scripts/natpmp-renew.zsh
```

精确、幂等删除公共 TCP 443 到本机 18443，并验证路由器确认 lifetime 0：

```zsh
./scripts/natpmp-renew.zsh --remove
```

持续续租只应在手工 production `--apply` 成功后配置。生成 LaunchAgent 副本时，把 DIRECT 占位符替换为 `YES` 的前提仍是已暂停代理或已验证 DIRECT；没有 `utun` 默认路由时可替换为 `NO`。

```zsh
install -d -m 0700 runtime/public-production/logs
direct_confirmation="YES"  # 未验证 DIRECT 时改为 NO；utun 下将安全拒绝续租
sed \
  -e "s/REPLACE_WITH_CURRENT_PUBLIC_IP/$PUBLIC_IP/" \
  -e "s/REPLACE_WITH_YES_AFTER_DIRECT_ROUTE_VALIDATION/$direct_confirmation/" \
  launchd/com.local.iphone-usb-console-natpmp.plist.template \
  > runtime/public-production/com.local.iphone-usb-console-natpmp.plist
chmod 0600 runtime/public-production/com.local.iphone-usb-console-natpmp.plist
plutil -lint runtime/public-production/com.local.iphone-usb-console-natpmp.plist
cp runtime/public-production/com.local.iphone-usb-console-natpmp.plist \
  "$HOME/Library/LaunchAgents/com.local.iphone-usb-console-natpmp.plist"
chmod 0600 "$HOME/Library/LaunchAgents/com.local.iphone-usb-console-natpmp.plist"
launchctl bootstrap "gui/$(id -u)" \
  "$HOME/Library/LaunchAgents/com.local.iphone-usb-console-natpmp.plist"
```

LaunchAgent 每 900 秒续租一次 3600 秒租期，且固定 `PUBLIC_EDGE_MODE=production`。WAN IP 变化、Caddy 配置/进程不符、`utun` 未显式确认或安全端口出现非 loopback 监听时，续租都会失败关闭。

## 一键停用与回滚

任何时候先执行：

```zsh
cd /Users/niechen/Documents/Codex/2026-08-25/files-pasted-by-the-user-mac/work/iphone-usb-console/deploy
export PATH="/opt/homebrew/bin:$PATH"
./scripts/stop-public.zsh
```

成功输出必须同时说明续租已停、NAT-PMP lifetime 0 已确认、部署 Caddy 已停、`18443` 无监听。如果 NAT-PMP 删除无法验证，脚本仍会继续停止 Caddy，使转发目标没有服务，但会以失败状态提示人工检查路由器。若曾使用手工路由器转发而非 NAT-PMP，还必须在路由器管理页删除那条 TCP 443 规则；脚本无法删除手工规则。

回滚不删除任何证书、日志或应用数据。确认公网已经关闭后，可保留 LaunchAgent plist 和 `runtime/` 作为审计记录；若要清理，应另行人工审核路径后操作。原生应用和 USB 视频/控制链路不依赖 Caddy，停用公网不会影响当前本机效果。

## 不可变安全边界

- 不开放 TCP/UDP 80、UDP 443、TCP 5901、TCP 15901、TCP 18765。
- 只允许外部 TCP 443；路由器目标只能是 `192.168.31.112:18443`。
- Web 密码、TrollVNC 密码、session cookie、CSRF token、完整 URI 不进入 Caddy 日志。
- WAN IP 改变后，旧 certificate identity 和 staging 标记均不可复用；更新 IP、重新走 staging，再显式切 production。
- 公网测试必须来自蜂窝/云端，成功页面、登录、视频和控制均实际验证后才能报告“可用”。
