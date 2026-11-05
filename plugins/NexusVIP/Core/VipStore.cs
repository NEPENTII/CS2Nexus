using System.Text.Json;
using System.Text.RegularExpressions;
using NexusVIP.Models;

namespace NexusVIP.Core;

/// <summary>
/// Per-server Normal VIP storage (one JSON file in the plugin's own folder).
/// Each server has its own copy, so memberships never leak between servers.
/// </summary>
public sealed class VipStore
{
    private static readonly Regex SteamId64Pattern = new(@"^7656119\d{10}$", RegexOptions.Compiled);
    private static readonly JsonSerializerOptions JsonOptions = new() { WriteIndented = true };

    private readonly string _dataPath;
    private readonly string _auditPath;
    private readonly object _gate = new();
    private readonly Dictionary<string, VipRecord> _records = new(StringComparer.Ordinal);

    public VipStore(string directory)
    {
        Directory.CreateDirectory(directory);
        _dataPath = Path.Combine(directory, "vip_players.json");
        _auditPath = Path.Combine(directory, "vip_audit.log");
        Load();
    }

    public static bool IsValidSteamId64(string value) => SteamId64Pattern.IsMatch(value);

    public List<VipRecord> All()
    {
        lock (_gate)
        {
            return _records.Values.ToList();
        }
    }

    /// <summary>
    /// Adds a membership, or updates an existing one. If the existing membership is still active,
    /// the new duration is added to its current expiry (never shortened).
    /// </summary>
    public VipRecord Grant(string steamId64, string name, VipLevel level, int days, string actor, DateTime nowUtc)
    {
        lock (_gate)
        {
            _records.TryGetValue(steamId64, out var existing);
            bool wasActive = existing is not null && existing.IsActive(nowUtc);

            var record = new VipRecord
            {
                SteamId64 = steamId64,
                Name = string.IsNullOrWhiteSpace(name) ? (existing?.Name ?? steamId64) : name,
                Level = level,
                StartsAtUtc = wasActive ? existing!.StartsAtUtc : nowUtc,
                ExpiresAtUtc = (wasActive ? existing!.ExpiresAtUtc : nowUtc).AddDays(days),
                AddedBy = actor,
            };

            _records[steamId64] = record;
            SaveUnlocked();
            AuditUnlocked(actor, wasActive ? "UPDATE" : "GRANT", steamId64,
                $"level={level} days={days} expires={record.ExpiresAtUtc:O}");
            return record;
        }
    }

    public VipRecord? Get(string steamId64)
    {
        lock (_gate)
        {
            return _records.TryGetValue(steamId64, out var record) ? record : null;
        }
    }

    public bool Remove(string steamId64, string actor)
    {
        lock (_gate)
        {
            if (!_records.Remove(steamId64)) return false;

            SaveUnlocked();
            AuditUnlocked(actor, "REMOVE", steamId64, string.Empty);
            return true;
        }
    }

    private void Load()
    {
        lock (_gate)
        {
            _records.Clear();
            if (!File.Exists(_dataPath)) return;

            try
            {
                var list = JsonSerializer.Deserialize<List<VipRecord>>(File.ReadAllText(_dataPath)) ?? new();
                foreach (var record in list)
                {
                    if (IsValidSteamId64(record.SteamId64))
                        _records[record.SteamId64] = record;
                }
            }
            catch (JsonException ex)
            {
                // Keep a copy of the broken file so no membership data is lost.
                string backup = _dataPath + ".corrupt-" + DateTime.UtcNow.ToString("yyyyMMddHHmmss");
                File.Copy(_dataPath, backup, overwrite: true);
                Console.WriteLine($"[NexusVIP] vip_players.json is corrupt, backup saved to {backup}: {ex.Message}");
            }
        }
    }

    private void SaveUnlocked()
    {
        string tmp = _dataPath + ".tmp";
        var ordered = _records.Values.OrderBy(r => r.SteamId64, StringComparer.Ordinal).ToList();
        File.WriteAllText(tmp, JsonSerializer.Serialize(ordered, JsonOptions));
        File.Move(tmp, _dataPath, overwrite: true);
    }

    private void AuditUnlocked(string actor, string action, string steamId64, string details)
    {
        File.AppendAllText(_auditPath,
            $"{DateTime.UtcNow:O} | {actor} | {action} | {steamId64} | {details}{Environment.NewLine}");
    }
}
