<div align="center">

**🌐 Language:** &nbsp; 🇬🇧 **English** &nbsp;|&nbsp; [🇮🇷 فارسی](README.fa.md)

<img src="https://raw.githubusercontent.com/NEPENTII/CS2Nexus/main/cs2nexus_logo.svg" width="720" alt="CS2NEXUS Logo">

<br>

# ⚡ CS2NEXUS

### The all-in-one Counter-Strike 2 server manager & launcher

*Create, run, configure and maintain multiple CS2 dedicated servers from a single menu —<br>shared plugins, one-click setup, auto-updates and a watchdog that never sleeps.*

<br>

![Platform](https://img.shields.io/badge/Ubuntu-22.04-E95420?style=for-the-badge&logo=ubuntu&logoColor=white)
![Shell](https://img.shields.io/badge/Bash-5.x-4EAA25?style=for-the-badge&logo=gnubash&logoColor=white)
![Game](https://img.shields.io/badge/Counter--Strike-2-F7B93E?style=for-the-badge&logo=counterstrike&logoColor=white)
![Plugins](https://img.shields.io/badge/Metamod-CounterStrikeSharp-3b82f6?style=for-the-badge)

![Disk](https://img.shields.io/badge/Per%20server-~MBs%20only-8b5cf6?style=flat-square)
![Servers](https://img.shields.io/badge/Servers-unlimited-ef4444?style=flat-square)
![Cvars](https://img.shields.io/badge/Documented%20cvars-150%2B-06b6d4?style=flat-square)
![Root](https://img.shields.io/badge/Requires-root-f97316?style=flat-square)
![Made in Iran](https://img.shields.io/badge/Made%20in-Iran%20🇮🇷-239f40?style=flat-square)

<br>

**[🚀 Quick Start](#-quick-start)** &nbsp;·&nbsp;
**[✨ Features](#-features)** &nbsp;·&nbsp;
**[🧭 Menu](#-the-menu)** &nbsp;·&nbsp;
**[💻 CLI](#-command-line-usage)** &nbsp;·&nbsp;
**[🔌 Plugins](#-shared-plugins)** &nbsp;·&nbsp;
**[❓ FAQ](#-faq)**

</div>

---

## 📖 Table of Contents

<details>
<summary><b>Click to expand</b></summary>

- [Why CS2Nexus?](#-why-cs2nexus)
- [How it works](#-how-it-works)
- [Features](#-features)
- [Requirements](#-requirements)
- [Quick Start](#-quick-start)
- [The Menu](#-the-menu)
- [Command-Line Usage](#-command-line-usage)
- [Shared Plugins](#-shared-plugins)
- [Server Settings](#-server-settings)
- [Maintenance](#-maintenance)
- [Directory Layout](#-directory-layout)
- [Configuration](#-configuration)
- [Safety Design](#-safety-design)
- [Troubleshooting](#-troubleshooting)
- [FAQ](#-faq)
- [Contributing](#-contributing)
- [Credits](#-credits)

</details>

---

## 🚀 Why CS2Nexus?

Running several CS2 servers normally means:

| ❌ The old way | ✅ With CS2Nexus |
|---|---|
| Copying **60+ GB** of game files for every server | **One** base install, shared through symlinks — a new server costs a few MB |
| Juggling `tmux` sessions by hand | Start / stop / attach from one menu |
| Updating plugins server by server | **One copy** of each plugin, linked into every server |
| Editing `server.cfg` and hoping game-mode configs don't override it | A managed config block **plus** override files that always win |
| Finding out a server crashed from angry players | A **watchdog** restarts it for you |

**One launcher. Every server. Zero babysitting.**

---

## 🧩 How it works

```mermaid
flowchart LR
    BASE[("📦 /opt/cs2<br>Base install<br>read-only")]
    SHARED[("🔌 shared/addons<br>One copy of each plugin")]

    BASE -. symlinks .-> S1
    BASE -. symlinks .-> S2
    BASE -. symlinks .-> S3
    SHARED -. symlinks .-> S1
    SHARED -. symlinks .-> S2
    SHARED -. symlinks .-> S3

    S1["🎮 Server 1<br>own cfg · logs · addons"]
    S2["🎮 Server 2<br>own cfg · logs · addons"]
    S3["🎮 Server 3<br>own cfg · logs · addons"]

    NEXUS{{"⚡ nexus<br>menu · CLI · watchdog"}} --> S1
    NEXUS --> S2
    NEXUS --> S3
```

---

## ✨ Features

### 🖥️ Server Management
- Create, start, stop, restart and delete servers from a menu
- Many servers on one machine — each with its own **port, name, map and client limit**
- **Workshop map support** — enter a map name, a Workshop ID, or a Steam Workshop link
- Per-server **GSLT token** support (`sv_setsteamaccount`)
- Live **player list** and **join/leave history** from game logs
- Runs inside `tmux`, so servers survive closing your SSH session

### 💾 Smart Disk Usage
- One base CS2 install (`/opt/cs2`) shared by every server via symlinks
- Each server keeps its own real `cfg`, `addons`, `logs` and launcher files
- Base files are **never modified** by the manager

### 🔌 Shared Plugin System
- One copy of each plugin, linked into every server
- **Drop-folder auto-discovery** — put a plugin in the shared folder and it is registered automatically
- Per-server data modes: **independent**, **shared**, or **custom per-file**
- Install a plugin on all servers, only selected ones, or all except some
- Built-in **Plugin Browser** that reads plugins straight from GitHub
- **Auto-update** timer with automatic backups of old versions

### ⚙️ Server Settings Engine
- **150+ documented cvars** grouped by category (rounds, economy, voice, votes, bots, GOTV, movement and more)
- **Quick options:** bunny hop, infinite ammo, friendly fire, all-talk, respawn, buy anywhere…
- **Presets:** free server, no votes, no shop, no drops, headshot only and others
- Game mode selector, round time and warmup control
- Default settings inherited by every new server
- Config is written into a managed block of `server.cfg`, plus game-mode override files so game-mode configs can't silently override your values
- **Live actions:** end warmup, pause, restart game, swap teams, scramble teams
- **Verify** what the running server actually uses

### 🛡️ Reliability
- **Watchdog** — restarts crashed servers (with restart-rate limiting) and never restarts servers you stopped on purpose
- **Scheduled restarts** with automatic 5-minute and 1-minute warnings to players
- **CS2 updates through SteamCMD** with countdown, safe stop, update and restart
- **Launcher self-update** from GitHub with syntax and marker validation and automatic backups
- Atomic JSON writes with rotating backups

### 🧰 Automation
- Full non-interactive CLI for **cron, systemd or a web panel**
- `--json` output for list and status commands

---

## 📋 Requirements

| | Requirement |
|---|---|
| 🐧 **OS** | Ubuntu 22.04 (other Debian-based systems may work) |
| 🔑 **Privileges** | `root` (or `sudo`) |
| 💽 **Disk** | ~65 GB free for the CS2 base installation |
| 🌐 **Network** | Internet access for SteamCMD and GitHub |

The launcher checks its own dependencies (`jq`, `tmux`, `curl`, `unzip`, `tar` and others) and offers to install anything missing.

---

## ⚡ Quick Start

```bash
# 1. Download the launcher
sudo curl -L -o /opt/nexus.sh \
  https://raw.githubusercontent.com/NEPENTII/CS2Nexus/main/launcher/nexus.sh

# 2. Make it executable
sudo chmod +x /opt/nexus.sh

# 3. (Optional) install the short commands "nexus" and "cs2"
sudo /opt/nexus.sh --install

# 4. Run it
sudo nexus
```

On the first run, a **setup wizard** will:

1. 👤 Create the `cs2` system user
2. 📥 Find your existing CS2 server files, or install SteamCMD and download them
3. 🎮 Create your first server with default settings
4. 🧱 Optionally install **Metamod:Source** and **CounterStrikeSharp**
5. 🔌 Optionally install the default plugins (**ServerCommands, MapVote, Parachute, AstraSkins**)
6. 🐕 Optionally enable the **watchdog** for automatic restarts

> 💡 **Tip:** The first CS2 download is large (60+ GB). The wizard retries SteamCMD automatically if the first attempt fails.

---

## 🧭 The Menu

```text
╔══════════════════════════════════╗
║            CS2 NEXUS             ║
║     Server Manager & Launcher    ║
╚══════════════════════════════════╝

  1) Create Server          8) Players & History
  2) Start Server           9) Plugins
  3) Stop Server           10) Server Settings
  4) Restart Server        11) Server Console
  5) List Servers          12) Log Viewer
  6) Server Status         13) Maintenance
  7) Delete Server         14) Exit
```

| Section | What it does |
|---|---|
| 🖲️ **Console** | Attach (full or read-only), send one command, or broadcast to all running servers |
| 📜 **Log Viewer** | View or follow game logs and console output (control characters are stripped) |
| 🧰 **Maintenance** | CS2 update, scheduled restarts, watchdog, JSON backups, launcher update, launcher settings |

> 🚪 To leave an attached console **without** stopping the server, press **`Ctrl+B`, then `D`**.

---

## 💻 Command-Line Usage

```bash
nexus list [--json]           # list servers and their state
nexus status [ID] [--json]    # status with player counts
nexus start ID                # start a server
nexus stop ID                 # stop a server
nexus restart ID              # restart a server
nexus sync [--dry-run]        # register dropped plugins and sync all servers
nexus say ID MESSAGE...       # send "say" to one server
nexus broadcast MESSAGE...    # send "say" to all running servers
nexus watchdog                # start offline autostart servers (used by the timer)
nexus plugin-update           # update plugins from the Plugin Browser (used by the timer)
nexus help                    # show help
```

> The short alias `cs2` works exactly the same as `nexus`.

| Exit code | Meaning |
|:---:|---|
| `0` | ✅ OK |
| `1` | ⚠️ Error or skipped items |
| `2` | ❌ Usage error |

With `--json`, **only JSON** goes to `stdout`; every human-readable message goes to `stderr`, so it pipes cleanly:

```bash
nexus status --json | jq '.[] | {name, port, status, players}'
```

<details>
<summary>⏰ <b>Cron example — announce a restart every night</b></summary>

```cron
55 3 * * * /usr/local/bin/nexus broadcast "Server restarts in 5 minutes!"
```

</details>

---

## 🔌 Shared Plugins

Plugins live **once** in:

```text
/opt/cs2-servers/shared/addons/
├── counterstrikesharp/plugins/<PluginName>
└── metamod/plugins/<PluginName>
```

Anything you place in these folders is **registered automatically** and linked into every server on the next sync or server start.

### 🗂️ Data modes

| Mode | Behaviour |
|---|---|
| 🔹 **Independent** | Each server keeps its own `data` folder |
| 🔸 **Shared** | All servers use the same data from the central copy |
| 🔶 **Custom** | You choose exactly which files or folders stay per-server (e.g. `data/astra_skins.sqlite`) |

### 🎯 Assignment

- ✅ All servers (default — including servers created later)
- 🎯 Selected servers only
- 🚫 All servers **except** some

### 🛒 Plugin Browser & Auto-Update

The built-in browser lists plugins from the `plugins` folder of the CS2Nexus GitHub repository, plus any extra GitHub release sources you add. Enable the **auto-update** timer (every 30 minutes) to keep them current. Old versions are backed up automatically — the last 5 are kept.

> ⚠️ Only single plugins can be shared (`<prefix>/<PLUGIN>`). Core files of Metamod or CounterStrikeSharp are **never** shared.

---

## 🎛️ Server Settings

Open **Server Settings** from the main menu. Choose `0` for the **DEFAULT** profile that new servers inherit, or pick a specific server.

| Area | Examples |
|---|---|
| 🏷️ **Basics** | Name, port, client limit, start map, GSLT |
| 🎮 **Game mode** | Casual, Competitive, Wingman, Arms Race, Demolition, Deathmatch |
| ⚡ **Quick options** | Bunny hop, infinite ammo/money, friendly fire, all-talk, respawn, GOTV, cheats |
| 🎁 **Presets** | Free server, no votes, no timeouts, no shop, no drops, headshot only |
| 📚 **CFG settings** | Every cvar by category, with descriptions and validation |
| ✍️ **Custom lines** | Any extra console command |
| 🔴 **Live actions** | End warmup, pause/resume, restart game, swap/scramble teams |
| 🔍 **Check** | Ask the running server what values it really uses |

---

## 🛠️ Maintenance

| Task | What happens |
|---|---|
| 🔄 **Update CS2** | Warns players with a countdown → stops running servers → runs SteamCMD → re-patches `gameinfo.gi` for Metamod → starts the servers again |
| ⏱️ **Scheduled restart** | Pick `HH:MM` or `+N` minutes; players get warnings 5 and 1 minute before |
| 🐕 **Watchdog / autostart** | A systemd timer checks every minute; limited to **3 restarts per 10 minutes** per server |
| 💾 **JSON backups** | Rotating backups of every registry file (newest 10 kept) |
| 🚀 **Update launcher** | Downloads, validates (shebang, marker, size, `bash -n`), backs up and swaps the launcher, then restarts the servers that were running |

---

## 📁 Directory Layout

```text
/opt/cs2/                         # Base CS2 install (never modified by servers)
/opt/cs2-servers/
├── servers.json                  # Server registry
├── <server-slug>/                # One folder per server (symlinks + real cfg/addons/logs)
└── shared/
    ├── addons/                   # Shared plugins (drop folders)
    ├── plugins.json              # Shared plugin registry
    ├── autostart.json            # Watchdog list
    ├── server-settings.json      # Default + per-server settings
    ├── backups/                  # JSON and plugin backups
    └── state/                    # Watchdog and manual-stop markers
/etc/cs2nexus.conf                # Launcher configuration
```

---

## ⚙️ Configuration

`/etc/cs2nexus.conf` holds plain `KEY=VALUE` lines. It is **parsed, never sourced**, and every value is validated.

| Key | Description |
|---|---|
| `BASE` | Path of the CS2 base installation |
| `NEXUS_REPO` / `NEXUS_BRANCH` | GitHub repository and branch used for plugins and launcher updates |
| `EXTRA_PLUGIN_REPOS` | Extra `owner/repo` release sources, comma separated |
| `GITHUB_TOKEN` | Optional token for private repos or rate limits |
| `AUTOUPDATE` | `1` to enable plugin auto-update |
| `UPDATE_ACTION` | `none` or `reload` — what to do on running servers after a plugin update |

Most of these can be changed from **Maintenance → Launcher settings**.

---

## 🔒 Safety Design

CS2Nexus is built so it can't damage your data:

- 🧱 Strict path validation before any destructive operation (`rm -rf` only with safety checks and `--one-file-system`)
- 🔗 Real local plugin files and foreign symlinks are **never overwritten**
- 📝 Every JSON write is validated, backed up, written to a temp file, then moved atomically
- 🔐 A re-entrant operations lock stops the menu, cron and timers from colliding
- 🚫 Lock file descriptors are closed for `tmux`, so they never leak into game servers
- 📦 Downloaded plugin packages are rejected if they contain symlinks or exceed the size limit
- 🙋 Servers are only touched when you ask — a manual stop is respected by the watchdog

> ⚠️ **Heads-up:** the launcher runs as **root** and its self-update downloads a script from GitHub. Only point it at a repository **you control**.

---

## 🩺 Troubleshooting

<details>
<summary><b>SteamCMD download fails or stalls</b></summary>

The wizard retries automatically. If it keeps failing, check free disk space (~65 GB) and your connection to Steam, then run **Maintenance → Update CS2** again.

</details>

<details>
<summary><b>A server won't start</b></summary>

Open **Log Viewer** and check `<server>/logs/console.log`. The most common causes are a port already in use or a missing/invalid GSLT token.

</details>

<details>
<summary><b>Plugin not loading after a CS2 update</b></summary>

Metamod and CounterStrikeSharp are not touched by CS2 updates. Make sure their versions match the new game build.

</details>

<details>
<summary><b>Dropped plugin doesn't appear</b></summary>

Run `nexus sync` (or `nexus sync --dry-run` first to preview what will change).

</details>

---

## ❓ FAQ

**Does each server need its own GSLT token?**
Yes. Create one per server at <https://steamcommunity.com/dev/managegameservers> with App ID `730`.

**Where are my game logs?**
In each server's `game/csgo/logs` folder; console output is in `<server>/logs/console.log`.

**How do I attach to a server console?**
Use **Server Console → Attach**, or run `runuser -u cs2 -- tmux attach -t cs2-<ID>`. Detach with **Ctrl+B, then D**.

**A plugin stopped working after a CS2 update.**
Metamod and CounterStrikeSharp are not touched by the CS2 update. Check that their versions match the new game build.

**Can I add my own plugins?**
Yes. Copy the plugin folder into `shared/addons/counterstrikesharp/plugins/` (or the `metamod/plugins/` equivalent) and run `nexus sync`.

---

## 🤝 Contributing

Issues and pull requests are welcome! If you find a bug or have an idea, open an issue and describe your setup (Ubuntu version, CS2 build and the steps to reproduce).

---

## 👤 Credits

<div align="center">

**CS2Nexus** is designed and developed by

## NEPENTII
🇮🇷 *Iran*

<br>

If this project helps you, please ⭐ **star the repository**!

<br>

![Made with love](https://img.shields.io/badge/Made%20with-❤️%20and%20Bash-ef4444?style=for-the-badge)

</div>
