using System.Text.Json.Serialization;

namespace ServerCommands;

public sealed class Punishment
{
	[JsonPropertyName("type")]
	public string Type { get; set; } = "";

	[JsonPropertyName("steam")]
	public string Steam { get; set; } = "";

	[JsonPropertyName("name")]
	public string Name { get; set; } = "";

	[JsonPropertyName("expires")]
	public long Expires { get; set; }

	[JsonPropertyName("by")]
	public string By { get; set; } = "";

	[JsonPropertyName("reason")]
	public string Reason { get; set; } = "";
}
