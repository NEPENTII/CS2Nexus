namespace NexusVIP.Models;

public enum VipFeature
{
    ChatColor, SmokeColor, VipTag, NameColor, VoteKick,
    PriorityJoin, KillEffect, VoteMute, GunMenu, ChatPrefix,
    DeathEffect, MvpEffect, VoteMap, FreeGrenade, FreeFlash, FreeSmoke, ExclusiveKillEffect,
    VoteBan, HeadshotEffect, BombPlantEffect, BombDefuseEffect, SpecialJoinEffect, ExclusiveGunMenu, FreeHealthShot,
}

/// <summary>Minimum Normal VIP level required for each feature (from the NEXUS VIP spec).</summary>
public static class VipFeatureMap
{
    private static readonly Dictionary<VipFeature, VipLevel> MinimumLevel = new()
    {
        [VipFeature.ChatColor] = VipLevel.Bronze,
        [VipFeature.SmokeColor] = VipLevel.Bronze,
        [VipFeature.VipTag] = VipLevel.Bronze,
        [VipFeature.NameColor] = VipLevel.Bronze,
        [VipFeature.VoteKick] = VipLevel.Bronze,

        [VipFeature.PriorityJoin] = VipLevel.Silver,
        [VipFeature.KillEffect] = VipLevel.Silver,
        [VipFeature.VoteMute] = VipLevel.Silver,
        [VipFeature.GunMenu] = VipLevel.Silver,
        [VipFeature.ChatPrefix] = VipLevel.Silver,

        [VipFeature.DeathEffect] = VipLevel.Gold,
        [VipFeature.MvpEffect] = VipLevel.Gold,
        [VipFeature.VoteMap] = VipLevel.Gold,
        [VipFeature.FreeGrenade] = VipLevel.Gold,
        [VipFeature.FreeFlash] = VipLevel.Gold,
        [VipFeature.FreeSmoke] = VipLevel.Gold,
        [VipFeature.ExclusiveKillEffect] = VipLevel.Gold,

        [VipFeature.VoteBan] = VipLevel.Platinum,
        [VipFeature.HeadshotEffect] = VipLevel.Platinum,
        [VipFeature.BombPlantEffect] = VipLevel.Platinum,
        [VipFeature.BombDefuseEffect] = VipLevel.Platinum,
        [VipFeature.SpecialJoinEffect] = VipLevel.Platinum,
        [VipFeature.ExclusiveGunMenu] = VipLevel.Platinum,
        [VipFeature.FreeHealthShot] = VipLevel.Platinum,
    };

    public static VipLevel MinimumFor(VipFeature feature) => MinimumLevel[feature];

    public static bool Has(VipLevel level, VipFeature feature)
    {
        return level != VipLevel.None
               && MinimumLevel.TryGetValue(feature, out var min)
               && level >= min;
    }
}
