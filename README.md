# ⚡ CS2NEXUS

### Advanced Counter-Strike 2 Dedicated Server Manager & Launcher

<p align="center">
  <b>Manage • Create • Launch • Control • Synchronize • Protect</b>
</p>

<p align="center">
  A powerful Linux-based management system for running and managing
  multiple Counter-Strike 2 dedicated servers from a single environment.
</p>

---

## 🚀 Overview

**CS2NEXUS** is a powerful Bash-based management system designed for
Counter-Strike 2 dedicated servers on Linux.

Instead of maintaining every CS2 server manually, CS2NEXUS provides a
centralized environment for managing multiple servers while sharing
large game files and plugins between them.

The system is designed around:

- ⚡ Fast server management
- 🧩 Shared plugin architecture
- 🗂️ JSON-based configuration
- 🔐 Safety and filesystem protection
- 🖥️ tmux-based server sessions
- 🔄 Server synchronization
- 💾 Automatic backups
- 🛡️ Operation locking
- ⚙️ Per-server configuration
- 📦 Plugin discovery and management
- 🔧 Automated server tree management

---

# ✨ Features

## 🖥️ Multi-Server Management

Run and manage multiple CS2 servers from one installation.

Each server is stored independently under:

```text
/opt/cs2-servers/<server-slug>
