#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <tf2_stocks>

#define PL_VERSION "1.0"

#define TF_CLASS_DEMOMAN		4
#define TF_CLASS_ENGINEER		9
#define TF_CLASS_HEAVY			6
#define TF_CLASS_MEDIC			5
#define TF_CLASS_PYRO			7
#define TF_CLASS_SCOUT			1
#define TF_CLASS_SNIPER			2
#define TF_CLASS_SOLDIER		3
#define TF_CLASS_SPY			8
#define TF_CLASS_UNKNOWN		0

#define TF_TEAM_BLU				3
#define TF_TEAM_RED				2

/* Plugin Info */

public Plugin myinfo =
{
	name        = "TF2 Class Restrictions",
	author      = "Tsunami (updated by ratawar)",
	description = "Restrict classes in TF2.",
	version     = PL_VERSION,
	url         = "http://www.tsunami-productions.nl"
}

/* Global Handles and Variables */

ConVar g_cvEnabled, g_cvEnableSounds, g_cvFlags, g_cvImmunity;
ConVar g_cvLimits[4][10];

int g_iClass[MAXPLAYERS + 1];
char g_sSounds[10][24] = {"", "vo/scout_no03.mp3",
							  "vo/sniper_no04.mp3", 
							  "vo/soldier_no01.mp3",
							  "vo/demoman_no03.mp3",
							  "vo/medic_no03.mp3",  
							  "vo/heavy_no02.mp3",
							  "vo/pyro_no01.mp3",
							  "vo/spy_no02.mp3",
							  "vo/engineer_no03.mp3"};

/* Plugin Start */

public void OnPluginStart()
{
	CreateConVar("sm_classrestrict_version", PL_VERSION, "Restrict classes in TF2.", FCVAR_SPONLY | FCVAR_REPLICATED | FCVAR_NOTIFY);
	
	g_cvEnabled                                = CreateConVar("sm_classrestrict_enabled",       "1",  "Enable/disable restricting classes in TF2.");
	g_cvFlags                                  = CreateConVar("sm_classrestrict_flags",         "",   "Admin flags for restricted classes in TF2.");
	g_cvImmunity                               = CreateConVar("sm_classrestrict_immunity",      "0",  "Enable/disable admins being immune for restricted classes in TF2.");
	g_cvEnableSounds 						   = CreateConVar("sm_classrestrict_sounds",       "1",  "Enable/disable sound effects on class restricts.");
	
	g_cvLimits[TF_TEAM_BLU][TF_CLASS_DEMOMAN]  = CreateConVar("sm_classrestrict_blu_demomen",   "-1", "Limit for Blu demomen in TF2.");
	g_cvLimits[TF_TEAM_BLU][TF_CLASS_ENGINEER] = CreateConVar("sm_classrestrict_blu_engineers", "-1", "Limit for Blu engineers in TF2.");
	g_cvLimits[TF_TEAM_BLU][TF_CLASS_HEAVY]    = CreateConVar("sm_classrestrict_blu_heavies",   "-1", "Limit for Blu heavies in TF2.");
	g_cvLimits[TF_TEAM_BLU][TF_CLASS_MEDIC]    = CreateConVar("sm_classrestrict_blu_medics",    "-1", "Limit for Blu medics in TF2.");
	g_cvLimits[TF_TEAM_BLU][TF_CLASS_PYRO]     = CreateConVar("sm_classrestrict_blu_pyros",     "-1", "Limit for Blu pyros in TF2.");
	g_cvLimits[TF_TEAM_BLU][TF_CLASS_SCOUT]    = CreateConVar("sm_classrestrict_blu_scouts",    "-1", "Limit for Blu scouts in TF2.");
	g_cvLimits[TF_TEAM_BLU][TF_CLASS_SNIPER]   = CreateConVar("sm_classrestrict_blu_snipers",   "-1", "Limit for Blu snipers in TF2.");
	g_cvLimits[TF_TEAM_BLU][TF_CLASS_SOLDIER]  = CreateConVar("sm_classrestrict_blu_soldiers",  "-1", "Limit for Blu soldiers in TF2.");
	g_cvLimits[TF_TEAM_BLU][TF_CLASS_SPY]      = CreateConVar("sm_classrestrict_blu_spies",     "-1", "Limit for Blu spies in TF2.");
	
	g_cvLimits[TF_TEAM_RED][TF_CLASS_DEMOMAN]  = CreateConVar("sm_classrestrict_red_demomen",   "-1", "Limit for Red demomen in TF2.");
	g_cvLimits[TF_TEAM_RED][TF_CLASS_ENGINEER] = CreateConVar("sm_classrestrict_red_engineers", "-1", "Limit for Red engineers in TF2.");
	g_cvLimits[TF_TEAM_RED][TF_CLASS_HEAVY]    = CreateConVar("sm_classrestrict_red_heavies",   "-1", "Limit for Red heavies in TF2.");
	g_cvLimits[TF_TEAM_RED][TF_CLASS_MEDIC]    = CreateConVar("sm_classrestrict_red_medics",    "-1", "Limit for Red medics in TF2.");
	g_cvLimits[TF_TEAM_RED][TF_CLASS_PYRO]     = CreateConVar("sm_classrestrict_red_pyros",     "-1", "Limit for Red pyros in TF2.");
	g_cvLimits[TF_TEAM_RED][TF_CLASS_SCOUT]    = CreateConVar("sm_classrestrict_red_scouts",    "-1", "Limit for Red scouts in TF2.");
	g_cvLimits[TF_TEAM_RED][TF_CLASS_SNIPER]   = CreateConVar("sm_classrestrict_red_snipers",   "-1", "Limit for Red snipers in TF2.");
	g_cvLimits[TF_TEAM_RED][TF_CLASS_SOLDIER]  = CreateConVar("sm_classrestrict_red_soldiers",  "-1", "Limit for Red soldiers in TF2.");
	g_cvLimits[TF_TEAM_RED][TF_CLASS_SPY]      = CreateConVar("sm_classrestrict_red_spies",     "-1", "Limit for Red spies in TF2.");
	
	HookEvent("player_changeclass", Event_PlayerClass);
	HookEvent("player_spawn",       Event_PlayerSpawn);
	HookEvent("player_team",        Event_PlayerTeam);
}

public void OnConfigsExecuted()
{
	
	if (g_cvEnableSounds.BoolValue) {
		PrintToServer("[ClassRestrict] Sound effects enabled!");
		char sSound[32];
	
		for (int i = 1; i < sizeof(g_sSounds); i++) {
			
			Format(sSound, sizeof(sSound), "sound/%s", g_sSounds[i]);
			PrecacheSound(g_sSounds[i]);
			//AddFileToDownloadsTable(sSound);
		}
		return;
	}
	
	PrintToServer("[ClassRestrict] Sound effects disabled!");
}

public void OnClientPutInServer(int client)
{
	g_iClass[client] = TF_CLASS_UNKNOWN;
}

public void Event_PlayerClass(Handle event, const char[] name, bool dontBroadcast)
{
	int iClient = GetClientOfUserId(GetEventInt(event, "userid"));
	int iClass = GetEventInt(event, "class");
	int iTeam = GetClientTeam(iClient);
	
	if (!(g_cvImmunity.BoolValue && IsImmune(iClient)) && IsFull(iTeam, iClass))
	{
		ShowVGUIPanel(iClient, iTeam == TF_TEAM_BLU ? "class_blue" : "class_red");
		TF2_SetPlayerClass(iClient, view_as<TFClassType>(g_iClass[iClient]));
		if (g_cvEnableSounds.BoolValue)
			EmitSoundToClient(iClient, g_sSounds[iClass]);
	}
}

public void Event_PlayerSpawn(Handle event, char[] name, bool dontBroadcast)
{
	int iClient = GetClientOfUserId(GetEventInt(event, "userid"));
	int iTeam = GetClientTeam(iClient);
	
	if (!(g_cvImmunity.BoolValue && IsImmune(iClient)) && IsFull(iTeam, (g_iClass[iClient] = view_as<int>(TF2_GetPlayerClass(iClient)))))
	{
		ShowVGUIPanel(iClient, iTeam == TF_TEAM_BLU ? "class_blue" : "class_red");
		PickClass(iClient);
		if (g_cvEnableSounds.BoolValue)
			EmitSoundToClient(iClient, g_sSounds[g_iClass[iClient]]);
	}
}

public void Event_PlayerTeam(Handle event, char[] name, bool dontBroadcast)
{
	int iClient = GetClientOfUserId(GetEventInt(event, "userid"));
	int iTeam   = GetEventInt(event, "team");
	
	if (!(g_cvImmunity.BoolValue && IsImmune(iClient)) && IsFull(iTeam, g_iClass[iClient]))
	{
		ShowVGUIPanel(iClient, iTeam == TF_TEAM_BLU ? "class_blue" : "class_red");
		PickClass(iClient);
		if (g_cvEnableSounds.BoolValue)
			EmitSoundToClient(iClient, g_sSounds[g_iClass[iClient]]);
	}
}

bool IsFull(int iTeam, int iClass)
{
	// If plugin is disabled, or team or class is invalid, class is not full
	if (!g_cvEnabled.BoolValue || iTeam < TF_TEAM_RED || iClass < TF_CLASS_SCOUT)
		return false;
	
	// Get team's class limit
	int iLimit;
	float flLimit = g_cvLimits[iTeam][iClass].FloatValue;
	
	// If limit is a percentage, calculate real limit
	if (flLimit > 0.0 && flLimit < 1.0)
		iLimit = RoundToNearest(flLimit * GetTeamClientCount(iTeam));
	else
		iLimit = RoundToNearest(flLimit);
	
	// If limit is -1, class is not full
	if (iLimit == -1)
		return false;
	// If limit is 0, class is full
	else if (iLimit == 0)
		return true;
	
	// Loop through all clients
	for (int i = 1, iCount = 0; i <= MaxClients; i++)
	{
		// If client is in game, on this team, has this class and limit has been reached, class is full
		if (IsClientInGame(i) && GetClientTeam(i) == iTeam && view_as<int>(TF2_GetPlayerClass(i)) == iClass && ++iCount > iLimit)
			return true;
	}
	
	return false;
}

bool IsImmune(int iClient)
{
	if (!iClient || !IsClientInGame(iClient))
		return false;
	
	char sFlags[32];
	g_cvFlags.GetString(sFlags, sizeof(sFlags));
	
	// If flags are specified and client has generic or root flag, client is immune
	return !StrEqual(sFlags, "") && GetUserFlagBits(iClient) & (ReadFlagString(sFlags)|ADMFLAG_ROOT);
}

void PickClass(int iClient)
{
	// Loop through all classes, starting at random class
	for (int i = GetRandomInt(TF_CLASS_SCOUT, TF_CLASS_ENGINEER), iClass = i, iTeam = GetClientTeam(iClient);;)
	{
		// If team's class is not full, set client's class
		if (!IsFull(iTeam, i))
		{
			g_iClass[iClient] = i;
			TF2_SetPlayerClass(iClient, view_as<TFClassType>(i));
			TF2_RespawnPlayer(iClient);
			break;
		}
		// If next class index is invalid, start at first class
		else if (++i > TF_CLASS_ENGINEER)
		{
			i = TF_CLASS_SCOUT;
		}
		// If loop has finished, stop searching
		else if (i == iClass)
		{
			TF2_ChangeClientTeam(iClient, TFTeam_Spectator);
			break;
		}
	}
}
