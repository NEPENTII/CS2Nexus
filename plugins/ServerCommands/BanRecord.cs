using System.Text.Json.Serialization;

namespace ServerCommands;

public sealed class BanRecord
{
	[JsonPropertyName("steam")]
	public string Steam { get; set; } = "";

	[JsonPropertyName("name")]
	public string Name { get; set; } = "";

	[JsonPropertyName("admin")]
	public string Admin { get; set; } = "";

	[JsonPropertyName("reason")]
	public string Reason { get; set; } = "";

	[JsonPropertyName("created")]
	public long Created { get; set; }

	[JsonPropertyName("expires")]
	public long Expires { get; set; }
}
