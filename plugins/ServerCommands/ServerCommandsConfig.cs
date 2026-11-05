using System.Collections.Generic;
using System.Text.Json.Serialization;
using CounterStrikeSharp.API.Core;

namespace ServerCommands;

public class ServerCommandsConfig : BasePluginConfig
{
	[JsonPropertyName("ConfigVersion")]
	public override int Version { get; set; } = 1;

	[JsonPropertyName("OwnerSteamIds")]
	public List<string> OwnerSteamIds { get; set; } = new List<string> { "76561198768187147" };

	[JsonPropertyName("AdminConfigDir")]
	public string AdminConfigDir { get; set; } = "";

	[JsonPropertyName("ApplyNameTags")]
	public bool ApplyNameTags { get; set; } = true;

	[JsonPropertyName("DefaultAdminTag")]
	public string DefaultAdminTag { get; set; } = "ADMIN";

	[JsonPropertyName("OwnerTag")]
	public string OwnerTag { get; set; } = "OWNER";

	[JsonPropertyName("TagPresets")]
	public List<string> TagPresets { get; set; } = new List<string> { "OWNER", "ADMIN", "MOD", "HELPER", "VIP" };

	[JsonPropertyName("NewAdminPermissions")]
	public List<string> NewAdminPermissions { get; set; } = new List<string>
	{
		"plist", "kick", "gag", "ungag", "mute", "unmute", "map", "spectate", "slap", "slay",
		"respawn", "move", "admincmd", "votekick"
	};

	[JsonPropertyName("NewAdminImmunity")]
	public int NewAdminImmunity { get; set; } = 50;

	[JsonPropertyName("ChatPrefix")]
	public string ChatPrefix { get; set; } = "[Server]";

	[JsonPropertyName("DefaultPunishMinutes")]
	public int DefaultPunishMinutes { get; set; } = 30;

	[JsonPropertyName("PunishMinutesMenu")]
	public List<int> PunishMinutesMenu { get; set; } = new List<int> { 5, 15, 60, 1440, 0 };

	[JsonPropertyName("CashMenu")]
	public List<int> CashMenu { get; set; } = new List<int> { 1000, 2500, 5000, 10000, 16000 };

	[JsonPropertyName("SlapDamageMenu")]
	public List<int> SlapDamageMenu { get; set; } = new List<int> { 0, 5, 10, 25, 50 };

	[JsonPropertyName("FreezeTimeMenu")]
	public List<int> FreezeTimeMenu { get; set; } = new List<int> { 0, 3, 5, 10, 15, 20 };

	[JsonPropertyName("MaxRoundsMenu")]
	public List<int> MaxRoundsMenu { get; set; } = new List<int> { 8, 12, 16, 24, 30 };

	[JsonPropertyName("VoteKickSeconds")]
	public int VoteKickSeconds { get; set; } = 30;

	[JsonPropertyName("KnifeRoundChoiceSeconds")]
	public int KnifeRoundChoiceSeconds { get; set; } = 30;

	[JsonPropertyName("Maps")]
	public List<string> Maps { get; set; } = new List<string>
	{
		"de_dust2", "de_mirage", "de_inferno", "de_nuke", "de_overpass", "de_ancient", "de_anubis", "de_vertigo", "de_train", "de_cache",
		"de_jura", "de_grail", "de_edin", "de_palais", "cs_office", "cs_italy", "cs_agency"
	};

	[JsonPropertyName("WorkshopMaps")]
	public Dictionary<string, string> WorkshopMaps { get; set; } = new Dictionary<string, string>();

	[JsonPropertyName("Modes")]
	public Dictionary<string, ModeConfig> Modes { get; set; } = new Dictionary<string, ModeConfig>
	{
		["casual"] = new ModeConfig
		{
			Label = "Casual",
			ChangeLevel = false,
			Restart = true,
			Commands = 
			{
				"mp_friendlyfire 0", "mp_timelimit 0", "mp_maxrounds 15", "mp_halftime 0", "mp_roundtime 3", "mp_freezetime 5", "mp_buytime 45", "mp_startmoney 1000", "mp_maxmoney 10000", "mp_limitteams 0",
				"mp_autoteambalance 0", "mp_solid_teammates 0", "sv_deadtalk 1", "mp_death_drop_gun 1", "mp_respawn_on_death_ct 0", "mp_respawn_on_death_t 0", "mp_ignore_round_win_conditions 0", "mp_teammates_are_enemies 0", "sv_infinite_ammo 0", "mp_buy_anywhere 0"
			}
		},
		["comp"] = new ModeConfig
		{
			Label = "Competitive",
			ChangeLevel = false,
			Restart = true,
			Commands = 
			{
				"mp_friendlyfire 1", "mp_timelimit 0", "mp_maxrounds 24", "mp_halftime 1", "mp_roundtime 1.92", "mp_freezetime 15", "mp_buytime 20", "mp_startmoney 800", "mp_maxmoney 16000", "mp_limitteams 1",
				"mp_autoteambalance 1", "mp_solid_teammates 1", "sv_deadtalk 0", "mp_death_drop_gun 1", "mp_respawn_on_death_ct 0", "mp_respawn_on_death_t 0", "mp_ignore_round_win_conditions 0", "mp_teammates_are_enemies 0", "sv_infinite_ammo 0", "mp_buy_anywhere 0"
			}
		},
		["dm"] = new ModeConfig
		{
			Label = "Deathmatch",
			ChangeLevel = false,
			Restart = true,
			Commands = 
			{
				"mp_timelimit 15", "mp_maxrounds 0", "mp_halftime 0", "mp_roundtime 60", "mp_freezetime 0", "mp_buytime 0", "mp_respawn_on_death_ct 1", "mp_respawn_on_death_t 1", "mp_ignore_round_win_conditions 1", "mp_teammates_are_enemies 1",
				"mp_solid_teammates 0", "mp_limitteams 0", "mp_autoteambalance 0", "mp_death_drop_gun 0", "mp_friendlyfire 1", "sv_infinite_ammo 0"
			}
		},
		["mix"] = new ModeConfig
		{
			Label = "Mix",
			ChangeLevel = false,
			Restart = true,
			Commands = 
			{
				"mp_friendlyfire 1", "mp_timelimit 0", "mp_maxrounds 24", "mp_halftime 1", "mp_roundtime 1.92", "mp_freezetime 15", "mp_buytime 20", "mp_startmoney 800", "mp_maxmoney 16000", "mp_limitteams 1",
				"mp_autoteambalance 0", "mp_solid_teammates 1", "mp_respawn_on_death_ct 0", "mp_respawn_on_death_t 0", "mp_ignore_round_win_conditions 0", "mp_autokick 0", "mp_teammates_are_enemies 0"
			}
		},
		["aim"] = new ModeConfig
		{
			Label = "Aim",
			ChangeLevel = false,
			Restart = true,
			Commands = 
			{
				"mp_timelimit 10", "mp_maxrounds 0", "mp_halftime 0", "mp_roundtime 60", "mp_freezetime 0", "mp_buytime 0", "mp_startmoney 16000", "mp_maxmoney 16000", "mp_respawn_on_death_ct 1", "mp_respawn_on_death_t 1",
				"mp_ignore_round_win_conditions 1", "mp_teammates_are_enemies 1", "mp_solid_teammates 0", "mp_limitteams 0", "mp_autoteambalance 0", "mp_death_drop_gun 0", "sv_infinite_ammo 2", "mp_friendlyfire 1"
			}
		},
		["prac"] = new ModeConfig
		{
			Label = "Practice",
			ChangeLevel = false,
			Restart = true,
			Commands = 
			{
				"mp_warmup_pausetimer 1", "mp_freezetime 0", "mp_roundtime 60", "mp_roundtime_defuse 60", "mp_startmoney 65535", "mp_maxmoney 65535", "mp_buy_anywhere 1", "mp_buytime 99999", "mp_respawn_on_death_ct 1", "mp_respawn_on_death_t 1",
				"sv_infinite_ammo 1", "mp_limitteams 0", "mp_autoteambalance 0", "mp_teammates_are_enemies 0", "mp_friendlyfire 0", "mp_ignore_round_win_conditions 1", "sv_grenade_trajectory 1"
			}
		},
		["retakes"] = new ModeConfig
		{
			Label = "Retakes",
			ChangeLevel = false,
			Restart = true,
			Commands = { "mp_warmup_pausetimer 1", "mp_autoteambalance 0", "mp_limitteams 0", "mp_teammates_are_enemies 0", "mp_respawn_on_death_ct 0", "mp_respawn_on_death_t 0" }
		},
		["warmup"] = new ModeConfig
		{
			Label = "Warmup",
			ChangeLevel = false,
			Restart = false,
			Commands = { "mp_warmup_start", "mp_warmup_pausetimer 1" }
		}
	};

	[JsonPropertyName("BanDisconnectReason")]
	public string BanDisconnectReason { get; set; } = "NETWORK_DISCONNECT_BANADDED";

	[JsonPropertyName("BanDefaultReason")]
	public string BanDefaultReason { get; set; } = "No reason given";

	[JsonPropertyName("BanReasons")]
	public List<string> BanReasons { get; set; } = new List<string> { "Cheating", "Toxic behavior", "Griefing", "Team killing", "Other" };

	[JsonPropertyName("BanBroadcast")]
	public string BanBroadcast { get; set; } = "{player} was banned by {admin}. Reason: {reason}";

	[JsonPropertyName("BanChatPrefix")]
	public string BanChatPrefix { get; set; } = "[BAN]";

	[JsonPropertyName("BanDisconnectDelaySeconds")]
	public float BanDisconnectDelaySeconds { get; set; } = 1f;

	[JsonPropertyName("InterceptEngineBanCommands")]
	public bool InterceptEngineBanCommands { get; set; } = true;

	[JsonPropertyName("NoVoteKickBans")]
	public bool NoVoteKickBans { get; set; } = true;

	[JsonPropertyName("ClearEngineBansEverySeconds")]
	public int ClearEngineBansEverySeconds { get; set; } = 60;

	[JsonPropertyName("RespectImmunity")]
	public bool RespectImmunity { get; set; } = true;

	[JsonPropertyName("LogBanHistory")]
	public bool LogBanHistory { get; set; } = true;

	[JsonPropertyName("BanHistoryFile")]
	public string BanHistoryFile { get; set; } = "data/fakebans.jsonl";

	[JsonPropertyName("BansFile")]
	public string BansFile { get; set; } = "data/bans.json";

	[JsonPropertyName("BanKickMessage")]
	public string BanKickMessage { get; set; } = "{player} tried to join but is banned here. Reason: {reason}";

	[JsonPropertyName("PunishmentsFile")]
	public string PunishmentsFile { get; set; } = "data/punishments.json";
}
