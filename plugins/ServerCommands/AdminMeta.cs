using System.Collections.Generic;

namespace ServerCommands;

public sealed class AdminMeta
{
	public string Identity { get; set; } = "";

	public string Name { get; set; } = "";

	public int Immunity { get; set; }

	public List<string> Flags { get; set; } = new List<string>();

	public string Tag { get; set; } = "";

	public bool Enabled { get; set; } = true;
}
