using System.Text;
using NexusVIP.Models;

namespace NexusVIP.Core;

/// <summary>
/// Maps VIP levels and features to CounterStrikeSharp permission flags.
///   vip.level.gold, vip.chat_color, vip.vote_kick, ...   (owned by NexusVIP)
///   @nepentii/votekick                                    (ServerCommands' own VoteKick check)
/// </summary>
public static class VipPermissions
{
    public const string Prefix = "vip.";

    public static string LevelFlag(VipLevel level) => $"{Prefix}level.{level.ToString().ToLowerInvariant()}";

    public static string FeatureFlag(VipFeature feature) => Prefix + ToSnake(feature.ToString());

    /// <summary>NexusVIP's own flags for this level (level flag + every inherited feature).</summary>
    public static IReadOnlyList<string> FlagsFor(VipLevel level)
    {
        if (level == VipLevel.None) return Array.Empty<string>();

        var flags = new List<string> { LevelFlag(level) };
        foreach (var feature in Enum.GetValues<VipFeature>())
        {
            if (VipFeatureMap.Has(level, feature))
                flags.Add(FeatureFlag(feature));
        }
        return flags;
    }

    /// <summary>
    /// ServerCommands permission flags that a VIP level unlocks.
    /// Only commands that ServerCommands already has are listed here.
    /// </summary>
    public static IReadOnlyList<string> ServerCommandsFlagsFor(VipLevel level, string prefix)
    {
        var flags = new List<string>();
        if (VipFeatureMap.Has(level, VipFeature.VoteKick))
            flags.Add(prefix + "votekick");
        return flags;
    }

    private static string ToSnake(string pascal)
    {
        var sb = new StringBuilder(pascal.Length + 4);
        for (int i = 0; i < pascal.Length; i++)
        {
            char c = pascal[i];
            if (char.IsUpper(c))
            {
                if (i > 0) sb.Append('_');
                sb.Append(char.ToLowerInvariant(c));
            }
            else
            {
                sb.Append(c);
            }
        }
        return sb.ToString();
    }
}
