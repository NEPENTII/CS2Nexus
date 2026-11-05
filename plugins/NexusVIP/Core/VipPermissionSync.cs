using CounterStrikeSharp.API;
using CounterStrikeSharp.API.Core;
using CounterStrikeSharp.API.Modules.Admin;
using NexusVIP.Models;

namespace NexusVIP.Core;

/// <summary>
/// Keeps VIP permission flags of connected players in sync with the server's VIP store.
///
/// Rules:
/// - Only flags this plugin granted are ever removed.
/// - If a player already holds a flag from another source (e.g. admins.json), we do not take ownership of it,
///   so an expiring VIP can never strip a real ServerCommands admin permission.
/// </summary>
internal static class VipPermissionSync
{
    // steamId64 -> flags this plugin has actually granted to that player
    private static readonly Dictionary<ulong, HashSet<string>> Granted = new();

    public static void SyncAllOnlinePlayers()
    {
        foreach (var player in Utilities.GetPlayers())
        {
            SyncPlayer(player);
        }
    }

    public static void SyncPlayer(CCSPlayerController player)
    {
        if (!player.IsValid || player.IsBot || player.SteamID == 0) return;

        ulong steamId = player.SteamID;
        var desired = DesiredFlags(steamId);

        Granted.TryGetValue(steamId, out var previous);
        previous ??= new HashSet<string>();

        // 1. Remove what we granted earlier but no longer deserve (expired, revoked, level lowered).
        foreach (var flag in previous.Where(f => !desired.Contains(f)).ToArray())
        {
            AdminManager.RemovePlayerPermissions(steamId, flag);
        }

        var kept = new HashSet<string>(previous.Where(desired.Contains));

        // 2. Grant missing flags, skipping any the player already has from another source.
        foreach (var flag in desired)
        {
            if (kept.Contains(flag)) continue;
            if (AdminManager.PlayerHasPermissions(player, flag)) continue;

            AdminManager.AddPlayerPermissions(steamId, flag);
            kept.Add(flag);
        }

        Granted[steamId] = kept;
    }

    private static HashSet<string> DesiredFlags(ulong steamId)
    {
        var record = NexusVIPPlugin.Store.Get(steamId.ToString());
        if (record is null || !record.IsActive(DateTime.UtcNow))
        {
            return new HashSet<string>();
        }

        var settings = NexusVIPPlugin.Settings;
        var flags = VipPermissions.FlagsFor(record.Level).ToHashSet();

        if (settings.ServerCommandsBridge)
        {
            foreach (var flag in VipPermissions.ServerCommandsFlagsFor(record.Level, settings.ServerCommandsFlagPrefix))
            {
                flags.Add(flag);
            }
        }

        return flags;
    }
}
