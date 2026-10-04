#!/bin/bash
set -euo pipefail
umask 077
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/.." && pwd)"
target="$repo/.private/credentials"
if [ -e "$target" ]; then
  echo "解密目录已存在：$target。为防止覆盖，本次退出。" >&2
  exit 1
fi
(cd "$here" && /usr/bin/shasum -a 256 -c server-access.sha256)
stage="$(mktemp -d "$repo/.decrypt.XXXXXXXX")"
trap 'unset secret; rm -rf "$stage"' EXIT
IFS= read -r -s -p '请输入单独提供的解密口令：' secret
printf '\n'
printf '%s\n' "$secret" | /usr/bin/openssl enc -d -aes-256-cbc \
  -pbkdf2 -iter 600000 -md sha256 -pass stdin \
  -in "$here/server-access.tar.gz.enc" -out "$stage/payload.tar.gz"
unset secret
/usr/bin/tar -tzf "$stage/payload.tar.gz" > "$stage/entries.txt"
while IFS= read -r name; do
  case "$name" in
    private-config|private-config/|private-config/*) ;;
    *) echo '归档路径不符合预期，已停止。' >&2; exit 1 ;;
  esac
  case "/$name/" in */../*) echo '归档包含不安全路径，已停止。' >&2; exit 1 ;; esac
done < "$stage/entries.txt"
/usr/bin/tar -xzf "$stage/payload.tar.gz" -C "$stage"
mkdir -p "$repo/.private"
chmod 700 "$repo/.private"
mv "$stage/private-config" "$target"
printf '已解密到：%s\n' "$target"
printf '香港管理员登录：bash "%s/hk-admin/login.command"\n' "$target"
printf '原站点配置仅作参考。新站点要使用独立端口、新设备编号和新密码。\n'
