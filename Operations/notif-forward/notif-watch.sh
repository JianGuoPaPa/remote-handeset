#!/bin/bash
# Android notification -> Telegram forwarder (runs on the Mac mini).
# Watches EVERY connected phone over adb every POLL seconds, de-dupes, and
# pushes new WeChat notifications to a Telegram bot. Message = 📱【phone name】
# app name + text.
#
# App-cloning ("应用分身"): the same package runs under extra user profiles
# (userId 900+). Each (pkg,userId) is a DISTINCT app here — separate list entry,
# separate on/off. userId 0/-1 = owner/system (no clone suffix).
#
# Name resolution priority (resolve_name):
#   1. custom override  appnames.txt  "serial<TAB>pkg<TAB>userId<TAB>name"
#   2. aapt real name   appcache.txt  "pkg<TAB>name"   (built by build-app-labels.sh)
#   3. built-in map     friendly()
#   4. package id
#   + "·分身N" suffix for clone users.
#
# Forwarding is limited to WeChat (com.tencent.mm). Additional filtering from
# the bot remains available: global on/off = paused file; per-app off =
# "serial<TAB>pkg<TAB>userId" lines in muted.txt.
set -uo pipefail

DIR="$HOME/notif-forward"
[ -f "$DIR/config.env" ] && . "$DIR/config.env"
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"
export TG_BOT_TOKEN="${TG_BOT_TOKEN:-}" TG_CHAT_ID="${TG_CHAT_ID:-}" TG_ALLOWED_IDS="${TG_ALLOWED_IDS:-}"

POLL="${POLL:-2}"
SEEN="$DIR/seen.txt"
PAUSED_FILE="$DIR/paused"
MUTED_FILE="$DIR/muted.txt"
APPCACHE_FILE="$DIR/appcache.txt"
APPNAMES_FILE="$DIR/appnames.txt"
IM_PACKAGES_FILE="$DIR/im-packages.txt"
mkdir -p "$DIR"; touch "$SEEN" "$MUTED_FILE" "$APPCACHE_FILE" "$APPNAMES_FILE"
MODE="${1:-daemon}"

list_serials() {
  if [ -n "${SERIALS:-}" ]; then echo "$SERIALS"
  else adb devices 2>/dev/null | awk 'NR>1 && $2=="device"{print $1}'; fi
}

label_for() {  # serial -> phone name
  local s="$1" var v m
  var="NAME_${s}"; v="${!var:-}"
  if [ -n "$v" ]; then echo "$v"; return; fi
  m=$(adb -s "$s" shell getprop ro.product.model 2>/dev/null | tr -d '\r\n')
  [ -z "$m" ] && m="$s"; echo "$m"
}

is_im_package() {  # package -> 0 when it belongs in the Telegram /apps menu
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

is_forwarded_notification_package() {  # package -> 0 when it may reach Telegram
  [ "$1" = "com.tencent.mm" ]
}

friendly() {  # package -> curated name, else the package id
  case "$1" in
    com.tencent.mm) echo "微信" ;;
    com.tencent.mobileqq*|com.tencent.qqlite|com.tencent.mobileqqi|com.tencent.minihd.qq) echo "QQ" ;;
    com.tencent.tim) echo "TIM" ;;
    com.tencent.wework|com.tencent.work|com.tencent.work.multiapp) echo "企业微信" ;;
    com.eg.android.AlipayGphone|com.alipay.android.app|hk.alipay.wallet) echo "支付宝" ;;
    com.taobao.taobao) echo "淘宝" ;;
    com.tmall.wireless) echo "天猫" ;;
    com.jingdong.app.mall) echo "京东" ;;
    com.sankuai.meituan) echo "美团" ;;
    me.ele) echo "饿了么" ;;
    com.ss.android.ugc.aweme) echo "抖音" ;;
    com.smile.gifmaker) echo "快手" ;;
    com.sina.weibo) echo "微博" ;;
    com.xingin.xhs) echo "小红书" ;;
    com.zhihu.android) echo "知乎" ;;
    com.alibaba.android.rimet) echo "钉钉" ;;
    com.ss.android.lark|com.larksuite.suite|com.bytedance.feishu) echo "飞书 / Lark" ;;
    com.tencent.qqmail) echo "QQ邮箱" ;;
    com.netease.mail|com.netease.mobimail) echo "网易邮箱" ;;
    com.baidu.searchbox) echo "百度" ;;
    com.autonavi.minimap) echo "高德地图" ;;
    com.baidu.BaiduMap) echo "百度地图" ;;
    com.tencent.map) echo "腾讯地图" ;;
    com.unionpay) echo "云闪付" ;;
    com.chinamworld.main) echo "中国建设银行" ;;
    com.icbc) echo "工商银行" ;;
    com.android.bankabc) echo "农业银行" ;;
    com.chinamobile.contacts.im|com.greenpoint.android.mc10086.activity) echo "中国移动" ;;
    com.sinovatech.unicom.ui) echo "中国联通" ;;
    com.ct.client) echo "电信营业厅" ;;
    org.telegram.messenger*|org.thunderdog.challegram) echo "Telegram" ;;
    com.whatsapp.w4b) echo "WhatsApp Business" ;;
    com.whatsapp*) echo "WhatsApp" ;;
    jp.naver.line.android) echo "LINE" ;;
    org.thoughtcrime.securesms) echo "Signal" ;;
    com.viber.voip) echo "Viber" ;;
    com.zing.zalo) echo "Zalo" ;;
    com.kakao.talk) echo "KakaoTalk" ;;
    com.skype.raider) echo "Skype" ;;
    com.discord) echo "Discord" ;;
    com.Slack) echo "Slack" ;;
    com.microsoft.teams*|com.microsoft.office.teams) echo "Microsoft Teams" ;;
    com.imo.android.imoim*) echo "imo" ;;
    kik.android) echo "Kik" ;;
    com.beeper.android) echo "Beeper" ;;
    network.loki.messenger) echo "Session" ;;
    im.vector.app|io.element.android.x) echo "Element" ;;
    com.wire) echo "Wire" ;;
    com.facebook.katana) echo "Facebook" ;;
    com.facebook.lite) echo "Facebook Lite" ;;
    com.facebook.orca) echo "Messenger" ;;
    com.facebook.mlite) echo "Messenger Lite" ;;
    com.instagram.android) echo "Instagram" ;;
    com.twitter.android|com.x.android) echo "X" ;;
    com.snapchat.android) echo "Snapchat" ;;
    com.grabtaxi.passenger) echo "Grab" ;;
    com.google.android.gm) echo "Gmail" ;;
    com.google.android.apps.dynamite) echo "Google Chat" ;;
    com.google.android.apps.tachyon) echo "Google Meet" ;;
    com.google.android.apps.messaging|com.android.mms|com.android.messaging|com.samsung.android.messaging) echo "短信" ;;
    com.google.android.gms) echo "Google 服务" ;;
    com.google.android.googlequicksearchbox) echo "Google" ;;
    com.android.vending) echo "Play 商店" ;;
    com.android.chrome) echo "Chrome" ;;
    com.microsoft.office.outlook) echo "Outlook" ;;
    com.android.systemui) echo "系统界面" ;;
    android) echo "系统" ;;
    com.android.phone|com.android.server.telecom) echo "电话" ;;
    com.android.settings) echo "设置" ;;
    com.motorola.ccc.ota) echo "手机系统更新" ;;
    com.motorola.*) echo "摩托罗拉" ;;
    com.lenovo.leos.appstore) echo "联想应用商店" ;;
    com.lenovo.lsf|com.lenovo.lsf.device) echo "联想服务" ;;
    com.lenovo.club.app) echo "联想圈" ;;
    com.zui.zhealthy) echo "联想健康" ;;
    com.klook) echo "Klook" ;;
    com.binance.dev) echo "币安 Binance" ;;
    com.okx.wallet) echo "OKX" ;;
    com.tencent.qqlivei18n) echo "WeTV" ;;
    com.ss.android.ugc.trill) echo "TikTok" ;;
    com.sohu.inputmethod.sogou.moto|com.sohu.inputmethod.sogou) echo "搜狗输入法" ;;
    com.chinamobile.mcloudlite) echo "移动云盘" ;;
    mail139.launcher) echo "139邮箱" ;;
    cn.emagsoftware.gamehall) echo "咪咕游戏厅" ;;
    com.ss.android.article.news) echo "今日头条" ;;
    com.agoda.mobile.consumer) echo "Agoda" ;;
    tv.danmaku.bili|tv.danmaku.bilibilihd) echo "哔哩哔哩" ;;
    com.tencent.qqmusic) echo "QQ音乐" ;;
    com.netease.cloudmusic) echo "网易云音乐" ;;
    com.lenovo.motorola.argus.camera|com.motorola.camera3) echo "相机" ;;
    com.lenovo.menu_assistant) echo "联想语音助手" ;;
    com.lenovo.octopus) echo "联想互传" ;;
    com.pinduoduo|com.xunmeng.pinduoduo) echo "拼多多" ;;
    *) echo "$1" ;;
  esac
}

# serial pkg userId -> display name (override > aapt cache > map > pkg, + clone suffix)
resolve_name() {
  local s="$1" p="$2" u="$3" ov c base n
  [ "$u" = "-1" ] && u=0
  ov=$(awk -F'\t' -v s="$s" -v p="$p" -v u="$u" '$1==s&&$2==p&&$3==u{print $4; exit}' "$APPNAMES_FILE" 2>/dev/null)
  if [ -n "$ov" ]; then echo "$ov"; return; fi
  c=$(awk -F'\t' -v p="$p" '$1==p{print $2; exit}' "$APPCACHE_FILE" 2>/dev/null)
  if [ -n "$c" ]; then base="$c"; else base="$(friendly "$p")"; fi
  if [ -n "$u" ] && [ "$u" != "0" ]; then
    n=$((u - 899)) 2>/dev/null || n="$u"
    [ "$n" -ge 1 ] 2>/dev/null && echo "${base}·分身${n}" || echo "${base}·分身${u}"
  else
    echo "$base"
  fi
}

# record an (pkg,userId) app for a phone (dedup); store resolved name.
append_app_to_file() {  # file pkg userId name
  local f="$1"; touch "$f"
  awk -F'\t' -v p="$2" -v u="$3" '$1==p&&$2==u{found=1} END{exit !found}' "$f" 2>/dev/null && return 0
  printf '%s\t%s\t%s\n' "$2" "$3" "$4" >> "$f"
}

record_app() {  # serial pkg userId name
  is_im_package "$2" || return 0
  append_app_to_file "$DIR/apps-$1.txt" "$2" "$3" "$4"
}

# rewrite the name column of apps-<serial>.txt (apply latest cache/overrides),
# preserving line order so the bot's paginated indices stay stable.
refresh_names() {  # serial
  local f="$DIR/apps-$1.txt" tmp pkg uid name
  [ -f "$f" ] || return 0
  tmp="$f.tmp"; : > "$tmp"
  while IFS=$'\t' read -r pkg uid name; do
    [ -z "$pkg" ] && continue
    printf '%s\t%s\t%s\n' "$pkg" "$uid" "$(resolve_name "$1" "$pkg" "$uid")" >> "$tmp"
  done < "$f"
  mv "$tmp" "$f"
}

# Rebuild the IM-only list across all user profiles. Package enumeration is a
# single lightweight pm query per profile; APKs and labels are never pulled here.
# Atomic replacement prevents the Telegram menu from seeing a partial list.
refresh_app_list() {  # serial
  local s="$1" f="$DIR/apps-$1.txt" tmp="$DIR/.apps-$1.tmp.$$"
  local users u pkg packages queried=0
  adb -s "$s" get-state 2>/dev/null | grep -qxF device || return 1
  users=$(adb -s "$s" shell pm list users 2>/dev/null | grep -oE 'UserInfo\{[0-9]+' | grep -oE '[0-9]+')
  [ -n "$users" ] || users=0
  : > "$tmp"
  for u in $users; do
    if packages=$(adb -s "$s" shell pm list packages -3 --user "$u" 2>/dev/null | tr -d '\r' | sed 's/^package://'); then
      queried=1
      while IFS= read -r pkg; do
        [[ "$pkg" =~ ^[a-zA-Z][a-zA-Z0-9_.]*$ ]] || continue
        is_im_package "$pkg" || continue
        append_app_to_file "$tmp" "$pkg" "$u" "$(resolve_name "$s" "$pkg" "$u")"
      done <<< "$packages"
    fi
  done
  if [ "$queried" -ne 1 ]; then
    rm -f "$tmp"
    return 1
  fi
  mv -f "$tmp" "$f"
  refresh_names "$s"
}

is_muted() {  # serial pkg userId
  grep -qxF "$(printf '%s\t%s\t%s' "$1" "$2" "$3")" "$MUTED_FILE" 2>/dev/null
}

# Parse dumpsys: key <US> pkg <US> userId <US> title <US> text   (US = 0x1F)
parse() {
  adb -s "$1" shell dumpsys notification --noredact 2>/dev/null | tr -d '\r' | awk '
    BEGIN { SEP=sprintf("%c",31) }
    function emit() {
      if (key=="") return
      if (title=="" && text=="") return
      split(key, ka, "|"); uid=ka[1]
      k=key; gsub(/\|/,"_",k)
      print k SEP pkg SEP uid SEP title SEP text
    }
    /NotificationRecord\(/ {
      emit(); pkg=""; key=""; title=""; text=""
      if (match($0,/pkg=[^ ]+/)) pkg=substr($0,RSTART+4,RLENGTH-4)
      if (match($0,/key=[^:]+/)) key=substr($0,RSTART+4,RLENGTH-4)
      next
    }
    /android\.title=String \(/ { s=$0; sub(/.*android\.title=String \(/,"",s); sub(/\)[ \t]*$/,"",s); title=s }
    /android\.text=String \(/  { s=$0; sub(/.*android\.text=String \(/,"",s);  sub(/\)[ \t]*$/,"",s);  text=s }
    END { emit() }
  '
}

send() {
  [ -n "${TG_BOT_TOKEN:-}" ] && [ -n "${TG_CHAT_ID:-}" ] || return 0
  curl -s --max-time 15 "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TG_CHAT_ID}" \
    --data-urlencode "text=$1" -o /dev/null
}

# A remote-control session streams scrcpy video through the SAME adb/USB channel
# these dumpsys polls use. Polling while streaming stalls the video for seconds
# and pushes the WebRTC RTT from ~15 ms to 1700-3000 ms, so stay off the channel
# while a session is live. Notifications resume as soon as it ends.
remote_session_active() {
  pgrep -f "com.genymobile.scrcpy.Server" >/dev/null 2>&1
}

process_commands() {
  [ -n "${TG_BOT_TOKEN:-}" ] || return 0
  [ -f "$DIR/tg-commands.py" ] || return 0
  python3 "$DIR/tg-commands.py" >/dev/null 2>&1 || true
}

wait_with_command_poll() {  # seconds; keep Telegram controls responsive
  local remaining="$1"
  while [ "$remaining" -gt 0 ]; do
    sleep 1
    process_commands
    remaining=$((remaining - 1))
  done
}

handle() {  # mode = send | dry
  local mode="$1" s phone applabel uid global_off=0
  [ -f "$PAUSED_FILE" ] && global_off=1
  for s in $(list_serials); do
    phone=$(label_for "$s")
    parse "$s" | while IFS=$'\x1f' read -r key pkg uid title text; do
      is_forwarded_notification_package "$pkg" || continue
      id=$(printf '%s|%s|%s|%s' "$s" "$key" "$title" "$text" | md5 -q 2>/dev/null || printf '%s|%s|%s|%s' "$s" "$key" "$title" "$text" | md5)
      grep -qxF "$id" "$SEEN" && continue
      echo "$id" >> "$SEEN"
      [ "$uid" = "-1" ] && uid=0
      applabel=$(resolve_name "$s" "$pkg" "$uid")
      record_app "$s" "$pkg" "$uid" "$applabel"
      msg="📱【${phone}】${applabel}"
      [ -n "$title" ] && [ "$title" != "null" ] && msg="${msg}"$'\n'"${title}"
      [ -n "$text" ]  && [ "$text"  != "null" ] && msg="${msg}"$'\n'"${text}"
      if [ "$mode" = "dry" ]; then echo "---- WOULD SEND ----"; echo "$msg"; continue; fi
      [ "$global_off" = 1 ] && continue
      is_muted "$s" "$pkg" "$uid" && continue
      send "$msg"
    done
  done
  tail -n 3000 "$SEEN" > "$SEEN.tmp" 2>/dev/null && mv "$SEEN.tmp" "$SEEN"
}

prime() {
  local s uid
  for s in $(list_serials); do
    refresh_app_list "$s"
    parse "$s" | while IFS=$'\x1f' read -r key pkg uid title text; do
      [ "$uid" = "-1" ] && uid=0
      record_app "$s" "$pkg" "$uid" "$(resolve_name "$s" "$pkg" "$uid")"
      id=$(printf '%s|%s|%s|%s' "$s" "$key" "$title" "$text" | md5 -q 2>/dev/null || printf '%s|%s|%s|%s' "$s" "$key" "$title" "$text" | md5)
      grep -qxF "$id" "$SEEN" || echo "$id" >> "$SEEN"
    done
  done
}

case "$MODE" in
  --once) handle dry ;;
  --dry)  prime; echo "[primed; watching, dry-run]"; while true; do handle dry; sleep "$POLL"; done ;;
  *)      prime
          n=0
          while true; do
            process_commands
            handle send
            n=$((n+1))
            if [ $((n % 150)) -eq 0 ] && ! remote_session_active; then
              for s in $(list_serials); do refresh_app_list "$s"; done
            fi
            if remote_session_active; then
              # Video shares the adb/USB channel with these dumpsys polls, so
              # keep forwarding notifications gently while Telegram controls
              # remain responsive instead of waiting for the full 10s cycle.
              wait_with_command_poll 10
            else
              sleep "$POLL"
            fi
          done ;;
esac
