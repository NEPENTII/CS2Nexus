using System;
using CounterStrikeSharp.API.Core;

namespace ServerCommands;

public sealed class Cmd
{
	public string Name = "";

	public string[] Aliases = Array.Empty<string>();

	public string Label = "";

	public string Usage = "";

	public string? Perm;

	public Action<CCSPlayerController?, CmdContext> Run = (CCSPlayerController? _, CmdContext _) =>
	{
	};

	public Action<CCSPlayerController>? Menu;
}
