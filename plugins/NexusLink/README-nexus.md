# NexusLink — live transport for the CS2NEXUS [NEXUS] system

**Version:** 1.6.1 · **Role:** the live Website → CS2-server channel that §14.4 / §14.7 rely on.

## Does NexusLink need a DLL change for the [NEXUS] system?

**No.** NexusLink already provides the live inbound channel the spec requires, so its DLL is
returned **unchanged** in this package. The two features that needed a change live in the
**ServerCommands** plugin (see `ServerCommands.zip`):

- **§14.2 `[NEXUS]` tag for both global owners** — applied by `ServerCommands.ApplyTag` / `TagOf`
  (hardcoded in that DLL). NexusLink never renders in-game tags; it only ships snapshots to the
  panel, and the panel's `state.js dn()` strips every in-game tag prefix from displayed names
  (§14.3), so `[NEXUS]` is transparent to NexusLink.
- **§14.4 custom tag + §14.5/14.7 live admin management** — the panel writes
  `ServerCommandsAdmins.json` / `ServerCommands.json` directly, then pushes a live reload through
  NexusLink's existing **`cmd`** command type, which runs any `css_*` server command — in
  particular `css_sc_reload` (hot-reloads the admin roster + re-applies tags to all connected
  players) and `css_plugins reload ServerCommands` (hot-reloads the config). No server restart,
  no plugin-source recompilation, no NexusLink modification.

## How the live path works (unchanged)

Every `SnapshotSeconds` (default 5 s) NexusLink POSTs a snapshot to the panel
(`/api/plugin/snapshot`, `X-Api-Key` header). The panel **responds** with a `commands` array that
NexusLink executes live via `Exec()`. The `cmd` type runs `Server.ExecuteCommand(text)` for any
`text` starting with `css_` — so the panel queues e.g. `{type:'cmd', text:'css_sc_reload'}` and
the next snapshot tick applies it. Player-targeted commands (`kick`/`mute`/`gag`/`ban`/…) and
match commands are also carried here. Login codes go through `/api/plugin/code`; finished matches
through `/api/plugin/match`.

## Configuration (per server, written by the launcher — not in this zip)

`NexusLinkConfig` (`PanelUrl`, `ApiKey`, `ServerId`, `SnapshotSeconds`, `LogChat`, …) is written
per-server by the CS2NEXUS launcher into each server's `addons/counterstrikesharp/configs/plugins/
NexusLink/NexusLinkConfig.json`. This package contains only the plugin itself (`NexusLink.dll`,
`plugin.json`, `version.txt`).

## Files

```
NexusLink/
├── NexusLink.dll      ← unchanged (1.6.1) — already supports the live cmd channel
├── plugin.json        ← CounterStrikeSharp plugin manifest
├── version.txt        ← 1.6.1
└── README-nexus.md    ← this file
```
