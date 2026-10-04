# -*- coding: utf-8 -*-
"""
NEPENTII • CS2 TOOL
Windows-only Tkinter utility for Counter-Strike 2.

PRIMARY CONNECTION METHOD:
    cs2.exe -console -novid +connect IP:PORT
(launched directly with subprocess.Popen, shell=False).

steam://connect/IP:PORT is kept ONLY as a separate fallback button.

Run:  py nepentii_cs2_tool.py
"""

import ctypes
import ipaddress
import json
import os
import re
import select
import socket
import string
import subprocess
import sys
import threading
import time
import tkinter as tk
from pathlib import Path
from tkinter import messagebox, ttk
from urllib.parse import quote

try:
    import winreg
except ImportError:  # not on Windows
    winreg = None

# --------------------------------------------------------------------------
# Constants
# --------------------------------------------------------------------------
APP_TITLE = "NEPENTII • CS2 TOOL"

BG = "#080A12"
PANEL = "#10131D"
PANEL2 = "#151925"
BORDER = "#252B3B"
CYAN = "#00D4FF"
PURPLE = "#9B5CFF"
GREEN = "#31E981"
RED = "#FF4D67"
YELLOW = "#FFC857"
WHITE = "#F5F7FA"
GRAY = "#8D96AA"
DARK_TEXT = "#070A10"

STEAMID64_BASE = 76561197960265728
CS2_DIR_NAME = "Counter-Strike Global Offensive"
DEFAULT_PORT = "27015"
REFRESH_MS = 2000
AUTO_CONNECT_DELAY_S = 25  # seconds to wait for the CS2 main menu before sending the console command

SC_GRAVE = 0x29  # physical ` / ~ key (scan code, layout independent)
SC_CTRL = 0x1D
SC_V = 0x2F
SC_ENTER = 0x1C

CREATE_NO_WINDOW = getattr(subprocess, "CREATE_NO_WINDOW", 0x08000000)
CREATE_NEW_PROCESS_GROUP = getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0x00000200)

HOST_RE = re.compile(
    r"^(?=.{1,253}$)"
    r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?"
    r"(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$"
)

STATUS_COLORS = {"ok": GREEN, "info": CYAN, "warn": YELLOW, "err": RED, "idle": GRAY}


# --------------------------------------------------------------------------
# Helpers: filesystem / registry
# --------------------------------------------------------------------------
def read_text(path):
    try:
        return Path(path).read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""


def reg_value(root, key, name):
    if winreg is None:
        return None
    try:
        with winreg.OpenKey(root, key) as handle:
            return winreg.QueryValueEx(handle, name)[0]
    except OSError:
        return None


def existing_drives():
    drives = []
    for letter in string.ascii_uppercase:
        root = letter + ":\\"
        if os.path.exists(root):
            drives.append(letter)
    return drives


def is_steam_dir(path):
    try:
        return (Path(path) / "steam.exe").is_file()
    except OSError:
        return False


def find_steam_path():
    """Return the Steam install folder (Path) or None."""
    candidates = []

    if winreg is not None:
        lookups = [
            (winreg.HKEY_CURRENT_USER, r"Software\Valve\Steam", "SteamPath"),
            (winreg.HKEY_LOCAL_MACHINE, r"SOFTWARE\WOW6432Node\Valve\Steam", "InstallPath"),
            (winreg.HKEY_LOCAL_MACHINE, r"SOFTWARE\Valve\Steam", "InstallPath"),
            (winreg.HKEY_CURRENT_USER, r"SOFTWARE\WOW6432Node\Valve\Steam", "SteamPath"),
            (winreg.HKEY_CURRENT_USER, r"SOFTWARE\Valve\Steam", "SteamPath"),
        ]
        for root, key, name in lookups:
            value = reg_value(root, key, name)
            if value:
                candidates.append(os.path.normpath(str(value)))

    candidates.extend(
        [
            r"C:\Program Files (x86)\Steam",
            r"C:\Program Files\Steam",
        ]
    )
    for letter in existing_drives():
        candidates.extend(
            [
                letter + r":\Steam",
                letter + r":\Program Files (x86)\Steam",
                letter + r":\Program Files\Steam",
            ]
        )

    seen = set()
    for cand in candidates:
        key = cand.lower()
        if key in seen:
            continue
        seen.add(key)
        if is_steam_dir(cand):
            return Path(cand)
    return None


def parse_login_users(steam_path):
    """Parse config\\loginusers.vdf -> list of dicts."""
    users = []
    if not steam_path:
        return users
    text = read_text(Path(steam_path) / "config" / "loginusers.vdf")
    for steamid, body in re.findall(r'"(\d{17})"\s*\{(.*?)\}', text, re.S):
        fields = {k.lower(): v for k, v in re.findall(r'"([^"]+)"\s*"([^"]*)"', body)}
        users.append(
            {
                "steamid": steamid,
                "name": fields.get("personaname") or fields.get("accountname") or "?",
                "account": fields.get("accountname", ""),
                "recent": fields.get("mostrecent", "0") == "1",
            }
        )
    return users


def account_id_from_steamid(steamid64):
    try:
        return str(int(steamid64) - STEAMID64_BASE)
    except (TypeError, ValueError):
        return "UNKNOWN"


def find_active_user(steam_path, users):
    """Return dict(steamid, name) for the active Steam user, or None."""
    for user in users:
        if user["recent"]:
            return user
    if winreg is not None:
        active = reg_value(
            winreg.HKEY_CURRENT_USER, r"Software\Valve\Steam\ActiveProcess", "ActiveUser"
        )
        try:
            active = int(active)
        except (TypeError, ValueError):
            active = 0
        if active:
            steamid = str(active + STEAMID64_BASE)
            for user in users:
                if user["steamid"] == steamid:
                    return user
            return {"steamid": steamid, "name": "?", "account": "", "recent": False}
    return None


def get_library_paths(steam_path):
    """All Steam library folders (Path objects)."""
    libs = []
    seen = set()

    def add(path):
        try:
            p = Path(os.path.normpath(path))
        except (TypeError, ValueError):
            return
        key = str(p).lower()
        if key not in seen and p.exists():
            seen.add(key)
            libs.append(p)

    if steam_path:
        add(steam_path)
        text = read_text(Path(steam_path) / "steamapps" / "libraryfolders.vdf")
        for raw in re.findall(r'"path"\s*"([^"]+)"', text):
            add(raw.replace("\\\\", "\\"))

    for letter in existing_drives():
        add(letter + r":\SteamLibrary")
        add(letter + r":\Steam")
        add(letter + r":\Program Files (x86)\Steam")
    return libs


def find_cs2(steam_path):
    """Return (cs2_path, library_path) or (None, None)."""
    for lib in get_library_paths(steam_path):
        cand = lib / "steamapps" / "common" / CS2_DIR_NAME
        if cand.is_dir():
            return cand, lib
    return None, None


def find_cs2_exe(cs2_path):
    if not cs2_path:
        return None
    for exe in (Path(cs2_path) / "game" / "bin" / "win64" / "cs2.exe", Path(cs2_path) / "cs2.exe"):
        if exe.is_file():
            return exe
    return None


def get_patch_version(cs2_path, library_path):
    if cs2_path:
        text = read_text(Path(cs2_path) / "game" / "csgo" / "steam.inf")
        match = re.search(r"^\s*PatchVersion\s*=\s*(\S+)", text, re.M)
        if match:
            return match.group(1)
    if library_path:
        text = read_text(Path(library_path) / "steamapps" / "appmanifest_730.acf")
        match = re.search(r'"buildid"\s*"(\d+)"', text)
        if match:
            return "BuildID " + match.group(1) + " (fallback)"
    return "UNKNOWN"


# --------------------------------------------------------------------------
# Helpers: processes / validation
# --------------------------------------------------------------------------
def is_process_running(image_name):
    try:
        result = subprocess.run(
            ["tasklist", "/FI", "IMAGENAME eq " + image_name, "/NH", "/FO", "CSV"],
            capture_output=True,
            text=True,
            errors="replace",
            timeout=5,
            creationflags=CREATE_NO_WINDOW,
        )
        return image_name.lower() in result.stdout.lower()
    except (OSError, subprocess.SubprocessError):
        return False


def validate_host(host):
    if not host:
        return False
    if re.fullmatch(r"[0-9.]+", host):
        try:
            ipaddress.IPv4Address(host)
            return True
        except ValueError:
            return False
    return bool(HOST_RE.match(host))


def validate_port(port_text):
    if not re.fullmatch(r"\d{1,5}", port_text or ""):
        return False
    return 1 <= int(port_text) <= 65535


def parse_server(host, port_text):
    """
    Returns (host, port, server, error) where error is None or
    (status_text, message). Accepts 'ip:port' pasted into the host field.
    """
    host = (host or "").strip()
    port_text = (port_text or "").strip()
    if host.count(":") == 1:
        h, p = host.split(":")
        host = h.strip()
        port_text = p.strip() or port_text
    if not validate_host(host):
        return host, port_text, None, ("INVALID SERVER", "Invalid server address.")
    if not validate_port(port_text):
        return host, port_text, None, ("INVALID PORT", "Invalid port. Use a number from 1 to 65535.")
    port_text = str(int(port_text))
    return host, port_text, host + ":" + port_text, None


def steam_uri(server):
    return "steam://connect/" + quote(server, safe=":.-")


def validate_password(password):
    """Empty is allowed. No spaces, ';' or quotes (they would break the console command)."""
    if not password:
        return True
    return bool(re.fullmatch(r"[^\s;\"']{1,64}", password))


def console_connect_command(server, password=""):
    """Text to paste into the CS2 console, e.g.  connect 1.2.3.4:27015; password abc"""
    command = "connect " + server
    if password:
        command += "; password " + password
    return command


# --------------------------------------------------------------------------
# Helpers: console.log reading + sending keys to the CS2 window
# --------------------------------------------------------------------------
def cs2_log_path(cs2_path):
    if not cs2_path:
        return None
    return Path(cs2_path) / "game" / "csgo" / "console.log"


def log_size(path):
    try:
        return Path(path).stat().st_size
    except (OSError, TypeError):
        return 0


def read_log_since(path, offset):
    """Text appended to console.log after `offset`, or None if the file does not exist."""
    if not path:
        return None
    try:
        size = Path(path).stat().st_size
        if size < offset:
            offset = 0
        with open(path, "rb") as handle:
            handle.seek(offset)
            return handle.read().decode("utf-8", errors="replace")
    except OSError:
        return None


class _KEYBDINPUT(ctypes.Structure):
    _fields_ = [
        ("wVk", ctypes.c_ushort),
        ("wScan", ctypes.c_ushort),
        ("dwFlags", ctypes.c_ulong),
        ("time", ctypes.c_ulong),
        ("dwExtraInfo", ctypes.c_size_t),
    ]


class _MOUSEINPUT(ctypes.Structure):
    _fields_ = [
        ("dx", ctypes.c_long),
        ("dy", ctypes.c_long),
        ("mouseData", ctypes.c_ulong),
        ("dwFlags", ctypes.c_ulong),
        ("time", ctypes.c_ulong),
        ("dwExtraInfo", ctypes.c_size_t),
    ]


class _INPUTUNION(ctypes.Union):
    _fields_ = [("ki", _KEYBDINPUT), ("mi", _MOUSEINPUT)]


class _INPUT(ctypes.Structure):
    _fields_ = [("type", ctypes.c_ulong), ("u", _INPUTUNION)]


def _send_scancode(scan, up=False):
    flags = 0x0008 | (0x0002 if up else 0)  # KEYEVENTF_SCANCODE (| KEYEVENTF_KEYUP)
    inp = _INPUT()
    inp.type = 1  # INPUT_KEYBOARD
    inp.u.ki = _KEYBDINPUT(0, scan, flags, 0, 0)
    sent = ctypes.windll.user32.SendInput(1, ctypes.byref(inp), ctypes.sizeof(_INPUT))
    return sent == 1


def _tap_scancode(scan, hold=0.06):
    _send_scancode(scan)
    time.sleep(hold)
    _send_scancode(scan, up=True)
    time.sleep(0.05)


def focus_cs2_window():
    """Bring the 'Counter-Strike 2' window to the foreground. Returns True on success."""
    user32 = ctypes.windll.user32
    user32.FindWindowW.restype = ctypes.c_void_p
    user32.IsIconic.argtypes = [ctypes.c_void_p]
    user32.ShowWindow.argtypes = [ctypes.c_void_p, ctypes.c_int]
    user32.SetForegroundWindow.argtypes = [ctypes.c_void_p]
    user32.GetForegroundWindow.restype = ctypes.c_void_p

    hwnd = user32.FindWindowW(None, "Counter-Strike 2")
    if not hwnd:
        return False
    if user32.IsIconic(hwnd):
        user32.ShowWindow(hwnd, 9)  # SW_RESTORE
    user32.keybd_event(0x12, 0, 0, 0)  # ALT trick so SetForegroundWindow is allowed
    user32.keybd_event(0x12, 0, 2, 0)
    user32.SetForegroundWindow(hwnd)
    time.sleep(0.5)
    return user32.GetForegroundWindow() == hwnd


def send_console_connect_keys():
    """
    Focus CS2, toggle the console (~), paste the clipboard (Ctrl+V) and press Enter.
    The text to paste must already be in the clipboard.
    """
    if not focus_cs2_window():
        return False
    _tap_scancode(SC_GRAVE, 0.08)
    time.sleep(0.5)
    _send_scancode(SC_CTRL)
    try:
        time.sleep(0.05)
        _tap_scancode(SC_V)
    finally:
        _send_scancode(SC_CTRL, up=True)
    time.sleep(0.25)
    _tap_scancode(SC_ENTER)
    return True


# --------------------------------------------------------------------------
# Helpers: saved servers + server query (A2S_INFO)
# --------------------------------------------------------------------------
HISTORY_LIMIT = 15


def settings_path():
    base = os.environ.get("APPDATA") or str(Path.home())
    return Path(base) / "NEPENTII_CS2_TOOL" / "servers.json"


def load_servers():
    data = {"favorites": [], "history": [], "names": {}}
    try:
        loaded = json.loads(settings_path().read_text(encoding="utf-8"))
        if isinstance(loaded, dict):
            favs = loaded.get("favorites")
            hist = loaded.get("history")
            names = loaded.get("names")
            if isinstance(favs, list):
                data["favorites"] = [x for x in favs if isinstance(x, str)]
            if isinstance(hist, list):
                data["history"] = [x for x in hist if isinstance(x, str)][:HISTORY_LIMIT]
            if isinstance(names, dict):
                data["names"] = {k: v for k, v in names.items() if isinstance(k, str) and isinstance(v, str)}
    except (OSError, ValueError):
        pass
    return data


def save_servers(data):
    """Best effort: never raises."""
    try:
        path = settings_path()
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
        return True
    except OSError:
        return False


def _read_cstring(data, pos):
    end = data.index(b"\x00", pos)
    return data[pos:end].decode("utf-8", errors="replace"), end + 1


def query_server_info(host, port, timeout=2.0):
    """
    Source engine A2S_INFO query. Returns dict(name, map, players, max_players, bots, ping_ms).
    Raises OSError (timeout / network) or ValueError (bad reply).
    """
    request = b"\xff\xff\xff\xffTSource Engine Query\x00"
    addr = socket.getaddrinfo(host, port, socket.AF_INET, socket.SOCK_DGRAM)[0][4]
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(timeout)
    try:
        start = time.perf_counter()
        sock.sendto(request, addr)
        data, _ = sock.recvfrom(4096)
        ping = (time.perf_counter() - start) * 1000.0
        if len(data) >= 9 and data[4] == 0x41:  # challenge: repeat request with the challenge number
            start = time.perf_counter()
            sock.sendto(request + data[5:9], addr)
            data, _ = sock.recvfrom(4096)
            ping = (time.perf_counter() - start) * 1000.0
    finally:
        sock.close()

    if len(data) < 6 or data[:4] != b"\xff\xff\xff\xff" or data[4] != 0x49:
        raise ValueError("unexpected reply")
    try:
        pos = 6  # skip header(4) + type(1) + protocol(1)
        name, pos = _read_cstring(data, pos)
        game_map, pos = _read_cstring(data, pos)
        _folder, pos = _read_cstring(data, pos)
        _game, pos = _read_cstring(data, pos)
        pos += 2  # app id
        players, max_players, bots = data[pos], data[pos + 1], data[pos + 2]
    except (ValueError, IndexError):
        raise ValueError("malformed reply")
    return {
        "name": name,
        "map": game_map,
        "players": players,
        "max_players": max_players,
        "bots": bots,
        "ping_ms": int(round(ping)),
    }


# --------------------------------------------------------------------------
# Local UDP relay (PROXY MODE)
# --------------------------------------------------------------------------
class UdpRelay(threading.Thread):
    """
    Transparent UDP relay:  CS2 -> 127.0.0.1:<local_port> -> remote server.
    Forwards every datagram unchanged in both directions (single local client).
    Listens on loopback only.
    """

    def __init__(self, remote_host, remote_port):
        super().__init__(daemon=True)
        infos = socket.getaddrinfo(remote_host, remote_port, socket.AF_INET, socket.SOCK_DGRAM)
        self.remote = infos[0][4]  # (ip, port)
        self.remote_key = (remote_host.lower(), int(remote_port))
        self.local = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.upstream = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            self.local.bind(("127.0.0.1", 0))
            self.upstream.connect(self.remote)
        except OSError:
            self.local.close()
            self.upstream.close()
            raise
        self.local_port = self.local.getsockname()[1]
        self.client = None
        self.packets_up = 0
        self.packets_down = 0
        self.stop_event = threading.Event()

    def run(self):
        while not self.stop_event.is_set():
            try:
                ready, _, _ = select.select([self.local, self.upstream], [], [], 0.5)
            except (OSError, ValueError):
                break
            for sock in ready:
                try:
                    data, addr = sock.recvfrom(65535)
                except (ConnectionResetError, BlockingIOError, InterruptedError):
                    continue
                except OSError:
                    if self.stop_event.is_set():
                        break
                    continue
                try:
                    if sock is self.local:
                        self.client = addr
                        self.upstream.send(data)
                        self.packets_up += 1
                    elif self.client is not None:
                        self.local.sendto(data, self.client)
                        self.packets_down += 1
                except OSError:
                    continue
        self.close_sockets()

    def close_sockets(self):
        for sock in (self.local, self.upstream):
            try:
                sock.close()
            except OSError:
                pass

    def stop(self):
        self.stop_event.set()


# --------------------------------------------------------------------------
# Application
# --------------------------------------------------------------------------
class App:
    def __init__(self, root):
        self.root = root
        root.title(APP_TITLE)
        root.geometry("1120x760")
        root.minsize(980, 680)
        root.configure(bg=BG)

        self.steam_path = None
        self.users = []
        self.active_user = None
        self.cs2_path = None
        self.cs2_library = None
        self.cs2_exe = None
        self.patch_version = "UNKNOWN"
        self.steam_running = False
        self.cs2_running = False
        self.monitor_job = None
        self.values = {}

        self.host_var = tk.StringVar()
        self.port_var = tk.StringVar(value=DEFAULT_PORT)
        self.preview_var = tk.StringVar(value="—")
        self.status_var = tk.StringVar(value="READY")
        self.log_path = None
        self.log_baseline = 0
        self.relay = None
        self.proxy_var = tk.BooleanVar(value=False)
        self.relay_var = tk.StringVar(value="")
        self.store = load_servers()
        self.faceit_var = tk.BooleanVar(value=False)
        self.pass_var = tk.StringVar()

        self.build_style()
        self.build_ui()
        self.bind_keys()

        self.host_var.trace_add("write", self.on_server_field_change)
        self.port_var.trace_add("write", self.on_server_field_change)

        self.scan()
        self.refresh_process_status()
        self.host_entry.focus_set()
        root.protocol("WM_DELETE_WINDOW", self.on_close)
        self.load_last_server()

    # ---------------------------------------------------------------- style
    def build_style(self):
        style = ttk.Style(self.root)
        try:
            style.theme_use("clam")
        except tk.TclError:
            pass
        style.configure(
            "N.TEntry",
            fieldbackground=PANEL2,
            background=PANEL2,
            foreground=WHITE,
            insertcolor=CYAN,
            bordercolor=BORDER,
            lightcolor=BORDER,
            darkcolor=BORDER,
            padding=8,
        )
        style.map(
            "N.TEntry",
            bordercolor=[("focus", CYAN)],
            lightcolor=[("focus", CYAN)],
            darkcolor=[("focus", CYAN)],
        )
        style.configure(
            "N.TCombobox",
            fieldbackground=PANEL2,
            background=PANEL2,
            foreground=WHITE,
            arrowcolor=CYAN,
            insertcolor=CYAN,
            bordercolor=BORDER,
            lightcolor=BORDER,
            darkcolor=BORDER,
            padding=8,
        )
        style.map(
            "N.TCombobox",
            fieldbackground=[("readonly", PANEL2)],
            foreground=[("readonly", WHITE)],
            bordercolor=[("focus", CYAN)],
            lightcolor=[("focus", CYAN)],
            darkcolor=[("focus", CYAN)],
        )
        self.root.option_add("*TCombobox*Listbox.background", PANEL2)
        self.root.option_add("*TCombobox*Listbox.foreground", WHITE)
        self.root.option_add("*TCombobox*Listbox.selectBackground", CYAN)
        self.root.option_add("*TCombobox*Listbox.selectForeground", DARK_TEXT)
        self.root.option_add("*TCombobox*Listbox.font", ("Consolas", 10))

    # ------------------------------------------------------------- widgets
    def card(self, parent, title, accent=CYAN):
        outer = tk.Frame(parent, bg=PANEL, highlightbackground=BORDER, highlightthickness=1)
        tk.Frame(outer, bg=accent, height=2).pack(fill="x")
        tk.Label(
            outer, text=title, bg=PANEL, fg=accent, font=("Segoe UI", 10, "bold")
        ).pack(anchor="w", padx=14, pady=(10, 4))
        body = tk.Frame(outer, bg=PANEL)
        body.pack(fill="x", padx=14, pady=(0, 12))
        return outer, body

    def row(self, body, key, label):
        frame = tk.Frame(body, bg=PANEL)
        frame.pack(fill="x", pady=2)
        tk.Label(
            frame, text=label, bg=PANEL, fg=GRAY, font=("Segoe UI", 9), width=15, anchor="w"
        ).pack(side="left", anchor="n")
        value = tk.Label(
            frame,
            text="...",
            bg=PANEL,
            fg=WHITE,
            font=("Consolas", 9),
            anchor="w",
            justify="left",
            wraplength=290,
        )
        value.pack(side="left", fill="x", expand=True)
        self.values[key] = value

    def setv(self, key, text, color=WHITE):
        label = self.values.get(key)
        if label is not None:
            label.config(text=text, fg=color)

    def make_button(self, parent, text, command, bg, fg, size=10, pady=8, hover=None):
        hover = hover or bg
        btn = tk.Button(
            parent,
            text=text,
            command=command,
            bg=bg,
            fg=fg,
            activebackground=hover,
            activeforeground=fg,
            relief="flat",
            bd=0,
            cursor="hand2",
            font=("Segoe UI", size, "bold"),
            pady=pady,
            padx=10,
        )
        btn.bind("<Enter>", lambda _e: btn.config(bg=hover))
        btn.bind("<Leave>", lambda _e: btn.config(bg=bg))
        return btn

    # ------------------------------------------------------------------ UI
    def build_ui(self):
        # Header
        header = tk.Frame(self.root, bg=BG)
        header.pack(fill="x", padx=20, pady=(16, 6))
        title = tk.Frame(header, bg=BG)
        title.pack(side="left")
        tk.Label(title, text="NEPENTII", bg=BG, fg=CYAN, font=("Segoe UI", 22, "bold")).pack(side="left")
        tk.Label(title, text=" • ", bg=BG, fg=PURPLE, font=("Segoe UI", 22, "bold")).pack(side="left")
        tk.Label(title, text="CS2 TOOL", bg=BG, fg=WHITE, font=("Segoe UI", 22, "bold")).pack(side="left")
        tk.Label(
            header,
            text="Direct launcher for Counter-Strike 2",
            bg=BG,
            fg=GRAY,
            font=("Segoe UI", 10),
        ).pack(side="right", anchor="s", pady=(0, 4))
        tk.Frame(self.root, bg=BORDER, height=1).pack(fill="x", padx=20)

        # Bottom status bar (packed before the body so it stays visible)
        bar = tk.Frame(self.root, bg=PANEL, highlightbackground=BORDER, highlightthickness=1)
        bar.pack(side="bottom", fill="x", padx=20, pady=(6, 16))
        tk.Label(bar, text="STATUS", bg=PANEL, fg=GRAY, font=("Segoe UI", 9, "bold")).pack(
            side="left", padx=(14, 10), pady=10
        )
        self.status_label = tk.Label(
            bar, textvariable=self.status_var, bg=PANEL, fg=GREEN, font=("Consolas", 10, "bold"), anchor="w"
        )
        self.status_label.pack(side="left", fill="x", expand=True)
        self.make_button(bar, "REFRESH", self.on_refresh, PANEL2, CYAN, size=9, pady=4, hover=BORDER).pack(
            side="right", padx=10, pady=6
        )

        # Body
        body = tk.Frame(self.root, bg=BG)
        body.pack(fill="both", expand=True, padx=20, pady=12)
        body.columnconfigure(0, weight=4, uniform="cols")
        body.columnconfigure(1, weight=5, uniform="cols")
        body.rowconfigure(0, weight=1)

        left = tk.Frame(body, bg=BG)
        left.grid(row=0, column=0, sticky="nsew", padx=(0, 8))
        right = tk.Frame(body, bg=BG)
        right.grid(row=0, column=1, sticky="nsew", padx=(8, 0))

        # Left: system status
        outer, card = self.card(left, "SYSTEM STATUS", CYAN)
        outer.pack(fill="x", pady=(0, 10))
        self.row(card, "sys_steam", "Steam Status")
        self.row(card, "sys_cs2", "CS2 Status")
        self.row(card, "sys_python", "Python Status")

        # Left: Steam information
        outer, card = self.card(left, "STEAM INFORMATION", PURPLE)
        outer.pack(fill="x", pady=(0, 10))
        self.row(card, "steam_path", "Steam Path")
        self.row(card, "steam_user", "Active Steam User")
        self.row(card, "steam_id64", "SteamID64")
        self.row(card, "account_id", "Account ID")
        self.row(card, "steam_users", "Steam Users")

        # Left: CS2 information
        outer, card = self.card(left, "CS2 INFORMATION", CYAN)
        outer.pack(fill="x")
        self.row(card, "cs2_path", "CS2 Path")
        self.row(card, "cs2_exe", "CS2 EXE")
        self.row(card, "cs2_patch", "Patch Version")
        self.row(card, "cs2_proc", "Process Status")

        # Right: direct server connect
        outer, card = self.card(right, "DIRECT SERVER CONNECT", CYAN)
        outer.pack(fill="both", expand=True)

        tk.Label(
            card,
            text=(
                "Launch Counter-Strike 2 directly with +connect.\n"
                "No steam:// URI is required for the main connection method."
            ),
            bg=PANEL,
            fg=GRAY,
            font=("Segoe UI", 10),
            justify="left",
            anchor="w",
        ).pack(fill="x", pady=(0, 10))

        badge = tk.Frame(card, bg=PANEL2, highlightbackground=PURPLE, highlightthickness=1)
        badge.pack(fill="x", pady=(0, 12))
        tk.Label(badge, text="DIRECT MODE", bg=PANEL2, fg=PURPLE, font=("Segoe UI", 9, "bold")).pack(
            anchor="w", padx=12, pady=(8, 0)
        )
        tk.Label(
            badge, text="CS2 EXE  →  +connect IP:PORT", bg=PANEL2, fg=WHITE, font=("Consolas", 10)
        ).pack(anchor="w", padx=12, pady=(0, 8))

        fields = tk.Frame(card, bg=PANEL)
        fields.pack(fill="x")
        fields.columnconfigure(0, weight=3)
        fields.columnconfigure(1, weight=1)

        tk.Label(fields, text="SERVER IP / HOST", bg=PANEL, fg=GRAY, font=("Segoe UI", 9, "bold")).grid(
            row=0, column=0, sticky="w"
        )
        tk.Label(fields, text="PORT", bg=PANEL, fg=GRAY, font=("Segoe UI", 9, "bold")).grid(
            row=0, column=1, sticky="w", padx=(10, 0)
        )
        self.host_entry = ttk.Combobox(
            fields,
            textvariable=self.host_var,
            style="N.TCombobox",
            font=("Consolas", 12),
            postcommand=self.refresh_server_list,
        )
        self.host_entry.bind("<<ComboboxSelected>>", self.on_server_pick)
        self.host_entry.grid(row=1, column=0, sticky="ew", pady=(4, 0))
        self.port_entry = ttk.Entry(fields, textvariable=self.port_var, style="N.TEntry", font=("Consolas", 12))
        self.port_entry.grid(row=1, column=1, sticky="ew", padx=(10, 0), pady=(4, 0))

        tk.Label(card, text="SERVER", bg=PANEL, fg=GRAY, font=("Segoe UI", 9, "bold")).pack(
            anchor="w", pady=(12, 0)
        )
        self.preview_label = tk.Label(
            card,
            textvariable=self.preview_var,
            bg=PANEL2,
            fg=CYAN,
            font=("Consolas", 15, "bold"),
            anchor="w",
            padx=12,
            pady=8,
            highlightbackground=BORDER,
            highlightthickness=1,
        )
        self.preview_label.pack(fill="x", pady=(4, 14))

        self.connect_btn = self.make_button(
            card, "CONNECT DIRECT", self.connect_direct, CYAN, DARK_TEXT, size=14, pady=14, hover="#4FE3FF"
        )
        self.connect_btn.pack(fill="x")

        # PROXY MODE (local UDP relay)
        tk.Checkbutton(
            card,
            text="PROXY MODE (local UDP relay)",
            variable=self.proxy_var,
            command=self.on_proxy_toggle,
            bg=PANEL,
            fg=PURPLE,
            selectcolor=PANEL2,
            activebackground=PANEL,
            activeforeground=PURPLE,
            font=("Segoe UI", 9, "bold"),
            cursor="hand2",
            anchor="w",
            bd=0,
            highlightthickness=0,
        ).pack(anchor="w", pady=(8, 0))
        self.relay_label = tk.Label(
            card, textvariable=self.relay_var, bg=PANEL, fg=GRAY, font=("Consolas", 8), anchor="w"
        )
        self.relay_label.pack(fill="x")

        # FACEIT MODE (toggle + collapsible panel)
        tk.Checkbutton(
            card,
            text="FACEIT MODE",
            variable=self.faceit_var,
            command=self.on_faceit_toggle,
            bg=PANEL,
            fg=GREEN,
            selectcolor=PANEL2,
            activebackground=PANEL,
            activeforeground=GREEN,
            font=("Segoe UI", 9, "bold"),
            cursor="hand2",
            anchor="w",
            bd=0,
            highlightthickness=0,
        ).pack(anchor="w", pady=(10, 0))

        self.faceit_holder = tk.Frame(card, bg=PANEL)
        self.faceit_holder.pack(fill="x")
        self.faceit_frame = tk.Frame(
            self.faceit_holder, bg=PANEL2, highlightbackground=GREEN, highlightthickness=1
        )
        tk.Label(
            self.faceit_frame,
            text=(
                "FACEIT needs CS2 started through Steam with Anti-Cheat running.\n"
                "Direct launch may be rejected. Use: LAUNCH VIA STEAM, then paste the\n"
                "copied command into the CS2 console (enable -console in Steam launch options)."
            ),
            bg=PANEL2,
            fg=YELLOW,
            font=("Segoe UI", 8),
            justify="left",
            anchor="w",
        ).pack(fill="x", padx=10, pady=(8, 4))
        pass_row = tk.Frame(self.faceit_frame, bg=PANEL2)
        pass_row.pack(fill="x", padx=10, pady=(0, 6))
        tk.Label(pass_row, text="PASSWORD", bg=PANEL2, fg=GRAY, font=("Segoe UI", 9, "bold")).pack(
            side="left", padx=(0, 8)
        )
        self.pass_entry = ttk.Entry(
            pass_row, textvariable=self.pass_var, style="N.TEntry", font=("Consolas", 11), show="*"
        )
        self.pass_entry.pack(side="left", fill="x", expand=True)
        faceit_btns = tk.Frame(self.faceit_frame, bg=PANEL2)
        faceit_btns.pack(fill="x", padx=7, pady=(0, 8))
        for col in range(2):
            faceit_btns.columnconfigure(col, weight=1, uniform="f")
        self.make_button(
            faceit_btns, "COPY CONNECT CMD", self.copy_connect_cmd, GREEN, DARK_TEXT, size=9, pady=7, hover="#6BF2A5"
        ).grid(row=0, column=0, sticky="ew", padx=3)
        self.make_button(
            faceit_btns, "LAUNCH VIA STEAM", self.launch_via_steam, PANEL, YELLOW, size=9, pady=7, hover=BORDER
        ).grid(row=0, column=1, sticky="ew", padx=3)

        grid = tk.Frame(card, bg=PANEL)
        grid.pack(fill="x", pady=(12, 0))
        for col in range(3):
            grid.columnconfigure(col, weight=1, uniform="b")
        buttons = [
            ("STEAM URI FALLBACK", self.steam_uri_fallback, PANEL2, YELLOW),
            ("COPY SERVER", self.copy_server, PANEL2, WHITE),
            ("COPY URI", self.copy_uri, PANEL2, WHITE),
            ("CLEAR", self.clear_fields, PANEL2, RED),
            ("OPEN STEAM", self.open_steam, PANEL2, PURPLE),
            ("OPEN CS2", self.open_cs2, PANEL2, PURPLE),
            ("SAVE SERVER", self.toggle_favorite, PANEL2, GREEN),
            ("QUERY SERVER", self.query_server, PANEL2, CYAN),
        ]
        for index, (text, command, bg, fg) in enumerate(buttons):
            btn = self.make_button(grid, text, command, bg, fg, size=9, pady=7, hover=BORDER)
            btn.grid(row=index // 3, column=index % 3, sticky="ew", padx=3, pady=3)

        tk.Label(
            card,
            text="Enter = CONNECT DIRECT   •   Ctrl+L = focus server   •   Esc = CLEAR",
            bg=PANEL,
            fg=GRAY,
            font=("Segoe UI", 8),
        ).pack(anchor="w", pady=(10, 0))

    def bind_keys(self):
        self.root.bind_all("<Return>", lambda _e: self.connect_direct())
        self.root.bind_all("<KP_Enter>", lambda _e: self.connect_direct())
        self.root.bind_all("<Control-l>", self.focus_server)
        self.root.bind_all("<Control-L>", self.focus_server)
        self.root.bind_all("<Escape>", lambda _e: self.clear_fields())

    def focus_server(self, _event=None):
        self.host_entry.focus_set()
        self.host_entry.select_range(0, "end")
        self.host_entry.icursor("end")
        return "break"

    # -------------------------------------------------------------- status
    def set_status(self, text, level="info"):
        self.status_var.set(text)
        self.status_label.config(fg=STATUS_COLORS.get(level, CYAN))

    # ---------------------------------------------------------------- scan
    def scan(self):
        try:
            self.steam_path = find_steam_path()
            self.users = parse_login_users(self.steam_path)
            self.active_user = find_active_user(self.steam_path, self.users)
            self.cs2_path, self.cs2_library = find_cs2(self.steam_path)
            self.cs2_exe = find_cs2_exe(self.cs2_path)
            self.patch_version = get_patch_version(self.cs2_path, self.cs2_library)
        except Exception as exc:  # never crash the UI on a scan
            self.set_status("SCAN ERROR: " + str(exc), "err")
        self.update_info_labels()

    def update_info_labels(self):
        py = sys.version.split()[0]
        self.setv("sys_python", "Python " + py + " OK", GREEN)

        if self.steam_path:
            self.setv("steam_path", str(self.steam_path), WHITE)
        else:
            self.setv("steam_path", "STEAM NOT FOUND", RED)

        if self.active_user:
            sid = self.active_user["steamid"]
            self.setv("steam_user", self.active_user["name"], WHITE)
            self.setv("steam_id64", sid, CYAN)
            self.setv("account_id", account_id_from_steamid(sid), CYAN)
        else:
            self.setv("steam_user", "UNKNOWN", GRAY)
            self.setv("steam_id64", "UNKNOWN", GRAY)
            self.setv("account_id", "UNKNOWN", GRAY)

        if self.users:
            names = ", ".join(u["name"] for u in self.users)
            self.setv("steam_users", str(len(self.users)) + " — " + names, WHITE)
        else:
            self.setv("steam_users", "NONE FOUND", GRAY)

        if self.cs2_path:
            self.setv("cs2_path", str(self.cs2_path), WHITE)
        else:
            self.setv("cs2_path", "CS2 NOT FOUND", RED)

        if self.cs2_exe:
            self.setv("cs2_exe", "CS2 EXE FOUND\n" + str(self.cs2_exe), GREEN)
        else:
            self.setv("cs2_exe", "CS2 EXE NOT FOUND", RED)

        self.setv("cs2_patch", self.patch_version, WHITE if self.patch_version != "UNKNOWN" else GRAY)
        self.update_process_labels()

    def update_process_labels(self):
        if self.steam_path:
            if self.steam_running:
                self.setv("sys_steam", "STEAM FOUND • RUNNING", GREEN)
            else:
                self.setv("sys_steam", "STEAM FOUND • NOT RUNNING", YELLOW)
        else:
            self.setv("sys_steam", "STEAM NOT FOUND", RED)

        if self.cs2_exe:
            if self.cs2_running:
                self.setv("sys_cs2", "CS2 EXE FOUND • RUNNING", GREEN)
            else:
                self.setv("sys_cs2", "CS2 EXE FOUND • NOT RUNNING", CYAN)
        else:
            self.setv("sys_cs2", "CS2 EXE NOT FOUND", RED)

        if self.cs2_running:
            self.setv("cs2_proc", "CS2\nRUNNING", GREEN)
        else:
            self.setv("cs2_proc", "CS2\nNOT RUNNING", GRAY)

    def refresh_process_status(self):
        try:
            self.steam_running = is_process_running("steam.exe")
            self.cs2_running = is_process_running("cs2.exe")
            self.update_process_labels()
            self.update_relay_label()
        except Exception:
            pass
        self.root.after(REFRESH_MS, self.refresh_process_status)

    def on_refresh(self):
        self.scan()
        self.steam_running = is_process_running("steam.exe")
        self.cs2_running = is_process_running("cs2.exe")
        self.update_process_labels()
        if self.cs2_exe:
            self.set_status("CS2 DETECTED • DIRECT MODE", "ok")
        else:
            self.set_status("CS2.EXE NOT FOUND", "err")

    # ------------------------------------------------------ server preview
    def on_server_field_change(self, *_):
        host, port, server, error = parse_server(self.host_var.get(), self.port_var.get())
        if server:
            self.preview_var.set(server)
            self.preview_label.config(fg=CYAN)
        elif not host:
            self.preview_var.set("—")
            self.preview_label.config(fg=GRAY)
        else:
            self.preview_var.set(host + ":" + port if port else host)
            self.preview_label.config(fg=RED)

    def get_server(self):
        """Validate fields; return server string or None (status already set)."""
        host, port, server, error = parse_server(self.host_var.get(), self.port_var.get())
        if error:
            self.set_status(error[0], "err")
            messagebox.showerror(APP_TITLE, error[1])
            return None
        # normalise fields if user pasted ip:port into the host field
        if self.host_var.get().strip() != host:
            self.host_var.set(host)
        if self.port_var.get().strip() != port:
            self.port_var.set(port)
        return server

    # ------------------------------------------------------ CONNECT DIRECT
    def connect_direct(self):
        try:
            server = self.get_server()
            if not server:
                return
            self.remember_server(server)

            if self.faceit_var.get():
                proceed = messagebox.askyesno(
                    APP_TITLE,
                    "FACEIT MODE is ON.\n\n"
                    "FACEIT may reject a CS2 that was not started through Steam\n"
                    "(error: 'You need to have the Anti-cheat client running').\n\n"
                    "Recommended: LAUNCH VIA STEAM, then COPY CONNECT CMD and paste it in the CS2 console.\n\n"
                    "Launch directly anyway?",
                )
                if not proceed:
                    self.set_status("FACEIT MODE • DIRECT LAUNCH CANCELLED", "warn")
                    return

            if not self.cs2_exe:
                self.scan()
            if not self.cs2_exe:
                self.set_status("CS2.EXE NOT FOUND", "err")
                messagebox.showerror(APP_TITLE, "CS2 executable was not found.")
                return

            self.cs2_running = is_process_running("cs2.exe")
            self.update_process_labels()
            if self.cs2_running:
                self.set_status("CS2 IS ALREADY RUNNING", "warn")
                target = self.resolve_target(server)
                if not target:
                    return
                send_now = messagebox.askyesno(
                    APP_TITLE,
                    "CS2 is already running.\n\n"
                    "A new direct launch cannot pass +connect to a running game.\n"
                    "Send the command into the running CS2 console instead?\n\n"
                    "connect " + target + "\n\n"
                    "(Keep CS2 open and use an English keyboard layout.)",
                )
                if send_now:
                    self.auto_console_connect(target, 1)
                return

            self.steam_running = is_process_running("steam.exe")
            if not self.steam_running:
                proceed = messagebox.askyesno(
                    APP_TITLE,
                    "Steam is not running.\n"
                    "CS2 needs the Steam client to be running to start and join servers.\n\n"
                    "Launch CS2 directly anyway?",
                )
                if not proceed:
                    self.set_status("LAUNCH CANCELLED: STEAM NOT RUNNING", "warn")
                    return

            target = self.resolve_target(server)
            if not target:
                return
            server = target  # with PROXY MODE this is the local relay address

            cs2_exe = str(self.cs2_exe)
            cwd = str(self.cs2_path) if self.cs2_path else str(self.cs2_exe.parent)
            cmd = [cs2_exe, "-console", "-novid", "-condebug", "+connect", server]
            self.log_path = cs2_log_path(self.cs2_path)
            self.log_baseline = 0
            if self.log_path:
                try:
                    self.log_path.unlink()
                except OSError:
                    pass

            self.set_status("LAUNCHING CS2...", "info")
            self.root.update_idletasks()
            try:
                proc = subprocess.Popen(
                    cmd,
                    cwd=cwd,
                    shell=False,
                    creationflags=CREATE_NEW_PROCESS_GROUP,
                )
            except (OSError, ValueError) as exc:
                self.set_status("UNABLE TO LAUNCH CS2", "err")
                messagebox.showerror(APP_TITLE, "Unable to launch CS2.\n\n" + str(exc))
                return

            self.set_status("DIRECT LAUNCH STARTED", "ok")
            if self.monitor_job is not None:
                try:
                    self.root.after_cancel(self.monitor_job)
                except (tk.TclError, ValueError):
                    pass
            self.monitor_job = self.root.after(1000, self.monitor_launch, proc, server, 1)
        except Exception as exc:
            self.set_status("UNABLE TO LAUNCH CS2", "err")
            messagebox.showerror(APP_TITLE, "Unable to launch CS2.\n\n" + str(exc))

    def monitor_launch(self, proc, server, tick):
        self.monitor_job = None
        try:
            running = is_process_running("cs2.exe")
            self.cs2_running = running
            self.update_process_labels()

            text = read_log_since(self.log_path, self.log_baseline)
            if text and "Remote Connect (" in text:
                self.set_status("CS2 RUNNING • CONNECTING TO " + server, "ok")
                return

            if not running and proc.poll() is not None and tick >= 5:
                self.set_status("CS2 PROCESS EXITED (code " + str(proc.returncode) + ")", "err")
                return

            if tick >= AUTO_CONNECT_DELAY_S:
                if not running:
                    self.set_status("CS2 NOT DETECTED YET • CHECK STEAM", "warn")
                    return
                self.set_status("+CONNECT WAS NOT APPLIED • SENDING CONSOLE COMMAND", "warn")
                self.auto_console_connect(server, 1)
                return

            if running:
                self.set_status(
                    "CS2 RUNNING • WAITING FOR MENU (" + str(tick) + "/" + str(AUTO_CONNECT_DELAY_S) + "s)",
                    "info",
                )
            else:
                self.set_status("LAUNCHING CS2... (" + str(tick) + "s)", "info")
            self.monitor_job = self.root.after(1000, self.monitor_launch, proc, server, tick + 1)
        except Exception as exc:
            self.set_status("MONITOR ERROR: " + str(exc), "err")

    # ------------------------------------------- send command to CS2 console
    def auto_console_connect(self, server, attempt=1):
        """Paste 'connect IP:PORT' into the CS2 console (retry once, verified via console.log)."""
        try:
            self.log_path = cs2_log_path(self.cs2_path)
            base = log_size(self.log_path) if self.log_path else 0
            self.set_clipboard(console_connect_command(server))
            if not send_console_connect_keys():
                self.set_status("CS2 WINDOW NOT FOUND • COMMAND COPIED, PASTE IT IN THE CONSOLE", "err")
                return
            self.set_status("CONSOLE COMMAND SENT (attempt " + str(attempt) + ")", "info")
            self.root.after(3000, self.verify_console_connect, server, attempt, base)
        except Exception as exc:
            self.set_status("CONSOLE SEND FAILED: " + str(exc), "err")

    def verify_console_connect(self, server, attempt, base):
        try:
            text = read_log_since(self.log_path, base)
            if text is None:
                self.set_status("CONSOLE COMMAND SENT • CANNOT VERIFY (no console.log)", "warn")
                return
            if "Remote Connect (" in text:
                self.set_status("CS2 RUNNING • CONNECTING TO " + server, "ok")
                return
            if attempt < 2:
                self.auto_console_connect(server, attempt + 1)
                return
            self.set_status("COULD NOT CONFIRM • COMMAND IS IN CLIPBOARD: PASTE IT IN THE CS2 CONSOLE", "warn")
        except Exception as exc:
            self.set_status("VERIFY FAILED: " + str(exc), "err")

    # ------------------------------------------------------ STEAM FALLBACK
    def steam_uri_fallback(self):
        try:
            server = self.get_server()
            if not server:
                return
            uri = steam_uri(server)
            os.startfile(uri)
            self.set_status("STEAM URI FALLBACK SENT: " + server, "warn")
        except Exception as exc:
            self.set_status("UNABLE TO OPEN STEAM URI", "err")
            messagebox.showerror(APP_TITLE, "Unable to open the Steam URI.\n\n" + str(exc))

    # --------------------------------------------------------------- copy
    def set_clipboard(self, text):
        self.root.clipboard_clear()
        self.root.clipboard_append(text)
        self.root.update()

    def copy_server(self):
        try:
            server = self.get_server()
            if not server:
                return
            self.set_clipboard(server)
            self.set_status("COPIED SERVER: " + server, "ok")
        except Exception as exc:
            self.set_status("COPY FAILED", "err")
            messagebox.showerror(APP_TITLE, str(exc))

    def copy_uri(self):
        try:
            server = self.get_server()
            if not server:
                return
            uri = steam_uri(server)
            self.set_clipboard(uri)
            self.set_status("COPIED URI (fallback only): " + uri, "ok")
        except Exception as exc:
            self.set_status("COPY FAILED", "err")
            messagebox.showerror(APP_TITLE, str(exc))

    # -------------------------------------------------------------- misc
    # --------------------------------------------- saved servers + query
    def server_display(self, server):
        star = "★ " if server in self.store["favorites"] else ""
        name = self.store["names"].get(server)
        return star + server + ((" — " + name) if name else "")

    def refresh_server_list(self):
        favs = list(self.store["favorites"])
        recent = [s for s in self.store["history"] if s not in favs]
        self.host_entry["values"] = [self.server_display(s) for s in favs + recent]

    def on_server_pick(self, _event=None):
        text = self.host_var.get().replace("★", "").strip()
        server = text.split(" — ")[0].strip()
        host, _, port = server.rpartition(":")
        if host and port:
            self.host_var.set(host)
            self.port_var.set(port)
            self.host_entry.icursor("end")

    def load_last_server(self):
        self.refresh_server_list()
        if self.store["history"] and not self.host_var.get():
            host, _, port = self.store["history"][0].rpartition(":")
            if host and port:
                self.host_var.set(host)
                self.port_var.set(port)

    def remember_server(self, server):
        history = [s for s in self.store["history"] if s != server]
        history.insert(0, server)
        self.store["history"] = history[:HISTORY_LIMIT]
        save_servers(self.store)

    def toggle_favorite(self):
        server = self.get_server()
        if not server:
            return
        favs = self.store["favorites"]
        if server in favs:
            favs.remove(server)
            self.set_status("REMOVED FROM FAVORITES: " + server, "info")
        else:
            favs.append(server)
            self.set_status("SAVED TO FAVORITES: " + server, "ok")
        if not save_servers(self.store):
            self.set_status("COULD NOT WRITE " + str(settings_path()), "warn")
        self.refresh_server_list()

    def query_server(self):
        server = self.get_server()
        if not server:
            return
        host, _, port_text = server.rpartition(":")
        self.set_status("QUERYING " + server + " ...", "info")
        result = {}

        def worker():
            try:
                result["info"] = query_server_info(host, int(port_text))
            except (OSError, ValueError) as exc:
                result["error"] = str(exc) or exc.__class__.__name__
            result["done"] = True

        threading.Thread(target=worker, daemon=True).start()
        self.root.after(150, self.poll_query, server, result, 0)

    def poll_query(self, server, result, tries):
        if not result.get("done"):
            if tries > 60:
                self.set_status("QUERY TIMED OUT: " + server, "err")
                return
            self.root.after(150, self.poll_query, server, result, tries + 1)
            return
        info = result.get("info")
        if not info:
            self.set_status(
                "QUERY FAILED • NO REPLY (server may block queries, or it needs the proxy)", "err"
            )
            return
        self.store["names"][server] = info["name"]
        save_servers(self.store)
        self.refresh_server_list()
        bots = (" +" + str(info["bots"]) + " bots") if info["bots"] else ""
        self.set_status(
            "QUERY OK • " + info["name"] + " • " + info["map"] + " • "
            + str(info["players"]) + "/" + str(info["max_players"]) + bots
            + " • " + str(info["ping_ms"]) + " ms",
            "ok",
        )

    # ------------------------------------------------------- PROXY MODE
    def on_proxy_toggle(self):
        if self.proxy_var.get():
            self.set_status("PROXY MODE • CS2 WILL CONNECT TO A LOCAL UDP RELAY", "info")
        else:
            self.stop_relay()
            self.set_status("DIRECT MODE", "ok")

    def resolve_target(self, server):
        """Return the address CS2 should connect to (server itself, or the local relay)."""
        if not self.proxy_var.get():
            return server
        return self.start_relay(server)

    def start_relay(self, server):
        host, _, port_text = server.rpartition(":")
        try:
            key = (host.lower(), int(port_text))
        except ValueError:
            self.set_status("INVALID SERVER", "err")
            return None
        if self.relay is not None and self.relay.is_alive() and self.relay.remote_key == key:
            return "127.0.0.1:" + str(self.relay.local_port)
        self.stop_relay()
        try:
            relay = UdpRelay(host, key[1])
            relay.start()
        except OSError as exc:
            self.set_status("UNABLE TO START UDP RELAY", "err")
            messagebox.showerror(APP_TITLE, "Unable to start the local UDP relay.\n\n" + str(exc))
            return None
        self.relay = relay
        self.update_relay_label()
        return "127.0.0.1:" + str(relay.local_port)

    def stop_relay(self):
        if self.relay is not None:
            self.relay.stop()
            self.relay = None
        self.relay_var.set("")

    def update_relay_label(self):
        relay = self.relay
        if relay is not None and relay.is_alive():
            self.relay_var.set(
                "RELAY 127.0.0.1:" + str(relay.local_port) + " → " + relay.remote[0] + ":" + str(relay.remote[1])
                + "   ↑" + str(relay.packets_up) + " ↓" + str(relay.packets_down)
            )
            self.relay_label.config(fg=GREEN if relay.packets_down > 0 else YELLOW)
        else:
            self.relay_var.set("")

    def on_close(self):
        self.stop_relay()
        self.root.destroy()

    def on_faceit_toggle(self):
        if self.faceit_var.get():
            self.faceit_frame.pack(fill="x", pady=(6, 0))
            self.set_status("FACEIT MODE • LAUNCH VIA STEAM + CONSOLE COMMAND", "warn")
        else:
            self.faceit_frame.pack_forget()
            self.set_status("DIRECT MODE", "ok")

    def copy_connect_cmd(self):
        try:
            server = self.get_server()
            if not server:
                return
            password = self.pass_var.get().strip()
            if not validate_password(password):
                self.set_status("INVALID PASSWORD", "err")
                messagebox.showerror(
                    APP_TITLE,
                    "Invalid password. Spaces, semicolons and quotes are not allowed (max 64 characters).",
                )
                return
            self.set_clipboard(console_connect_command(server, password))
            self.set_status("COPIED CONNECT COMMAND • PASTE IT IN THE CS2 CONSOLE", "ok")
        except Exception as exc:
            self.set_status("COPY FAILED", "err")
            messagebox.showerror(APP_TITLE, str(exc))

    def launch_via_steam(self):
        try:
            os.startfile("steam://rungameid/730")
            self.set_status("CS2 LAUNCH VIA STEAM REQUESTED (FACEIT)", "warn")
        except Exception as exc:
            self.set_status("UNABLE TO LAUNCH VIA STEAM", "err")
            messagebox.showerror(APP_TITLE, "Unable to launch CS2 through Steam.\n\n" + str(exc))

    def clear_fields(self):
        self.pass_var.set("")
        self.host_var.set("")
        self.port_var.set(DEFAULT_PORT)
        self.set_status("READY", "idle")
        self.host_entry.focus_set()

    def open_steam(self):
        if not self.steam_path:
            self.set_status("STEAM NOT FOUND", "err")
            messagebox.showerror(APP_TITLE, "Steam installation was not found.")
            return
        try:
            os.startfile(str(self.steam_path))
            self.set_status("OPENED STEAM FOLDER", "ok")
        except OSError as exc:
            self.set_status("UNABLE TO OPEN STEAM FOLDER", "err")
            messagebox.showerror(APP_TITLE, str(exc))

    def open_cs2(self):
        if not self.cs2_path:
            self.set_status("CS2 NOT FOUND", "err")
            messagebox.showerror(APP_TITLE, "CS2 installation was not found.")
            return
        try:
            os.startfile(str(self.cs2_path))
            self.set_status("OPENED CS2 FOLDER", "ok")
        except OSError as exc:
            self.set_status("UNABLE TO OPEN CS2 FOLDER", "err")
            messagebox.showerror(APP_TITLE, str(exc))


def main():
    if os.name != "nt":
        print("NEPENTII • CS2 TOOL only supports Windows.")
        return
    try:
        import ctypes

        ctypes.windll.shcore.SetProcessDpiAwareness(1)
    except Exception:
        pass
    root = tk.Tk()
    App(root)
    root.mainloop()


if __name__ == "__main__":
    main()