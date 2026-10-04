# 在新 Mac 上接手 iOS 构建和发布

本说明对应 RemoteHandset（计算器远控 App）。服务器凭证仍由 `Credentials/decrypt.command` 单独解密；本页说明的是 iOS 发布凭证。

## 已核实信息

| 项目 | 值 |
| --- | --- |
| App Store Connect Key ID | `67LCK7NDBS` |
| Issuer ID | `04749df8-717c-4976-b7ba-ef75bd6e8ea5` |
| App ID | `6799048892` |
| Bundle ID | `com.dltengwen.remotehandset` |
| Apple Team ID | `232AW49Q9J` |
| 描述文件类型 | App Store |
| 描述文件有效期 | 至 2027-06-24；实际失效时刻以文件内 `ExpirationDate` 为准 |
| 描述文件匹配的证书 SHA-1 指纹 | `3D0436E9D1438AC2FD91692E688B171AAAE9B884` |

App Store Connect API 使用上述密钥访问已返回 HTTP 200。这证明该 API 访问已验证；实际构建、签名和上传还需要新 Mac 上的 Xcode、可用签名身份及相应权限。

**本包已包含上传 API 私钥、App Store 描述文件和公开证书，但不包含签名私钥或 P12。** 原 MacBook 的匹配身份存在、钥匙串已解锁且密钥可导出；从 SSH 调用标准导出接口仍被 macOS 拒绝（`errSecInteractionNotAllowed`，-25308），需要在正常本机会话中完成系统授权。新增 Distribution 证书请求也被 Apple 以 HTTP 409 拒绝，未创建或撤销任何证书。

这套材料可用于上传已有的有效签名 IPA；新 Mac 要独立构建、签名和导出新版，还必须补齐匹配的 P12，或正常配置另一套有效签名身份。不要把本包当作完整签名环境。包内 `manifest.json` 记录此限制。

## 解密

在仓库根目录执行：

```bash
bash Credentials/decrypt-ios.command
```

脚本需要 Python 3、macOS 自带的 OpenSSL 和 shasum。它先校验 `Credentials/ios-publish-credentials.sha256`，再交互读取单独提供的口令。加密参数为 AES-256-CBC、PBKDF2、SHA-256、600000 次迭代。

解密结果写入 `.private/ios-publishing/`；该目录已存在时拒绝覆盖。临时目录权限为 0700，正常退出或报错后清理。归档必须以 `ios-publish` 为根，仅允许普通文件和目录；绝对路径、`..`、符号链接、硬链接及特殊文件均被拒绝。

请先阅读解密目录中的清单和说明。私钥、P12 口令、API 配置及解密内容不得加入 Git，也不要打印 JWT、私钥或口令到日志。

## 配置 API 密钥

找到包内的 App Store Connect `.p8` 私钥和 JSON 配置。将 JSON 配置中的 `keyPath` 改为该私钥在新 Mac 上的**绝对路径**，保留已核实的 `keyId` 和 `issuerId`。例如目录应从 `/Users/新电脑用户名/...` 开始，不能继续使用旧 MacBook 的路径，也不能直接写 `~`。

原脚本 `Distribution/generate_asc_jwt.js` 使用 `path.resolve(config.keyPath)`，相对路径会按运行时工作目录解析。因此需要重写本机绝对路径后再使用该脚本。将私钥与配置权限设为 0600。生成的 JWT 是短期访问凭证，仅在调用 API 时使用，不要存入共享文件或提交到仓库。

## 导入签名材料

安装适用的 Xcode，完成命令行工具选择和首次启动。当前包没有 P12 或 P12 导入口令，以下签名步骤只能在后续取得匹配 P12 后进行。不要撤销、替换旧 MacBook 的证书，也不要导入整个旧钥匙串。

使用以下命令检查新 Mac 的代码签名身份：

```bash
security find-identity -v -p codesigning
```

应能看到有效身份指纹 `3D0436E9D1438AC2FD91692E688B171AAAE9B884`。签名需要该证书对应的私钥；只有 `.cer` 文件不够。再安装匹配的 App Store 描述文件，检查 Team ID、Bundle ID、证书指纹及有效期，然后按 Xcode 项目的签名设置选择同一身份与描述文件。

若交接包没有可导入且有效的匹配 P12，先记录确切缺失项，继续完成源码和 API 配置；不要擅自撤销旧证书或声称 App 已具备发布条件。

## 构建、验证和上传

先阅读 `Handoff/notes-app.txt` 和 `Handoff/TestFlight-upload-reference.md`，复用已成功验证的项目构建与上传流程，并将其中本机路径改为新 Mac 的实际路径。

新电脑上的两台手机需要独立设备清单和服务器入口。不要覆盖原七台 Android 手机用户正在使用的入口、设备配置或已发布版本。使用现有 Bundle ID 上传属于同一个 App，并不会自动成为独立 App；正式发布前必须确认版本如何兼容旧站点，或明确采用独立 App 的方案及签名材料。

每次提交构建前，查询 App Store Connect 中该 App 的最新构建号，按项目的版本策略递增 `buildNumber`（最终写入 `CFBundleVersion`），不要照搬交接时的旧编号。完成 Archive、签名与导出验证后，再使用已配置的 API 密钥上传。

上传成功只表示构建已送达 App Store Connect；仍需检查处理状态。TestFlight 测试分发与正式 App Store 发布是不同步骤，不要将上传完成称为正式上线。
