#!/bin/bash
set -euo pipefail
umask 077

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/.." && pwd)"
target="$repo/.private/ios-publishing"
if ! command -v python3 >/dev/null 2>&1; then
  echo '需要 Python 3 验证并安全解压凭证归档，请先安装 Python 3。' >&2
  exit 1
fi
if [ -L "$repo/.private" ]; then
  echo '.private 不能是符号链接，已停止。' >&2
  exit 1
fi
if [ -e "$target" ] || [ -L "$target" ]; then
  echo "解密目录已存在：$target。为防止覆盖，本次退出。" >&2
  exit 1
fi
(cd "$here" && /usr/bin/shasum -a 256 -c ios-publish-credentials.sha256)
stage="$(mktemp -d "$repo/.decrypt.XXXXXXXX")"
chmod 700 "$stage"
trap 'unset secret; rm -rf -- "$stage"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

IFS= read -r -s -p '请输入单独提供的解密口令：' secret
printf '\n'
printf '%s\n' "$secret" | /usr/bin/openssl enc -d -aes-256-cbc \
  -pbkdf2 -iter 600000 -md sha256 -pass stdin \
  -in "$here/ios-publish-credentials.tar.gz.enc" -out "$stage/payload.tar.gz"
unset secret

python3 - "$stage" <<'PY'
import pathlib
import shutil
import sys
import tarfile

stage = pathlib.Path(sys.argv[1])
with tarfile.open(stage / "payload.tar.gz", "r:gz") as archive:
    members = archive.getmembers()
    if not members:
        raise SystemExit("归档为空，已停止。")
    seen = set()
    for member in members:
        name = member.name
        path = pathlib.PurePosixPath(name)
        if (path.is_absolute() or ".." in name.split("/")
                or not path.parts or path.parts[0] != "ios-publish"
                or "\\" in name):
            raise SystemExit("归档包含不安全路径，已停止。")
        if not (member.isdir() or member.isfile()):
            raise SystemExit("归档包含链接或特殊文件，已停止。")
        if len(path.parts) == 1 and not member.isdir():
            raise SystemExit("归档根目录类型不符合预期，已停止。")
        normalized = str(path)
        if normalized in seen:
            raise SystemExit("归档包含重复路径，已停止。")
        seen.add(normalized)

    # 先验证全部成员，再手动提取普通文件，避免 tar 自动处理链接或权限。
    for member in members:
        destination = stage.joinpath(*pathlib.PurePosixPath(member.name).parts)
        if member.isdir():
            destination.mkdir(mode=0o700, parents=True, exist_ok=True)
        else:
            destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            source = archive.extractfile(member)
            if source is None:
                raise SystemExit("无法读取归档文件，已停止。")
            with source, destination.open("xb") as output:
                shutil.copyfileobj(source, output)
            destination.chmod(0o600)
PY

if [ -L "$repo/.private" ] || [ -e "$target" ] || [ -L "$target" ]; then
  echo '目标目录在解密期间发生变化，为防止覆盖，已停止。' >&2
  exit 1
fi
mkdir -p "$repo/.private"
chmod 700 "$repo/.private"
mv "$stage/ios-publish" "$target"
printf '已解密到：%s\n' "$target"
printf '下一步请阅读 Handoff/ios-publishing.md 和加密包内的说明。\n'
printf '解密内容、口令及签名私钥不得提交到 Git。\n'
