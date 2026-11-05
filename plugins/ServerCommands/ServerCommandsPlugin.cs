using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using CounterStrikeSharp.API;
using CounterStrikeSharp.API.Core;
using CounterStrikeSharp.API.Core.Attributes;
using CounterStrikeSharp.API.Core.Attributes.Registration;
using CounterStrikeSharp.API.Modules.Admin;
using CounterStrikeSharp.API.Modules.Commands;
using CounterStrikeSharp.API.Modules.Cvars;
using CounterStrikeSharp.API.Modules.Menu;
using CounterStrikeSharp.API.Modules.Timers;
using CounterStrikeSharp.API.Modules.Utils;
using CounterStrikeSharp.API.ValveConstants.Protobuf;
using Microsoft.Extensions.Logging;

namespace ServerCommands;

[MinimumApiVersion(200)]
public class ServerCommandsPlugin : BasePlugin, IPluginConfig<ServerCommandsConfig>
{
	private sealed class VoteState
	{
		public ulong TargetSteam;

		public string TargetName = "";

		public int Team;

		public HashSet<ulong> Eligible = new HashSet<ulong>();

		public HashSet<ulong> Yes = new HashSet<ulong>();

		public HashSet<ulong> No = new HashSet<ulong>();

		public bool Finished;
	}

	public static readonly (string perm, string label)[] PermList = new (string, string)[49]
	{
		("rr", "Restart Round"),
		("start", "Start Match"),
		("end", "End Match"),
		("endwarmup", "End Warmup"),
		("startwarmup", "Start Warmup"),
		("pausewarmup", "Pause Warmup"),
		("pause", "Force Pause / Unpause"),
		("kniferound", "Knife Round"),
		("gag", "Gag Player"),
		("ungag", "Ungag Player"),
		("mute", "Mute Player"),
		("unmute", "Unmute Player"),
		("kick", "Kick Player"),
		("ban", "Ban Player"),
		("unban", "Unban"),
		("slay", "Slay"),
		("slap", "Slap"),
		("respawn", "Respawn"),
		("move", "Move Player Team"),
		("rename", "Rename Player"),
		("spectate", "Spectate Player"),
		("plist", "Player List"),
		("addcash", "Add Cash"),
		("cash", "Set Cash"),
		("give", "Give Weapons"),
		("bh", "BunnyHop"),
		("ff", "Friendly Fire"),
		("t", "All Talk"),
		("hs", "Headshot Only"),
		("casual", "Casual Mode"),
		("comp", "Competitive Mode"),
		("dm", "Deathmatch Mode"),
		("mix", "Mix Mode"),
		("aim", "Aim Mode"),
		("prac", "Practice Mode"),
		("retakes", "Retakes Mode"),
		("warmup", "Warmup Mode"),
		("map", "Change Map"),
		("wmap", "Workshop Map"),
		("maxrounds", "Max Rounds"),
		("freezetime", "Freeze Time"),
		("bot", "Bots"),
		("lock", "Lock Teams"),
		("rcon", "RCON"),
		("asay", "Admin Say"),
		("votekick", "Vote Kick"),
		("addvip", "Add VIP"),
		("vip", "VIP List"),
		("admincmd", "Admin Command Menu"),
		("addadmin", "Add Admin"),
		("adminsp", "Admin Permissions")
	};

	private static readonly (string cat, string[] items)[] WeaponCats = new (string, string[])[6]
	{
		("Rifles", new string[7] { "ak47", "m4a1", "m4a1_silencer", "aug", "sg556", "galilar", "famas" }),
		("Snipers", new string[4] { "awp", "ssg08", "g3sg1", "scar20" }),
		("SMGs", new string[7] { "mp9", "mac10", "p90", "ump45", "bizon", "mp7", "mp5sd" }),
		("Heavy", new string[6] { "nova", "xm1014", "mag7", "sawedoff", "m249", "negev" }),
		("Pistols", new string[10] { "deagle", "revolver", "usp_silencer", "glock", "p250", "fiveseven", "tec9", "cz75a", "elite", "hkp2000" }),
		("Gear", new string[10] { "knife", "flashbang", "hegrenade", "smokegrenade", "molotov", "incgrenade", "decoy", "taser", "c4", "healthshot" })
	};

	private bool _teamsLocked;

	private bool _knifeEnabled;

	private bool _knifeRunning;

	private int _knifeAwaitTeam;

	private readonly HashSet<int> _pauseReq = new HashSet<int>();

	private readonly HashSet<int> _unpauseReq = new HashSet<int>();

	private readonly Dictionary<string, string> _savedCvars = new Dictionary<string, string>();

	private bool _warmupPaused;

	private static readonly Dictionary<string, string> KnifeFallback = new Dictionary<string, string>
	{
		["mp_buytime"] = "20",
		["mp_startmoney"] = "800",
		["mp_maxmoney"] = "16000"
	};

	private static readonly Regex MapRx = new Regex("^[A-Za-z0-9_\\-]+$", RegexOptions.Compiled);

	private static readonly Random Rng = new Random();

	private static readonly string[] KnifeCvars = new string[3] { "mp_buytime", "mp_startmoney", "mp_maxmoney" };

	private VoteState? _vote;

	private readonly List<Cmd> _cmds = new List<Cmd>();

	private readonly Dictionary<string, Cmd> _byName = new Dictionary<string, Cmd>(StringComparer.OrdinalIgnoreCase);

	private readonly object _fileLock = new object();

	private NetworkDisconnectionReason _banReason = (NetworkDisconnectionReason)40;

	private Timer? _tagTimer;

	private Timer? _sweepTimer;

	private Timer? _clearBansTimer;

	private readonly Dictionary<ulong, Action<CCSPlayerController, string>> _prompts = new Dictionary<ulong, Action<CCSPlayerController, string>>();

	private static readonly JsonSerializerOptions JsonRead = new JsonSerializerOptions
	{
		PropertyNameCaseInsensitive = true
	};

	private static readonly JsonSerializerOptions JsonWrite = new JsonSerializerOptions
	{
		WriteIndented = true
	};

	private static readonly Regex TagPrefix = new Regex("^\\|\\s*[^|]{1,16}?\\s*\\|\\s*", RegexOptions.Compiled);

	private List<AdminMeta> _metaCache = new List<AdminMeta>();

	private long _metaCacheAt;

	private List<Punishment> _pun = new List<Punishment>();

	private readonly List<(ulong steam, string name)> _recent = new List<(ulong, string)>();

	private List<BanRecord> _bans = new List<BanRecord>();

	public override string ModuleName => "ServerCommands";

	public override string ModuleVersion => "4.1.0";

	public override string ModuleAuthor => "NEPENTII / CS2Nexus";

	public override string ModuleDescription => "Central admin commands with menus, admin tags, gag/mute and real bans (per server).";

	public ServerCommandsConfig Config { get; set; } = new ServerCommandsConfig();

	private string Pfx => $" {ChatColors.Red}{Config.ChatPrefix}{ChatColors.White} ";

	private string AdminsFile => Path.Combine(AdminDir(), "admins.json");

	private string MetaFile => Path.Combine(AdminDir(), "ServerCommandsAdmins.json");

	private string TagOf(AdminMeta m)
	{
		if (m.Tag.Length <= 0)
		{
			return Config.DefaultAdminTag;
		}
		return m.Tag;
	}

	private void ShowAdmins(CCSPlayerController? caller)
	{
		List<AdminMeta> source = LoadMeta();
		List<(AdminMeta, string)> list = new List<(AdminMeta, string)>();
		foreach (CCSPlayerController p in Humans())
		{
			AdminMeta adminMeta = source.FirstOrDefault((AdminMeta x) => x.Identity == ((CBasePlayerController)p).SteamID.ToString() && x.Enabled);
			if (adminMeta != null)
			{
				list.Add((adminMeta, CleanName(((CBasePlayerController)p).PlayerName)));
			}
		}
		list = list.OrderByDescending(((AdminMeta m, string name) r) => Config.OwnerSteamIds.Contains(r.m.Identity)).ThenBy(((AdminMeta m, string name) r) => r.name, StringComparer.OrdinalIgnoreCase).ToList();
		if (list.Count == 0)
		{
			Server.PrintToChatAll($" {ChatColors.Yellow}[Admins] {ChatColors.White}No admins are currently online.");
			return;
		}
		Server.PrintToChatAll($" {ChatColors.Green}[Admins] {ChatColors.White}Online admins ({list.Count}):");
		foreach (var (m, value) in list)
		{
			Server.PrintToChatAll($" {ChatColors.Green}| {TagOf(m)} | {ChatColors.White}{value}");
		}
	}

	private void AdminCmdMenu(CCSPlayerController p)
	{
		List<(string, Action<CCSPlayerController>)> list = new List<(string, Action<CCSPlayerController>)>();
		foreach (Cmd item in _cmds.Where((Cmd c) => c.Perm != null && c.Name != "admincmd" && c.Name != "cmds" && HasPerm(p, c.Perm)))
		{
			Cmd cmd = item;
			list.Add(($"/{cmd.Name}  {ChatColors.Grey}{cmd.Label}", (CCSPlayerController a) =>
			{
				if (cmd.Menu != null)
				{
					cmd.Menu(a);
				}
				else
				{
					Reply(a, "Usage: " + cmd.Usage);
					if (cmd.Run != null && cmd.Usage.IndexOf('<') < 0 && cmd.Usage.IndexOf('[') < 0)
					{
						cmd.Run(a, new CmdContext
						{
							Alias = cmd.Name
						});
					}
				}
			}));
		}
		ShowMenu(p, "Admin commands", list);
	}

	private void ListCommandsConsole()
	{
		foreach (Cmd cmd in _cmds)
		{
			Console.WriteLine($"{cmd.Usage,-48} {cmd.Label}");
		}
	}

	private List<string> NewAdminFlags()
	{
		return Config.NewAdminPermissions.Select((string x) => "@nepentii/" + x).ToList();
	}

	private void AddAdmin(CCSPlayerController? by, string identity, string name)
	{
		//IL_00fd: Unknown result type (might be due to invalid IL or missing references)
		//IL_0108: Expected Obj, but got Unknown
		List<AdminMeta> list = LoadMeta();
		AdminMeta adminMeta = list.FirstOrDefault((AdminMeta x) => x.Identity == identity);
		if (adminMeta == null)
		{
			adminMeta = new AdminMeta
			{
				Identity = identity,
				Name = name,
				Immunity = Config.NewAdminImmunity,
				Flags = NewAdminFlags(),
				Tag = Config.DefaultAdminTag,
				Enabled = true
			};
			list.Add(adminMeta);
			Reply(by, name + " added as admin.");
		}
		else
		{
			adminMeta.Enabled = true;
			adminMeta.Name = name;
			if (adminMeta.Tag.Length == 0)
			{
				adminMeta.Tag = Config.DefaultAdminTag;
			}
			Reply(by, name + " is now enabled as admin.");
		}
		SaveMeta(list);
		SyncAdmins(list);
		InvalidateMetaCache();
		CCSPlayerController val = Players().FirstOrDefault((CCSPlayerController x) => ((CBasePlayerController)x).SteamID.ToString() == identity);
		if ((CEntityInstance)val != (CEntityInstance)null)
		{
			ApplyTag(val);
		}
	}

	private void AddAdminMenu(CCSPlayerController p)
	{
		List<AdminMeta> meta = LoadMeta();
		List<(string, Action<CCSPlayerController>)> list = new List<(string, Action<CCSPlayerController>)>();
		foreach (CCSPlayerController item in from x in Humans()
			where !meta.Any((AdminMeta m) => m.Identity == ((CBasePlayerController)x).SteamID.ToString() && m.Enabled)
			orderby ((CBasePlayerController)x).PlayerName
			select x)
		{
			string id = ((CBasePlayerController)item).SteamID.ToString();
			string nm = CleanName(((CBasePlayerController)item).PlayerName);
			list.Add(($"{nm} #{item.UserId}", (CCSPlayerController a) =>
			{
				if (HasPerm(a, "addadmin"))
				{
					AddAdmin(a, id, nm);
				}
			}));
		}
		foreach (AdminMeta item2 in meta.Where((AdminMeta m) => !m.Enabled && !Humans().Any((CCSPlayerController x) => ((CBasePlayerController)x).SteamID.ToString() == m.Identity)))
		{
			string id2 = item2.Identity;
			string nm2 = item2.Name;
			list.Add(("(offline, disabled) " + nm2, (CCSPlayerController a) =>
			{
				if (HasPerm(a, "addadmin"))
				{
					AddAdmin(a, id2, nm2);
				}
			}));
		}
		if (list.Count == 0)
		{
			Reply(p, "Nobody to add. Online players are already admins. (/addadmin <steamid64> adds offline)");
		}
		else
		{
			ShowMenu(p, "Add admin", list);
		}
	}

	private void AdminListMenu(CCSPlayerController viewer)
	{
		List<AdminMeta> list = LoadMeta();
		if (list.Count == 0)
		{
			Reply(viewer, "No managed admins found.");
			return;
		}
		List<(string, Action<CCSPlayerController>)> items = (from m in list
			orderby Config.OwnerSteamIds.Contains(m.Identity) descending, m.Enabled descending
			select m).ThenBy((AdminMeta m) => m.Name, StringComparer.OrdinalIgnoreCase).Select((AdminMeta m) =>
		{
			string id = m.Identity;
			return ((string, Action<CCSPlayerController>))($"{(m.Enabled ? "ON " : "OFF")} | {TagOf(m)} | {m.Name}", (CCSPlayerController a) =>
			{
				AdminMenu(a, id, 0);
			});
		}).ToList();
		ShowMenu(viewer, "Admin permissions", items);
	}

	private void AdminMenu(CCSPlayerController viewer, string identity, int page)
	{
		if (!HasPerm(viewer, "adminsp"))
		{
			Reply(viewer, "You do not have permission.");
			return;
		}
		AdminMeta adminMeta = LoadMeta().FirstOrDefault((AdminMeta x) => x.Identity == identity);
		if (adminMeta == null)
		{
			Reply(viewer, "Admin not found.");
			return;
		}
		bool ownerTarget = Config.OwnerSteamIds.Contains(identity);
		if (ownerTarget && !IsOwner(viewer))
		{
			Reply(viewer, "Owners can only be edited by owners.");
			return;
		}
		List<(string, Action<CCSPlayerController>)> list = new List<(string, Action<CCSPlayerController>)>();
		list.Add((ownerTarget ? "Admin: ON (owner, protected)" : ("Admin: " + (adminMeta.Enabled ? "ON  (click to disable)" : "OFF (click to enable)")), (CCSPlayerController a) =>
		{
			if (ownerTarget)
			{
				Reply(a, "Owners cannot be disabled.");
				AdminMenu(a, identity, 0);
			}
			else
			{
				Mutate(identity, (AdminMeta x) =>
				{
					x.Enabled = !x.Enabled;
				});
				AdminMenu(a, identity, 0);
			}
		}));
		list.Add(("Tag: " + ((adminMeta.Tag.Length > 0) ? adminMeta.Tag : "(none)"), (CCSPlayerController a) =>
		{
			TagMenu(a, identity);
		}));
		(string, string)[] permList = PermList;
		for (int num = 0; num < permList.Length; num++)
		{
			(string, string) tuple = permList[num];
			string item = tuple.Item1;
			string item2 = tuple.Item2;
			string flag = "@nepentii/" + item;
			bool flag2 = ownerTarget || adminMeta.Flags.Contains(flag, StringComparer.OrdinalIgnoreCase);
			int idx = list.Count;
			list.Add(((flag2 ? "☑" : "☐") + " " + item2, (CCSPlayerController a) =>
			{
				if (ownerTarget)
				{
					Reply(a, "Owners always have every permission.");
					AdminMenu(a, identity, idx / 6);
				}
				else
				{
					Mutate(identity, (AdminMeta x) =>
					{
						int num2 = x.Flags.FindIndex((string f) => f.Equals(flag, StringComparison.OrdinalIgnoreCase));
						if (num2 >= 0)
						{
							x.Flags.RemoveAt(num2);
						}
						else
						{
							x.Flags.Add(flag);
						}
					});
					AdminMenu(a, identity, idx / 6);
				}
			}));
		}
		ShowMenu(viewer, adminMeta.Name ?? "", list, page);
	}

	private void TagMenu(CCSPlayerController viewer, string identity)
	{
		List<(string, Action<CCSPlayerController>)> list = new List<(string, Action<CCSPlayerController>)>();
		foreach (string tagPreset in Config.TagPresets)
		{
			string tag = NormTag(tagPreset);
			list.Add(("| " + tag + " |", (CCSPlayerController a) =>
			{
				Mutate(identity, (AdminMeta x) =>
				{
					x.Tag = tag;
				});
				AdminMenu(a, identity, 0);
			}));
		}
		list.Add(("✎ Custom tag…", (CCSPlayerController a) =>
		{
			Prompt(a, "Type the new tag (max 16 characters):", (CCSPlayerController pl, string txt) =>
			{
				string tag2 = NormTag(txt);
				if (tag2.Length == 0)
				{
					Reply(pl, "Invalid tag.");
				}
				else if (HasPerm(pl, "adminsp"))
				{
					Mutate(identity, (AdminMeta x) =>
					{
						x.Tag = tag2;
					});
					AdminMenu(pl, identity, 0);
				}
			});
		}));
		list.Add(("No tag (name is not changed)", (CCSPlayerController a) =>
		{
			Mutate(identity, (AdminMeta x) =>
			{
				x.Tag = "";
			});
			AdminMenu(a, identity, 0);
		}));
		ShowMenu(viewer, "Choose the tag", list);
	}

	[ConsoleCommand("css_sc_reload", "Reload admins written by the CS2Nexus launcher")]
	[CommandHelper(/*Could not decode attribute arguments.*/)]
	public void OnScReload(CCSPlayerController? player, CommandInfo command)
	{
		InvalidateMetaCache();
		try
		{
			AdminManager.LoadAdminData(AdminsFile);
		}
		catch (Exception ex)
		{
			LoggerExtensions.LogWarning(((BasePlugin)this).Logger, "Reload admins failed: {M}", new object[1] { ex.Message });
		}
		foreach (CCSPlayerController item in Humans())
		{
			ApplyTag(item);
		}
	}

	private void Mutate(string identity, Action<AdminMeta> change)
	{
		//IL_0094: Unknown result type (might be due to invalid IL or missing references)
		//IL_009f: Expected Obj, but got Unknown
		List<AdminMeta> list = LoadMeta();
		AdminMeta adminMeta = list.FirstOrDefault((AdminMeta x) => x.Identity == identity);
		if (adminMeta != null)
		{
			change(adminMeta);
			if (Config.OwnerSteamIds.Contains(identity))
			{
				adminMeta.Enabled = true;
				adminMeta.Flags = AllFlags().ToList();
				adminMeta.Immunity = 100;
			}
			SaveMeta(list);
			SyncAdmins(list);
			InvalidateMetaCache();
			CCSPlayerController val = Players().FirstOrDefault((CCSPlayerController x) => ((CBasePlayerController)x).SteamID.ToString() == identity);
			if ((CEntityInstance)val != (CEntityInstance)null)
			{
				ApplyTag(val, list);
			}
		}
	}

	public static IEnumerable<string> AllFlags()
	{
		return PermList.Select(((string perm, string label) x) => "@nepentii/" + x.perm);
	}

	private void ResetMatchState()
	{
		if (_knifeRunning || _savedCvars.Count > 0)
		{
			RestoreKnifeCvars();
		}
		_knifeRunning = false;
		_knifeAwaitTeam = 0;
		_pauseReq.Clear();
		_unpauseReq.Clear();
	}

	private void RestoreKnifeCvars()
	{
		string[] knifeCvars = KnifeCvars;
		foreach (string text in knifeCvars)
		{
			_savedCvars.TryGetValue(text, out var value);
			if (string.IsNullOrEmpty(value) || (value == "0" && KnifeFallback.ContainsKey(text)))
			{
				value = KnifeFallback[text];
			}
			Exec(text + " " + value);
		}
		_savedCvars.Clear();
	}

	private Cmd Add(string name, string label, string usage, string? perm, Action<CCSPlayerController?, CmdContext> run, Action<CCSPlayerController>? menu = null, params string[] aliases)
	{
		Cmd cmd = new Cmd
		{
			Name = name,
			Label = label,
			Usage = usage,
			Perm = perm,
			Run = run,
			Menu = menu,
			Aliases = aliases
		};
		_cmds.Add(cmd);
		return cmd;
	}

	private static int ArgInt(string[] a, int i, int def)
	{
		if (a.Length <= i || !int.TryParse(a[i], out var result))
		{
			return def;
		}
		return result;
	}

	private static string Rest(string[] a, int from)
	{
		if (a.Length <= from)
		{
			return "";
		}
		return string.Join(' ', a.Skip(from)).Trim();
	}

	private static string DurationText(int minutes)
	{
		if (minutes > 0)
		{
			if (minutes < 1440 || minutes % 1440 != 0)
			{
				if (minutes >= 60 && minutes % 60 == 0)
				{
					return $"{minutes / 60} hour(s)";
				}
				return $"{minutes} min";
			}
			return $"{minutes / 1440} day(s)";
		}
		return "permanent";
	}

	private void BuildCommands()
	{
		_cmds.Clear();
		Add("rr", "Restart round.", "/rr", "rr", (CCSPlayerController? p, CmdContext c) =>
		{
			Exec("mp_restartgame 1");
			Announce("Round restarted.");
		}, null);
		Add("rs", "Reset your own score.", "/rs", null, (CCSPlayerController? p, CmdContext c) =>
		{
			//IL_0001: Unknown result type (might be due to invalid IL or missing references)
			//IL_000c: Expected Obj, but got Unknown
			if ((CEntityInstance)p == (CEntityInstance)null)
			{
				Reply(p, "Players only.");
			}
			else
			{
				ResetScore(p);
				Reply(p, "Your score was reset.");
			}
		}, null);
		Add("start", "Start match (knife round first if enabled).", "/start", "start", (CCSPlayerController? p, CmdContext c) =>
		{
			StartMatch();
		}, null);
		Add("end", "End match (back to warmup).", "/end", "end", (CCSPlayerController? p, CmdContext c) =>
		{
			RestoreKnifeCvars();
			_knifeRunning = false;
			Exec("mp_warmup_start");
			Announce("Match ended.");
		}, null);
		Add("endwarmup", "End warmup.", "/endwarmup", "endwarmup", (CCSPlayerController? p, CmdContext c) =>
		{
			_warmupPaused = false;
			Exec("mp_warmup_pausetimer 0");
			Exec("mp_warmup_end");
			Announce("Warmup ended.");
		}, null);
		Add("startwarmup", "Restart warmup.", "/startwarmup", "startwarmup", (CCSPlayerController? p, CmdContext c) =>
		{
			Exec("mp_warmup_start");
			Announce("Warmup started.");
		}, null);
		Add("pausewarmup", "Pause / resume the warmup timer.", "/pausewarmup", "pausewarmup", (CCSPlayerController? p, CmdContext c) =>
		{
			_warmupPaused = !_warmupPaused;
			Exec("mp_warmup_pausetimer " + (int)(_warmupPaused ? 1 : 0));
			Announce(_warmupPaused ? "Warmup timer paused." : "Warmup timer resumed.");
		}, null);
		Add("kniferound", "Toggle the knife round before the match.", "/kniferound", "kniferound", (CCSPlayerController? p, CmdContext c) =>
		{
			_knifeEnabled = !_knifeEnabled;
			Announce(_knifeEnabled ? "Knife round is ON (it runs when you use /start)." : "Knife round is OFF.");
		}, null);
		Add("stay", "Knife round winners: stay on the side.", "/stay", null, (CCSPlayerController? p, CmdContext c) =>
		{
			KnifeDecision(p, swap: false);
		}, null);
		Add("switch", "Knife round winners: switch sides.", "/switch", null, (CCSPlayerController? p, CmdContext c) =>
		{
			KnifeDecision(p, swap: true);
		}, null);
		Add("pause", "Request a pause (needs both teams).", "/pause", null, (CCSPlayerController? p, CmdContext c) =>
		{
			PauseRequest(p, pause: true);
		}, null);
		Add("unpause", "Request to continue (needs both teams).", "/unpause", null, (CCSPlayerController? p, CmdContext c) =>
		{
			PauseRequest(p, pause: false);
		}, null);
		Add("fpause", "Force pause.", "/fpause", "pause", (CCSPlayerController? p, CmdContext c) =>
		{
			Exec("mp_pause_match");
			Announce("Match paused by an admin.");
		}, null);
		Add("funpause", "Force unpause.", "/funpause", "pause", (CCSPlayerController? p, CmdContext c) =>
		{
			Exec("mp_unpause_match");
			_pauseReq.Clear();
			_unpauseReq.Clear();
			Announce("Match resumed by an admin.");
		}, null);
		Add("lock", "Lock / unlock team changes.", "/lock", "lock", (CCSPlayerController? p, CmdContext c) =>
		{
			_teamsLocked = !_teamsLocked;
			Announce(_teamsLocked ? "Teams are LOCKED." : "Teams are unlocked.");
		}, null);
		AddToggle("bh", "BunnyHop", "bh", (int v) =>
		{
			Exec($"sv_autobunnyhopping {v}");
			Exec($"sv_enablebunnyhopping {v}");
		}, "bh1", "bh0");
		AddToggle("ff", "Friendly Fire", "ff", (int v) =>
		{
			Exec($"mp_friendlyfire {v}");
		}, "ff1", "ff0");
		AddToggle("t", "All Talk", "t", (int v) =>
		{
			Exec($"sv_alltalk {v}");
		}, "t1", "t0");
		AddToggle("hs", "Headshot Only", "hs", (int v) =>
		{
			Exec($"mp_damage_headshot_only {v}");
		}, "hs1", "hs0");
		AddMode("casual", "casual");
		AddMode("comp", "comp", "competitive");
		AddMode("dm", "dm", "deathmatch");
		AddMode("mix", "mix", "mm", "match");
		AddMode("aim", "aim");
		AddMode("prac", "prac", "practice");
		AddMode("retakes", "retakes", "retake");
		AddMode("warmup", "warmup");
		Add("map", "Change map.", "/map <map>", "map", (CCSPlayerController? p, CmdContext c) =>
		{
			if (c.Args.Length == 0)
			{
				Reply(p, "Usage: /map <map>");
			}
			else
			{
				ChangeMap(p, c.Args[0]);
			}
		}, (CCSPlayerController p) =>
		{
			ShowMenu(p, "Change map", (from m in ((IEnumerable<string>)Config.Maps).Where((Func<string, bool>)Server.IsMapValid)
				select ((string m, Action<CCSPlayerController>))(m: m, (CCSPlayerController a) =>
				{
					ChangeMap(a, m);
				})).ToList());
		});
		Add("wmap", "Change to a workshop map (workshop id).", "/wmap <workshop id>", "wmap", (CCSPlayerController? p, CmdContext c) =>
		{
			if (c.Args.Length == 0)
			{
				Reply(p, "Usage: /wmap <workshop id>");
			}
			else
			{
				WorkshopMap(p, c.Args[0]);
			}
		}, (CCSPlayerController p) =>
		{
			List<(string, Action<CCSPlayerController>)> list = Config.WorkshopMaps.Select((KeyValuePair<string, string> kv) => ((string Key, Action<CCSPlayerController>))(Key: kv.Key, (CCSPlayerController a) =>
			{
				WorkshopMap(a, kv.Value);
			})).ToList();
			list.Add(("✎ Enter a workshop id…", (CCSPlayerController a) =>
			{
				Prompt(a, "Type the workshop map id:", (CCSPlayerController pl, string t) =>
				{
					WorkshopMap(pl, t);
				});
			}));
			ShowMenu(p, "Workshop map", list);
		});
		Add("maxrounds", "Set mp_maxrounds.", "/maxrounds <rounds>", "maxrounds", (CCSPlayerController? p, CmdContext c) =>
		{
			int num = ArgInt(c.Args, 0, -1);
			if (num < 1 || num > 100)
			{
				Reply(p, "Usage: /maxrounds <1-100>");
			}
			else
			{
				Exec($"mp_maxrounds {num}");
				Announce($"Max rounds set to {num}.");
			}
		}, (CCSPlayerController p) =>
		{
			ShowMenu(p, "Max rounds", Config.MaxRoundsMenu.Select((int n) => ((string, Action<CCSPlayerController>))($"{n} rounds", (CCSPlayerController a) =>
			{
				Exec($"mp_maxrounds {n}");
				Announce($"Max rounds set to {n}.");
			})).ToList());
		});
		Add("freezetime", "Set mp_freezetime.", "/freezetime <seconds>", "freezetime", (CCSPlayerController? p, CmdContext c) =>
		{
			int num = ArgInt(c.Args, 0, -1);
			if (num < 0 || num > 120)
			{
				Reply(p, "Usage: /freezetime <0-120>");
			}
			else
			{
				Exec($"mp_freezetime {num}");
				Announce($"Freeze time set to {num}s.");
			}
		}, (CCSPlayerController p) =>
		{
			ShowMenu(p, "Freeze time", Config.FreezeTimeMenu.Select((int n) => ((string, Action<CCSPlayerController>))($"{n} seconds", (CCSPlayerController a) =>
			{
				Exec($"mp_freezetime {n}");
				Announce($"Freeze time set to {n}s.");
			})).ToList());
		});
		Add("rcon", "Run a server console command.", "/rcon <command>", "rcon", (CCSPlayerController? p, CmdContext c) =>
		{
			if (c.Args.Length == 0)
			{
				Reply(p, "Usage: /rcon <command>");
			}
			else
			{
				string text = string.Join(' ', c.Args);
				if (text.Contains('\n') || text.Contains('\r') || text.Contains(';'))
				{
					Reply(p, "One command at a time (no ';').");
				}
				else
				{
					LoggerExtensions.LogInformation(((BasePlugin)this).Logger, "rcon by {A}: {C}", new object[2]
					{
						(((CEntityInstance)(object)p != (CEntityInstance)null) ? ((CBasePlayerController)p).PlayerName : null) ?? "Console",
						text
					});
					Exec(text);
					Reply(p, "Executed: " + text);
				}
			}
		}, (CCSPlayerController p) =>
		{
			Prompt(p, "Type the console command:", (CCSPlayerController pl, string t) =>
			{
				if (HasPerm(pl, "rcon"))
				{
					Exec(t);
					Reply(pl, "Executed: " + t);
				}
			});
		});
		Add("asay", "Admin message in chat.", "/asay <message>", "asay", (CCSPlayerController? p, CmdContext c) =>
		{
			//IL_0053: Unknown result type (might be due to invalid IL or missing references)
			//IL_005e: Expected Obj, but got Unknown
			if (c.Args.Length == 0)
			{
				Reply(p, "Usage: /asay <message>");
			}
			else
			{
				Server.PrintToChatAll($" {ChatColors.Red}[ADMIN] {ChatColors.Gold}{(((CEntityInstance)p == (CEntityInstance)null) ? "Console" : CleanName(((CBasePlayerController)p).PlayerName))}{ChatColors.White}: {string.Join(' ', c.Args)}");
			}
		}, (CCSPlayerController p) =>
		{
			Prompt(p, "Type the message for everybody:", (CCSPlayerController pl, string t) =>
			{
				Server.PrintToChatAll($" {ChatColors.Red}[ADMIN] {ChatColors.Gold}{CleanName(((CBasePlayerController)pl).PlayerName)}{ChatColors.White}: {t}");
			});
		});
		Add("hsay", "Admin message in the center of the screen.", "/hsay <message>", "asay", (CCSPlayerController? p, CmdContext c) =>
		{
			if (c.Args.Length == 0)
			{
				Reply(p, "Usage: /hsay <message>");
			}
			else
			{
				CenterAll(string.Join(' ', c.Args));
			}
		}, (CCSPlayerController p) =>
		{
			Prompt(p, "Type the message for everybody:", (CCSPlayerController pl, string t) =>
			{
				CenterAll(t);
			});
		});
		Add("bot", "Practice bots: /bot [ct|t|kick|freeze|go].", "/bot [ct|t|kick|freeze|go]", "bot", (CCSPlayerController? p, CmdContext c) =>
		{
			BotCmd(p, (c.Args.Length != 0) ? c.Args[0] : "");
		}, (CCSPlayerController p) =>
		{
			ShowMenu(p, "Bots", new List<(string, Action<CCSPlayerController>)>
			{
				("Add CT bot", (CCSPlayerController a) =>
				{
					BotCmd(a, "ct");
				}),
				("Add T bot", (CCSPlayerController a) =>
				{
					BotCmd(a, "t");
				}),
				("Freeze bots (stand still)", (CCSPlayerController a) =>
				{
					BotCmd(a, "freeze");
				}),
				("Bots move again", (CCSPlayerController a) =>
				{
					BotCmd(a, "go");
				}),
				("Kick all bots", (CCSPlayerController a) =>
				{
					BotCmd(a, "kick");
				})
			});
		});
		Add("plist", "List online players.", "/plist", "plist", (CCSPlayerController? p, CmdContext c) =>
		{
			List<CCSPlayerController> list = (from x in Players()
				orderby x.UserId
				select x).ToList();
			Reply(p, $"Players ({list.Count}):");
			foreach (CCSPlayerController item in list)
			{
				Reply(p, $"#{item.UserId} {CleanName(((CBasePlayerController)item).PlayerName)} [{TeamTag(item)}] {(item.IsBot ? "BOT" : ((CBasePlayerController)item).SteamID.ToString())}");
			}
		}, null);
		Add("admins", "Show the online admins.", "/admins", null, (CCSPlayerController? p, CmdContext c) =>
		{
			ShowAdmins(p);
		}, null);
		AddPlayerAction("kick", "Kick a player.", "/kick <player> [reason]", "kick", (CCSPlayerController? a, CCSPlayerController t, CmdContext c) =>
		{
			KickPlayer(a, t, Rest(c.Args, 1));
		}, groups: false, new string[1] { "kickid" }, (CCSPlayerController? a, CCSPlayerController t) =>
		{
			KickPlayer(a, t, "");
		});
		AddPlayerAction("slay", "Kill a player.", "/slay <player|@ct|@t|@all>", "slay", (CCSPlayerController? a, CCSPlayerController t, CmdContext c) =>
		{
			Slay(t);
		}, groups: true, null, null, "slayed");
		AddPlayerAction("respawn", "Respawn a player.", "/respawn <player|@ct|@t|@all>", "respawn", (CCSPlayerController? a, CCSPlayerController t, CmdContext c) =>
		{
			if (!t.PawnIsAlive)
			{
				t.Respawn();
			}
		}, groups: true, null, null, "respawned", noImmunity: true, (CCSPlayerController x) => ((CBaseEntity)x).TeamNum == 2 || ((CBaseEntity)x).TeamNum == 3);
		AddPlayerAction("spectate", "Spectate a player.", "/spectate <player>", "spectate", (CCSPlayerController? a, CCSPlayerController t, CmdContext c) =>
		{
			SpectatePlayer(a, t);
		}, groups: false, null, null, null, noImmunity: true, null, allowSelfOnly: true);
		Add("slap", "Slap a player.", "/slap <player> [damage]", "slap", (CCSPlayerController? p, CmdContext c) =>
		{
			//IL_0029: Unknown result type (might be due to invalid IL or missing references)
			//IL_0034: Expected Obj, but got Unknown
			if (c.Args.Length == 0)
			{
				Reply(p, "Usage: /slap <player> [damage]");
			}
			else
			{
				CCSPlayerController val = FindOne(p, c.Args[0], out var error);
				if ((CEntityInstance)val == (CEntityInstance)null)
				{
					Reply(p, error);
				}
				else if (!CanTarget(p, val))
				{
					Reply(p, "That player has more immunity than you.");
				}
				else
				{
					Slap(val, ArgInt(c.Args, 1, 0));
					Reply(p, "Slapped " + CleanName(((CBasePlayerController)val).PlayerName) + ".");
				}
			}
		}, (CCSPlayerController p) =>
		{
			PickPlayer(p, "Slap who?", (CCSPlayerController a, CCSPlayerController t) =>
			{
				ShowMenu(a, "Damage", Config.SlapDamageMenu.Select((int d) => ((string, Action<CCSPlayerController>))($"{d} damage", (CCSPlayerController b) =>
				{
					if (((CEntityInstance)t).IsValid && CanTarget(b, t))
					{
						Slap(t, d);
						Reply(b, "Slapped " + CleanName(((CBasePlayerController)t).PlayerName) + ".");
					}
				})).ToList());
			}, groups: false, null, (CCSPlayerController x) => x.PawnIsAlive);
		});
		Add("move", "Move a player to another team.", "/move <player|@group> <t|ct|spec>", "move", (CCSPlayerController? p, CmdContext c) =>
		{
			//IL_00c6: Unknown result type (might be due to invalid IL or missing references)
			//IL_0121: Unknown result type (might be due to invalid IL or missing references)
			if (c.Args.Length < 2)
			{
				Reply(p, "Usage: /move <player> <t|ct|spec>");
			}
			else
			{
				CsTeam? val = ParseTeam(c.Args[1]);
				if (!val.HasValue)
				{
					Reply(p, "Team must be t, ct or spec.");
				}
				else
				{
					List<CCSPlayerController> list = FindPlayers(p, c.Args[0], allowGroups: true, out var error);
					if (list.Count == 0)
					{
						Reply(p, error);
					}
					else
					{
						foreach (CCSPlayerController item2 in list.Where((CCSPlayerController x) => CanTarget(p, x)))
						{
							MovePlayer(item2, val.Value);
						}
						Reply(p, $"Moved {list.Count} player(s) to {TeamName(val.Value)}.");
					}
				}
			}
		}, (CCSPlayerController p) =>
		{
			PickPlayer(p, "Move who?", (CCSPlayerController a, CCSPlayerController t) =>
			{
				MoveTeamMenu(a, t.Slot, 0, group: false);
			}, groups: true, (CCSPlayerController a, string g) =>
			{
				MoveTeamMenu(a, -1, 0, group: true, g);
			});
		});
		Add("rename", "Rename a player.", "/rename <player> <new name>", "rename", (CCSPlayerController? p, CmdContext c) =>
		{
			//IL_002b: Unknown result type (might be due to invalid IL or missing references)
			//IL_0036: Expected Obj, but got Unknown
			if (c.Args.Length < 2)
			{
				Reply(p, "Usage: /rename <player> <new name>");
			}
			else
			{
				CCSPlayerController val = FindOne(p, c.Args[0], out var error);
				if ((CEntityInstance)val == (CEntityInstance)null)
				{
					Reply(p, error);
				}
				else
				{
					RenamePlayer(p, val, Rest(c.Args, 1));
				}
			}
		}, (CCSPlayerController p) =>
		{
			PickPlayer(p, "Rename who?", (CCSPlayerController a, CCSPlayerController t) =>
			{
				int slot = t.Slot;
				Prompt(a, "Type the new name for " + CleanName(((CBasePlayerController)t).PlayerName) + ":", (CCSPlayerController pl, string txt) =>
				{
					//IL_002b: Unknown result type (might be due to invalid IL or missing references)
					//IL_0036: Expected Obj, but got Unknown
					CCSPlayerController val = Players().FirstOrDefault((CCSPlayerController x) => x.Slot == slot);
					if ((CEntityInstance)val != (CEntityInstance)null && HasPerm(pl, "rename"))
					{
						RenamePlayer(pl, val, txt);
					}
				});
			});
		});
		Add("addcash", "Add money to a player.", "/addcash <player|@group> <amount>", "addcash", (CCSPlayerController? p, CmdContext c) =>
		{
			CashCmd(p, c, add: true);
		}, (CCSPlayerController p) =>
		{
			CashMenu(p, add: true);
		});
		Add("cash", "Set the money of a player.", "/cash <player|@group> <amount>", "cash", (CCSPlayerController? p, CmdContext c) =>
		{
			CashCmd(p, c, add: false);
		}, (CCSPlayerController p) =>
		{
			CashMenu(p, add: false);
		});
		Add("give", "Give a weapon / item.", "/give <player|@ct|@t|@all> <weapon>", "give", (CCSPlayerController? p, CmdContext c) =>
		{
			if (c.Args.Length < 2)
			{
				Reply(p, "Usage: /give <player|@ct|@t|@all> <weapon_name>");
			}
			else
			{
				List<CCSPlayerController> list = FindPlayers(p, c.Args[0], allowGroups: true, out var error);
				if (list.Count == 0)
				{
					Reply(p, error);
				}
				else
				{
					GiveItem(p, list, c.Args[1]);
				}
			}
		}, (CCSPlayerController p) =>
		{
			PickPlayer(p, "Give to?", (CCSPlayerController a, CCSPlayerController t) =>
			{
				GiveCategoryMenu(a, new List<int> { t.Slot });
			}, groups: true, (CCSPlayerController a, string g) =>
			{
				GiveCategoryMenu(a, (from x in FindPlayers(a, g, allowGroups: true, out var _)
					select x.Slot).ToList());
			}, (CCSPlayerController x) => x.PawnIsAlive);
		});
		AddPunishCmd("gag", "gag", "Gag a player (no chat).", new string[1] { "gagid" }, new string[1] { "addgag" }, new string[1] { "ungag" }, new string[1] { "oungag" });
		AddPunishCmd("mute", "mute", "Mute a player (no voice).", new string[1] { "muteid" }, new string[1] { "addmute" }, new string[1] { "unmute" }, new string[1] { "ounmute" });
		Add("ban", "Ban a player from THIS server (0 or no minutes = permanent).", "/ban <player> [minutes] [reason]", "ban", (CCSPlayerController? p, CmdContext c) =>
		{
			//IL_0029: Unknown result type (might be due to invalid IL or missing references)
			//IL_0034: Expected Obj, but got Unknown
			if (c.Args.Length == 0)
			{
				Reply(p, "Usage: /ban <player> [minutes] [reason]");
			}
			else
			{
				CCSPlayerController val = FindOne(p, c.Args[0], out var error);
				if ((CEntityInstance)val == (CEntityInstance)null)
				{
					Reply(p, error);
				}
				else if (!CanTarget(p, val))
				{
					Reply(p, "That player has more immunity than you.");
				}
				else
				{
					int minutes = 0;
					int num = 1;
					if (c.Args.Length > 1 && int.TryParse(c.Args[1], out var result))
					{
						minutes = result;
						num = 2;
					}
					FakeBanPlayer(val, p, Rest(c.Args, num), minutes, "css_ban");
				}
			}
		}, (CCSPlayerController p) =>
		{
			PickPlayer(p, "Ban who?", (CCSPlayerController a, CCSPlayerController t) =>
			{
				int slot = t.Slot;
				List<(string, Action<CCSPlayerController>)> items = Config.BanReasons.Select((string r) => ((string, Action<CCSPlayerController>))("Reason: " + r, (CCSPlayerController b) =>
				{
					//IL_003a: Unknown result type (might be due to invalid IL or missing references)
					//IL_0045: Expected Obj, but got Unknown
					CCSPlayerController val = Players().FirstOrDefault((CCSPlayerController x) => x.Slot == slot);
					if ((CEntityInstance)val == (CEntityInstance)null)
					{
						Reply(b, "That player left.");
					}
					else if (!CanTarget(b, val))
					{
						Reply(b, "That player has more immunity than you.");
					}
					else
					{
						FakeBanPlayer(val, b, r, 0, "css_ban");
					}
				})).ToList();
				ShowMenu(a, "Ban " + CleanName(((CBasePlayerController)t).PlayerName), items);
			}, groups: false, null, (CCSPlayerController x) => !x.IsBot);
		}, "banid");
		Add("unban", "Unban a player on this server.", "/unban <steamid64>", "unban", (CCSPlayerController? p, CmdContext c) =>
		{
			if (c.Args.Length != 0 && ulong.TryParse(c.Args[0], out var result))
			{
				UnbanReply(p, result);
			}
			else
			{
				Reply(p, "Usage: /unban <steamid64>");
			}
		}, (CCSPlayerController p) =>
		{
			List<BanRecord> list = _bans.Where((BanRecord b) => b.Expires == 0L || b.Expires > Now()).Take(40).ToList();
			if (list.Count == 0)
			{
				Reply(p, "Nobody is banned on this server.");
			}
			else
			{
				ShowMenu(p, "Unban who?", list.Select((BanRecord b) => ((string, Action<CCSPlayerController>))(b.Name + " (" + b.Reason + ")", (CCSPlayerController a) =>
				{
					if (ulong.TryParse(b.Steam, out var result))
					{
						UnbanReply(a, result);
					}
				})).ToList());
			}
		});
		Add("banlist", "Show the banned players of this server.", "/banlist", "unban", (CCSPlayerController? p, CmdContext c) =>
		{
			List<BanRecord> list = _bans.Where((BanRecord b) => b.Expires == 0L || b.Expires > Now()).ToList();
			if (list.Count == 0)
			{
				Reply(p, "Nobody is banned on this server.");
				return;
			}
			Reply(p, $"{list.Count} banned player(s) - see the console.");
			foreach (BanRecord item3 in list.Take(30))
			{
				Reply(p, $"{item3.Name} | {item3.Steam} | {((item3.Expires == 0L) ? "permanent" : ("until " + DateTimeOffset.FromUnixTimeSeconds(item3.Expires).ToString("yyyy-MM-dd HH:mm") + " UTC"))} | {item3.Reason}");
			}
		}, null);
		Add("addvip", "Add or update a Normal VIP (NexusVIP).", "/addvip [name]&<steamid64> <bronze|silver|gold|platinum|1-4> [days]", "addvip", (CCSPlayerController? p, CmdContext c) =>
		{
			AddVipFromCommand(p, c.Raw);
		});
		Add("vip", "List the Normal VIP players of this server.", "/vip", "vip", (CCSPlayerController? p, CmdContext c) =>
		{
			ListVipPlayers(p);
		});
		Add("votekick", "Start a team vote kick.", "/votekick <player>", "votekick", (CCSPlayerController? p, CmdContext c) =>
		{
			//IL_0001: Unknown result type (might be due to invalid IL or missing references)
			//IL_000c: Expected Obj, but got Unknown
			//IL_0044: Unknown result type (might be due to invalid IL or missing references)
			//IL_004f: Expected Obj, but got Unknown
			if ((CEntityInstance)p == (CEntityInstance)null)
			{
				Reply(p, "Players only.");
			}
			else if (c.Args.Length == 0)
			{
				Reply(p, "Usage: /votekick <player>");
			}
			else
			{
				CCSPlayerController val = FindOne(p, c.Args[0], out var error);
				if ((CEntityInstance)val == (CEntityInstance)null)
				{
					Reply(p, error);
				}
				else
				{
					StartVoteKick(p, val);
				}
			}
		}, (CCSPlayerController p) =>
		{
			PickPlayer(p, "Vote kick who?", (CCSPlayerController a, CCSPlayerController t) =>
			{
				StartVoteKick(a, t);
			}, groups: false, null, (CCSPlayerController x) => !x.IsBot);
		});
		Add("f1", "Vote YES.", "/f1", null, (CCSPlayerController? p, CmdContext c) =>
		{
			CastVote(p, yes: true);
		}, null);
		Add("f2", "Vote NO.", "/f2", null, (CCSPlayerController? p, CmdContext c) =>
		{
			CastVote(p, yes: false);
		}, null);
		Add("admincmd", "Command menu: pick a command to use.", "/admincmd", "admincmd", (CCSPlayerController? p, CmdContext c) =>
		{
			//IL_0001: Unknown result type (might be due to invalid IL or missing references)
			//IL_000c: Expected Obj, but got Unknown
			if ((CEntityInstance)p != (CEntityInstance)null)
			{
				AdminCmdMenu(p);
			}
			else
			{
				ListCommandsConsole();
			}
		}, (CCSPlayerController p) =>
		{
			AdminCmdMenu(p);
		});
		Add("addadmin", "Add an admin.", "/addadmin [player|steamid64]", "addadmin", (CCSPlayerController? p, CmdContext c) =>
		{
			//IL_0025: Unknown result type (might be due to invalid IL or missing references)
			//IL_0030: Expected Obj, but got Unknown
			//IL_00f5: Unknown result type (might be due to invalid IL or missing references)
			//IL_0100: Expected Obj, but got Unknown
			ulong sid;
			if (c.Args.Length == 0 || c.Args[0].Equals("list", StringComparison.OrdinalIgnoreCase))
			{
				if ((CEntityInstance)p != (CEntityInstance)null)
				{
					AddAdminMenu(p);
				}
			}
			else if (ulong.TryParse(c.Args[0], out sid) && sid > 70000000000000000L && Players().All((CCSPlayerController x) => ((CBasePlayerController)x).SteamID != sid))
			{
				string identity = sid.ToString();
				string name;
				if (c.Args.Length <= 1)
				{
					string text = sid.ToString();
					int length = text.Length;
					int num = length - 4;
					name = "Admin_" + text.Substring(num, length - num);
				}
				else
				{
					name = Rest(c.Args, 1);
				}
				AddAdmin(p, identity, name);
			}
			else
			{
				CCSPlayerController val = FindOne(p, c.Args[0], out var error);
				if ((CEntityInstance)val == (CEntityInstance)null)
				{
					Reply(p, error);
				}
				else
				{
					AddAdmin(p, ((CBasePlayerController)val).SteamID.ToString(), CleanName(((CBasePlayerController)val).PlayerName));
				}
			}
		}, (CCSPlayerController p) =>
		{
			AddAdminMenu(p);
		});
		Add("adminsp", "Manage admins: enable, tag, permissions.", "/adminsp", "adminsp", (CCSPlayerController? p, CmdContext c) =>
		{
			//IL_0001: Unknown result type (might be due to invalid IL or missing references)
			//IL_000c: Expected Obj, but got Unknown
			if ((CEntityInstance)p != (CEntityInstance)null)
			{
				AdminListMenu(p);
			}
			else
			{
				Reply(p, "Players only.");
			}
		}, (CCSPlayerController p) =>
		{
			AdminListMenu(p);
		});
		Add("cmds", "List the commands you can use.", "/cmds", null, (CCSPlayerController? p, CmdContext c) =>
		{
			//IL_0001: Unknown result type (might be due to invalid IL or missing references)
			//IL_000c: Expected Obj, but got Unknown
			if ((CEntityInstance)p != (CEntityInstance)null)
			{
				AdminCmdMenu(p);
			}
			else
			{
				ListCommandsConsole();
			}
		}, null);
		void UnbanReply(CCSPlayerController? p, ulong sid)
		{
			Reply(p, RemoveBan(sid) ? $"Unbanned {sid} on this server." : "That SteamID is not banned on this server.");
		}
	}

	private void AddToggle(string name, string label, string perm, Action<int> apply, string on, string off)
	{
		Add(name, label + " on/off.", "/" + name + " <1|0>", perm, (CCSPlayerController? p, CmdContext c) =>
		{
			int? num = ((c.Alias == on) ? new int?(1) : ((c.Alias == off) ? new int?(0) : ((c.Args.Length != 0 && (c.Args[0] == "1" || c.Args[0] == "0")) ? new int?(int.Parse(c.Args[0])) : ((int?)null))));
			if (!num.HasValue)
			{
				Reply(p, "Usage: /" + name + " <1|0>");
			}
			else
			{
				Set(p, num.Value);
			}
		}, (CCSPlayerController p) =>
		{
			ShowMenu(p, label, new List<(string, Action<CCSPlayerController>)>
			{
				("Enable", (CCSPlayerController a) =>
				{
					Set(a, 1);
				}),
				("Disable", (CCSPlayerController a) =>
				{
					Set(a, 0);
				})
			});
		}, on, off);
		void Set(CCSPlayerController? p, int v)
		{
			apply(v);
			Announce(label + " " + ((v == 1) ? "enabled" : "disabled") + ".");
		}
	}

	private void AddMode(string name, string key, params string[] aliases)
	{
		Add(name, "Switch to " + name + ".", "/" + name, name, (CCSPlayerController? p, CmdContext c) =>
		{
			ApplyMode(key);
		}, null, aliases);
	}

	private void AddPlayerAction(string name, string label, string usage, string perm, Action<CCSPlayerController?, CCSPlayerController, CmdContext> run, bool groups, string[]? aliases = null, Action<CCSPlayerController?, CCSPlayerController>? menu = null, string? announceDone = null, bool noImmunity = false, Func<CCSPlayerController, bool>? filter = null, bool allowSelfOnly = false)
	{
		Add(name, label, usage, perm, (CCSPlayerController? p, CmdContext c) =>
		{
			//IL_014d: Unknown result type (might be due to invalid IL or missing references)
			//IL_0158: Expected Obj, but got Unknown
			if (c.Args.Length == 0)
			{
				Reply(p, "Usage: " + usage);
			}
			else
			{
				List<CCSPlayerController> list = FindPlayers(p, c.Args[0], groups, out var error);
				if (list.Count == 0)
				{
					Reply(p, error);
				}
				else
				{
					int num = 0;
					foreach (CCSPlayerController item in list)
					{
						if (!noImmunity && !CanTarget(p, item))
						{
							Reply(p, CleanName(((CBasePlayerController)item).PlayerName) + " has more immunity than you.");
						}
						else
						{
							run(p, item, c);
							num++;
						}
					}
					if (announceDone != null && num > 0)
					{
						Announce($"{((num == 1) ? CleanName(((CBasePlayerController)list[0]).PlayerName) : (num + " players"))} {announceDone} by {(((CEntityInstance)p == (CEntityInstance)null) ? "Console" : CleanName(((CBasePlayerController)p).PlayerName))}.");
					}
				}
			}
		}, (CCSPlayerController p) =>
		{
			PickPlayer(p, label.TrimEnd('.'), Do, groups, groups ? ((Action<CCSPlayerController, string>)((CCSPlayerController a, string g) =>
			{
				List<CCSPlayerController> list = FindPlayers(a, g, allowGroups: true, out var _);
				int num = 0;
				foreach (CCSPlayerController item2 in list)
				{
					if (noImmunity || CanTarget(a, item2))
					{
						run(a, item2, new CmdContext());
						num++;
					}
				}
				if (announceDone != null && num > 0)
				{
					Announce($"{num} players {announceDone} by {CleanName(((CBasePlayerController)a).PlayerName)}.");
				}
			})) : null, filter);
		}, aliases ?? Array.Empty<string>());
		void Do(CCSPlayerController a, CCSPlayerController t)
		{
			if (!noImmunity && !CanTarget(a, t))
			{
				Reply(a, "That player has more immunity than you.");
			}
			else
			{
				if (menu != null)
				{
					menu(a, t);
				}
				else
				{
					run(a, t, new CmdContext());
				}
				if (announceDone != null)
				{
					Announce($"{CleanName(((CBasePlayerController)t).PlayerName)} {announceDone} by {CleanName(((CBasePlayerController)a).PlayerName)}.");
				}
			}
		}
	}

	private void CenterAll(string text)
	{
		foreach (CCSPlayerController item in Humans())
		{
			item.PrintToCenter(text);
		}
	}

	private void ChangeMap(CCSPlayerController? p, string map)
	{
		if (!MapRx.IsMatch(map))
		{
			Reply(p, "Invalid map name.");
			return;
		}
		if (!Server.IsMapValid(map))
		{
			Reply(p, "Map is not valid.");
			return;
		}
		Announce($"Changing map to {ChatColors.Green}{map}{ChatColors.White}…");
		((BasePlugin)this).AddTimer(1.5f, (Action)(() =>
		{
			Exec("changelevel " + map);
		}), null);
	}

	private void WorkshopMap(CCSPlayerController? p, string id)
	{
		id = id.Trim();
		Match match = Regex.Match(id, "id=(\\d+)");
		if (match.Success)
		{
			id = match.Groups[1].Value;
		}
		if (!Regex.IsMatch(id, "^\\d{5,15}$"))
		{
			Reply(p, "Give the numeric workshop id (or the workshop link).");
			return;
		}
		Announce($"Changing to workshop map {ChatColors.Green}{id}{ChatColors.White}…");
		((BasePlugin)this).AddTimer(1.5f, (Action)(() =>
		{
			Exec("host_workshop_map " + id);
		}), null);
	}

	private void ApplyMode(string key)
	{
		if (!Config.Modes.TryGetValue(key, out var value))
		{
			Announce("Mode '" + key + "' is not configured.");
			return;
		}
		foreach (string command in value.Commands)
		{
			if (!string.IsNullOrWhiteSpace(command))
			{
				string text = command.Trim();
				string text2 = text.ToLowerInvariant();
				if (!text2.StartsWith("game_type") && !text2.StartsWith("game_mode") && !text2.StartsWith("changelevel") && !text2.StartsWith("map ") && !text2.StartsWith("host_workshop_map") && !text2.StartsWith("quit") && !text2.StartsWith("_restart") && !(text2 == "restart"))
				{
					Exec(text);
				}
			}
		}
		if (!string.IsNullOrWhiteSpace(value.Exec) && Regex.IsMatch(value.Exec, "^[A-Za-z0-9_\\-./]+$") && !value.Exec.Contains(".."))
		{
			string text3 = value.Exec.ToLowerInvariant();
			if (!text3.Contains("game_type") && !text3.Contains("game_mode") && !text3.Contains("changelevel"))
			{
				Exec("exec " + value.Exec);
			}
		}
		Announce($"Mode: {ChatColors.Green}{(string.IsNullOrWhiteSpace(value.Label) ? key : value.Label)}{ChatColors.White} {ChatColors.Grey}(script · Competitive kept){ChatColors.White}.");
		if (value.Restart || value.ChangeLevel)
		{
			Exec("mp_restartgame 1");
		}
	}

	private void ResetScore(CCSPlayerController p)
	{
		//IL_005e: Unknown result type (might be due to invalid IL or missing references)
		//IL_0073: Expected Obj, but got Unknown
		//IL_0040: Unknown result type (might be due to invalid IL or missing references)
		//IL_0055: Expected Obj, but got Unknown
		try
		{
			CCSPlayerController_ActionTrackingServices actionTrackingServices = p.ActionTrackingServices;
			CSMatchStats_t val = ((actionTrackingServices != null) ? actionTrackingServices.MatchStats : null);
			if (val != null)
			{
				((CSPerRoundStats_t)val).Kills = 0;
				((CSPerRoundStats_t)val).Deaths = 0;
				((CSPerRoundStats_t)val).Assists = 0;
				((CSPerRoundStats_t)val).Damage = 0;
				((CSPerRoundStats_t)val).HeadShotKills = 0;
				Utilities.SetStateChanged((CBaseEntity)p, "CCSPlayerController_ActionTrackingServices", "m_matchStats", 0);
			}
			p.Score = 0;
			Utilities.SetStateChanged((CBaseEntity)p, "CCSPlayerController", "m_iScore", 0);
		}
		catch (Exception ex)
		{
			LoggerExtensions.LogWarning(((BasePlugin)this).Logger, "Reset score failed: {M}", new object[1] { ex.Message });
		}
	}

	private void Slay(CCSPlayerController t)
	{
		if (t.PawnIsAlive)
		{
			t.CommitSuicide(false, true);
		}
	}

	private void Slap(CCSPlayerController t, int damage)
	{
		//IL_000d: Unknown result type (might be due to invalid IL or missing references)
		//IL_0018: Expected Obj, but got Unknown
		//IL_009a: Unknown result type (might be due to invalid IL or missing references)
		//IL_00af: Expected Obj, but got Unknown
		CCSPlayerPawn value = t.PlayerPawn.Value;
		if ((CEntityInstance)value == (CEntityInstance)null || !t.PawnIsAlive)
		{
			return;
		}
		Vector absVelocity = ((CBaseEntity)value).AbsVelocity;
		absVelocity.X += Rng.Next(-250, 250);
		absVelocity.Y += Rng.Next(-250, 250);
		absVelocity.Z += 280f;
		if (damage > 0)
		{
			int num = ((CBaseEntity)value).Health - damage;
			if (num <= 0)
			{
				t.CommitSuicide(false, true);
				return;
			}
			((CBaseEntity)value).Health = num;
			Utilities.SetStateChanged((CBaseEntity)value, "CBaseEntity", "m_iHealth", 0);
		}
	}

	private static CsTeam? ParseTeam(string s)
	{
		string text = (s ?? "").Trim().ToLowerInvariant();
		if (text != null)
		{
			switch (text.Length)
			{
			case 1:
				switch (text[0])
				{
				case '2':
				case 't':
					break;
				case '3':
					goto IL_00fd;
				case '1':
				case 's':
					goto IL_0104;
				default:
					goto end_IL_0025;
				}
				goto IL_00f6;
			case 9:
			{
				char c = text[0];
				if (c != 's')
				{
					if (c != 't' || !(text == "terrorist"))
					{
						break;
					}
					goto IL_00f6;
				}
				if (!(text == "spectator"))
				{
					break;
				}
				goto IL_0104;
			}
			case 2:
				if (!(text == "ct"))
				{
					break;
				}
				goto IL_00fd;
			case 16:
				if (!(text == "counterterrorist"))
				{
					break;
				}
				goto IL_00fd;
			case 17:
				if (!(text == "counter-terrorist"))
				{
					break;
				}
				goto IL_00fd;
			case 4:
				{
					if (!(text == "spec"))
					{
						break;
					}
					goto IL_0104;
				}
				IL_0104:
				return (CsTeam)1;
				IL_00f6:
				return (CsTeam)2;
				IL_00fd:
				return (CsTeam)3;
				end_IL_0025:
				break;
			}
		}
		return null;
	}

	private static string TeamName(CsTeam t)
	{
		//IL_0000: Unknown result type (might be due to invalid IL or missing references)
		//IL_0002: Invalid comparison between Unknown and I4
		//IL_0004: Unknown result type (might be due to invalid IL or missing references)
		//IL_0006: Invalid comparison between Unknown and I4
		if ((int)t != 2)
		{
			if ((int)t == 3)
			{
				return "CT";
			}
			return "Spectators";
		}
		return "T";
	}

	private void MovePlayer(CCSPlayerController t, CsTeam team)
	{
		//IL_0000: Unknown result type (might be due to invalid IL or missing references)
		//IL_0002: Invalid comparison between Unknown and I4
		//IL_000d: Unknown result type (might be due to invalid IL or missing references)
		if ((int)team == 1)
		{
			t.ChangeTeam((CsTeam)1);
		}
		else
		{
			t.SwitchTeam(team);
		}
	}

	private void MoveTeamMenu(CCSPlayerController admin, int slot, int unused, bool group, string g = "")
	{
		ShowMenu(admin, "Move to which team?", new List<(string, Action<CCSPlayerController>)>
		{
			("Terrorists", (CCSPlayerController a) =>
			{
				Go(a, (CsTeam)2);
			}),
			("Counter-Terrorists", (CCSPlayerController a) =>
			{
				Go(a, (CsTeam)3);
			}),
			("Spectators", (CCSPlayerController a) =>
			{
				Go(a, (CsTeam)1);
			})
		});
		void Go(CCSPlayerController a, CsTeam team)
		{
			//IL_0093: Unknown result type (might be due to invalid IL or missing references)
			//IL_00ed: Unknown result type (might be due to invalid IL or missing references)
			List<CCSPlayerController> list = (group ? FindPlayers(a, g, allowGroups: true, out var _) : (from x in Players()
				where x.Slot == slot
				select x).ToList());
			foreach (CCSPlayerController item in list.Where((CCSPlayerController x) => CanTarget(a, x)))
			{
				MovePlayer(item, team);
			}
			Announce(((list.Count == 1) ? CleanName(((CBasePlayerController)list[0]).PlayerName) : (list.Count + " players")) + " moved to " + TeamName(team) + ".");
		}
	}

	private void RenamePlayer(CCSPlayerController? admin, CCSPlayerController t, string name)
	{
		name = CleanName(name);
		if (name.Length == 0 || name.Length > 28)
		{
			Reply(admin, "The name must have 1-28 characters.");
			return;
		}
		if (!CanTarget(admin, t))
		{
			Reply(admin, "That player has more immunity than you.");
			return;
		}
		string text = CleanName(((CBasePlayerController)t).PlayerName);
		SetName(t, name);
		ApplyTag(t);
		Announce(text + " was renamed to " + name + ".");
	}

	private void SpectatePlayer(CCSPlayerController? admin, CCSPlayerController target)
	{
		//IL_001a: Unknown result type (might be due to invalid IL or missing references)
		//IL_0025: Expected Obj, but got Unknown
		if ((CEntityInstance)admin == (CEntityInstance)null)
		{
			Reply(admin, "Players only.");
			return;
		}
		if (((CBaseEntity)admin).TeamNum != 1)
		{
			admin.ChangeTeam((CsTeam)1);
		}
		_ = target.UserId;
		((BasePlugin)this).AddTimer(0.4f, (Action)(() =>
		{
			if (((CEntityInstance)admin).IsValid && ((CEntityInstance)target).IsValid)
			{
				admin.ExecuteClientCommand($"spec_player_by_accountid {((CBasePlayerController)target).SteamID & 0xFFFFFFFFu}");
			}
		}), null);
		Reply(admin, "Spectating " + CleanName(((CBasePlayerController)target).PlayerName) + ".");
	}

	private void CashCmd(CCSPlayerController? p, CmdContext c, bool add)
	{
		if (c.Args.Length < 2 || !int.TryParse(c.Args[1], out var result))
		{
			Reply(p, "Usage: /" + (add ? "addcash" : "cash") + " <player|@group> <amount>");
			return;
		}
		List<CCSPlayerController> list = FindPlayers(p, c.Args[0], allowGroups: true, out var error);
		if (list.Count == 0)
		{
			Reply(p, error);
			return;
		}
		foreach (CCSPlayerController item in list)
		{
			SetCash(item, result, add);
		}
		Reply(p, $"{(add ? "Gave" : "Set")} {result} cash {(add ? "to" : "for")} {((list.Count == 1) ? CleanName(((CBasePlayerController)list[0]).PlayerName) : (list.Count + " players"))}.");
	}

	private void SetCash(CCSPlayerController t, int amount, bool add)
	{
		//IL_002c: Unknown result type (might be due to invalid IL or missing references)
		//IL_0041: Expected Obj, but got Unknown
		CCSPlayerController_InGameMoneyServices inGameMoneyServices = t.InGameMoneyServices;
		if (inGameMoneyServices != null)
		{
			inGameMoneyServices.Account = Math.Clamp(add ? (inGameMoneyServices.Account + amount) : amount, 0, 65535);
			Utilities.SetStateChanged((CBaseEntity)t, "CCSPlayerController_InGameMoneyServices", "m_iAccount", 0);
		}
	}

	private void CashMenu(CCSPlayerController admin, bool add)
	{
		PickPlayer(admin, add ? "Add cash to?" : "Set cash for?", (CCSPlayerController a, CCSPlayerController t) =>
		{
			int slot = t.Slot;
			Amounts(a, () => (from x in Players()
				where x.Slot == slot
				select x).ToList());
		}, groups: true, (CCSPlayerController a, string g) =>
		{
			Amounts(a, () => FindPlayers(a, g, allowGroups: true, out var _));
		});
		void Amounts(CCSPlayerController a, Func<List<CCSPlayerController>> targets)
		{
			List<(string, Action<CCSPlayerController>)> list = Config.CashMenu.Select((int n) => ((string, Action<CCSPlayerController>))($"${n}", (CCSPlayerController b) =>
			{
				List<CCSPlayerController> list2 = targets();
				foreach (CCSPlayerController item in list2)
				{
					SetCash(item, n, add);
				}
				Reply(b, $"{(add ? "Gave" : "Set")} ${n} {(add ? "to" : "for")} {list2.Count} player(s).");
			})).ToList();
			list.Add(("✎ Other amount…", (CCSPlayerController b) =>
			{
				Prompt(b, "Type the amount:", (CCSPlayerController pl, string txt) =>
				{
					if (!int.TryParse(txt, out var result) || result < 0)
					{
						Reply(pl, "Invalid amount.");
					}
					else
					{
						List<CCSPlayerController> list2 = targets();
						foreach (CCSPlayerController item2 in list2)
						{
							SetCash(item2, result, add);
						}
						Reply(pl, $"Done for {list2.Count} player(s).");
					}
				});
			}));
			ShowMenu(a, add ? "Add cash" : "Set cash", list);
		}
	}

	private void GiveCategoryMenu(CCSPlayerController admin, List<int> slots)
	{
		List<(string, Action<CCSPlayerController>)> list = WeaponCats.Select(((string cat, string[] items) wc) => ((string cat, Action<CCSPlayerController>))(cat: wc.cat, (CCSPlayerController a) =>
		{
			ShowMenu(a, wc.cat, wc.items.Select((string w) => ((string w, Action<CCSPlayerController>))(w: w, (CCSPlayerController b) =>
			{
				GiveItem(b, (from x in Players()
					where slots.Contains(x.Slot)
					select x).ToList(), w);
			})).ToList());
		})).ToList();
		list.Add(("Armor + helmet", (CCSPlayerController a) =>
		{
			GiveItem(a, (from x in Players()
				where slots.Contains(x.Slot)
				select x).ToList(), "item_assaultsuit");
		}));
		ShowMenu(admin, "Give what?", list);
	}

	private void GiveItem(CCSPlayerController? admin, List<CCSPlayerController> targets, string item)
	{
		item = item.ToLowerInvariant();
		if (!item.StartsWith("weapon_") && !item.StartsWith("item_"))
		{
			item = "weapon_" + item;
		}
		if (!Regex.IsMatch(item, "^(weapon|item)_[a-z0-9_]+$"))
		{
			Reply(admin, "Invalid item name.");
			return;
		}
		int num = 0;
		foreach (CCSPlayerController item2 in targets.Where((CCSPlayerController x) => x.PawnIsAlive))
		{
			item2.GiveNamedItem(item);
			num++;
		}
		Reply(admin, (num == 0) ? "Nobody alive to give it to." : $"Gave {item} to {num} player(s).");
	}

	private void BotCmd(CCSPlayerController? p, string what)
	{
		switch (what.ToLowerInvariant())
		{
		case "ct":
			Exec("bot_add_ct");
			break;
		case "t":
			Exec("bot_add_t");
			break;
		case "kick":
			Exec("bot_kick");
			break;
		case "freeze":
		case "stop":
			Exec("bot_stop 1");
			break;
		case "go":
			Exec("bot_stop 0");
			break;
		default:
			Reply(p, "Usage: /bot [ct|t|kick|freeze|go]");
			return;
		}
		Reply(p, "Bot command sent: " + what);
	}

	private void StartMatch()
	{
		_warmupPaused = false;
		Exec("mp_warmup_pausetimer 0");
		if (_knifeEnabled)
		{
			StartKnifeRound();
			return;
		}
		Exec("mp_warmup_end");
		Exec("mp_restartgame 1");
		Announce("Match started. Good luck!");
	}

	private void StartKnifeRound()
	{
		if (_savedCvars.Count > 0)
		{
			RestoreKnifeCvars();
		}
		string[] knifeCvars = KnifeCvars;
		foreach (string text in knifeCvars)
		{
			_savedCvars[text] = CvarString(text);
		}
		Exec("mp_buytime 0");
		Exec("mp_startmoney 0");
		Exec("mp_maxmoney 0");
		_knifeRunning = true;
		_knifeAwaitTeam = 0;
		Exec("mp_warmup_end");
		Exec("mp_restartgame 1");
		Announce("KNIFE ROUND! The winners choose the side.");
	}

	private HookResult OnRoundStart(EventRoundStart e, GameEventInfo i)
	{
		if (_knifeRunning && _knifeAwaitTeam == 0)
		{
			((BasePlugin)this).AddTimer(0.6f, (Action)(() =>
			{
				foreach (CCSPlayerController item in from x in Players()
					where x.PawnIsAlive
					select x)
				{
					item.RemoveWeapons();
					item.GiveNamedItem("weapon_knife");
				}
			}), null);
		}
		return (HookResult)0;
	}

	private HookResult OnRoundEnd(EventRoundEnd e, GameEventInfo i)
	{
		if (_knifeRunning && _knifeAwaitTeam == 0)
		{
			int winner = e.Winner;
			if (winner != 2 && winner != 3)
			{
				return (HookResult)0;
			}
			_knifeAwaitTeam = winner;
			Announce($"{ChatColors.Green}{((winner == 2) ? "Terrorists" : "Counter-Terrorists")}{ChatColors.White} won the knife round. Winners: type {ChatColors.Green}!stay{ChatColors.White} or {ChatColors.Green}!switch{ChatColors.White} ({Config.KnifeRoundChoiceSeconds}s).");
			int team = winner;
			((BasePlugin)this).AddTimer((float)Config.KnifeRoundChoiceSeconds, (Action)(() =>
			{
				if (_knifeRunning && _knifeAwaitTeam == team)
				{
					FinishKnife(swap: false);
				}
			}), null);
			return (HookResult)0;
		}
		return (HookResult)0;
	}

	private void KnifeDecision(CCSPlayerController? p, bool swap)
	{
		//IL_001e: Unknown result type (might be due to invalid IL or missing references)
		//IL_0029: Expected Obj, but got Unknown
		if (!_knifeRunning || _knifeAwaitTeam == 0)
		{
			Reply(p, "There is no knife round decision to make.");
		}
		else if ((CEntityInstance)p != (CEntityInstance)null && ((CBaseEntity)p).TeamNum != _knifeAwaitTeam && !HasPerm(p, "start"))
		{
			Reply(p, "Only the winning team decides.");
		}
		else
		{
			FinishKnife(swap);
		}
	}

	private void FinishKnife(bool swap)
	{
		_knifeRunning = false;
		_knifeAwaitTeam = 0;
		RestoreKnifeCvars();
		if (swap)
		{
			Exec("mp_swapteams");
		}
		((BasePlugin)this).AddTimer(1f, (Action)(() =>
		{
			Exec("mp_restartgame 1");
		}), null);
		Announce(swap ? "Sides switched. The match is LIVE in a moment!" : "Sides kept. The match is LIVE in a moment!");
	}

	private void PauseRequest(CCSPlayerController? p, bool pause)
	{
		//IL_0001: Unknown result type (might be due to invalid IL or missing references)
		//IL_000c: Expected Obj, but got Unknown
		if ((CEntityInstance)p == (CEntityInstance)null)
		{
			Exec(pause ? "mp_pause_match" : "mp_unpause_match");
			return;
		}
		byte teamNum = ((CBaseEntity)p).TeamNum;
		if (teamNum != 2 && teamNum != 3)
		{
			Reply(p, "Only players in a team can do that.");
			return;
		}
		HashSet<int> hashSet = (pause ? _pauseReq : _unpauseReq);
		hashSet.Add(teamNum);
		if (hashSet.Count >= 2)
		{
			Exec(pause ? "mp_pause_match" : "mp_unpause_match");
			_pauseReq.Clear();
			_unpauseReq.Clear();
			Announce(pause ? "Match PAUSED (both teams agreed)." : "Match RESUMED (both teams agreed).");
		}
		else
		{
			Announce($"{((teamNum == 2) ? "T" : "CT")} asked to {(pause ? "pause" : "continue")}. The other team must type !{(pause ? "pause" : "unpause")} too.");
		}
	}

	private void StartVoteKick(CCSPlayerController starter, CCSPlayerController t)
	{
		VoteState vote = _vote;
		if (vote != null && !vote.Finished)
		{
			Reply(starter, "A vote is already active.");
			return;
		}
		if (((CBaseEntity)t).TeamNum != 2 && ((CBaseEntity)t).TeamNum != 3)
		{
			Reply(starter, "Target must be on T or CT.");
			return;
		}
		if (!CanTarget(starter, t))
		{
			Reply(starter, "That player has more immunity than you.");
			return;
		}
		VoteState v = new VoteState
		{
			TargetSteam = ((CBasePlayerController)t).SteamID,
			TargetName = CleanName(((CBasePlayerController)t).PlayerName),
			Team = ((CBaseEntity)t).TeamNum
		};
		foreach (CCSPlayerController item in from x in Humans()
			where ((CBaseEntity)x).TeamNum == v.Team && ((CBasePlayerController)x).SteamID != v.TargetSteam
			select x)
		{
			v.Eligible.Add(((CBasePlayerController)item).SteamID);
		}
		if (v.Eligible.Count == 0)
		{
			Reply(starter, "There are no eligible teammates to vote.");
			return;
		}
		_vote = v;
		Announce($"Vote to kick {ChatColors.Green}{v.TargetName}{ChatColors.White} started.");
		foreach (CCSPlayerController item2 in from x in Humans()
			where v.Eligible.Contains(((CBasePlayerController)x).SteamID)
			select x)
		{
			item2.PrintToChat($" {ChatColors.Red}[VoteKick] {ChatColors.White}Same-team players: {ChatColors.Green}!f1 YES {ChatColors.White}| {ChatColors.Red}!f2 NO");
		}
		((BasePlugin)this).AddTimer((float)Config.VoteKickSeconds, (Action)(() =>
		{
			if (_vote == v && !v.Finished)
			{
				v.Finished = true;
				Announce("Vote kick expired.");
			}
		}), null);
	}

	private void CastVote(CCSPlayerController? p, bool yes)
	{
		//IL_0007: Unknown result type (might be due to invalid IL or missing references)
		//IL_0012: Expected Obj, but got Unknown
		//IL_013b: Unknown result type (might be due to invalid IL or missing references)
		//IL_0146: Expected Obj, but got Unknown
		if ((CEntityInstance)p == (CEntityInstance)null)
		{
			return;
		}
		VoteState v = _vote;
		if (v == null || v.Finished)
		{
			Reply(p, "There is no active vote.");
		}
		else if (!v.Eligible.Contains(((CBasePlayerController)p).SteamID))
		{
			Reply(p, "You are not eligible to vote.");
		}
		else if (v.Yes.Contains(((CBasePlayerController)p).SteamID) || v.No.Contains(((CBasePlayerController)p).SteamID))
		{
			Reply(p, "You already voted.");
		}
		else if (yes)
		{
			v.Yes.Add(((CBasePlayerController)p).SteamID);
			Reply(p, "Your vote: YES.");
			if (v.Yes.Count >= v.Eligible.Count)
			{
				v.Finished = true;
				Announce("Vote passed. " + v.TargetName + " was kicked.");
				CCSPlayerController val = Players().FirstOrDefault((CCSPlayerController x) => ((CBasePlayerController)x).SteamID == v.TargetSteam);
				if ((CEntityInstance)val != (CEntityInstance)null)
				{
					val.Disconnect((NetworkDisconnectionReason)39);
				}
			}
		}
		else
		{
			v.No.Add(((CBasePlayerController)p).SteamID);
			Reply(p, "Your vote: NO.");
			v.Finished = true;
			Announce("Vote failed because a player voted NO.");
		}
	}

	private void KickPlayer(CCSPlayerController? admin, CCSPlayerController t, string reason)
	{
		//IL_0025: Unknown result type (might be due to invalid IL or missing references)
		//IL_0030: Expected Obj, but got Unknown
		string text = CleanName(((CBasePlayerController)t).PlayerName);
		Announce(text + " was kicked by " + (((CEntityInstance)admin == (CEntityInstance)null) ? "Console" : CleanName(((CBasePlayerController)admin).PlayerName)) + ((reason.Length > 0) ? (". Reason: " + reason) : "."));
		Server.NextFrame((Action)(() =>
		{
			if (((CEntityInstance)t).IsValid)
			{
				t.Disconnect((NetworkDisconnectionReason)39);
			}
		}));
	}

	public void OnConfigParsed(ServerCommandsConfig config)
	{
		//IL_001e: Unknown result type (might be due to invalid IL or missing references)
		Config = config;
		if (!Enum.TryParse<NetworkDisconnectionReason>(config.BanDisconnectReason, true, out _banReason))
		{
			_banReason = (NetworkDisconnectionReason)40;
		}
	}

	public override void Load(bool hotReload)
	{
		//IL_00db: Unknown result type (might be due to invalid IL or missing references)
		//IL_00e6: Expected Obj, but got Unknown
		//IL_00f3: Unknown result type (might be due to invalid IL or missing references)
		//IL_00fe: Expected Obj, but got Unknown
		//IL_010b: Unknown result type (might be due to invalid IL or missing references)
		//IL_0116: Expected Obj, but got Unknown
		//IL_01a7: Unknown result type (might be due to invalid IL or missing references)
		//IL_01b1: Expected Obj, but got Unknown
		//IL_0130: Unknown result type (might be due to invalid IL or missing references)
		//IL_013b: Expected Obj, but got Unknown
		//IL_0148: Unknown result type (might be due to invalid IL or missing references)
		//IL_0153: Expected Obj, but got Unknown
		//IL_0094: Unknown result type (might be due to invalid IL or missing references)
		//IL_009e: Expected Obj, but got Unknown
		BuildCommands();
		foreach (Cmd cmd2 in _cmds)
		{
			foreach (string item in new string[1] { cmd2.Name }.Concat(cmd2.Aliases))
			{
				_byName[item] = cmd2;
				Cmd cmd = cmd2;
				string alias = item;
				((BasePlugin)this).AddCommand("css_" + item, cmd.Label, (CommandInfo.CommandCallback)((CCSPlayerController? p, CommandInfo info) =>
				{
					Dispatch(cmd, alias, p, info);
				}));
			}
		}
		((BasePlugin)this).AddCommandListener("say", (CommandInfo.CommandListenerCallback)OnSay, (HookMode)0);
		((BasePlugin)this).AddCommandListener("say_team", (CommandInfo.CommandListenerCallback)OnSay, (HookMode)0);
		((BasePlugin)this).AddCommandListener("jointeam", (CommandInfo.CommandListenerCallback)OnJoinTeam, (HookMode)0);
		if (Config.InterceptEngineBanCommands)
		{
			((BasePlugin)this).AddCommandListener("ban", (CommandInfo.CommandListenerCallback)OnEngineBan, (HookMode)0);
			((BasePlugin)this).AddCommandListener("banid", (CommandInfo.CommandListenerCallback)OnEngineBan, (HookMode)0);
		}
		((BasePlugin)this).RegisterEventHandler<EventPlayerConnectFull>((GameEventHandler<EventPlayerConnectFull>)OnConnectFull, (HookMode)1);
		((BasePlugin)this).RegisterEventHandler<EventPlayerDisconnect>((GameEventHandler<EventPlayerDisconnect>)OnDisconnect, (HookMode)1);
		((BasePlugin)this).RegisterEventHandler<EventRoundStart>((GameEventHandler<EventRoundStart>)OnRoundStart, (HookMode)1);
		((BasePlugin)this).RegisterEventHandler<EventRoundEnd>((GameEventHandler<EventRoundEnd>)OnRoundEnd, (HookMode)1);
		((BasePlugin)this).RegisterListener<Listeners.OnMapStart>((Listeners.OnMapStart)((string _) =>
		{
			ApplyBanRules();
			ResetMatchState();
		}));
		EnsureMetadataFile();
		EnsureOwners();
		LoadPunishments();
		LoadBans();
		ApplyBanRules();
		_tagTimer = ((BasePlugin)this).AddTimer(3f, (Action)ApplyAllTags, (TimerFlags)1);
		_sweepTimer = ((BasePlugin)this).AddTimer(15f, (Action)SweepPunishments, (TimerFlags)1);
		if (Config.ClearEngineBansEverySeconds > 0)
		{
			_clearBansTimer = ((BasePlugin)this).AddTimer((float)Config.ClearEngineBansEverySeconds, (Action)ClearEngineBans, (TimerFlags)1);
		}
		LoggerExtensions.LogInformation(((BasePlugin)this).Logger, "ServerCommands {V} loaded: {N} commands, admin files in {D}", new object[3]
		{
			((BasePlugin)this).ModuleVersion,
			_cmds.Count,
			AdminDir()
		});
	}

	public override void Unload(bool hotReload)
	{
		Timer tagTimer = _tagTimer;
		if (tagTimer != null)
		{
			tagTimer.Kill();
		}
		Timer sweepTimer = _sweepTimer;
		if (sweepTimer != null)
		{
			sweepTimer.Kill();
		}
		Timer clearBansTimer = _clearBansTimer;
		if (clearBansTimer != null)
		{
			clearBansTimer.Kill();
		}
	}

	private void Dispatch(Cmd c, string alias, CCSPlayerController? p, CommandInfo info)
	{
		//IL_0001: Unknown result type (might be due to invalid IL or missing references)
		//IL_000c: Expected Obj, but got Unknown
		//IL_007c: Unknown result type (might be due to invalid IL or missing references)
		//IL_0087: Expected Obj, but got Unknown
		try
		{
			if ((CEntityInstance)p != (CEntityInstance)null && !((CEntityInstance)p).IsValid)
			{
				return;
			}
			if (c.Perm != null && !HasPerm(p, c.Perm))
			{
				Reply(p, "You do not have permission.");
				return;
			}
			string[] array = new string[Math.Max(0, info.ArgCount - 1)];
			for (int i = 1; i < info.ArgCount; i++)
			{
				array[i - 1] = info.GetArg(i);
			}
			if (array.Length == 0 && (CEntityInstance)p != (CEntityInstance)null && c.Menu != null)
			{
				c.Menu(p);
				return;
			}
			c.Run(p, new CmdContext
			{
				Args = array,
				Alias = alias.ToLowerInvariant(),
				Raw = info.ArgString
			});
		}
		catch (Exception ex)
		{
			LoggerExtensions.LogError(((BasePlugin)this).Logger, ex, "Command {C} failed", new object[1] { c.Name });
			Reply(p, "The command failed: " + ex.Message);
		}
	}

	private static readonly Regex VipAddPattern = new Regex(@"^\s*(?:(?<name>[^&]*?)\s*&\s*)?(?<steam>\d{17})\s+(?<level>\S+)(?:\s+(?<days>\d{1,5}))?\s*$", RegexOptions.Compiled, TimeSpan.FromMilliseconds(200));

	private static readonly string[] VipLevelNames = new string[4] { "bronze", "silver", "gold", "platinum" };

	private static readonly Regex VipSteamPattern = new Regex("^7656119\\d{10}$", RegexOptions.Compiled);

	// Admins with the "addvip" permission can grant any level (owners too). NexusVIP does the actual write.
	private void AddVipFromCommand(CCSPlayerController? p, string raw)
	{
		if (p == null || !p.IsValid)
		{
			Reply(p, "Use this command in-game (players only).");
			return;
		}
		Match m = VipAddPattern.Match(raw ?? "");
		if (!m.Success)
		{
			Reply(p, "Usage: /addvip [name]&<steamid64> <bronze|silver|gold|platinum|1-4> [days]");
			return;
		}
		string steam = m.Groups["steam"].Value;
		if (!VipSteamPattern.IsMatch(steam))
		{
			Reply(p, "Invalid SteamID64.");
			return;
		}
		int level = ParseVipLevel(m.Groups["level"].Value);
		if (level == 0)
		{
			Reply(p, "Invalid level. Use bronze, silver, gold, platinum or 1-4.");
			return;
		}
		int days = m.Groups["days"].Success ? int.Parse(m.Groups["days"].Value) : 30;
		if (days < 1 || days > 3650)
		{
			Reply(p, "Days must be between 1 and 3650.");
			return;
		}
		// Strip characters that could break or chain a console command (";", quotes, "&", control chars).
		string name = Regex.Replace(m.Groups["name"].Value, "[\\x00-\\x1F\\x7F;\"'&]", "").Trim();
		if (name.Length > 32)
		{
			name = name.Substring(0, 32);
		}
		string actor = p.SteamID.ToString();
		Exec($"css_addvip_as {actor} {name}&{steam} {level} {days}");
		Reply(p, $"VIP {VipLevelNames[level - 1]} request sent for {steam} ({days} day(s)). Use /vip to check.");
	}

	private static int ParseVipLevel(string value)
	{
		string v = value.Trim().ToLowerInvariant();
		if (int.TryParse(v, out int n) && n >= 1 && n <= 4)
		{
			return n;
		}
		for (int i = 0; i < VipLevelNames.Length; i++)
		{
			if (VipLevelNames[i] == v)
			{
				return i + 1;
			}
		}
		return 0;
	}

	// Reads NexusVIP's vip_players.json (read-only) from the sibling plugin folder.
	private void ListVipPlayers(CCSPlayerController? p)
	{
		string path = Path.GetFullPath(Path.Combine(((BasePlugin)this).ModuleDirectory, "..", "NexusVIP", "vip_players.json"));
		if (!File.Exists(path))
		{
			Reply(p, "No VIP data yet (NexusVIP is not loaded or nobody is VIP).");
			return;
		}
		List<VipRow> rows;
		try
		{
			rows = JsonSerializer.Deserialize<List<VipRow>>(File.ReadAllText(path)) ?? new List<VipRow>();
		}
		catch (Exception ex)
		{
			Reply(p, "Cannot read VIP data: " + ex.Message);
			return;
		}
		DateTime now = DateTime.UtcNow;
		var list = rows.OrderByDescending((VipRow r) => now < r.ExpiresAtUtc).ThenByDescending((VipRow r) => r.ExpiresAtUtc).ToList();
		Reply(p, $"VIP on this server: {list.Count}");
		foreach (VipRow r in list.Take(20))
		{
			bool valid = r.Level >= 1 && r.Level <= 4;
			bool active = valid && now < r.ExpiresAtUtc;
			string lvl = valid ? VipLevelNames[r.Level - 1] : "?";
			Reply(p, $"[{(active ? "ACTIVE" : "EXPIRED")}] {r.Name} | {r.SteamId64} | {lvl} | until {r.ExpiresAtUtc:yyyy-MM-dd}");
		}
	}

	private sealed class VipRow
	{
		public string SteamId64 { get; set; } = "";

		public string Name { get; set; } = "";

		public int Level { get; set; }

		public DateTime ExpiresAtUtc { get; set; }
	}

	public void Reply(CCSPlayerController? p, string text)
	{
		//IL_0001: Unknown result type (might be due to invalid IL or missing references)
		//IL_000c: Expected Obj, but got Unknown
		if ((CEntityInstance)p == (CEntityInstance)null || !((CEntityInstance)p).IsValid)
		{
			Console.WriteLine(Config.ChatPrefix + " " + text);
		}
		else
		{
			p.PrintToChat(Pfx + text);
		}
	}

	private void Announce(string text)
	{
		Server.PrintToChatAll(Pfx + text);
	}

	public bool IsOwner(CCSPlayerController? p)
	{
		//IL_0001: Unknown result type (might be due to invalid IL or missing references)
		//IL_000c: Expected Obj, but got Unknown
		if ((CEntityInstance)p != (CEntityInstance)null && ((CEntityInstance)p).IsValid)
		{
			return Config.OwnerSteamIds.Contains(((CBasePlayerController)p).SteamID.ToString());
		}
		return false;
	}

	public bool HasPerm(CCSPlayerController? p, string perm)
	{
		//IL_0001: Unknown result type (might be due to invalid IL or missing references)
		//IL_000c: Expected Obj, but got Unknown
		if ((CEntityInstance)p == (CEntityInstance)null)
		{
			return true;
		}
		if (!((CEntityInstance)p).IsValid)
		{
			return false;
		}
		if (IsOwner(p))
		{
			return true;
		}
		string text = (perm.StartsWith('@') ? perm : ("@nepentii/" + perm));
		try
		{
			return AdminManager.PlayerHasPermissions(p, new string[1] { text }) || AdminManager.PlayerHasPermissions(p, new string[1] { "@css/root" });
		}
		catch
		{
			return false;
		}
	}

	private bool CanTarget(CCSPlayerController? admin, CCSPlayerController target)
	{
		//IL_0001: Unknown result type (might be due to invalid IL or missing references)
		//IL_000c: Expected Obj, but got Unknown
		if ((CEntityInstance)admin == (CEntityInstance)null || !Config.RespectImmunity)
		{
			return true;
		}
		if (admin.Slot == target.Slot)
		{
			return true;
		}
		if (IsOwner(admin))
		{
			return true;
		}
		if (IsOwner(target))
		{
			return false;
		}
		try
		{
			return AdminManager.CanPlayerTarget(admin, target);
		}
		catch
		{
			return true;
		}
	}

	public static IEnumerable<CCSPlayerController> Players()
	{
		return from p in Utilities.GetPlayers()
			where ((CEntityInstance)p).IsValid && !((CBasePlayerController)p).IsHLTV
			select p;
	}

	public static IEnumerable<CCSPlayerController> Humans()
	{
		return from p in Players()
			where !p.IsBot
			select p;
	}

	public List<CCSPlayerController> FindPlayers(CCSPlayerController? caller, string token, bool allowGroups, out string error)
	{
		//IL_03d1: Unknown result type (might be due to invalid IL or missing references)
		//IL_03dc: Expected Obj, but got Unknown
		//IL_0477: Unknown result type (might be due to invalid IL or missing references)
		//IL_0482: Expected Obj, but got Unknown
		//IL_0419: Unknown result type (might be due to invalid IL or missing references)
		//IL_0424: Expected Obj, but got Unknown
		//IL_04bf: Unknown result type (might be due to invalid IL or missing references)
		//IL_04ca: Expected Obj, but got Unknown
		//IL_031e: Unknown result type (might be due to invalid IL or missing references)
		//IL_0329: Expected Obj, but got Unknown
		error = "";
		token = (token ?? "").Trim();
		List<CCSPlayerController> list = Players().ToList();
		if (token.Length == 0)
		{
			error = "Specify a player.";
			return new List<CCSPlayerController>();
		}
		if (token[0] == '@')
		{
			if (!allowGroups)
			{
				error = "Groups are not allowed here.";
				return new List<CCSPlayerController>();
			}
			List<CCSPlayerController> list2 = token.ToLowerInvariant() switch
			{
				"@all" => list, 
				"@ct" => list.Where((CCSPlayerController x) => ((CBaseEntity)x).TeamNum == 3).ToList(), 
				"@t" => list.Where((CCSPlayerController x) => ((CBaseEntity)x).TeamNum == 2).ToList(), 
				"@spec" => list.Where((CCSPlayerController x) => ((CBaseEntity)x).TeamNum == 1).ToList(), 
				"@bots" => list.Where((CCSPlayerController x) => x.IsBot).ToList(), 
				"@humans" => list.Where((CCSPlayerController x) => !x.IsBot).ToList(), 
				"@alive" => list.Where((CCSPlayerController x) => x.PawnIsAlive).ToList(), 
				"@dead" => list.Where((CCSPlayerController x) => !x.PawnIsAlive).ToList(), 
				"@me" => ((CEntityInstance)caller != (CEntityInstance)null) ? new List<CCSPlayerController> { caller } : new List<CCSPlayerController>(), 
				_ => null, 
			};
			if (list2 == null)
			{
				error = "Unknown group " + token + ".";
				return new List<CCSPlayerController>();
			}
			if (list2.Count == 0)
			{
				error = "Nobody matches " + token + ".";
			}
			return list2;
		}
		if (token[0] == '#' && int.TryParse(token.AsSpan(1), out var uid))
		{
			CCSPlayerController val = list.FirstOrDefault((CCSPlayerController x) => x.UserId == uid);
			if ((CEntityInstance)val == (CEntityInstance)null)
			{
				error = $"No player with userid {uid}.";
			}
			if (!((CEntityInstance)val == (CEntityInstance)null))
			{
				return new List<CCSPlayerController> { val };
			}
			return new List<CCSPlayerController>();
		}
		if (ulong.TryParse(token, out var sid) && sid > 70000000000000000L)
		{
			CCSPlayerController val2 = list.FirstOrDefault((CCSPlayerController x) => ((CBasePlayerController)x).SteamID == sid);
			if ((CEntityInstance)val2 == (CEntityInstance)null)
			{
				error = $"No connected player has SteamID {sid}.";
			}
			if (!((CEntityInstance)val2 == (CEntityInstance)null))
			{
				return new List<CCSPlayerController> { val2 };
			}
			return new List<CCSPlayerController>();
		}
		List<CCSPlayerController> list3 = list.Where((CCSPlayerController x) => CleanName(((CBasePlayerController)x).PlayerName).Equals(token, StringComparison.OrdinalIgnoreCase)).ToList();
		if (list3.Count == 1)
		{
			return list3;
		}
		List<CCSPlayerController> list4 = list.Where((CCSPlayerController x) => CleanName(((CBasePlayerController)x).PlayerName).Contains(token, StringComparison.OrdinalIgnoreCase)).ToList();
		if (list4.Count == 1)
		{
			return list4;
		}
		error = ((list4.Count == 0) ? ("No player matches '" + token + "'.") : ("More than one player matches '" + token + "'; use #userid (see /plist)."));
		return new List<CCSPlayerController>();
	}

	public CCSPlayerController? FindOne(CCSPlayerController? caller, string token, out string error)
	{
		List<CCSPlayerController> list = FindPlayers(caller, token, allowGroups: false, out error);
		if (list.Count != 1)
		{
			return null;
		}
		return list[0];
	}

	public void ShowMenu(CCSPlayerController p, string title, List<(string text, Action<CCSPlayerController> act)> items, int page = 0)
	{
		//IL_0024: Unknown result type (might be due to invalid IL or missing references)
		//IL_002f: Expected Obj, but got Unknown
		//IL_00df: Unknown result type (might be due to invalid IL or missing references)
		//IL_00e5: Expected Obj, but got Unknown
		if ((CEntityInstance)p == (CEntityInstance)null || !((CEntityInstance)p).IsValid)
		{
			return;
		}
		if (items.Count == 0)
		{
			Reply(p, "Nothing to choose from.");
			return;
		}
		int num = (items.Count + 6 - 1) / 6;
		page = Math.Clamp(page, 0, num - 1);
		ChatMenu val = new ChatMenu((num > 1) ? $"{title} ({page + 1}/{num})" : title);
		foreach (var item in items.Skip(page * 6).Take(6))
		{
			Action<CCSPlayerController> act = item.act;
			((BaseMenu)val).AddMenuOption(item.text, (Action<CCSPlayerController, ChatMenuOption>)((CCSPlayerController pl, ChatMenuOption _) =>
			{
				if (((CEntityInstance)pl).IsValid)
				{
					act(pl);
				}
			}), false);
		}
		if (page > 0)
		{
			((BaseMenu)val).AddMenuOption("« Previous", (Action<CCSPlayerController, ChatMenuOption>)((CCSPlayerController pl, ChatMenuOption _) =>
			{
				ShowMenu(pl, title, items, page - 1);
			}), false);
		}
		if (page < num - 1)
		{
			((BaseMenu)val).AddMenuOption("Next »", (Action<CCSPlayerController, ChatMenuOption>)((CCSPlayerController pl, ChatMenuOption _) =>
			{
				ShowMenu(pl, title, items, page + 1);
			}), false);
		}
		MenuManager.OpenChatMenu(p, val);
	}

	private static string TeamTag(CCSPlayerController x)
	{
		return ((CBaseEntity)x).TeamNum switch
		{
			2 => "T", 
			3 => "CT", 
			1 => "SPEC", 
			_ => "-", 
		};
	}

	public void PickPlayer(CCSPlayerController admin, string title, Action<CCSPlayerController, CCSPlayerController> onPick, bool groups = false, Action<CCSPlayerController, string>? onGroup = null, Func<CCSPlayerController, bool>? filter = null)
	{
		List<(string, Action<CCSPlayerController>)> list = new List<(string, Action<CCSPlayerController>)>();
		if (groups && onGroup != null)
		{
			list.Add(("★ Everyone", (CCSPlayerController a) =>
			{
				onGroup(a, "@all");
			}));
			list.Add(("★ All CT", (CCSPlayerController a) =>
			{
				onGroup(a, "@ct");
			}));
			list.Add(("★ All T", (CCSPlayerController a) =>
			{
				onGroup(a, "@t");
			}));
		}
		foreach (CCSPlayerController item in (from x in Players()
			where filter == null || filter(x)
			select x).OrderBy((CCSPlayerController x) => ((CBasePlayerController)x).PlayerName, StringComparer.OrdinalIgnoreCase))
		{
			int slot = item.Slot;
			ulong sid = ((CBasePlayerController)item).SteamID;
			bool isBot = item.IsBot;
			list.Add(($"{CleanName(((CBasePlayerController)item).PlayerName)} [{TeamTag(item)}] #{item.UserId}", (CCSPlayerController a) =>
			{
				//IL_002b: Unknown result type (might be due to invalid IL or missing references)
				//IL_0036: Expected Obj, but got Unknown
				CCSPlayerController val = Players().FirstOrDefault((CCSPlayerController x) => x.Slot == slot && (isBot || ((CBasePlayerController)x).SteamID == sid));
				if ((CEntityInstance)val == (CEntityInstance)null)
				{
					Reply(a, "That player left.");
				}
				else
				{
					onPick(a, val);
				}
			}));
		}
		ShowMenu(admin, title, list);
	}

	public void Prompt(CCSPlayerController p, string question, Action<CCSPlayerController, string> onText)
	{
		_prompts[((CBasePlayerController)p).SteamID] = onText;
		Reply(p, $"{question} {ChatColors.Grey}(type it in chat, or 'cancel')");
		try
		{
			p.PrintToCenter(question);
		}
		catch
		{
		}
	}

	// NexusVIP grants "vip.level.<name>" flags. This renders VIP chat (tag + name color)
	// for normal chat and team chat. Called only after the gag check, so gagged players stay silenced.
	private bool TryRenderVipChat(CCSPlayerController p, CommandInfo info, string text)
	{
		string? level = null;
		foreach (string candidate in new string[4] { "platinum", "gold", "silver", "bronze" })
		{
			try
			{
				if (AdminManager.PlayerHasPermissions(p, new string[1] { "vip.level." + candidate }))
				{
					level = candidate;
					break;
				}
			}
			catch
			{
				return false;
			}
		}
		if (level == null)
		{
			return false;
		}
		bool teamOnly = info.GetArg(0).Equals("say_team", StringComparison.OrdinalIgnoreCase);
		string name = CleanName(((CBasePlayerController)p).PlayerName);
		string message = new string(text.Where((char ch) => !char.IsControl(ch)).Take(160).ToArray()).Trim();
		if (message.Length == 0)
		{
			return true;
		}
		string line = $" {ChatColors.Yellow}[VIP {level.ToUpperInvariant()}]{(teamOnly ? " (Team)" : "")} {ChatColors.Green}{name}{ChatColors.White}: {message}";
		if (teamOnly)
		{
			foreach (CCSPlayerController x in Humans())
			{
				if (((CBaseEntity)x).TeamNum == ((CBaseEntity)p).TeamNum)
				{
					x.PrintToChat(line);
				}
			}
		}
		else
		{
			Server.PrintToChatAll(line);
		}
		return true;
	}

	private HookResult OnSay(CCSPlayerController? p, CommandInfo info)
	{
		//IL_0001: Unknown result type (might be due to invalid IL or missing references)
		//IL_000c: Expected Obj, but got Unknown
		if (!((CEntityInstance)p == (CEntityInstance)null) && ((CEntityInstance)p).IsValid)
		{
			string text = ((info.ArgCount > 1) ? info.GetArg(1) : "").Trim();
			if (text.Length != 0)
			{
				bool flag = text[0] == '!' || text[0] == '/';
				if (!flag && _prompts.Remove(((CBasePlayerController)p).SteamID, out var value))
				{
					if (!text.Equals("cancel", StringComparison.OrdinalIgnoreCase))
					{
						value(p, text);
					}
					else
					{
						Reply(p, "Cancelled.");
					}
					return (HookResult)3;
				}
				if (!flag && IsPunished("gag", ((CBasePlayerController)p).SteamID))
				{
					Reply(p, "You are gagged.");
					return (HookResult)3;
				}
				if (!flag && TryRenderVipChat(p, info, text))
				{
					return (HookResult)3;
				}
				return (HookResult)0;
			}
			return (HookResult)0;
		}
		return (HookResult)0;
	}

	private HookResult OnJoinTeam(CCSPlayerController? p, CommandInfo info)
	{
		//IL_0009: Unknown result type (might be due to invalid IL or missing references)
		//IL_0014: Expected Obj, but got Unknown
		if (_teamsLocked && !((CEntityInstance)p == (CEntityInstance)null) && ((CEntityInstance)p).IsValid)
		{
			if (!HasPerm(p, "lock"))
			{
				if (((CBaseEntity)p).TeamNum == 3 || ((CBaseEntity)p).TeamNum == 2)
				{
					Reply(p, "Teams are locked.");
					return (HookResult)3;
				}
				return (HookResult)0;
			}
			return (HookResult)0;
		}
		return (HookResult)0;
	}

	private HookResult OnConnectFull(EventPlayerConnectFull e, GameEventInfo i)
	{
		//IL_001f: Unknown result type (might be due to invalid IL or missing references)
		//IL_002a: Expected Obj, but got Unknown
		CCSPlayerController p = e.Userid;
		if (!((CEntityInstance)p == (CEntityInstance)null) && ((CEntityInstance)p).IsValid && !p.IsBot)
		{
			if (!EnforceBan(p))
			{
				Server.NextFrame((Action)(() =>
				{
					if (((CEntityInstance)p).IsValid)
					{
						ApplyPunishments(p);
						ApplyTag(p);
					}
				}));
				((BasePlugin)this).AddTimer(2f, (Action)(() =>
				{
					if (((CEntityInstance)p).IsValid)
					{
						ApplyTag(p);
					}
				}), null);
				return (HookResult)0;
			}
			return (HookResult)0;
		}
		return (HookResult)0;
	}

	private HookResult OnDisconnect(EventPlayerDisconnect e, GameEventInfo i)
	{
		//IL_0008: Unknown result type (might be due to invalid IL or missing references)
		//IL_0013: Expected Obj, but got Unknown
		CCSPlayerController userid = e.Userid;
		if (!((CEntityInstance)userid == (CEntityInstance)null) && !userid.IsBot)
		{
			RememberDisconnect(((CBasePlayerController)userid).SteamID, CleanName(((CBasePlayerController)userid).PlayerName));
			_prompts.Remove(((CBasePlayerController)userid).SteamID);
			return (HookResult)0;
		}
		return (HookResult)0;
	}

	private string AdminDir()
	{
		if (!string.IsNullOrWhiteSpace(Config.AdminConfigDir))
		{
			return Config.AdminConfigDir;
		}
		return Path.Combine(Application.RootDirectory, "configs");
	}

	private void EnsureMetadataFile()
	{
		try
		{
			Directory.CreateDirectory(AdminDir());
			if (!File.Exists(MetaFile))
			{
				File.WriteAllText(MetaFile, "[]");
			}
		}
		catch (Exception ex)
		{
			LoggerExtensions.LogError(((BasePlugin)this).Logger, "Cannot prepare {D}: {M}", new object[2]
			{
				AdminDir(),
				ex.Message
			});
		}
	}

	public List<AdminMeta> LoadMeta()
	{
		lock (_fileLock)
		{
			try
			{
				if (!File.Exists(MetaFile))
				{
					return new List<AdminMeta>();
				}
				return JsonSerializer.Deserialize<List<AdminMeta>>(File.ReadAllText(MetaFile), JsonRead) ?? new List<AdminMeta>();
			}
			catch (Exception ex)
			{
				LoggerExtensions.LogWarning(((BasePlugin)this).Logger, "Metadata load error: {M}", new object[1] { ex.Message });
				return new List<AdminMeta>();
			}
		}
	}

	public void SaveMeta(List<AdminMeta> list)
	{
		lock (_fileLock)
		{
			try
			{
				Directory.CreateDirectory(AdminDir());
				string text = MetaFile + ".tmp";
				File.WriteAllText(text, JsonSerializer.Serialize(list, JsonWrite));
				File.Move(text, MetaFile, overwrite: true);
			}
			catch (Exception ex)
			{
				LoggerExtensions.LogError(((BasePlugin)this).Logger, "Metadata save error: {M}", new object[1] { ex.Message });
			}
		}
	}

	private JsonObject LoadAdminsJson()
	{
		try
		{
			if (File.Exists(AdminsFile))
			{
				return JsonNode.Parse(File.ReadAllText(AdminsFile), null, new JsonDocumentOptions
				{
					CommentHandling = JsonCommentHandling.Skip,
					AllowTrailingCommas = true
				})?.AsObject() ?? new JsonObject();
			}
		}
		catch (Exception ex)
		{
			LoggerExtensions.LogWarning(((BasePlugin)this).Logger, "admins.json load error: {M}", new object[1] { ex.Message });
		}
		return new JsonObject();
	}

	public void SyncAdmins(List<AdminMeta> meta)
	{
		lock (_fileLock)
		{
			try
			{
				JsonObject jsonObject = LoadAdminsJson();
				HashSet<string> hashSet = new HashSet<string>(meta.Select((AdminMeta m) => m.Identity));
				JsonObject jsonObject2 = new JsonObject();
				foreach (KeyValuePair<string, JsonNode> item2 in jsonObject)
				{
					string item = item2.Value?["identity"]?.GetValue<string>() ?? "";
					if (!hashSet.Contains(item) && item2.Value != null)
					{
						jsonObject2[item2.Key] = JsonNode.Parse(item2.Value.ToJsonString());
					}
				}
				foreach (AdminMeta item3 in meta.Where((AdminMeta x) => x.Enabled))
				{
					string text = (string.IsNullOrWhiteSpace(item3.Name) ? item3.Identity : item3.Name);
					string propertyName = text;
					int num = 2;
					while (jsonObject2.ContainsKey(propertyName))
					{
						propertyName = $"{text}_{num++}";
					}
					jsonObject2[propertyName] = new JsonObject
					{
						["identity"] = item3.Identity,
						["immunity"] = item3.Immunity,
						["flags"] = new JsonArray(((IEnumerable<string>)item3.Flags).Select((Func<string, JsonNode>)((string f) => JsonValue.Create(f))).ToArray())
					};
				}
				Directory.CreateDirectory(AdminDir());
				string text2 = AdminsFile + ".tmp";
				File.WriteAllText(text2, jsonObject2.ToJsonString(JsonWrite));
				File.Move(text2, AdminsFile, overwrite: true);
			}
			catch (Exception ex)
			{
				LoggerExtensions.LogError(((BasePlugin)this).Logger, "admins.json save error: {M}", new object[1] { ex.Message });
			}
		}
		try
		{
			AdminManager.LoadAdminData(AdminsFile);
		}
		catch (Exception ex2)
		{
			LoggerExtensions.LogWarning(((BasePlugin)this).Logger, "Reload admins failed: {M}", new object[1] { ex2.Message });
		}
	}

	public static string NormTag(string? t)
	{
		if (t == null)
		{
			t = "";
		}
		t = t.Replace("[", "").Replace("]", "").Replace("|", "")
			.Trim();
		if (t.Length <= 16)
		{
			return t;
		}
		return t.Substring(0, 16).Trim();
	}

	private void EnsureOwners()
	{
		List<AdminMeta> list = LoadMeta();
		foreach (KeyValuePair<string, JsonNode> item in LoadAdminsJson())
		{
			if (!(item.Value is JsonObject jsonObject))
			{
				continue;
			}
			string id = jsonObject["identity"]?.GetValue<string>() ?? "";
			if (string.IsNullOrWhiteSpace(id) || list.Any((AdminMeta m) => m.Identity == id))
			{
				continue;
			}
			List<string> list2 = new List<string>();
			if (jsonObject["flags"] is JsonArray jsonArray)
			{
				foreach (JsonNode item2 in jsonArray)
				{
					string text = item2?.GetValue<string>();
					if (!string.IsNullOrWhiteSpace(text))
					{
						list2.Add(text);
					}
				}
			}
			list.Add(new AdminMeta
			{
				Identity = id,
				Name = item.Key,
				Immunity = (jsonObject["immunity"]?.GetValue<int>() ?? 0),
				Flags = list2,
				Tag = "",
				Enabled = true
			});
		}
		foreach (AdminMeta item3 in list)
		{
			bool num = item3.Tag.Contains('[') || string.IsNullOrWhiteSpace(item3.Tag);
			bool flag = Config.OwnerSteamIds.Contains(item3.Identity);
			if (num)
			{
				item3.Tag = (flag ? Config.OwnerTag : Config.DefaultAdminTag);
			}
			else
			{
				item3.Tag = NormTag(item3.Tag);
			}
			if (flag)
			{
				item3.Enabled = true;
				item3.Immunity = 100;
				item3.Flags = AllFlags().ToList();
			}
		}
		foreach (string id2 in Config.OwnerSteamIds)
		{
			if (!list.Any((AdminMeta m) => m.Identity == id2))
			{
				AdminMeta adminMeta = new AdminMeta
				{
					Identity = id2
				};
				string name;
				if (!(id2 == "76561198768187147"))
				{
					string text2 = id2;
					int length = text2.Length;
					int num2 = length - 4;
					name = "Owner_" + text2.Substring(num2, length - num2);
				}
				else
				{
					name = "NEPENTII";
				}
				adminMeta.Name = name;
				adminMeta.Immunity = 100;
				adminMeta.Flags = AllFlags().ToList();
				adminMeta.Tag = Config.OwnerTag;
				adminMeta.Enabled = true;
				list.Add(adminMeta);
			}
		}
		SaveMeta(list);
		SyncAdmins(list);
	}

	public AdminMeta? FindMeta(ulong steam)
	{
		return LoadMeta().FirstOrDefault((AdminMeta m) => m.Identity == steam.ToString());
	}

	public static string CleanName(string? n)
	{
		if (n == null)
		{
			n = "";
		}
		for (int i = 0; i < 3; i++)
		{
			string text = TagPrefix.Replace(n, "");
			if (text == n)
			{
				break;
			}
			n = text;
		}
		return n.Trim();
	}

	private void ApplyAllTags()
	{
		if (!Config.ApplyNameTags)
		{
			return;
		}
		long tickCount = Environment.TickCount64;
		if (tickCount - _metaCacheAt > 10000)
		{
			_metaCache = LoadMeta();
			_metaCacheAt = tickCount;
		}
		foreach (CCSPlayerController item in Humans())
		{
			ApplyTag(item, _metaCache);
		}
	}

	public void InvalidateMetaCache()
	{
		_metaCacheAt = 0L;
	}

	public void ApplyTag(CCSPlayerController p, List<AdminMeta>? meta = null)
	{
		if (!((CEntityInstance)p).IsValid || p.IsBot)
		{
			return;
		}
		string text = CleanName(((CBasePlayerController)p).PlayerName);
		if (text.Length == 0)
		{
			return;
		}
		string text2 = text;
		if (Config.ApplyNameTags)
		{
			if (meta == null)
			{
				meta = LoadMeta();
			}
			AdminMeta adminMeta = meta.FirstOrDefault((AdminMeta x) => x.Identity == ((CBasePlayerController)p).SteamID.ToString());
			if (adminMeta != null && adminMeta.Enabled && adminMeta.Tag.Length > 0)
			{
				string text3 = "| " + adminMeta.Tag + " | ";
				if (text.Length + text3.Length > 32)
				{
					text = text.Substring(0, Math.Max(1, 32 - text3.Length));
				}
				text2 = text3 + text;
			}
		}
		if (((CBasePlayerController)p).PlayerName != text2)
		{
			SetName(p, text2);
		}
	}

	public static void SetName(CCSPlayerController p, string name)
	{
		//IL_0008: Unknown result type (might be due to invalid IL or missing references)
		//IL_001d: Expected Obj, but got Unknown
		((CBasePlayerController)p).PlayerName = name;
		Utilities.SetStateChanged((CBaseEntity)p, "CBasePlayerController", "m_iszPlayerName", 0);
	}

	public static void Exec(string cmd)
	{
		Server.ExecuteCommand(cmd);
	}

	public static string CvarString(string name)
	{
		try
		{
			ConVar val = ConVar.Find(name);
			return ((val != null) ? val.StringValue : null) ?? "";
		}
		catch
		{
			return "";
		}
	}

	private static long Now()
	{
		return DateTimeOffset.UtcNow.ToUnixTimeSeconds();
	}

	private string? DataPath(string rel)
	{
		try
		{
			if (string.IsNullOrWhiteSpace(rel) || Path.IsPathRooted(rel) || rel.Contains(".."))
			{
				return null;
			}
			string fullPath = Path.GetFullPath(((BasePlugin)this).ModuleDirectory);
			string fullPath2 = Path.GetFullPath(Path.Combine(fullPath, rel));
			return fullPath2.StartsWith(fullPath + Path.DirectorySeparatorChar, StringComparison.Ordinal) ? fullPath2 : null;
		}
		catch
		{
			return null;
		}
	}

	private void LoadPunishments()
	{
		string text = DataPath(Config.PunishmentsFile);
		if (text == null)
		{
			LoggerExtensions.LogWarning(((BasePlugin)this).Logger, "PunishmentsFile is not a safe relative path; gags/mutes are not saved.", Array.Empty<object>());
			return;
		}
		lock (_fileLock)
		{
			try
			{
				_pun = (File.Exists(text) ? (JsonSerializer.Deserialize<List<Punishment>>(File.ReadAllText(text)) ?? new List<Punishment>()) : new List<Punishment>());
			}
			catch (Exception ex)
			{
				LoggerExtensions.LogWarning(((BasePlugin)this).Logger, "Cannot read punishments: {M}", new object[1] { ex.Message });
				_pun = new List<Punishment>();
			}
		}
	}

	private void SavePunishments()
	{
		string text = DataPath(Config.PunishmentsFile);
		if (text == null)
		{
			return;
		}
		lock (_fileLock)
		{
			try
			{
				Directory.CreateDirectory(Path.GetDirectoryName(text));
				string text2 = text + ".tmp";
				File.WriteAllText(text2, JsonSerializer.Serialize(_pun, new JsonSerializerOptions
				{
					WriteIndented = true
				}));
				File.Move(text2, text, overwrite: true);
			}
			catch (Exception ex)
			{
				LoggerExtensions.LogWarning(((BasePlugin)this).Logger, "Cannot save punishments: {M}", new object[1] { ex.Message });
			}
		}
	}

	private bool Active(Punishment x)
	{
		if (x.Expires != 0L)
		{
			return x.Expires > Now();
		}
		return true;
	}

	public bool IsPunished(string type, ulong steam)
	{
		return _pun.Any((Punishment x) => x.Type == type && x.Steam == steam.ToString() && Active(x));
	}

	private void SweepPunishments()
	{
		if (_pun.RemoveAll((Punishment x) => !Active(x)) <= 0)
		{
			return;
		}
		SavePunishments();
		foreach (CCSPlayerController item in Humans())
		{
			ApplyPunishments(item);
		}
	}

	public void ApplyPunishments(CCSPlayerController p)
	{
		//IL_0030: Unknown result type (might be due to invalid IL or missing references)
		if (!((CEntityInstance)p).IsValid || p.IsBot)
		{
			return;
		}
		try
		{
			if (IsPunished("mute", ((CBasePlayerController)p).SteamID))
			{
				p.VoiceFlags = (VoiceFlags)1;
			}
			else if (((Enum)p.VoiceFlags).HasFlag((Enum)(object)(VoiceFlags)1))
			{
				p.VoiceFlags = (VoiceFlags)0;
			}
		}
		catch
		{
		}
	}

	private void RememberDisconnect(ulong steam, string name)
	{
		_recent.RemoveAll(((ulong steam, string name) x) => x.steam == steam);
		_recent.Insert(0, (steam, name));
		if (_recent.Count > 20)
		{
			_recent.RemoveRange(20, _recent.Count - 20);
		}
	}

	private void AddPunishment(CCSPlayerController? by, string type, string steam, string name, int minutes, string reason)
	{
		//IL_0059: Unknown result type (might be due to invalid IL or missing references)
		//IL_0064: Expected Obj, but got Unknown
		//IL_00c4: Unknown result type (might be due to invalid IL or missing references)
		//IL_00cf: Expected Obj, but got Unknown
		//IL_0148: Unknown result type (might be due to invalid IL or missing references)
		//IL_0153: Expected Obj, but got Unknown
		_pun.RemoveAll((Punishment x) => x.Type == type && x.Steam == steam);
		_pun.Add(new Punishment
		{
			Type = type,
			Steam = steam,
			Name = name,
			By = (((CEntityInstance)by == (CEntityInstance)null) ? "Console" : CleanName(((CBasePlayerController)by).PlayerName)),
			Reason = reason,
			Expires = ((minutes <= 0) ? 0 : (Now() + (long)minutes * 60L))
		});
		SavePunishments();
		CCSPlayerController val = Players().FirstOrDefault((CCSPlayerController x) => ((CBasePlayerController)x).SteamID.ToString() == steam);
		if ((CEntityInstance)val != (CEntityInstance)null)
		{
			ApplyPunishments(val);
		}
		string value = ((type == "gag") ? "gagged" : "muted");
		Announce($"{name} was {value} ({DurationText(minutes)}) by {(((CEntityInstance)by == (CEntityInstance)null) ? "Console" : CleanName(((CBasePlayerController)by).PlayerName))}{((reason.Length > 0) ? (". Reason: " + reason) : ".")}");
	}

	private bool RemovePunishment(CCSPlayerController? by, string type, string steam)
	{
		//IL_005c: Unknown result type (might be due to invalid IL or missing references)
		//IL_0067: Expected Obj, but got Unknown
		//IL_00c8: Unknown result type (might be due to invalid IL or missing references)
		//IL_00d3: Expected Obj, but got Unknown
		Punishment punishment = _pun.FirstOrDefault((Punishment x) => x.Type == type && x.Steam == steam);
		if (punishment == null)
		{
			return false;
		}
		_pun.Remove(punishment);
		SavePunishments();
		CCSPlayerController val = Players().FirstOrDefault((CCSPlayerController x) => ((CBasePlayerController)x).SteamID.ToString() == steam);
		if ((CEntityInstance)val != (CEntityInstance)null)
		{
			ApplyPunishments(val);
		}
		Announce($"{punishment.Name} was {((type == "gag") ? "ungagged" : "unmuted")} by {(((CEntityInstance)by == (CEntityInstance)null) ? "Console" : CleanName(((CBasePlayerController)by).PlayerName))}.");
		return true;
	}

	private void AddPunishCmd(string type, string perm, string label, string[] idAliases, string[] addNames, string[] undoNames, string[] offlineUndoNames)
	{
		string undoPerm = "un" + type;
		Add(type, label, "/" + type + " <player> [minutes] [reason]", perm, (CCSPlayerController? p, CmdContext c) =>
		{
			//IL_0043: Unknown result type (might be due to invalid IL or missing references)
			//IL_004e: Expected Obj, but got Unknown
			if (c.Args.Length == 0)
			{
				Reply(p, "Usage: /" + type + " <player> [minutes] [reason]");
			}
			else
			{
				CCSPlayerController val = FindOne(p, c.Args[0], out var error);
				if ((CEntityInstance)val == (CEntityInstance)null)
				{
					Reply(p, error);
				}
				else if (val.IsBot)
				{
					Reply(p, "Bots cannot be punished.");
				}
				else if (!CanTarget(p, val))
				{
					Reply(p, "That player has more immunity than you.");
				}
				else
				{
					int minutes = Config.DefaultPunishMinutes;
					int num = 1;
					if (c.Args.Length > 1 && int.TryParse(c.Args[1], out var result))
					{
						minutes = result;
						num = 2;
					}
					AddPunishment(p, type, ((CBasePlayerController)val).SteamID.ToString(), CleanName(((CBasePlayerController)val).PlayerName), minutes, Rest(c.Args, num));
				}
			}
		}, (CCSPlayerController p) =>
		{
			PickPlayer(p, label.TrimEnd('.'), (CCSPlayerController a, CCSPlayerController t) =>
			{
				DurationMenu(a, ((CBasePlayerController)t).SteamID.ToString(), CleanName(((CBasePlayerController)t).PlayerName), check: true);
			}, groups: false, null, (CCSPlayerController x) => !x.IsBot);
		}, idAliases);
		Add(addNames[0], label.TrimEnd('.') + " (offline, by SteamID64).", "/" + addNames[0] + " <steamid64> [minutes] [reason]", perm, (CCSPlayerController? p, CmdContext c) =>
		{
			if (c.Args.Length == 0 || !ulong.TryParse(c.Args[0], out var sid) || sid < 70000000000000000L)
			{
				Reply(p, "Usage: /" + addNames[0] + " <steamid64> [minutes] [reason]");
			}
			else
			{
				int minutes = Config.DefaultPunishMinutes;
				int num = 1;
				if (c.Args.Length > 1 && int.TryParse(c.Args[1], out var result))
				{
					minutes = result;
					num = 2;
				}
				object obj = _recent.FirstOrDefault(((ulong steam, string name) x) => x.steam == sid).name;
				if (obj == null)
				{
					CCSPlayerController val = Players().FirstOrDefault((CCSPlayerController x) => ((CBasePlayerController)x).SteamID == sid);
					obj = (((CEntityInstance)(object)val != (CEntityInstance)null) ? ((CBasePlayerController)val).PlayerName : null) ?? sid.ToString();
				}
				string n = (string)obj;
				AddPunishment(p, type, sid.ToString(), CleanName(n), minutes, Rest(c.Args, num));
			}
		}, (CCSPlayerController p) =>
		{
			List<(string, Action<CCSPlayerController>)> list = _recent.Select(((ulong steam, string name) r) => ((string, Action<CCSPlayerController>))(r.name + " (left)", (CCSPlayerController a) =>
			{
				DurationMenu(a, r.steam.ToString(), r.name, check: false);
			})).ToList();
			list.Add(("✎ Enter a SteamID64…", (CCSPlayerController a) =>
			{
				Prompt(a, "Type the SteamID64:", (CCSPlayerController pl, string txt) =>
				{
					if (!ulong.TryParse(txt, out var result) || result < 70000000000000000L)
					{
						Reply(pl, "Invalid SteamID64.");
					}
					else
					{
						DurationMenu(pl, result.ToString(), result.ToString(), check: false);
					}
				});
			}));
			ShowMenu(p, label.TrimEnd('.') + " (offline)", list);
		});
		Add(undoNames[0], "Remove a " + type + ".", "/" + undoNames[0] + " <player|steamid64>", undoPerm, UndoRun, UndoMenu);
		Add(offlineUndoNames[0], "Remove a " + type + " (offline, by SteamID64).", "/" + offlineUndoNames[0] + " <steamid64>", undoPerm, UndoRun, UndoMenu);
		void DurationMenu(CCSPlayerController a, string steam, string name, bool check)
		{
			List<(string, Action<CCSPlayerController>)> items = Config.PunishMinutesMenu.Select((int m) => ((string, Action<CCSPlayerController>))(DurationText(m) ?? "", (CCSPlayerController b) =>
			{
				//IL_0072: Unknown result type (might be due to invalid IL or missing references)
				//IL_007d: Expected Obj, but got Unknown
				if (HasPerm(b, perm))
				{
					if (check)
					{
						CCSPlayerController val = Players().FirstOrDefault((CCSPlayerController x) => ((CBasePlayerController)x).SteamID.ToString() == steam);
						if ((CEntityInstance)val != (CEntityInstance)null && !CanTarget(b, val))
						{
							Reply(b, "That player has more immunity than you.");
							return;
						}
					}
					AddPunishment(b, type, steam, name, m, "");
				}
			})).ToList();
			ShowMenu(a, label.TrimEnd('.') + ": " + name, items);
		}
		void UndoMenu(CCSPlayerController p)
		{
			List<Punishment> list = _pun.Where((Punishment x) => x.Type == type && Active(x)).ToList();
			if (list.Count == 0)
			{
				Reply(p, "Nobody is " + ((type == "gag") ? "gagged" : "muted") + ".");
			}
			else
			{
				ShowMenu(p, "Remove " + type, list.Select((Punishment x) => ((string, Action<CCSPlayerController>))(x.Name + " (" + ((x.Expires == 0L) ? "permanent" : ((x.Expires - Now()) / 60 + 1 + " min left")) + ")", (CCSPlayerController a) =>
				{
					if (HasPerm(a, undoPerm))
					{
						RemovePunishment(a, type, x.Steam);
					}
				})).ToList());
			}
		}
		void UndoRun(CCSPlayerController? p, CmdContext c)
		{
			//IL_006c: Unknown result type (might be due to invalid IL or missing references)
			//IL_0077: Expected Obj, but got Unknown
			if (c.Args.Length == 0)
			{
				Reply(p, "Usage: /" + undoNames[0] + " <player|steamid64>");
			}
			else
			{
				string steam;
				if (ulong.TryParse(c.Args[0], out var result) && result > 70000000000000000L)
				{
					steam = result.ToString();
				}
				else
				{
					CCSPlayerController val = FindOne(p, c.Args[0], out var error);
					if ((CEntityInstance)val == (CEntityInstance)null)
					{
						Reply(p, error);
						return;
					}
					steam = ((CBasePlayerController)val).SteamID.ToString();
				}
				if (!RemovePunishment(p, type, steam))
				{
					Reply(p, "That player is not " + ((type == "gag") ? "gagged." : "muted."));
				}
			}
		}
	}

	private void LoadBans()
	{
		string text = DataPath(Config.BansFile);
		if (text == null)
		{
			LoggerExtensions.LogWarning(((BasePlugin)this).Logger, "BansFile is not a safe relative path; bans are not saved.", Array.Empty<object>());
			return;
		}
		lock (_fileLock)
		{
			try
			{
				_bans = (File.Exists(text) ? (JsonSerializer.Deserialize<List<BanRecord>>(File.ReadAllText(text)) ?? new List<BanRecord>()) : new List<BanRecord>());
			}
			catch (Exception ex)
			{
				LoggerExtensions.LogWarning(((BasePlugin)this).Logger, "Cannot read bans: {M}", new object[1] { ex.Message });
				_bans = new List<BanRecord>();
			}
		}
	}

	private void SaveBans()
	{
		string text = DataPath(Config.BansFile);
		if (text == null)
		{
			return;
		}
		lock (_fileLock)
		{
			try
			{
				Directory.CreateDirectory(Path.GetDirectoryName(text));
				string text2 = text + ".tmp";
				File.WriteAllText(text2, JsonSerializer.Serialize(_bans, new JsonSerializerOptions
				{
					WriteIndented = true
				}));
				File.Move(text2, text, overwrite: true);
			}
			catch (Exception ex)
			{
				LoggerExtensions.LogWarning(((BasePlugin)this).Logger, "Cannot save bans: {M}", new object[1] { ex.Message });
			}
		}
	}

	private BanRecord? FindBan(ulong steam)
	{
		string s = steam.ToString();
		return _bans.FirstOrDefault((BanRecord b) => b.Steam == s && (b.Expires == 0L || b.Expires > Now()));
	}

	private bool RemoveBan(ulong steam)
	{
		string s = steam.ToString();
		int num = _bans.RemoveAll((BanRecord b) => b.Steam == s);
		if (num > 0)
		{
			SaveBans();
		}
		return num > 0;
	}

	private bool EnforceBan(CCSPlayerController p)
	{
		//IL_001a: Unknown result type (might be due to invalid IL or missing references)
		//IL_0025: Expected Obj, but got Unknown
		if ((CEntityInstance)p == (CEntityInstance)null || !((CEntityInstance)p).IsValid || p.IsBot)
		{
			return false;
		}
		BanRecord banRecord = FindBan(((CBasePlayerController)p).SteamID);
		if (banRecord == null)
		{
			return false;
		}
		Console.WriteLine($"[Ban] {((CBasePlayerController)p).PlayerName} ({((CBasePlayerController)p).SteamID}) is banned on this server ({banRecord.Reason}); disconnected.");
		string value = Config.BanKickMessage.Replace("{player}", CleanName(((CBasePlayerController)p).PlayerName)).Replace("{reason}", banRecord.Reason);
		Server.PrintToChatAll($" {ChatColors.Red}{Config.BanChatPrefix}{ChatColors.White} {value}");
		Server.NextFrame((Action)(() =>
		{
			//IL_0019: Unknown result type (might be due to invalid IL or missing references)
			if (((CEntityInstance)p).IsValid)
			{
				p.Disconnect(_banReason);
			}
		}));
		return true;
	}

	private void BanSteam(ulong steam, string name, string adminName, string reason, int minutes)
	{
		RemoveBan(steam);
		_bans.Add(new BanRecord
		{
			Steam = steam.ToString(),
			Name = name,
			Admin = adminName,
			Reason = reason,
			Created = Now(),
			Expires = ((minutes > 0) ? (Now() + (long)minutes * 60L) : 0)
		});
		SaveBans();
	}

	private void ApplyBanRules()
	{
		if (Config.NoVoteKickBans)
		{
			Exec("sv_kick_ban_duration 0");
			Exec("sv_kick_players_with_cooldown 0");
		}
		ClearEngineBans();
	}

	private static void ClearEngineBans()
	{
		Exec("removeallids");
		Exec("removeallips");
	}

	private HookResult OnEngineBan(CCSPlayerController? caller, CommandInfo command)
	{
		//IL_0001: Unknown result type (might be due to invalid IL or missing references)
		//IL_000c: Expected Obj, but got Unknown
		//IL_0025: Unknown result type (might be due to invalid IL or missing references)
		//IL_0030: Expected Obj, but got Unknown
		//IL_0059: Unknown result type (might be due to invalid IL or missing references)
		//IL_0064: Expected Obj, but got Unknown
		if ((CEntityInstance)caller != (CEntityInstance)null && !HasPerm(caller, "ban"))
		{
			return (HookResult)3;
		}
		CCSPlayerController val = null;
		for (int i = 1; i < command.ArgCount; i++)
		{
			if (!((CEntityInstance)val == (CEntityInstance)null))
			{
				break;
			}
			string arg = command.GetArg(i);
			val = FindPlayers(caller, arg, allowGroups: false, out var _).FirstOrDefault();
		}
		if ((CEntityInstance)val != (CEntityInstance)null)
		{
			FakeBanPlayer(val, caller, "", 0, command.GetArg(0));
		}
		return (HookResult)3;
	}

	private void FakeBanPlayer(CCSPlayerController target, CCSPlayerController? admin, string reason, int minutes, string source)
	{
		//IL_0015: Unknown result type (might be due to invalid IL or missing references)
		//IL_0020: Expected Obj, but got Unknown
		string text = (((CEntityInstance)admin == (CEntityInstance)null) ? "Console" : CleanName(((CBasePlayerController)admin).PlayerName));
		if (string.IsNullOrWhiteSpace(reason))
		{
			reason = Config.BanDefaultReason;
		}
		string text2 = CleanName(((CBasePlayerController)target).PlayerName);
		ulong steamID = ((CBasePlayerController)target).SteamID;
		BanSteam(steamID, text2, text, reason, minutes);
		WriteBanHistory(text2, steamID, text, ((CEntityInstance)(object)admin != (CEntityInstance)null) ? ((CBasePlayerController)admin).SteamID : 0, reason, minutes, source);
		string value = Config.BanBroadcast.Replace("{player}", text2).Replace("{admin}", text).Replace("{reason}", reason);
		Server.PrintToChatAll($" {ChatColors.Red}{Config.BanChatPrefix}{ChatColors.White} {value}");
		Console.WriteLine($"[Ban] {text2} ({steamID}) banned by {text} for {DurationText(minutes)}: {reason}");
		try
		{
			target.PrintToCenter(Config.BanChatPrefix + " You were banned. Reason: " + reason);
		}
		catch
		{
		}
		if (Config.BanDisconnectDelaySeconds > 0.05f)
		{
			((BasePlugin)this).AddTimer(Config.BanDisconnectDelaySeconds, (Action)Kick, null);
		}
		else
		{
			Server.NextFrame((Action)Kick);
		}
		void Kick()
		{
			//IL_0019: Unknown result type (might be due to invalid IL or missing references)
			if (((CEntityInstance)target).IsValid)
			{
				target.Disconnect(_banReason);
			}
		}
	}

	private void WriteBanHistory(string name, ulong steam, string admin, ulong adminSteam, string reason, int minutes, string source)
	{
		if (!Config.LogBanHistory)
		{
			return;
		}
		string text = DataPath(Config.BanHistoryFile);
		if (text == null)
		{
			LoggerExtensions.LogWarning(((BasePlugin)this).Logger, "BanHistoryFile is not a safe relative path; nothing written.", Array.Empty<object>());
			return;
		}
		try
		{
			string value = "";
			try
			{
				value = CvarString("hostname");
			}
			catch
			{
			}
			string text2 = JsonSerializer.Serialize(new Dictionary<string, object>
			{
				["time"] = DateTime.UtcNow.ToString("yyyy-MM-dd HH:mm:ss"),
				["server"] = value,
				["steamid"] = steam.ToString(),
				["name"] = name,
				["admin"] = admin,
				["adminsteamid"] = adminSteam.ToString(),
				["minutes"] = minutes,
				["reason"] = reason,
				["source"] = source
			});
			byte[] bytes = Encoding.UTF8.GetBytes(text2 + "\n");
			lock (_fileLock)
			{
				Directory.CreateDirectory(Path.GetDirectoryName(text));
				using FileStream fileStream = new FileStream(text, FileMode.Append, FileAccess.Write, FileShare.ReadWrite);
				fileStream.Write(bytes, 0, bytes.Length);
			}
		}
		catch (Exception ex)
		{
			LoggerExtensions.LogWarning(((BasePlugin)this).Logger, "Could not write the ban history: {M}", new object[1] { ex.Message });
		}
	}

	public ServerCommandsPlugin()
	{
		//IL_004a: Unknown result type (might be due to invalid IL or missing references)
	}
}
