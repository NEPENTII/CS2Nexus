using System.Collections.Generic;
using System.Text.Json.Serialization;

namespace ServerCommands;

public class ModeConfig
{
	[JsonPropertyName("Label")]
	public string Label { get; set; } = "";

	[JsonPropertyName("Commands")]
	public List<string> Commands { get; set; } = new List<string>();

	[JsonPropertyName("Exec")]
	public string Exec { get; set; } = "";

	[JsonPropertyName("ChangeLevel")]
	public bool ChangeLevel { get; set; }

	[JsonPropertyName("Restart")]
	public bool Restart { get; set; } = true;
}
