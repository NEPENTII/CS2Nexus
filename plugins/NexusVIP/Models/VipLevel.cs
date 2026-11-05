namespace NexusVIP.Models;

/// <summary>Normal VIP levels. Higher levels inherit everything from lower levels.</summary>
public enum VipLevel
{
    None = 0,
    Bronze = 1,
    Silver = 2,
    Gold = 3,
    Platinum = 4,
}

public static class VipLevels
{
    private static readonly Dictionary<string, VipLevel> Aliases = new(StringComparer.OrdinalIgnoreCase)
    {
        ["1"] = VipLevel.Bronze,   ["bronze"] = VipLevel.Bronze,
        ["2"] = VipLevel.Silver,   ["silver"] = VipLevel.Silver,
        ["3"] = VipLevel.Gold,     ["gold"] = VipLevel.Gold,
        ["4"] = VipLevel.Platinum, ["platinum"] = VipLevel.Platinum,
    };

    public static bool TryParse(string input, out VipLevel level)
    {
        return Aliases.TryGetValue(input.Trim(), out level);
    }
}
