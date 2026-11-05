namespace NexusVIP.Models;

/// <summary>One Normal VIP membership on one server. SteamID64 is the canonical identity.</summary>
public sealed class VipRecord
{
    public string SteamId64 { get; set; } = "";
    public string Name { get; set; } = "";
    public VipLevel Level { get; set; } = VipLevel.None;
    public DateTime StartsAtUtc { get; set; }
    public DateTime ExpiresAtUtc { get; set; }
    public string AddedBy { get; set; } = "";

    public bool IsActive(DateTime nowUtc) => Level != VipLevel.None && nowUtc < ExpiresAtUtc;
}
