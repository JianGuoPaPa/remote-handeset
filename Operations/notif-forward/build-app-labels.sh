#!/bin/bash
# One-shot / re-runnable: resolve real launcher names via aapt2 for apps not
# yet cached. Pulls each app's base.apk one at a time, extracts the best label
# (zh-CN > zh > default), appends to appcache.txt (pkg<TAB>label), deletes the
# apk. Skips already-cached apps and APKs larger than MAXBYTES (the big common
# apps are already named by the map, so no need to pull hundreds of MB).
set -uo pipefail
DIR="$HOME/notif-forward"
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"
AAPT="$DIR/tools/aapt2"
CACHE="$DIR/appcache.txt"
IM_PACKAGES_FILE="$DIR/im-packages.txt"
touch "$CACHE"
TMP="/tmp/applabel-$$.apk"
MAXBYTES=$((120 * 1024 * 1024))

list_serials() { adb devices 2>/dev/null | awk 'NR>1 && $2=="device"{print $1}'; }

is_im_package() {
  local pkg="$1" pattern
  [ -r "$IM_PACKAGES_FILE" ] || return 1
  while IFS= read -r pattern || [ -n "$pattern" ]; do
    pattern="${pattern%%#*}"
    pattern="${pattern#"${pattern%%[![:space:]]*}"}"
    pattern="${pattern%"${pattern##*[![:space:]]}"}"
    [ -z "$pattern" ] && continue
    case "$pkg" in $pattern) return 0 ;; esac
  done < "$IM_PACKAGES_FILE"
  return 1
}

extract_label() {
  "$AAPT" dump badging "$1" 2>/dev/null | awk -F"'" '
    /^application-label-zh-CN:/ {z=$2}
    /^application-label-zh:/    {if(z=="")z=$2}
    /^application-label:/       {d=$2}
    END { if(z!="") print z; else print d }'
}

[ -x "$AAPT" ] || { echo "no aapt2 at $AAPT"; exit 1; }

PKGLIST="/tmp/applabel-pkgs-$$.txt"
for s in $(list_serials); do
  # collect the package list to a FILE first — looping over a pipe while running
  # adb inside the loop makes adb eat the loop's stdin and it stops after one.
  adb -s "$s" shell pm list packages -3 </dev/null 2>/dev/null | tr -d '\r' | sed 's/^package://' \
    | grep -E '^[a-zA-Z][a-zA-Z0-9_.]*$' | sort -u > "$PKGLIST"
  while IFS= read -r pkg; do
    [ -z "$pkg" ] && continue
    is_im_package "$pkg" || continue
    cut -f1 "$CACHE" 2>/dev/null | grep -qxF "$pkg" && continue
    p=$(adb -s "$s" shell pm path "$pkg" </dev/null 2>/dev/null | grep base.apk | head -1 | tr -d '\r' | sed 's/^package://')
    [ -z "$p" ] && continue
    sz=$(adb -s "$s" shell stat -c %s "$p" </dev/null 2>/dev/null | tr -d '\r'); [ -z "$sz" ] && sz=0
    if [ "$sz" -gt "$MAXBYTES" ] 2>/dev/null; then echo "skip-big $pkg $((sz/1024/1024))MB"; continue; fi
    adb -s "$s" pull "$p" "$TMP" </dev/null >/dev/null 2>&1 || { echo "pull-fail $pkg"; continue; }
    label=$(extract_label "$TMP"); rm -f "$TMP"
    if [ -n "$label" ]; then printf '%s\t%s\n' "$pkg" "$label" >> "$CACHE"; echo "cached $pkg = $label"; fi
  done < "$PKGLIST"
done
rm -f "$PKGLIST"
echo "DONE app-label cache ($(wc -l < "$CACHE") entries)"
