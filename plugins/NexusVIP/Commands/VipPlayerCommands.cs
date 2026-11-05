using CounterStrikeSharp.API.Core;
using NexusVIP.Core;
using NexusVIP.Models;

namespace NexusVIP.Commands;

/// <summary>Commands for players themselves: !vipinfo and !vipmenu.</summary>
internal static class VipPlayerCommands
{
    // !vipinfo  -> own level and expiry on this server
    public static void OnVipInfo(CCSPlayerController? caller, CommandInfo info)
    {
        if (caller is null || !caller.IsValid)
        {
            info.ReplyToCommand("Players only.");
            return;
        }

        var now = DateTime.UtcNow;
        var record = NexusVIPPlugin.Store.Get(caller.SteamID.ToString());

        if (record is null || !record.IsActive(now))
        {
            info.ReplyToCommand("You do not have an active VIP on this server.");
            return;
        }

        int daysLeft = (int)Math.Ceiling((record.ExpiresAtUtc - now).TotalDays);
        info.ReplyToCommand(
            $"VIP {record.Level} | expires {record.ExpiresAtUtc:yyyy-MM-dd} UTC | {daysLeft} day(s) left");
    }

    // !vipmenu  -> every feature with its status for this player
    public static void OnVipMenu(CCSPlayerController? caller, CommandInfo info)
    {
        if (caller is null || !caller.IsValid)
        {
            info.ReplyToCommand("Players only.");
            return;
        }

        var now = DateTime.UtcNow;
        var record = NexusVIPPlugin.Store.Get(caller.SteamID.ToString());
        var level = record is not null && record.IsActive(now) ? record.Level : VipLevel.None;

        info.ReplyToCommand(level == VipLevel.None
            ? "VIP features (you are not VIP on this server):"
            : $"VIP features (your level: {level}):");

        foreach (var feature in Enum.GetValues<VipFeature>())
        {
            bool unlocked = VipFeatureMap.Has(level, feature);
            var required = VipFeatureMap.MinimumFor(feature);

            info.ReplyToCommand(unlocked
                ? $"[OK] {feature}"
                : $"[LOCKED] {feature} (needs {required})");
        }
    }
}
