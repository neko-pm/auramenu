#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <clientprefs>

#pragma newdecls required
#pragma semicolon 1

public Plugin myinfo = 
{
	name = "Player Auras with Menu",
	author = "domino_ | orginal by Sprilo",
	description = "Auras without a Store",
	version = "0.2.1",
	url = "https://forums.alliedmods.net/showthread.php?t=295597"
};

Handle db = INVALID_HANDLE;

enum CustomParticles
{
	String:szAuraName[PLATFORM_MAX_PATH],
	String:szParticleName[PLATFORM_MAX_PATH],
	String:szEffectName[PLATFORM_MAX_PATH],
	String:szSteamID[PLATFORM_MAX_PATH],
	String:szAdminFlags[PLATFORM_MAX_PATH],
	Float:fPosition[3],
	iCacheID,
}

#define CS_TEAM_SPECTATOR 1
#define MAX_CFG_PARTICLES 256

int g_eCustomParticles[MAX_CFG_PARTICLES+1][CustomParticles];
int g_iCustomParticlesCount;
int g_iClientParticleEntRef[MAXPLAYERS+1] = {INVALID_ENT_REFERENCE, ...};

Handle g_hCookieIndex;
int g_iAuraIndex[MAXPLAYERS+1];

Handle g_hCookieBlocked;
bool g_bBlockTransmit[MAXPLAYERS+1] = false;

ConVar g_cvHideUnavailable;
ConVar g_cvCreateTimer;
ConVar g_cvReopenMenu;

char sPath[PLATFORM_MAX_PATH];

public void OnPluginStart()
{
	LoadTranslations("dominoaura.phrases");
		
	RegConsoleCmd("sm_aura", Menu_Aura);
	RegConsoleCmd("sm_auras", Menu_Aura);
	
	RegConsoleCmd("sm_hideauras", Command_HideAuras);
	RegConsoleCmd("sm_hideaura", Command_HideAuras);
	RegConsoleCmd("sm_showauras", Command_HideAuras);
	RegConsoleCmd("sm_showaura", Command_HideAuras);
	
	RegAdminCmd("sm_reloadauras", Command_ReloadAuras, ADMFLAG_ROOT);
	
	g_hCookieIndex		= RegClientCookie("aura_index", "cookie for auras preference", CookieAccess_Private);
	g_hCookieBlocked	= RegClientCookie("aura_blocked", "cookie for block preference", CookieAccess_Private);
	
	g_cvHideUnavailable = CreateConVar("aura_hideunavailable", "1.0", "Should menu items be hidden if unavailable?", _, true, 0.0, true, 1.0);
	g_cvCreateTimer		= CreateConVar("aura_createtimer", "3.0", "How long after spawn should the particles be created?", _, true, 0.0, true, 30.0);
	g_cvReopenMenu		= CreateConVar("aura_reopen_menu", "0", "Should menu be reopened after selecting an aura?", _, true, 0.0, true, 1.0);
	
	BuildPath(Path_SM, sPath, PLATFORM_MAX_PATH, "configs/dominoaura.cfg");
	
	if(!LoadAurasFromConfig())
		SetFailState("%T", "Console Reload Auras", LANG_SERVER);
	
	HookEvent("player_spawn", Particles_PlayerSpawn);
	HookEvent("player_death", Particles_PlayerDeath);
	HookEvent("player_team", Particles_PlayerTeam, EventHookMode_Post);
	
	//for late load
	for(int i = 1; i <= MaxClients; i++){ if(IsValidClient(i) && IsPlayerAlive(i)){ OnClientCookiesCached(i); CreateCustomParticle(i); }}
}

public void OnPluginEnd()
{
	for(int i = 1; i <= MaxClients; i++){ if(IsValidClient(i)){ RemoveCustomParticle(i);}}
}

/* DATABASE */
public void OnMapStart()
{
	char[] error = new char[PLATFORM_MAX_PATH];
	db = SQL_Connect("clientprefs", true, error, PLATFORM_MAX_PATH);
	
	if (!LibraryExists("clientprefs") || db == INVALID_HANDLE)
		SetFailState("clientpref error: %s", error);
	
	PrecacheParticles();
}

public void OnMapEnd()
{
	CloseHandle(db);
}

/* MENU */
public Action Menu_Aura(int iClient, int iArgs)
{
	Menu menu = new Menu(MenuHandler_Aura, MENU_ACTIONS_ALL);
	menu.SetTitle("%T", "Aura Menu Title", iClient);
	
	for(int i = 0; i < g_iCustomParticlesCount; i++)
	{
		char[] sIndex = new char[3];
		IntToString(i, sIndex, 3);
		menu.AddItem(sIndex, g_eCustomParticles[i][szAuraName]);
	}
	
	menu.ExitButton = true;
	menu.Display(iClient, 30);
 
	return Plugin_Handled;
}

public int MenuHandler_Aura(Menu menu, MenuAction action, int param1, int param2)
{
	switch(action)
	{
		case MenuAction_Select:
		{
			char[] info = new char[32];
			menu.GetItem(param2, info, 32);
			
			g_iAuraIndex[param1] = StringToInt(info);
			
			RemoveCustomParticle(param1);
			CreateCustomParticle(param1);
			
			SetCookie(param1, g_hCookieIndex, g_iAuraIndex[param1]);
			
			if(g_cvReopenMenu.IntValue > 0)
				DisplayMenuAtItem(menu, param1, GetMenuSelectionPosition(), MENU_TIME_FOREVER);
		}
		case MenuAction_DisplayItem:
		{
			char[] sDisplay = new char[64];
			menu.GetItem(param2, "", 0, _, sDisplay, 64);
			
			if(StrEqual(sDisplay, "NoAuraTranslation", false))
			{
				char[] sBuffer = new char[64];
				FormatEx(sBuffer, 64, "%T", "No Aura", param1);
				return RedrawMenuItem(sBuffer);
			}
		}
		case MenuAction_DrawItem:
		{
			char[] sAuth = new char[32];
			GetClientAuthId(param1, AuthId_Steam2, sAuth, 32, true);
			
			char[] info = new char[32];
			menu.GetItem(param2, info, 32);
			
 			int iIndex = StringToInt(info);
 			
			if(StrEqual(sAuth, g_eCustomParticles[iIndex][szSteamID], false))
			{
				return ITEMDRAW_DEFAULT;
			}
			int bFlags = ReadFlagString(g_eCustomParticles[iIndex][szAdminFlags]);
			if(bFlags > 0 && CheckCommandAccess(param1, "cmd_aura_access_override", bFlags))
			{
				return ITEMDRAW_DEFAULT;
			}
			if(bFlags == 0 && StrEqual("", g_eCustomParticles[iIndex][szSteamID], false))
			{
				return ITEMDRAW_DEFAULT;
			}
			else
			{
				if(g_cvHideUnavailable.BoolValue)
					return ITEMDRAW_IGNORE;
				
				return ITEMDRAW_DISABLED;
			}
		}
		case MenuAction_End:
		{
			CloseHandle(menu);
		}
	}
	return 0;
}

/* COMMANDS */
public Action Command_HideAuras(int iClient, int iArgs)
{
	if(!g_bBlockTransmit[iClient])
	{
		g_bBlockTransmit[iClient] = true;
		SetCookie(iClient, g_hCookieBlocked, g_bBlockTransmit[iClient]);
		PrintToChat(iClient, "%t", "Chat Auras Disabled"); //"\x01[\x0BAura\x01] You can no longer see \x04Auras"
	}
	else if(g_bBlockTransmit[iClient])
	{
		g_bBlockTransmit[iClient] = false;
		SetCookie(iClient, g_hCookieBlocked, g_bBlockTransmit[iClient]);
		PrintToChat(iClient, "%t", "Chat Auras Enabled"); //"\x01[\x0BAura\x01] You can now see \x04Auras"
	}
	return Plugin_Handled;
}

public Action Command_ReloadAuras(int iClient, int iArgs)
{
	if(!LoadAurasFromConfig())
		ReplyToCommand(iClient, "%t", "Chat Reload Failed"); //"\x01[\x0BAura\x01] \x04Auras\x01 failed to reload";
	
	//reset all g_iAuraIndex[] to 0 and remove existing auras
	for(int i = 1; i <= MaxClients; i++){ if(IsValidClient(i)){ g_iAuraIndex[i] = 0; if(IsPlayerAlive(i)){ RemoveCustomParticle(i); }}}
	
	//SQLite query to remove all aura_index cookies, this stops people having new auras that they're not allowed to have.
	char[] query = new char[512];
	FormatEx(query, 512, "DELETE FROM sm_cookie_cache WHERE EXISTS( SELECT * FROM sm_cookies WHERE sm_cookie_cache.cookie_id = sm_cookies.id AND sm_cookies.name = 'aura_index');");
	SQL_TQuery(db, ClientPref_PurgeCallback, query);
	
	ReplyToCommand(iClient, "%t", "Chat Reloaded Auras"); //"\x01[\x0BAura\x01] \x04Auras\x01 have been reloaded"
}

public void ClientPref_PurgeCallback(Handle owner, Handle handle, const char[] error, any data)
{
	if (SQL_GetAffectedRows(owner))
		LogMessage("%T", "SQLite Callback", LANG_SERVER, SQL_GetAffectedRows(owner));
}

/* CLIENTPREF */
public void OnClientPostAdminCheck(int iClient)
{
	if(AreClientCookiesCached(iClient))
		OnClientCookiesCached(iClient);
}

public void OnClientCookiesCached(int iClient)
{
	if(!IsValidClient(iClient))
		return;
	
	char[] strCookie = new char[4];
	
	GetClientCookie(iClient, g_hCookieIndex, strCookie, 4);
	if(StrEqual(strCookie, ""))
		g_iAuraIndex[iClient] = 0;
	else
		g_iAuraIndex[iClient] = StringToInt(strCookie);
	
	GetClientCookie(iClient, g_hCookieBlocked, strCookie, 4);
	if(StrEqual(strCookie, ""))
		g_bBlockTransmit[iClient] = false;
	else
		g_bBlockTransmit[iClient] = view_as<bool>(StringToInt(strCookie));
}

public void SetCookie(int iClient, Handle hCookie, int n)
{
	char[] strCookie = new char[4];
	
	IntToString(n, strCookie, 4);
	SetClientCookie(iClient, hCookie, strCookie);
}

/* PARTICLES */
public Action Hook_SetTransmit(int iEntity, int iClient)
{
	setFlags(iEntity);
	if(g_bBlockTransmit[iClient])
	{
		return Plugin_Handled;	
	}
	return Plugin_Continue;
}

void setFlags(int edict)
{
    if (GetEdictFlags(edict) & FL_EDICT_ALWAYS)
    {
        SetEdictFlags(edict, (GetEdictFlags(edict) ^ FL_EDICT_ALWAYS));
    }
}

public void PrecacheParticles()
{
	if(g_iCustomParticlesCount > 1)
	{
		PrecacheEffect("ParticleEffect");
		
		for(int i = 1; i < g_iCustomParticlesCount; i++)
		{
			if(!IsModelPrecached(g_eCustomParticles[i][szParticleName]))
			{	
				g_eCustomParticles[i][iCacheID] = PrecacheGeneric(g_eCustomParticles[i][szParticleName], true);
				AddFileToDownloadsTable(g_eCustomParticles[i][szParticleName]);
				
				PrecacheParticleEffect(g_eCustomParticles[i][szEffectName]);
			}
		}
	}
} 

public Action Particles_PlayerSpawn(Handle event, const char[] name, bool dontBroadcast)
{
	int iClient = GetClientOfUserId(GetEventInt(event, "userid"));
	if(!IsClientInGame(iClient) || !IsPlayerAlive(iClient) || !(GetClientTeam(iClient) > CS_TEAM_SPECTATOR))
		return Plugin_Continue;
	
	CreateTimer(g_cvCreateTimer.FloatValue, Timer_CreateParticle, iClient);

	return Plugin_Continue;		
}

public Action Particles_PlayerDeath(Handle event, const char[] name, bool dontBroadcast)
{
	int iClient = GetClientOfUserId(GetEventInt(event, "userid"));
	
	if(IsValidClient(iClient))
		RemoveCustomParticle(iClient);
	
	return Plugin_Continue;
}

public Action Particles_PlayerTeam(Handle event, const char[] name, bool dontBroadcast)
{
	int iClient = GetClientOfUserId(GetEventInt(event, "userid"));
	
	if(IsValidClient(iClient))
		RemoveCustomParticle(iClient);
	
	return Plugin_Continue;
}

public Action Timer_CreateParticle(Handle timer, any iClient)
{
	if(IsValidClient(iClient) && IsPlayerAlive(iClient))
		CreateCustomParticle(iClient);		
}

void CreateCustomParticle(int iClient)
{	
	if(!IsValidClient(iClient))
		return;
	
	if(g_iAuraIndex[iClient] < 1)
		return;
	
	RemoveCustomParticle(iClient);
	
	if(!IsPlayerAlive(iClient))
		return;
	
	if(g_iClientParticleEntRef[iClient] != INVALID_ENT_REFERENCE)
		return;
			
	int m_iData = g_iAuraIndex[iClient];
	
	int m_unEnt = CreateEntityByName("info_particle_system");
	if (IsValidEntity(m_unEnt))
	{
		DispatchKeyValue(m_unEnt, "start_active", "1");
		DispatchKeyValue(m_unEnt, "effect_name", g_eCustomParticles[m_iData][szEffectName]);
		DispatchSpawn(m_unEnt);
		
		float m_flPosition[3];
		GetClientAbsOrigin(iClient, m_flPosition);
		
		m_flPosition[0] += g_eCustomParticles[m_iData][fPosition][0];
		m_flPosition[1] += g_eCustomParticles[m_iData][fPosition][1];
		m_flPosition[2] += g_eCustomParticles[m_iData][fPosition][2];

		TeleportEntity(m_unEnt, m_flPosition, NULL_VECTOR, NULL_VECTOR);
	   
		SetVariantString("!activator");
		AcceptEntityInput(m_unEnt, "SetParent", iClient, m_unEnt, 0);		
		
		ActivateEntity(m_unEnt);
		
		g_iClientParticleEntRef[iClient] = EntIndexToEntRef(m_unEnt);
		
		SetEdictFlags(m_unEnt, GetEdictFlags(m_unEnt)&(~FL_EDICT_ALWAYS)); //to allow settransmit hooks
		SDKHookEx(m_unEnt, SDKHook_SetTransmit, Hook_SetTransmit);
	}
}

public void RemoveCustomParticle(int iClient)
{
	if(g_iClientParticleEntRef[iClient] == INVALID_ENT_REFERENCE)
		return;
	
	int m_unEnt = EntRefToEntIndex(g_iClientParticleEntRef[iClient]);
	g_iClientParticleEntRef[iClient] = INVALID_ENT_REFERENCE;
	
	if(!IsValidEntity(m_unEnt))
		return;
	
	AcceptEntityInput(m_unEnt, "DestroyImmediately"); //some particles don't disappear without this
	CreateTimer(1.0, KillCustomParticle, m_unEnt); 
}

public Action KillCustomParticle(Handle timer, int m_unEnt)
{
	if(IsValidEntity(m_unEnt))
		AcceptEntityInput(m_unEnt, "kill");
}

public void OnClientDisconnect(int iClient)
{
	g_iAuraIndex[iClient] = 0;
}

/* CONFIG */
public bool LoadAurasFromConfig()
{
	g_iCustomParticlesCount = 0;
	
	strcopy(g_eCustomParticles[g_iCustomParticlesCount][szAuraName], PLATFORM_MAX_PATH, "NoAuraTranslation");
	g_iCustomParticlesCount++;
	
	KeyValues kv = new KeyValues("dominoaura");
	kv.ImportFromFile(sPath);

	kv.JumpToKey("auras");
	
	if (!kv.GotoFirstSubKey())
		return false;
		
	do {
		float m_fTemp[3];
		
		kv.GetSectionName(g_eCustomParticles[g_iCustomParticlesCount][szAuraName], PLATFORM_MAX_PATH);
		kv.GetString("particlename", g_eCustomParticles[g_iCustomParticlesCount][szParticleName], PLATFORM_MAX_PATH);
		kv.GetString("effectname", g_eCustomParticles[g_iCustomParticlesCount][szEffectName], PLATFORM_MAX_PATH);
		kv.GetString("steamid", g_eCustomParticles[g_iCustomParticlesCount][szSteamID], PLATFORM_MAX_PATH, "");
		kv.GetString("flags", g_eCustomParticles[g_iCustomParticlesCount][szAdminFlags], PLATFORM_MAX_PATH, "");
		kv.GetVector("position", m_fTemp);
		
		g_eCustomParticles[g_iCustomParticlesCount][fPosition] = m_fTemp;
		
		g_iCustomParticlesCount++;
	} while (kv.GotoNextKey());
	
	PrecacheParticles();
	
	PrintToServer("%T", "Console Reload Auras", LANG_SERVER, g_iCustomParticlesCount-1);
	
	delete kv;
	return true;
}

/* STOCKS */
/**
 * Fix for "Attempted to precache unknown particle system"
 * https://forums.alliedmods.net/showpost.php?p=2471747&postcount=4
 *
 * @param sEffectName		"ParticleEffect".
 * @noreturn
 */
stock void PrecacheEffect(const char[] sEffectName)
{
    static int table = INVALID_STRING_TABLE;
    
    if (table == INVALID_STRING_TABLE)
        table = FindStringTable("EffectDispatch");
	
    bool save = LockStringTables(false);
    AddToStringTable(table, sEffectName);
    LockStringTables(save);
}

/**
 * Fix for "Attempted to precache unknown particle system"
 * https://forums.alliedmods.net/showpost.php?p=2471747&postcount=4
 *
 * @param sEffectName		String containing particle effect name.
 * @noreturn
 */
stock void PrecacheParticleEffect(const char[] sEffectName)
{
    static int table = INVALID_STRING_TABLE;
    
    if (table == INVALID_STRING_TABLE)
        table = FindStringTable("ParticleEffectNames");
	
    bool save = LockStringTables(false);
    AddToStringTable(table, sEffectName);
    LockStringTables(save);
}

stock bool IsValidClient(int iClient, bool noBots = true)
{ 
    if (iClient <= 0 || iClient > MaxClients || !IsClientConnected(iClient) || !IsClientAuthorized(iClient) || (noBots && IsFakeClient(iClient)))
		return false;
	
    return IsClientInGame(iClient);
}