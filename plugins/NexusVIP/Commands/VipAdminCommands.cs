using System.Text.RegularExpressions;
using CounterStrikeSharp.API.Core;
using CounterStrikeSharp.API.Modules.Admin;
using NexusVIP.Core;
using NexusVIP.Models;

namespace NexusVIP.Commands;

internal static class VipAdminCommands
{
    // Accepts:  [name]&<steamid64> <level> [days]
    //           <steamid64> <level> [days]
    private static readonly Regex AddPattern = new(
        @"^\s*(?:(?<name>[^&]*?)\s*&\s*)?(?<steam>\d{17})\s+(?<level>\S+)(?:\s+(?<days>\d{1,5}))?\s*$",
        RegexOptions.Compiled | RegexOptions.CultureInvariant,
        TimeSpan.FromMilliseconds(200));

    // Console-only form used by ServerCommands: <actorSteamId64> <args of css_addvip>
    private static readonly Regex ActorPattern = new(
        @"^\s*(?<actor>\d{17})\s+(?<rest>.+)$",
        RegexOptions.Compiled | RegexOptions.CultureInvariant,
        TimeSpan.FromMilliseconds(200));

    private const string Usage =
        "Usage: !addvip [name]&<steamid64> <bronze|silver|gold|platinum|1-4> [days]";

    // !addvip  (owner or server console)
    public static void OnAddVip(CCSPlayerController? caller, CommandInfo info)
    {
        if (!IsOwner(caller))
        {
            info.ReplyToCommand("You are not allowed to use this command.");
            return;
        }

        GrantFromArgs(info.ArgString, ActorId(caller), info);
    }

    // css_addvip_as  (server console only, called by ServerCommands after it checked the admin's permission)
    public static void OnAddVipAs(CCSPlayerController? caller, CommandInfo info)
    {
        if (caller is not null && caller.IsValid)
        {
            info.ReplyToCommand("This command can only be run from the server console.");
            return;
        }

        var match = ActorPattern.Match(info.ArgString);
        if (!match.Success)
        {
            info.ReplyToCommand("Usage: css_addvip_as <actorSteamId64> [name]&<steamid64> <level> [days]");
            return;
        }

        GrantFromArgs(match.Groups["rest"].Value, match.Groups["actor"].Value, info);
    }

    // !vip  -> list every Normal VIP membership of THIS server (owner only)
    public static void OnVipList(CCSPlayerController? caller, CommandInfo info)
    {
        if (!IsOwner(caller))
        {
            info.ReplyToCommand("You are not allowed to use this command.");
            return;
        }

        var now = DateTime.UtcNow;
        var records = NexusVIPPlugin.Store.All()
            .OrderByDescending(r => r.IsActive(now))
            .ThenByDescending(r => r.ExpiresAtUtc)
            .ToList();

        int limit = NexusVIPPlugin.Settings.VipListLimit;

        info.ReplyToCommand($"NexusVIP: {records.Count} membership(s) on this server.");

        foreach (var r in records.Take(limit))
        {
            bool active = r.IsActive(now);
            string status = active ? "ACTIVE" : "EXPIRED";
            int daysLeft = active ? (int)Math.Ceiling((r.ExpiresAtUtc - now).TotalDays) : 0;

            info.ReplyToCommand(
                $"[{status}] {r.Name} | {r.SteamId64} | {r.Level} | until {r.ExpiresAtUtc:yyyy-MM-dd} | {daysLeft}d left");
        }

        if (records.Count > limit)
        {
            info.ReplyToCommand($"...and {records.Count - limit} more (raise VipListLimit to see them).");
        }
    }

    private static void GrantFromArgs(string args, string actor, CommandInfo info)
    {
        var settings = NexusVIPPlugin.Settings;
        var match = AddPattern.Match(args);
        if (!match.Success)
        {
            info.ReplyToCommand(Usage);
            return;
        }

        string steamId64 = match.Groups["steam"].Value;
        if (!VipStore.IsValidSteamId64(steamId64))
        {
            info.ReplyToCommand("Invalid SteamID64.");
            return;
        }

        if (!VipLevels.TryParse(match.Groups["level"].Value, out var level))
        {
            info.ReplyToCommand("Invalid level. Use bronze, silver, gold, platinum or 1-4.");
            return;
        }

        int days = settings.DefaultDays;
        if (match.Groups["days"].Success)
        {
            days = int.Parse(match.Groups["days"].Value);
        }

        if (days < 1 || days > settings.MaxDays)
        {
            info.ReplyToCommand($"Days must be between 1 and {settings.MaxDays}.");
            return;
        }

        string name = CleanName(match.Groups["name"].Value);

        var record = NexusVIPPlugin.Store.Grant(steamId64, name, level, days, actor, DateTime.UtcNow);
        VipPermissionSync.SyncAllOnlinePlayers();

        info.ReplyToCommand(
            $"VIP {record.Level} granted to {record.Name} ({record.SteamId64}) until {record.ExpiresAtUtc:yyyy-MM-dd HH:mm} UTC.");
    }

    private static bool IsOwner(CCSPlayerController? caller)
    {
        // Server console is always allowed.
        if (caller is null || !caller.IsValid) return true;

        return AdminManager.PlayerHasPermissions(caller, NexusVIPPlugin.Settings.OwnerFlags.ToArray());
    }

    private static string ActorId(CCSPlayerController? caller)
    {
        if (caller is null || !caller.IsValid) return "console";
        return caller.SteamID.ToString();
    }

    private static string CleanName(string raw)
    {
        var chars = raw.Where(c => !char.IsControl(c)).Take(64).ToArray();
        return new string(chars).Trim();
    }
}
