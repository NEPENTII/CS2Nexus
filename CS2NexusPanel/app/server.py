#!/usr/bin/env python3
"""CS2Nexus web panel: player login by in-game code, live servers, play history, matches.

Standard library only (Python 3.8+). Two listeners:
  * public   (settings.port, HTTP or HTTPS) : the website + /api/*
  * internal (127.0.0.1:settings.internal_port) : /api/plugin/* used by the NexusLink plugin (needs the API key)
"""
import hashlib, hmac, http.server, json, mimetypes, os, queue, re, secrets, signal, socketserver, sqlite3, ssl, sys, threading, time, urllib.request
from collections import deque
from http.cookies import SimpleCookie
from urllib.parse import urlparse, parse_qs

APP_DIR = os.path.dirname(os.path.abspath(__file__))
STATIC_DIR = os.path.join(APP_DIR, "static")
DATA_DIR = os.environ.get("NEXUS_PANEL_DATA", "/opt/cs2-panel/data")
SETTINGS_FILE = os.path.join(DATA_DIR, "settings.json")
DB_FILE = os.path.join(DATA_DIR, "panel.db")

DEFAULTS = {
    "port": 8080, "bind": "0.0.0.0", "internal_port": 27500, "api_key": "",
    "domain": "", "tls_cert": "", "tls_key": "", "trust_proxy": False,
    "servers_file": os.path.join(DATA_DIR, "servers-public.json"),
    "maps_dir": "/opt/cs2-panel/maps", "title": "CS2Nexus",
    "session_hours": 720, "code_ttl": 600, "steam_api_key": "",
}

CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
STEAM_RX = re.compile(r"^\d{17}$")
NAME_CLEAN = re.compile(r"[\x00-\x1f\x7f]")
LIVE_FRESH = 25          # seconds without a snapshot before a server counts as offline
MAX_BODY = 1_000_000

S = dict(DEFAULTS)
DB = None
DB_LOCK = threading.RLock()
LIVE = {}                # server_id -> snapshot dict (+ "_ts")
LIVE_LOCK = threading.RLock()
RATE = {}                # ip -> deque of timestamps
RATE_LOCK = threading.Lock()
_servers_cache = {"mtime": 0, "data": []}


def log(msg):
    sys.stderr.write("%s %s\n" % (time.strftime("%F %T"), msg))
    sys.stderr.flush()


def load_settings():
    global S
    S = dict(DEFAULTS)
    try:
        with open(SETTINGS_FILE, "r", encoding="utf-8") as f:
            S.update({k: v for k, v in json.load(f).items() if k in DEFAULTS})
    except FileNotFoundError:
        log("settings.json not found, using defaults")
    except Exception as e:
        log("cannot read settings.json: %s" % e)
    S["port"] = int(S["port"]); S["internal_port"] = int(S["internal_port"])


# ----------------------------------------------------------------------------- database
SCHEMA = """
CREATE TABLE IF NOT EXISTS users(steam TEXT PRIMARY KEY, name TEXT NOT NULL DEFAULT '', first_seen INTEGER NOT NULL,
    last_login INTEGER, prev_login INTEGER, last_seen INTEGER, last_server INTEGER);
CREATE TABLE IF NOT EXISTS codes(code TEXT PRIMARY KEY, steam TEXT NOT NULL, name TEXT, server_id INTEGER, created INTEGER NOT NULL, used INTEGER NOT NULL DEFAULT 0);
CREATE INDEX IF NOT EXISTS codes_steam ON codes(steam);
CREATE TABLE IF NOT EXISTS sessions(token_hash TEXT PRIMARY KEY, steam TEXT NOT NULL, created INTEGER NOT NULL, expires INTEGER NOT NULL, ip TEXT);
CREATE INDEX IF NOT EXISTS sessions_steam ON sessions(steam);
CREATE TABLE IF NOT EXISTS play_sessions(id INTEGER PRIMARY KEY AUTOINCREMENT, steam TEXT NOT NULL, server_id INTEGER NOT NULL, joined INTEGER NOT NULL, left INTEGER);
CREATE INDEX IF NOT EXISTS ps_steam ON play_sessions(steam, server_id);
CREATE INDEX IF NOT EXISTS ps_open ON play_sessions(server_id, left);
CREATE TABLE IF NOT EXISTS server_names(server_id INTEGER PRIMARY KEY, name TEXT, last_map TEXT, last_seen INTEGER);
CREATE TABLE IF NOT EXISTS matches(id INTEGER PRIMARY KEY AUTOINCREMENT, server_id INTEGER NOT NULL, uid TEXT NOT NULL, map TEXT, started INTEGER, ended INTEGER NOT NULL,
    score_t INTEGER, score_ct INTEGER, winner INTEGER, rounds INTEGER, UNIQUE(server_id, uid));
CREATE TABLE IF NOT EXISTS match_players(match_id INTEGER NOT NULL, steam TEXT NOT NULL, name TEXT, team INTEGER, kills INTEGER, deaths INTEGER, assists INTEGER,
    damage INTEGER, mvps INTEGER, score INTEGER, present_at_end INTEGER, PRIMARY KEY(match_id, steam));
CREATE INDEX IF NOT EXISTS mp_steam ON match_players(steam);
CREATE TABLE IF NOT EXISTS avatars(steam TEXT PRIMARY KEY, fetched INTEGER NOT NULL, ok INTEGER NOT NULL DEFAULT 0, persona TEXT);
"""


def db_open():
    global DB
    os.makedirs(DATA_DIR, exist_ok=True)
    DB = sqlite3.connect(DB_FILE, check_same_thread=False, isolation_level=None, timeout=15)
    DB.row_factory = sqlite3.Row
    DB.execute("PRAGMA journal_mode=WAL")
    DB.execute("PRAGMA synchronous=NORMAL")
    DB.executescript(SCHEMA)
    try: os.chmod(DB_FILE, 0o600)
    except OSError: pass
    # sessions that were open when the panel stopped are closed at their last known moment
    with DB_LOCK:
        DB.execute("UPDATE play_sessions SET left = MAX(joined, COALESCE((SELECT last_seen FROM users u WHERE u.steam = play_sessions.steam), joined)) WHERE left IS NULL")
        DB.execute("DELETE FROM sessions WHERE expires < ?", (int(time.time()),))
        DB.execute("DELETE FROM codes WHERE created < ?", (int(time.time()) - 86400,))


def now():
    return int(time.time())


def clean_name(v, n=64):
    return NAME_CLEAN.sub("", str(v or "")).strip()[:n]


def to_int(v, d=0, lo=-10**9, hi=10**9):
    try: v = int(v)
    except (TypeError, ValueError): return d
    return max(lo, min(hi, v))


def norm_map(m):
    m = str(m or "").strip().lower().replace("\\", "/")
    m = m.split("/")[-1]
    return re.sub(r"[^a-z0-9_\-]", "", m)[:64]


# ----------------------------------------------------------------------------- servers list (written by the launcher)
def file_servers():
    p = S["servers_file"]
    try:
        mt = os.path.getmtime(p)
        if mt != _servers_cache["mtime"]:
            with open(p, "r", encoding="utf-8") as f:
                d = json.load(f)
            _servers_cache["data"] = [x for x in d if isinstance(x, dict) and isinstance(x.get("id"), int)]
            _servers_cache["mtime"] = mt
    except Exception:
        pass
    return _servers_cache["data"]


def live_fresh(sid):
    with LIVE_LOCK:
        d = LIVE.get(sid)
        if d and now() - d["_ts"] <= LIVE_FRESH:
            return d
    return None


def server_name(sid):
    for s in file_servers():
        if s.get("id") == sid and s.get("name"):
            return str(s["name"])
    d = live_fresh(sid)
    if d and d.get("name"):
        return d["name"]
    with DB_LOCK:
        r = DB.execute("SELECT name FROM server_names WHERE server_id=?", (sid,)).fetchone()
    return (r["name"] if r and r["name"] else "Server %d" % sid)


def public_servers():
    out, seen = [], set()
    for s in file_servers():
        sid = s["id"]; seen.add(sid)
        d = live_fresh(sid)
        out.append({"id": sid, "name": str(s.get("name") or "Server %d" % sid), "port": s.get("port"),
                    "online": bool(d), "map": (d or {}).get("map") or s.get("map") or "",
                    "players": len((d or {}).get("players", [])) if d else 0,
                    "max": (d or {}).get("max") or s.get("maxplayers") or 0})
    with LIVE_LOCK:
        extra = [k for k in LIVE if k not in seen]
    for sid in extra:
        d = live_fresh(sid)
        if d:
            out.append({"id": sid, "name": d.get("name") or "Server %d" % sid, "port": None, "online": True,
                        "map": d.get("map") or "", "players": len(d.get("players", [])), "max": d.get("max") or 0})
    out.sort(key=lambda x: x["id"])
    return out


# ----------------------------------------------------------------------------- plugin events
def handle_code(body):
    steam = str(body.get("steam", ""))
    if not STEAM_RX.match(steam):
        return {"ok": False, "error": "Invalid player."}
    name = clean_name(body.get("name"))
    t = now()
    with DB_LOCK:
        n = DB.execute("SELECT COUNT(*) c FROM codes WHERE steam=? AND created > ?", (steam, t - 600)).fetchone()["c"]
        if n >= 6:
            return {"ok": False, "error": "Too many codes requested. Wait a few minutes."}
        DB.execute("UPDATE codes SET used=1 WHERE steam=? AND used=0", (steam,))
        for _ in range(20):
            code = "".join(secrets.choice(CODE_ALPHABET) for _ in range(8))
            try:
                DB.execute("INSERT INTO codes(code, steam, name, server_id, created) VALUES(?,?,?,?,?)",
                           (code, steam, name, to_int(body.get("server_id")), t))
                break
            except sqlite3.IntegrityError:
                continue
        else:
            return {"ok": False, "error": "Try again."}
        DB.execute("INSERT INTO users(steam, name, first_seen, last_seen) VALUES(?,?,?,?) ON CONFLICT(steam) DO UPDATE SET name=excluded.name",
                   (steam, name, t, t))
    return {"ok": True, "code": code[:4] + "-" + code[4:], "ttl": int(S["code_ttl"])}


def handle_snapshot(body):
    sid = to_int(body.get("server_id"), 0, 1, 10**6)
    if sid <= 0:
        return {"ok": False, "error": "server_id"}
    t = now()
    players = []
    for p in (body.get("players") or [])[:128]:
        if not isinstance(p, dict) or not STEAM_RX.match(str(p.get("steam", ""))):
            continue
        players.append({"steam": str(p["steam"]), "name": clean_name(p.get("name")), "team": to_int(p.get("team"), 0, 0, 3),
                        "kills": to_int(p.get("kills"), 0, 0, 10**4), "deaths": to_int(p.get("deaths"), 0, 0, 10**4),
                        "assists": to_int(p.get("assists"), 0, 0, 10**4), "score": to_int(p.get("score"), 0, -10**4, 10**5),
                        "ping": to_int(p.get("ping"), 0, 0, 10**4), "joined": to_int(p.get("joined"), t, 0, t + 60) or t})
    snap = {"name": clean_name(body.get("name"), 100), "map": clean_name(body.get("map"), 64), "max": to_int(body.get("max"), 0, 0, 128),
            "in_match": bool(body.get("in_match")), "warmup": bool(body.get("warmup")),
            "score_t": to_int(body.get("score_t"), 0, 0, 999), "score_ct": to_int(body.get("score_ct"), 0, 0, 999),
            "players": players, "_ts": t}
    with LIVE_LOCK:
        LIVE[sid] = snap
    steams = [p["steam"] for p in players]
    for s_ in steams[:64]: av_want(s_)
    with DB_LOCK:
        DB.execute("BEGIN")
        try:
            DB.execute("INSERT INTO server_names(server_id,name,last_map,last_seen) VALUES(?,?,?,?) ON CONFLICT(server_id) DO UPDATE SET name=CASE WHEN excluded.name<>'' THEN excluded.name ELSE name END, last_map=excluded.last_map, last_seen=excluded.last_seen",
                       (sid, snap["name"], snap["map"], t))
            for p in players:
                DB.execute("INSERT INTO users(steam,name,first_seen,last_seen,last_server) VALUES(?,?,?,?,?) ON CONFLICT(steam) DO UPDATE SET name=excluded.name, last_seen=excluded.last_seen, last_server=excluded.last_server",
                           (p["steam"], p["name"], t, t, sid))
                # one open session per player: opened here, any open session elsewhere is closed
                DB.execute("UPDATE play_sessions SET left=? WHERE steam=? AND left IS NULL AND server_id<>?", (t, p["steam"], sid))
                if not DB.execute("SELECT 1 FROM play_sessions WHERE steam=? AND server_id=? AND left IS NULL", (p["steam"], sid)).fetchone():
                    DB.execute("INSERT INTO play_sessions(steam,server_id,joined) VALUES(?,?,?)", (p["steam"], sid, min(p["joined"], t)))
            if steams:
                q = ",".join("?" * len(steams))
                DB.execute("UPDATE play_sessions SET left=? WHERE server_id=? AND left IS NULL AND steam NOT IN (%s)" % q, [t, sid] + steams)
            else:
                DB.execute("UPDATE play_sessions SET left=? WHERE server_id=? AND left IS NULL", (t, sid))
            DB.execute("COMMIT")
        except Exception:
            DB.execute("ROLLBACK"); raise
    return {"ok": True}


def handle_match(body):
    sid = to_int(body.get("server_id"), 0, 1, 10**6)
    uid = clean_name(body.get("uid"), 64)
    if sid <= 0 or not uid:
        return {"ok": False, "error": "bad match"}
    players = [p for p in (body.get("players") or [])[:128] if isinstance(p, dict) and STEAM_RX.match(str(p.get("steam", "")))]
    with DB_LOCK:
        DB.execute("BEGIN")
        try:
            cur = DB.execute("INSERT OR IGNORE INTO matches(server_id,uid,map,started,ended,score_t,score_ct,winner,rounds) VALUES(?,?,?,?,?,?,?,?,?)",
                             (sid, uid, clean_name(body.get("map"), 64), to_int(body.get("started"), 0, 0, 4 * 10**9), to_int(body.get("ended"), now(), 0, 4 * 10**9),
                              to_int(body.get("score_t"), 0, 0, 999), to_int(body.get("score_ct"), 0, 0, 999),
                              to_int(body.get("winner"), 0, 0, 3), to_int(body.get("rounds"), 0, 0, 999)))
            if cur.rowcount:
                mid = cur.lastrowid
                for p in players:
                    DB.execute("INSERT OR REPLACE INTO match_players VALUES(?,?,?,?,?,?,?,?,?,?,?)",
                               (mid, str(p["steam"]), clean_name(p.get("name")), to_int(p.get("team"), 0, 0, 3), to_int(p.get("kills"), 0, 0, 10**4),
                                to_int(p.get("deaths"), 0, 0, 10**4), to_int(p.get("assists"), 0, 0, 10**4), to_int(p.get("damage"), 0, 0, 10**6),
                                to_int(p.get("mvps"), 0, 0, 10**3), to_int(p.get("score"), 0, -10**4, 10**5), 1 if p.get("present_at_end") else 0))
            DB.execute("COMMIT")
        except Exception:
            DB.execute("ROLLBACK"); raise
    return {"ok": True}


def reaper():
    """Servers that stopped sending snapshots: close their open play sessions at the last snapshot time."""
    while True:
        time.sleep(10)
        try:
            t = now()
            with LIVE_LOCK:
                stale = [(sid, d["_ts"]) for sid, d in LIVE.items() if t - d["_ts"] > LIVE_FRESH and d.get("players")]
            for sid, ts in stale:
                with DB_LOCK:
                    DB.execute("UPDATE play_sessions SET left=? WHERE server_id=? AND left IS NULL", (ts, sid))
                with LIVE_LOCK:
                    if sid in LIVE: LIVE[sid]["players"] = []
            with DB_LOCK:
                DB.execute("DELETE FROM sessions WHERE expires < ?", (t,))
        except Exception as e:
            log("reaper: %s" % e)



# ----------------------------------------------------------------------------- steam avatars
AV_DIR = None
AV_Q = queue.Queue(maxsize=500)
AV_PENDING = set()
AV_TTL_OK = 24 * 3600
AV_TTL_FAIL = 2 * 3600
AV_HOSTS = ("steamstatic.com", "akamaihd.net", "steamcommunity.com", "steamusercontent.com")


def av_path(steam):
    return os.path.join(AV_DIR, steam + ".jpg")


def av_want(steam):
    """Queue a refresh of this player's Steam avatar when it is missing or old."""
    if not STEAM_RX.match(steam or ""):
        return
    with DB_LOCK:
        r = DB.execute("SELECT fetched, ok FROM avatars WHERE steam=?", (steam,)).fetchone()
    if r and now() - r["fetched"] < (AV_TTL_OK if r["ok"] else AV_TTL_FAIL) and (not r["ok"] or os.path.isfile(av_path(steam))):
        return
    if steam in AV_PENDING:
        return
    try:
        AV_PENDING.add(steam)
        AV_Q.put_nowait(steam)
    except queue.Full:
        AV_PENDING.discard(steam)


def _http_get(url, limit, timeout=8):
    req = urllib.request.Request(url, headers={"User-Agent": "CS2Nexus-Panel/1.0"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read(limit + 1)[:limit]


def av_lookup(steam):
    """Return (avatar_url, persona_name) from Steam, or (None, None)."""
    key = (S.get("steam_api_key") or "").strip()
    if key:
        try:
            d = json.loads(_http_get("https://api.steampowered.com/ISteamUser/GetPlayerSummaries/v2/?key=%s&steamids=%s" % (key, steam), 100000))
            pl = (d.get("response") or {}).get("players") or []
            if pl:
                return pl[0].get("avatarfull") or pl[0].get("avatarmedium"), pl[0].get("personaname")
        except Exception as e:
            log("steam api failed: %s" % e)
    try:
        x = _http_get("https://steamcommunity.com/profiles/%s/?xml=1" % steam, 200000).decode("utf-8", "replace")
        m = re.search(r"<avatarFull><!\[CDATA\[(.*?)\]\]></avatarFull>", x) or re.search(r"<avatarMedium><!\[CDATA\[(.*?)\]\]></avatarMedium>", x)
        n = re.search(r"<steamID><!\[CDATA\[(.*?)\]\]></steamID>", x)
        return (m.group(1) if m else None), (n.group(1) if n else None)
    except Exception as e:
        log("steam profile failed for %s: %s" % (steam, e))
        return None, None


def av_worker():
    while True:
        steam = AV_Q.get()
        ok = 0; persona = None
        try:
            url, persona = av_lookup(steam)
            if url and url.startswith("https://") and any((urlparse(url).hostname or "").endswith(h) for h in AV_HOSTS):
                data = _http_get(url, 400000)
                if data[:3] == b"\xff\xd8\xff":
                    tmp = av_path(steam) + ".tmp"
                    with open(tmp, "wb") as f: f.write(data)
                    os.replace(tmp, av_path(steam))
                    ok = 1
        except Exception as e:
            log("avatar %s failed: %s" % (steam, e))
        with DB_LOCK:
            DB.execute("INSERT INTO avatars(steam,fetched,ok,persona) VALUES(?,?,?,?) ON CONFLICT(steam) DO UPDATE SET fetched=excluded.fetched, ok=excluded.ok, persona=COALESCE(excluded.persona, avatars.persona)",
                       (steam, now(), ok, persona))
        AV_PENDING.discard(steam)
        time.sleep(0.4)


# ----------------------------------------------------------------------------- user data
def me_payload(steam):
    t = now()
    with DB_LOCK:
        u = DB.execute("SELECT * FROM users WHERE steam=?", (steam,)).fetchone()
        if not u:
            return None
        rows = DB.execute("SELECT server_id, SUM(COALESCE(left,?)-joined) secs, MAX(COALESCE(left,?)) last, COUNT(*) n FROM play_sessions WHERE steam=? GROUP BY server_id ORDER BY last DESC", (t, t, steam)).fetchall()
        mrows = DB.execute("SELECT m.winner, m.score_t, m.score_ct, p.team FROM match_players p JOIN matches m ON m.id=p.match_id WHERE p.steam=?", (steam,)).fetchall()
    servers = [{"server_id": r["server_id"], "name": server_name(r["server_id"]), "seconds": int(r["secs"] or 0), "last_played": r["last"], "sessions": r["n"]} for r in rows]
    total = sum(s["seconds"] for s in servers)
    w = l = d = 0
    for r in mrows:
        res = result_for(r["team"], r["score_t"], r["score_ct"])
        if res == "win": w += 1
        elif res == "loss": l += 1
        elif res == "draw": d += 1
    online = None
    with LIVE_LOCK:
        for sid, snap in LIVE.items():
            if t - snap["_ts"] > LIVE_FRESH: continue
            if any(p["steam"] == steam for p in snap["players"]):
                online = {"server_id": sid, "name": server_name(sid), "map": snap["map"], "max": snap["max"], "in_match": snap["in_match"], "warmup": snap["warmup"],
                          "score_t": snap["score_t"], "score_ct": snap["score_ct"], "port": next((s.get("port") for s in file_servers() if s["id"] == sid), None),
                          "players": [{"steam": p["steam"], "name": p["name"], "team": p["team"], "joined": p["joined"], "kills": p["kills"], "deaths": p["deaths"], "score": p["score"],
                                       "me": p["steam"] == steam} for p in sorted(snap["players"], key=lambda x: (-x["score"], x["name"].lower()))]}
                break
    av_want(steam)
    return {"steam": steam, "name": u["name"], "first_seen": u["first_seen"], "last_login": u["prev_login"], "last_seen": u["last_seen"],
            "playtime": total, "online": online, "servers": servers, "matches": {"total": len(mrows), "wins": w, "losses": l, "draws": d}, "now": t}


def result_for(team, st, sct):
    if team == 2: mine, other = st, sct
    elif team == 3: mine, other = sct, st
    else: return None
    return "win" if mine > other else "loss" if mine < other else "draw"


def match_list(steam, limit, offset):
    with DB_LOCK:
        rows = DB.execute("SELECT m.id, m.server_id, m.map, m.started, m.ended, m.score_t, m.score_ct, m.rounds, p.team, p.kills, p.deaths, p.assists "
                          "FROM match_players p JOIN matches m ON m.id=p.match_id WHERE p.steam=? ORDER BY m.ended DESC LIMIT ? OFFSET ?",
                          (steam, limit, offset)).fetchall()
    return [{"id": r["id"], "server_id": r["server_id"], "server": server_name(r["server_id"]), "map": r["map"], "started": r["started"], "ended": r["ended"],
             "score_t": r["score_t"], "score_ct": r["score_ct"], "rounds": r["rounds"], "team": r["team"], "kills": r["kills"], "deaths": r["deaths"],
             "assists": r["assists"], "result": result_for(r["team"], r["score_t"], r["score_ct"])} for r in rows]


def match_detail(steam, mid):
    with DB_LOCK:
        mine = DB.execute("SELECT team FROM match_players WHERE match_id=? AND steam=?", (mid, steam)).fetchone()
        if not mine: return None
        m = DB.execute("SELECT * FROM matches WHERE id=?", (mid,)).fetchone()
        ps = DB.execute("SELECT steam, name, team, kills, deaths, assists, damage, mvps, score, present_at_end FROM match_players WHERE match_id=? ORDER BY team, score DESC, kills DESC", (mid,)).fetchall()
    return {"id": m["id"], "server": server_name(m["server_id"]), "map": m["map"], "started": m["started"], "ended": m["ended"], "score_t": m["score_t"],
            "score_ct": m["score_ct"], "rounds": m["rounds"], "result": result_for(mine["team"], m["score_t"], m["score_ct"]),
            "players": [{"name": p["name"], "team": p["team"], "kills": p["kills"], "deaths": p["deaths"], "assists": p["assists"], "damage": p["damage"],
                         "mvps": p["mvps"], "score": p["score"], "left_early": not p["present_at_end"], "me": p["steam"] == steam, "steam": p["steam"]} for p in ps]}


def maps_available():
    out = {}
    d = S["maps_dir"]
    try:
        for f in os.listdir(d):
            base, ext = os.path.splitext(f)
            if ext.lower() in (".png", ".jpg", ".jpeg", ".webp") and re.match(r"^[A-Za-z0-9_\-]+$", base):
                out[base.lower()] = f
    except OSError:
        pass
    return out


# ----------------------------------------------------------------------------- auth
def rate_ok(key, limit, window):
    t = time.time()
    with RATE_LOCK:
        q = RATE.setdefault(key, deque())
        while q and q[0] < t - window: q.popleft()
        if len(q) >= limit: return False
        q.append(t)
        if len(RATE) > 5000:
            for k in [k for k, v in RATE.items() if not v or v[-1] < t - 3600]: RATE.pop(k, None)
    return True


def redeem(code, ip):
    code = re.sub(r"[^A-Za-z0-9]", "", str(code or "")).upper()
    if len(code) != 8: return None
    t = now()
    with DB_LOCK:
        r = DB.execute("SELECT * FROM codes WHERE code=? AND used=0", (code,)).fetchone()
        if not r or t - r["created"] > int(S["code_ttl"]):
            return None
        DB.execute("UPDATE codes SET used=1 WHERE code=?", (code,))
        steam = r["steam"]
        DB.execute("UPDATE users SET prev_login=last_login, last_login=? WHERE steam=?", (t, steam))
        token = secrets.token_urlsafe(32)
        DB.execute("INSERT INTO sessions(token_hash, steam, created, expires, ip) VALUES(?,?,?,?,?)",
                   (hashlib.sha256(token.encode()).hexdigest(), steam, t, t + int(S["session_hours"]) * 3600, ip))
    return steam, token


def session_user(token):
    if not token: return None
    with DB_LOCK:
        r = DB.execute("SELECT steam FROM sessions WHERE token_hash=? AND expires>?", (hashlib.sha256(token.encode()).hexdigest(), now())).fetchone()
    return r["steam"] if r else None


# ----------------------------------------------------------------------------- http
class Quiet(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True
    request_queue_size = 64
    tls_ctx = None      # the TLS handshake happens in the request thread, so a slow client cannot block accept()

    def handle_error(self, request, client_address):
        e = sys.exc_info()[1]
        if not isinstance(e, (ConnectionError, TimeoutError, ssl.SSLError, OSError)):
            log("request error from %s: %r" % (client_address[0], e))


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "CS2NexusPanel"
    sys_version = ""
    internal = False
    protocol_version = "HTTP/1.1"
    timeout = 20

    def setup(self):
        ctx = getattr(self.server, "tls_ctx", None)
        if ctx is not None:
            self.request.settimeout(10)
            self.request = ctx.wrap_socket(self.request, server_side=True)
        super().setup()

    def log_message(self, fmt, *a):
        pass

    # ---- helpers
    def ip(self):
        if S.get("trust_proxy"):
            xf = self.headers.get("X-Forwarded-For", "")
            if xf: return xf.split(",")[0].strip()[:45]
        return self.client_address[0]

    def send_json(self, obj, status=200, headers=None):
        data = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.security_headers()
        for k, v in (headers or []): self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def security_headers(self):
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Content-Security-Policy", "default-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'")

    def read_json(self):
        n = to_int(self.headers.get("Content-Length"), 0, 0, MAX_BODY + 1)
        if n > MAX_BODY: raise ValueError("too large")
        raw = self.rfile.read(n) if n else b"{}"
        d = json.loads(raw.decode("utf-8") or "{}")
        if not isinstance(d, dict): raise ValueError("object expected")
        return d

    def cookie(self, name):
        try:
            c = SimpleCookie(self.headers.get("Cookie", ""))
            return c[name].value if name in c else ""
        except Exception:
            return ""

    def user(self):
        return session_user(self.cookie("nx_session"))

    def secure_cookie(self):
        return bool(S["tls_cert"] and S["tls_key"]) or (S.get("trust_proxy") and self.headers.get("X-Forwarded-Proto") == "https")

    # ---- methods
    def do_GET(self):
        try:
            u = urlparse(self.path)
            p, q = u.path, parse_qs(u.query)
            if self.internal:
                return self.send_json({"ok": False}, 404)
            if p == "/api/servers": return self.send_json({"servers": public_servers(), "title": S["title"]})
            m = re.match(r"^/avatar/(\d{17})\.jpg$", p)
            if m:
                av_want(m.group(1))
                if os.path.isfile(av_path(m.group(1))): return self.send_file(AV_DIR, m.group(1) + ".jpg", 3600)
                return self.send_json({"ok": False}, 404)
            if p == "/api/maps": return self.send_json({"maps": maps_available()})
            if p == "/api/me":
                steam = self.user()
                if not steam: return self.send_json({"ok": False, "error": "login"}, 401)
                d = me_payload(steam)
                return self.send_json(d) if d else self.send_json({"ok": False, "error": "login"}, 401)
            if p == "/api/me/matches":
                steam = self.user()
                if not steam: return self.send_json({"ok": False, "error": "login"}, 401)
                return self.send_json({"matches": match_list(steam, to_int((q.get("limit") or [20])[0], 20, 1, 50), to_int((q.get("offset") or [0])[0], 0, 0, 10**6))})
            m = re.match(r"^/api/me/matches/(\d+)$", p)
            if m:
                steam = self.user()
                if not steam: return self.send_json({"ok": False, "error": "login"}, 401)
                d = match_detail(steam, int(m.group(1)))
                return self.send_json(d) if d else self.send_json({"ok": False, "error": "not found"}, 404)
            if p.startswith("/maps/"): return self.send_file(S["maps_dir"], p[6:], 3600)
            if p.startswith("/static/"): return self.send_file(STATIC_DIR, p[8:], 0)
            if p in ("/", "/index.html", "/login", "/me"): return self.send_file(STATIC_DIR, "index.html", 0)
            if p == "/favicon.ico": return self.send_file(STATIC_DIR, "favicon.svg", 3600)
            return self.send_json({"ok": False, "error": "not found"}, 404)
        except (BrokenPipeError, ConnectionResetError):
            pass
        except Exception as e:
            log("GET %s: %s" % (self.path, e))
            try: self.send_json({"ok": False, "error": "server error"}, 500)
            except Exception: pass

    def do_POST(self):
        try:
            p = urlparse(self.path).path
            if self.internal:
                key = self.headers.get("X-Api-Key", "")
                if not S["api_key"] or not hmac.compare_digest(key, S["api_key"]):
                    return self.send_json({"ok": False, "error": "unauthorized"}, 401)
                body = self.read_json()
                if p == "/api/plugin/code": return self.send_json(handle_code(body))
                if p == "/api/plugin/snapshot": return self.send_json(handle_snapshot(body))
                if p == "/api/plugin/match": return self.send_json(handle_match(body))
                return self.send_json({"ok": False, "error": "not found"}, 404)
            if self.headers.get("X-NX") != "1":      # custom header: cross-site forms cannot send it
                return self.send_json({"ok": False, "error": "bad request"}, 400)
            if p == "/api/auth/login":
                ip = self.ip()
                if not rate_ok("ip:" + ip, 8, 60) or not rate_ok("global", 120, 60):
                    return self.send_json({"ok": False, "error": "Too many attempts. Wait a minute."}, 429)
                body = self.read_json()
                r = redeem(body.get("code"), ip)
                if not r:
                    return self.send_json({"ok": False, "error": "That code is wrong or has expired. Type !getcode on a server for a new one."}, 400)
                steam, token = r
                ck = "nx_session=%s; Path=/; HttpOnly; SameSite=Lax; Max-Age=%d" % (token, int(S["session_hours"]) * 3600)
                if self.secure_cookie(): ck += "; Secure"
                return self.send_json({"ok": True}, 200, [("Set-Cookie", ck)])
            if p == "/api/auth/logout":
                tok = self.cookie("nx_session")
                if tok:
                    with DB_LOCK:
                        DB.execute("DELETE FROM sessions WHERE token_hash=?", (hashlib.sha256(tok.encode()).hexdigest(),))
                return self.send_json({"ok": True}, 200, [("Set-Cookie", "nx_session=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0")])
            return self.send_json({"ok": False, "error": "not found"}, 404)
        except (BrokenPipeError, ConnectionResetError):
            pass
        except ValueError:
            self.send_json({"ok": False, "error": "bad request"}, 400)
        except Exception as e:
            log("POST %s: %s" % (self.path, e))
            try: self.send_json({"ok": False, "error": "server error"}, 500)
            except Exception: pass

    def send_file(self, root, rel, max_age):
        rel = rel.lstrip("/")
        full = os.path.realpath(os.path.join(root, rel))
        if not full.startswith(os.path.realpath(root) + os.sep) or not os.path.isfile(full):
            return self.send_json({"ok": False, "error": "not found"}, 404)
        ctype = mimetypes.guess_type(full)[0] or "application/octet-stream"
        if ctype.startswith("text/") or ctype in ("application/javascript", "application/json", "image/svg+xml"):
            ctype += "; charset=utf-8" if "charset" not in ctype else ""
        with open(full, "rb") as f:
            data = f.read()
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "public, max-age=%d" % max_age if max_age else "no-cache")
        self.security_headers()
        self.end_headers()
        self.wfile.write(data)


class InternalHandler(Handler):
    internal = True


def main():
    load_settings()
    db_open()
    global AV_DIR
    AV_DIR = os.path.join(DATA_DIR, "avatars")
    os.makedirs(AV_DIR, exist_ok=True)
    threading.Thread(target=av_worker, daemon=True).start()
    mimetypes.add_type("application/javascript", ".js")
    mimetypes.add_type("image/svg+xml", ".svg")
    if not S["api_key"]:
        log("WARNING: no api_key in settings.json; the plugin API is disabled")
    internal = Quiet(("127.0.0.1", S["internal_port"]), InternalHandler)
    public = Quiet((S["bind"], S["port"]), Handler)
    scheme = "http"
    if S["tls_cert"] and S["tls_key"]:
        try:
            ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            ctx.minimum_version = ssl.TLSVersion.TLSv1_2
            ctx.load_cert_chain(S["tls_cert"], S["tls_key"])
            public.tls_ctx = ctx
            scheme = "https"
        except Exception as e:
            log("TLS could not be enabled (%s); serving plain HTTP" % e)
    threading.Thread(target=reaper, daemon=True).start()
    threading.Thread(target=internal.serve_forever, daemon=True).start()
    log("panel up: %s://%s:%d  (plugin API 127.0.0.1:%d)" % (scheme, S["bind"], S["port"], S["internal_port"]))

    def stop(*_):
        threading.Thread(target=public.shutdown, daemon=True).start()
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    public.serve_forever()
    log("panel stopped")


if __name__ == "__main__":
    main()
