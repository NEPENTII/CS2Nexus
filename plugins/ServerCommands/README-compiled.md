# ServerCommands.dll — compiled with the !admins command toggle

This is the **fully compiled** plugin DLL with the `!admins` command toggle built in.
Built by directly patching the original `ServerCommands.dll` with Mono.Cecil
(no source recompilation needed — the original DLL's Vip modules are decompiled
source that does not recompile cleanly).

## File
- `ServerCommands.dll` — 263,680 bytes (orig 265,216). Drop-in replacement.

## What it does at runtime
Two changes vs. the original DLL:

### 1. New config field `AdminsCommandEnabled` (default `true`)
Added to `ServerCommands.ServerCommandsConfig` with `[JsonPropertyName("AdminsCommandEnabled")]`.
The Nexus owner panel writes this field into each server's `ServerCommands.json`.
CounterStrikeSharp hot-reloads the config on file change, so toggling it from the
panel takes effect immediately — no server restart.

### 2. `!admins` command gated on the new field
The `ShowAdmins` method (the `!admins` handler) now begins with:
```csharp
if (!Config.AdminsCommandEnabled && !IsOwner(p)) {
    Reply(p, "The !admins command is disabled on this server.");
    return;
}
```
- When `AdminsCommandEnabled = false` → regular users get the "disabled" reply; **owners always see the list**.
- When `AdminsCommandEnabled = true` (default) → behaves exactly like before.

`ApplyNameTags` (the admin/owner name-tag toggle) already existed in the original
DLL and already worked — the panel exposes it in the same config card.

## Install
Replace `addons/counterstrikesharp/plugins/ServerCommands/ServerCommands.dll` on
each game server. No other files need to change; `plugin.json` and `version.txt`
are unchanged.

## How it was built (for the record)
- .NET 10 SDK (10.0.404) installed locally
- Mono.Cecil 0.11.6 patched the original DLL:
  - added the `<AdminsCommandEnabled>k__BackingField` field
  - added `get_AdminsCommandEnabled` / `set_AdminsCommandEnabled` methods
  - added the `AdminsCommandEnabled` property with `[JsonPropertyName]`
  - injected `ldarg.0; ldc.i4.1; stfld` into the `.ctor` (default = true)
  - injected the 13-instruction guard at the start of `ShowAdmins`
- Verified with Cecil: IL is in correct forward order, all call operands resolve,
  branch targets valid, 176 instructions (163 original + 13 guard).


---

## [NEXUS] global-owner tag patch (v5.6.5-nexus)

This DLL is Cecil-patched on the v5.6.5 base so the **two global Nexus owners** show the
protected `[NEXUS]` tag in-game (spec §14.1/14.2). Three in-place IL edits (no structural change,
branch offsets recomputed by Cecil):

1. **`ApplyTag` owner-branch** — the owner name prefix is now the hardcoded `ldstr "NEXUS"`,
   wrapped by the existing `"[" + … + "] "` -> `"[NEXUS] "` (was `Config.OwnerTag`). Every
   SteamID in `OwnerSteamIds` gets it; the launcher's `owners_ensure` puts only the two global
   owners (`76561198768187147`, `76561198878431088`) there on every server.
2. **`TagOf` owner-branch** — returns hardcoded `ldstr "[NEXUS]"` (was `Config.OwnerTag`), so the
   `!admins` list shows `| [NEXUS] |` for owners.
3. **`NexusNamePrefix` regex** — `^(?:nexus|\[ᴏᴡɴᴇʀ\])\s*` -> `^(?:nexus|\[ᴏᴡɴᴇʀ\]|\[NEXUS\])\s*`
   so `StripPrefixes` strips a stale `[NEXUS] ` left in a player's name after a plugin reload
   (no `[NEXUS] [NEXUS] name` stacking).

`[NEXUS]` is **hardcoded** = protected: per-server `OwnerTag` config cannot override it, ordinary
admins can't remove it, it survives restarts (baked into the DLL). The website strips all in-game
tags from displayed names (`state.js dn()`), so `[NEXUS]` is in-game only — permissions are
unchanged. The seed `ServerCommands.json` now lists both global owners in `OwnerSteamIds`.
