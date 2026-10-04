# 远控计算器 TestFlight 成功上传流程

这份方案交给 Mac mini 上负责远控计算器发布的执行者。2026 年 10 月 3 日，Mac mini 交付的 `RemoteHandset-1.0.0-33.ipa` 已由本机成功上传，Apple 处理状态为 `VALID`，构建已出现在现有“个人测试”组中。

当前可复用的流程是：Mac mini 把签名完成的 IPA 放在 Downloads，本机取回文件，使用 Apple 官方旧版 altool 的 `--upload-package`，显式指定应用 ID 和包内版本，随后确认 Apple 处理结果及测试组包含该构建。

## 应用和成功记录

| 项目 | 已确认的值 |
| --- | --- |
| App Store Connect 应用名 | 简易计算器工具 |
| 安装后的显示名 | 计算器 |
| 应用 Apple ID | `6799048892` |
| Bundle ID | `com.dltengwen.remotehandset` |
| 开发团队 ID | `232AW49Q9J` |
| API Key ID | `67LCK7NDBS` |
| API Issuer ID | `04749df8-717c-4976-b7ba-ef75bd6e8ea5` |
| 本次版本 | `1.0.0`，构建 `33` |
| 个人测试组 ID | `0d25f9b4-4901-4891-b9dc-c387bd0c1a16` |
| 本次上传 Delivery UUID | `33ddbd04-34ae-4668-9732-90dee214e506` |
| IPA SHA256 | `d332c9139932d393a8623e5238eb8faa89c788e2104ea362b4011158bdfe8fae` |

构建 33 已上传，不要再次提交相同构建。下一版必须使用尚未上传的构建号；通常从 34 开始，但先核对后台已有编号。上传参数必须与 IPA 内的 `CFBundleVersion` 和 `CFBundleShortVersionString` 一致，单独修改命令参数不能改变安装包版本。

## 当前两台机器的环境

成功执行上传的本机使用 `/Applications/Xcode.app/Contents/Developer`，并已有以下认证文件：

- API 配置：`/Users/zhaogongzi/.config/dmini/asc-api-key.json`
- 配置所引用的私钥：`/Users/zhaogongzi/.config/dmini/asc-api-key.p8`
- altool 可发现的私钥：`/Users/zhaogongzi/.appstoreconnect/private_keys/AuthKey_67LCK7NDBS.p8`
- JWT 生成工具：`/Users/zhaogongzi/Documents/手机远控/Distribution/generate_asc_jwt.js`

本次检查 Mac mini 时，`xcode-select -p` 返回 `/Library/Developer/CommandLineTools`，`xcrun --find altool` 找不到工具；上述认证文件在 mini 的对应路径下也不存在。这是当前检查结果，不代表其他目录一定没有 Xcode 或凭据。现阶段按下面的交付流程让本机上传。若以后改由 mini 直接上传，先确认完整 Xcode 的开发工具路径、旧版 altool 和经过授权配置的认证文件都已可用。

本文仅记录 Key ID、Issuer ID 和文件路径，不包含私钥内容、密码或 JWT。不要把认证文件放进源码目录或上传日志。

## 第一步 Mac mini 交付安装包

将签名完成的 IPA 放在 mini 的：

```text
/Users/zhaogongzi/Downloads/RemoteHandset-<版本>-<构建号>.ipa
```

向负责本机上传的执行者交付准确路径、包内版本、构建号和 SHA256。签名应为该应用的 App Store 分发签名；本次使用的描述文件名为 `Remote Handset App Store`。

在 mini 上计算校验值：

```bash
shasum -a 256 "$HOME/Downloads/RemoteHandset-<版本>-<构建号>.ipa"
```

本次交付路径为 `/Users/zhaogongzi/Downloads/RemoteHandset-1.0.0-33.ipa`。

## 第二步 本机取回并核对安装包

以下命令在已成功上传的本机执行。`rh-macmini` 是这台本机已有的 SSH 别名，对应 `zhaogongzi@mac-mini-2.local`。

用实际新版本替换 `APP_VERSION` 和 `BUILD_NUMBER`，不要照抄已上传的 33：

```bash
APP_VERSION='1.0.0'
BUILD_NUMBER='34'
RELEASE_DIR="$HOME/Documents/手机远控/Distribution/TestFlight-${APP_VERSION}-${BUILD_NUMBER}-from-mini"
IPA_PATH="$RELEASE_DIR/RemoteHandset-${APP_VERSION}-${BUILD_NUMBER}.ipa"

mkdir -p "$RELEASE_DIR"
scp -p "rh-macmini:/Users/zhaogongzi/Downloads/RemoteHandset-${APP_VERSION}-${BUILD_NUMBER}.ipa" "$IPA_PATH"
shasum -a 256 "$IPA_PATH"
```

本机校验值必须与 mini 交付的值一致。接着读取 IPA 的实际身份和版本：

```bash
python3 - "$IPA_PATH" <<'PY'
import json, plistlib, sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as archive:
    candidates = [name for name in archive.namelist()
                  if name.startswith('Payload/') and name.count('/') == 2
                  and name.endswith('.app/Info.plist')]
    if len(candidates) != 1:
        raise SystemExit('无法唯一定位主应用 Info.plist')
    info = plistlib.loads(archive.read(candidates[0]))
    fields = ('CFBundleIdentifier', 'CFBundleShortVersionString', 'CFBundleVersion')
    print(json.dumps({key: info.get(key) for key in fields}, ensure_ascii=False))
PY
```

确认 Bundle ID 为 `com.dltengwen.remotehandset`，并将后续上传参数设为这里读出的真实版本。

## 第三步 使用已成功的上传命令

先确认本机工具可用：

```bash
xcode-select -p
xcrun --find altool
xcrun altool --use-old-altool --help
```

若已安装完整 Xcode，但默认选到了 Command Line Tools，可在当前终端使用 `export DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer'`；路径应指向这台机器实际安装的完整 Xcode。

在第二步的同一终端执行以下命令。本机已有的 `AuthKey_67LCK7NDBS.p8` 供 altool 查找使用：

```bash
ASC_KEY_ID='67LCK7NDBS'
ASC_ISSUER_ID='04749df8-717c-4976-b7ba-ef75bd6e8ea5'
UPLOAD_LOG="$RELEASE_DIR/altool-upload-$(date +%Y%m%d-%H%M%S).log"

(
  set -o pipefail
  xcrun altool --use-old-altool \
    --upload-package "$IPA_PATH" \
    --type ios \
    --apple-id 6799048892 \
    --bundle-version "$BUILD_NUMBER" \
    --bundle-short-version-string "$APP_VERSION" \
    --bundle-id com.dltengwen.remotehandset \
    --asc-public-id "$ASC_ISSUER_ID" \
    --apiKey "$ASC_KEY_ID" \
    --apiIssuer "$ASC_ISSUER_ID" \
    2>&1 | tee "$UPLOAD_LOG"
)
```

这与本次成功命令采用同一组上传选项；本次实际版本参数是 `1.0.0` 和 `33`。

只有命令退出码为 0，且 Apple 明确返回 `UPLOAD SUCCEEDED with no errors`，才能报告上传成功。保存返回的 Delivery UUID，作为下一步查询依据。命令已经成功后，不要因为后台列表暂时未出现该构建而再次上传。

## 第四步 确认 Apple 已处理安装包

使用新上传返回的 Delivery UUID 替换占位值：

```bash
DELIVERY_ID='<本次上传返回的 Delivery UUID>'
xcrun altool --build-status \
  --delivery-id "$DELIVERY_ID" \
  --api-key "$ASC_KEY_ID" \
  --api-issuer "$ASC_ISSUER_ID" \
  --output-format json
```

这里使用默认 altool 的 `--build-status`，没有添加 `--use-old-altool`。本次它成功返回：`build-status=VALID`、`import-status=VALID`、`is-on-app-store-connect=true`。

构建列表刚开始可能为空。本次安装包在 Apple 接收后，稍后才出现在构建列表中。继续观察同一构建的状态，不能把“已接收”直接写成“已处理完成”，也不能因列表暂时为空就创建重复上传。

## 第五步 确认现有个人测试组可见

在 App Store Connect 中打开应用 `6799048892` 的 TestFlight，确认新构建已显示，并在“个人测试”组中可见。本次已有组配置 `hasAccessToAllBuilds=true`，构建 33 自动进入该组，没有新增测试人员或更改分发权限。

可通过现有 JWT 工具及 API 只读核对。先用 `GET /v1/builds?filter[app]=6799048892&filter[version]=<构建号>&include=preReleaseVersion` 查询新构建，确认关联版本正确，取响应 `data[].id` 作为 `ASC_BUILD_ID`。本次它为 `33ddbd04-34ae-4668-9732-90dee214e506`。以下命令在本机执行：

```bash
ASC_BUILD_ID='<本次构建记录的 data[].id>'
python3 - "$ASC_BUILD_ID" <<'PY'
import json, subprocess, sys, urllib.request

expected = sys.argv[1]
token = subprocess.check_output([
    'node',
    '/Users/zhaogongzi/Documents/手机远控/Distribution/generate_asc_jwt.js',
    '/Users/zhaogongzi/.config/dmini/asc-api-key.json',
], text=True).strip()
url = ('https://api.appstoreconnect.apple.com/v1/betaGroups/'
       '0d25f9b4-4901-4891-b9dc-c387bd0c1a16/relationships/builds?limit=200')
ids = set()
while url:
    request = urllib.request.Request(url, headers={'Authorization': 'Bearer ' + token})
    with urllib.request.urlopen(request, timeout=30) as response:
        data = json.load(response)
    ids.update(build['id'] for build in data.get('data', []))
    url = data.get('links', {}).get('next')
present = expected in ids
print(json.dumps({'group': '个人测试', 'buildPresent': present}, ensure_ascii=False))
raise SystemExit(0 if present else 1)
PY
```

本次 Delivery UUID 与 App Store Connect build ID 相同，但后续分发查询应使用实际 `ASC_BUILD_ID`，不要假定它总与上传接收编号相同。若关系查询没有找到新构建，检查组内状态；不要据此直接再次上传。

完成后应分别报告：上传成功、Apple 处理完成、构建在个人测试组中可见。手机实际安装和远控功能运行情况属于另外的确认步骤，本方案没有运行手机功能测试。

## 查询错误的处理

本次 `/v1/apps?filter[bundleId]=...` 返回 `403 FORBIDDEN.REQUIRED_AGREEMENTS_MISSING_OR_EXPIRED`，默认 `--upload-app` 随后返回 `Cannot determine the Apple ID from Bundle ID`。这两个结果没有证明本次 IPA 无法上传，也不足以直接断定账号仍有协议未签。

同一 Key ID 和 Issuer ID 使用下列官方命令，可以正常识别正确开发团队和应用：

```bash
xcrun altool --list-providers --legacy \
  --api-key "$ASC_KEY_ID" --api-issuer "$ASC_ISSUER_ID" --output-format json

xcrun altool --use-old-altool --list-apps \
  --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID" --output-format json
```

随后显式指定应用 ID 的 `--upload-package` 成功上传，`--build-status`、构建查询和个人测试组查询也成功。因此，对这款应用复用本文的明确应用 ID 和上传命令，不要依赖出错的应用自动查询步骤。

若未来上传本身返回明确的协议拒绝，再结合正确团队的实际后台状态判断。确有待签协议时，交由账号持有人阅读处理，不自动替用户接受协议。本次未对 Apple 的协议错误产生原因作出确定诊断。
