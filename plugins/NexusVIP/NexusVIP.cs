using CounterStrikeSharp.API;
using CounterStrikeSharp.API.Core;
using NexusVIP.Commands;
using NexusVIP.Config;
using NexusVIP.Core;

namespace NexusVIP;

public sealed class NexusVIPPlugin : BasePlugin
{
    public override string ModuleName => "NexusVIP";
    public override string ModuleVersion => "0.4.0";
    public override string ModuleAuthor => "CS2Nexus";
    public override string ModuleDescription => "Per-server Normal VIP (Bronze..Platinum) managed by the server owner.";

    internal static NexusVIPConfig Settings { get; private set; } = new();
    internal static VipStore Store { get; private set; } = null!;

    public override void Load(bool hotReload)
    {
        Settings = NexusVIPConfig.Load(Path.Combine(ModuleDirectory, "NexusVIP.json"));
        Store = new VipStore(ModuleDirectory);

        AddCommand("css_addvip",
            "Owner: grant or update a Normal VIP. Usage: [name]&<steamid64> <level> [days]",
            VipAdminCommands.OnAddVip);

        AddCommand("css_addvip_as",
            "Console only (used by ServerCommands). Usage: <actorSteamId64> [name]&<steamid64> <level> [days]",
            VipAdminCommands.OnAddVipAs);

        AddCommand("css_vipinfo",
            "Show your own VIP level and expiry on this server",
            VipPlayerCommands.OnVipInfo);

        AddCommand("css_vipmenu",
            "Show all VIP features and which ones you have",
            VipPlayerCommands.OnVipMenu);

        AddCommand("css_vip",
            "Owner: list the Normal VIP players of this server",
            VipAdminCommands.OnVipList);

        // Give VIP flags as soon as the player is authorized, and keep them in sync (expiry, edits).
        RegisterListener<Listeners.OnClientAuthorized>((slot, steamId) =>
        {
            var player = Utilities.GetPlayerFromSlot(slot);
            if (player is not null) VipPermissionSync.SyncPlayer(player);
        });

        AddTimer(60.0f, VipPermissionSync.SyncAllOnlinePlayers, TimerFlags.REPEAT);
    }
}
