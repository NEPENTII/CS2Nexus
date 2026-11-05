using System.Text.Json;

namespace NexusVIP.Config;

public sealed class NexusVIPConfig
{
    /// <summary>CSS permission flags that count as the server owner (any one is enough).</summary>
    public List<string> OwnerFlags { get; set; } = new() { "@css/root" };

    public int DefaultDays { get; set; } = 30;
    public int MaxDays { get; set; } = 3650;
    public int VipListLimit { get; set; } = 20;

    /// <summary>
    /// When true, VIP levels also grant the ServerCommands permission flags it already checks
    /// (e.g. VoteKick -> "@nepentii/votekick"). ServerCommands itself is not modified.
    /// </summary>
    public bool ServerCommandsBridge { get; set; } = true;

    /// <summary>Prefix ServerCommands uses in HasPerm(): "@nepentii/" + permission name.</summary>
    public string ServerCommandsFlagPrefix { get; set; } = "@nepentii/";

    private static readonly JsonSerializerOptions WriteOptions = new() { WriteIndented = true };

    public static NexusVIPConfig Load(string path)
    {
        var defaults = new NexusVIPConfig();

        if (!File.Exists(path))
        {
            File.WriteAllText(path, JsonSerializer.Serialize(defaults, WriteOptions));
            return defaults;
        }

        try
        {
            var cfg = JsonSerializer.Deserialize<NexusVIPConfig>(File.ReadAllText(path)) ?? defaults;

            bool valid = cfg.OwnerFlags.Count > 0
                         && cfg.DefaultDays >= 1
                         && cfg.MaxDays >= cfg.DefaultDays
                         && cfg.VipListLimit >= 1
                         && !string.IsNullOrWhiteSpace(cfg.ServerCommandsFlagPrefix);

            if (valid) return cfg;

            Console.WriteLine("[NexusVIP] Config values are invalid, using defaults.");
            return defaults;
        }
        catch (JsonException ex)
        {
            Console.WriteLine($"[NexusVIP] Cannot parse NexusVIP.json, using defaults: {ex.Message}");
            return defaults;
        }
    }
}
