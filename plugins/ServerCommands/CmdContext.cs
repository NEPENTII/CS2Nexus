using System;

namespace ServerCommands;

public sealed class CmdContext
{
	public string[] Args = Array.Empty<string>();

	public string Alias = "";

	public string Raw = "";
}
