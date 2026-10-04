#!/usr/bin/env python3
# Telegram command/callback handler for the phone-notification bot. Owner-only.
#   /on /off (global), /apps (per-phone per-app toggle + rename, paginated),
#   /status /help.
# App clones = distinct (pkg,userId) entries. Custom names (esp. clones, which
# the launcher won't expose over adb) are set in-bot via rename and stored in
# appnames.txt "serial<TAB>pkg<TAB>userId<TAB>name".
# muted.txt: "serial<TAB>pkg<TAB>userId".  apps-<serial>.txt: pkg<TAB>userId<TAB>name.
import fnmatch
import os, sys, json, urllib.request, urllib.parse

DIR = os.path.expanduser("~/notif-forward")
OFFSET_FILE = os.path.join(DIR, "tg_offset")
PAUSED_FILE = os.path.join(DIR, "paused")
MUTED_FILE = os.path.join(DIR, "muted.txt")
APPNAMES_FILE = os.path.join(DIR, "appnames.txt")
PENDING_FILE = os.path.join(DIR, "pending_rename.txt")
PAGE_SIZE = 12
IM_PACKAGES_FILE = os.path.join(DIR, "im-packages.txt")


def load_im_package_patterns():
    patterns = []
    try:
        for raw in open(IM_PACKAGES_FILE, encoding="utf-8"):
            pattern = raw.split("#", 1)[0].strip()
            if pattern:
                patterns.append(pattern)
    except Exception:
        pass
    return patterns


IM_PACKAGE_PATTERNS = load_im_package_patterns()


def is_im_package(package):
    return any(fnmatch.fnmatchcase(package, pattern) for pattern in IM_PACKAGE_PATTERNS)


def load_config():
    cfg = {}
    try:
        for line in open(os.path.join(DIR, "config.env"), encoding="utf-8"):
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            cfg[k] = v
    except Exception:
        pass
    return cfg


CFG = load_config()
TOKEN = (CFG.get("TG_BOT_TOKEN") or os.environ.get("TG_BOT_TOKEN", "")).strip()
allowed_raw = CFG.get("TG_ALLOWED_IDS") or CFG.get("TG_CHAT_ID") or os.environ.get("TG_ALLOWED_IDS") or os.environ.get("TG_CHAT_ID", "")
ALLOWED = {x for x in allowed_raw.replace(",", " ").split() if x}
PHONES = [(k[len("NAME_"):], v) for k, v in CFG.items() if k.startswith("NAME_")]
if not TOKEN:
    sys.exit(0)

API = "https://api.telegram.org/bot" + TOKEN


def api(method, params=None):
    data = urllib.parse.urlencode(params).encode() if params else None
    try:
        with urllib.request.urlopen(API + "/" + method, data=data, timeout=8) as r:
            return json.load(r)
    except Exception:
        return {}


def kb(rows):
    return json.dumps({"inline_keyboard": rows}, ensure_ascii=False)


def send_message(chat_id, text, keyboard=None):
    p = {"chat_id": chat_id, "text": text}
    if keyboard:
        p["reply_markup"] = keyboard
    api("sendMessage", p)


def send_force_reply(chat_id, text):
    api("sendMessage", {"chat_id": chat_id, "text": text,
                        "reply_markup": json.dumps({"force_reply": True})})


def edit_message(chat_id, mid, text, keyboard=None):
    p = {"chat_id": chat_id, "message_id": mid, "text": text}
    if keyboard:
        p["reply_markup"] = keyboard
    api("editMessageText", p)


def answer_cb(cb_id, text=None):
    p = {"callback_query_id": cb_id}
    if text:
        p["text"] = text
    api("answerCallbackQuery", p)


def is_paused():
    return os.path.exists(PAUSED_FILE)


def set_paused(p):
    if p:
        open(PAUSED_FILE, "w").write("1")
    else:
        try:
            os.remove(PAUSED_FILE)
        except FileNotFoundError:
            pass


def read_muted():
    s = set()
    try:
        for line in open(MUTED_FILE, encoding="utf-8"):
            line = line.rstrip("\n")
            if line.count("\t") == 2:
                s.add(line)
    except Exception:
        pass
    return s


def write_muted(s):
    open(MUTED_FILE, "w", encoding="utf-8").write("".join(x + "\n" for x in sorted(s)))


def read_appnames():
    d = {}
    try:
        for line in open(APPNAMES_FILE, encoding="utf-8"):
            line = line.rstrip("\n")
            parts = line.split("\t")
            if len(parts) >= 4 and parts[3]:
                d[(parts[0], parts[1], parts[2])] = parts[3]
    except Exception:
        pass
    return d


def set_appname(serial, pkg, uid, name):
    d = read_appnames()
    if name:
        d[(serial, pkg, uid)] = name
    else:
        d.pop((serial, pkg, uid), None)
    with open(APPNAMES_FILE, "w", encoding="utf-8") as f:
        for (s, p, u), n in sorted(d.items()):
            f.write("%s\t%s\t%s\t%s\n" % (s, p, u, n))


def mkey(serial, pkg, uid):
    return "%s\t%s\t%s" % (serial, pkg, uid)


def apps_for(serial):
    """[(aidx, pkg, uid, name)]; name = custom override if set, else file name."""
    over = read_appnames()
    out = []
    try:
        for i, line in enumerate(open(os.path.join(DIR, "apps-%s.txt" % serial), encoding="utf-8")):
            line = line.rstrip("\n")
            if not line:
                continue
            parts = line.split("\t")
            pkg = parts[0]
            if not is_im_package(pkg):
                continue
            uid = parts[1] if len(parts) > 1 else "0"
            name = parts[2] if len(parts) > 2 and parts[2] else pkg
            name = over.get((serial, pkg, uid), name)
            out.append((i, pkg, uid, name))
    except Exception:
        pass
    return out


def read_offset():
    try:
        return int(open(OFFSET_FILE).read().strip())
    except Exception:
        return 0


def write_offset(v):
    try:
        open(OFFSET_FILE, "w").write(str(v))
    except Exception:
        pass


def read_pending():
    try:
        parts = open(PENDING_FILE, encoding="utf-8").read().rstrip("\n").split("\t")
        if len(parts) == 6:
            return {"chat": parts[0], "mid": parts[1], "pidx": int(parts[2]),
                    "page": int(parts[3]), "serial": parts[4], "aidx": int(parts[5])}
    except Exception:
        pass
    return None


def set_pending(chat, mid, pidx, page, serial, aidx):
    open(PENDING_FILE, "w", encoding="utf-8").write(
        "%s\t%s\t%s\t%s\t%s\t%s\n" % (chat, mid, pidx, page, serial, aidx))


def clear_pending():
    try:
        os.remove(PENDING_FILE)
    except FileNotFoundError:
        pass


def status_text():
    return "🔔 全局：转发中" if not is_paused() else "🔕 全局：已暂停"


def muted_count(serial):
    muted = read_muted()
    visible = {mkey(serial, pkg, uid) for _i, pkg, uid, _name in apps_for(serial)}
    return len(muted & visible)


def phone_menu_kb():
    rows = []
    g = "🔕 全局已暂停 → 点此开启" if is_paused() else "🔔 全局转发中 → 点此暂停"
    rows.append([{"text": g, "callback_data": "g"}])
    for i, (serial, name) in enumerate(PHONES):
        n = muted_count(serial)
        label = "📱 %s" % name + ("（%d 个已屏蔽）" % n if n else "")
        rows.append([{"text": label, "callback_data": "ph:%d:0" % i}])
    return kb(rows)


def _sorted_apps(serial):
    apps = apps_for(serial)
    return sorted(apps, key=lambda t: (t[3] == t[1], t[3].lower()))


def app_menu_text(pidx, mode):
    serial, name = PHONES[pidx]
    if mode == "rn":
        return "【%s】改名模式：点选要改名的 App（分身可在这里起名）" % name
    return "【%s】共 %d 个通讯 App（✅=转发 / 🚫=屏蔽）\n点按切换；✏️改名可给分身起名。" % (name, len(apps_for(serial)))


def app_menu_kb(pidx, page, mode="t"):
    serial, name = PHONES[pidx]
    muted = read_muted()
    disp = _sorted_apps(serial)
    total = len(disp)
    pages = max(1, (total + PAGE_SIZE - 1) // PAGE_SIZE)
    page = max(0, min(page, pages - 1))
    rows = []
    if total == 0:
        rows.append([{"text": "（暂无 App，稍等自动刷新）", "callback_data": "noop"}])
    for aidx, pkg, uid, aname in disp[page * PAGE_SIZE:(page + 1) * PAGE_SIZE]:
        if mode == "rn":
            rows.append([{"text": "✏️ " + aname, "callback_data": "rn:%d:%d:%d" % (pidx, aidx, page)}])
        else:
            on = mkey(serial, pkg, uid) not in muted
            rows.append([{"text": "%s %s" % ("✅" if on else "🚫", aname),
                          "callback_data": "t:%d:%d:%d" % (pidx, aidx, page)}])
    if pages > 1:
        nav = []
        php = "phr" if mode == "rn" else "ph"
        if page > 0:
            nav.append({"text": "‹ 上一页", "callback_data": "%s:%d:%d" % (php, pidx, page - 1)})
        nav.append({"text": "%d/%d" % (page + 1, pages), "callback_data": "noop"})
        if page < pages - 1:
            nav.append({"text": "下一页 ›", "callback_data": "%s:%d:%d" % (php, pidx, page + 1)})
        rows.append(nav)
    if mode == "rn":
        rows.append([{"text": "↩︎ 完成改名（回到开关）", "callback_data": "ph:%d:%d" % (pidx, page)}])
    else:
        rows.append([
            {"text": "全部开启", "callback_data": "a:%d:1:%d" % (pidx, page)},
            {"text": "全部屏蔽", "callback_data": "a:%d:0:%d" % (pidx, page)},
        ])
        rows.append([{"text": "✏️ 改名模式", "callback_data": "phr:%d:%d" % (pidx, page)}])
    rows.append([{"text": "‹ 返回手机列表", "callback_data": "back"}])
    return kb(rows)


HELP = (
    "🤖 手机通知转发机器人\n\n"
    "/apps — 按手机 / App 设置转发；✏️改名模式可给分身起名\n"
    "/on  或 /开启 — 全局开启转发\n"
    "/off 或 /关闭 — 全局暂停转发\n"
    "/status 或 /状态 — 查看状态\n"
    "/help — 显示此帮助\n\n"
)


offset = read_offset()
resp = api("getUpdates", {"offset": offset + 1, "timeout": 0,
                          "allowed_updates": '["message","callback_query"]'})
if not resp.get("ok"):
    sys.exit(0)

max_id = offset
for u in resp.get("result", []):
    uid_ = u.get("update_id", 0)
    if uid_ > max_id:
        max_id = uid_

    cq = u.get("callback_query")
    if cq:
        frm = str(cq.get("from", {}).get("id"))
        data = cq.get("data", "") or ""
        msg = cq.get("message", {}) or {}
        chat_id = msg.get("chat", {}).get("id")
        mid = msg.get("message_id")
        if frm not in ALLOWED:
            answer_cb(cq.get("id"))
            continue
        try:
            if data == "g":
                set_paused(not is_paused())
                edit_message(chat_id, mid, "请选择要设置的手机：", phone_menu_kb())
                answer_cb(cq.get("id"), "全局已" + ("暂停" if is_paused() else "开启"))
            elif data == "back":
                edit_message(chat_id, mid, "请选择要设置的手机：", phone_menu_kb())
                answer_cb(cq.get("id"))
            elif data == "noop":
                answer_cb(cq.get("id"))
            elif data.startswith("phr:"):
                _, ps, pg = data.split(":")
                pidx = int(ps); page = int(pg)
                edit_message(chat_id, mid, app_menu_text(pidx, "rn"), app_menu_kb(pidx, page, "rn"))
                answer_cb(cq.get("id"))
            elif data.startswith("ph:"):
                parts = data.split(":")
                pidx = int(parts[1]); page = int(parts[2]) if len(parts) > 2 else 0
                edit_message(chat_id, mid, app_menu_text(pidx, "t"), app_menu_kb(pidx, page, "t"))
                answer_cb(cq.get("id"))
            elif data.startswith("t:"):
                _, ps, as_, pg = data.split(":")
                pidx = int(ps); aidx = int(as_); page = int(pg)
                serial, _ = PHONES[pidx]
                by_idx = {a[0]: a for a in apps_for(serial)}
                _i, pkg, cuid, aname = by_idx[aidx]
                key = mkey(serial, pkg, cuid)
                muted = read_muted()
                if key in muted:
                    muted.discard(key); note = "已开启：" + aname
                else:
                    muted.add(key); note = "已屏蔽：" + aname
                write_muted(muted)
                edit_message(chat_id, mid, app_menu_text(pidx, "t"), app_menu_kb(pidx, page, "t"))
                answer_cb(cq.get("id"), note)
            elif data.startswith("rn:"):
                _, ps, as_, pg = data.split(":")
                pidx = int(ps); aidx = int(as_); page = int(pg)
                serial, _ = PHONES[pidx]
                by_idx = {a[0]: a for a in apps_for(serial)}
                _i, pkg, cuid, aname = by_idx[aidx]
                set_pending(chat_id, mid, pidx, page, serial, aidx)
                send_force_reply(chat_id, "给「%s」起个新名字，直接回复此消息即可。\n（发一个减号 - 可恢复默认名）" % aname)
                answer_cb(cq.get("id"), "请回复新名字")
            elif data.startswith("a:"):
                _, ps, on, pg = data.split(":")
                pidx = int(ps); page = int(pg)
                serial, _ = PHONES[pidx]
                muted = read_muted()
                for _aidx, pkg, cuid, _n in apps_for(serial):
                    key = mkey(serial, pkg, cuid)
                    muted.add(key) if on == "0" else muted.discard(key)
                write_muted(muted)
                edit_message(chat_id, mid, app_menu_text(pidx, "t"), app_menu_kb(pidx, page, "t"))
                answer_cb(cq.get("id"), "全部" + ("屏蔽" if on == "0" else "开启"))
            else:
                answer_cb(cq.get("id"))
        except Exception:
            answer_cb(cq.get("id"))
        continue

    m = u.get("message") or {}
    chat = m.get("chat", {})
    cid = chat.get("id")
    text = (m.get("text") or "").strip()
    if cid is None:
        continue
    if str(cid) not in ALLOWED:
        continue
    if not text:
        continue

    # pending rename: a non-command reply becomes the new name
    pend = read_pending()
    if pend and str(pend["chat"]) == str(cid) and not text.startswith("/"):
        try:
            serial = pend["serial"]
            by_idx = {a[0]: a for a in apps_for(serial)}
            _i, pkg, cuid, oldname = by_idx[pend["aidx"]]
            newname = "" if text == "-" else text[:40]
            set_appname(serial, pkg, cuid, newname)
            shown = newname if newname else "（默认名）"
            send_message(cid, "✅ 已改名为：%s" % shown)
            edit_message(cid, pend["mid"], app_menu_text(pend["pidx"], "rn"),
                         app_menu_kb(pend["pidx"], pend["page"], "rn"))
        except Exception:
            send_message(cid, "改名失败，请重试。")
        clear_pending()
        continue

    cmd = text.split()[0].lower()
    if "@" in cmd:
        cmd = cmd.split("@", 1)[0]
    if cmd in ("/off", "/stop", "/pause", "/mute", "/关闭", "/暂停", "/停止"):
        set_paused(True); send_message(cid, "🔕 已全局暂停通知转发。发送 /on 恢复。")
    elif cmd in ("/on", "/resume", "/unmute", "/开启", "/恢复"):
        set_paused(False); send_message(cid, "🔔 已全局恢复通知转发。")
    elif cmd in ("/apps", "/app", "/应用", "/设置"):
        send_message(cid, "请选择要设置的手机：", phone_menu_kb())
    elif cmd in ("/status", "/state", "/状态"):
        lines = [status_text()]
        for serial, name in PHONES:
            lines.append("📱 %s：共 %d 个通讯 App，屏蔽 %d 个" % (name, len(apps_for(serial)), muted_count(serial)))
        send_message(cid, "\n".join(lines))
    elif cmd in ("/start", "/help", "/帮助"):
        send_message(cid, HELP + status_text())
    else:
        send_message(cid, "未知指令，/help 查看。\n" + status_text())

write_offset(max_id)
