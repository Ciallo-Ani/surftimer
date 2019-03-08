/*
 * shavit's Timer - World Records
 * by: shavit
 *
 * This file is part of shavit's Timer.
 *
 * This program is free software; you can redistribute it and/or modify it under
 * the terms of the GNU General Public License, version 3.0, as published by the
 * Free Software Foundation.
 *
 * This program is distributed in the hope that it will be useful, but WITHOUT
 * ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
 * FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more
 * details.
 *
 * You should have received a copy of the GNU General Public License along with
 * this program.  If not, see <http://www.gnu.org/licenses/>.
 *
*/

#include <sourcemod>

#undef REQUIRE_PLUGIN
#include <shavit>
#include <adminmenu>

#pragma newdecls required
#pragma semicolon 1

// #define DEBUG

enum struct wrcache_t
{
	int iLastStyle;
	int iLastTrack;
	bool bPendingMenu;
	char sClientMap[128];
}

bool gB_Late = false;
bool gB_Rankings = false;
bool gB_Stats = false;

// forwards
Handle gH_OnWorldRecord = null;
Handle gH_OnFinish_Post = null;
Handle gH_OnWRDeleted = null;
Handle gH_OnWorstRecord = null;

// database handle
Database gH_SQL = null;
bool gB_Connected = false;
bool gB_MySQL = false;

// cache
wrcache_t gA_WRCache[MAXPLAYERS+1];

char gS_Map[160]; // blame workshop paths being so fucking long
ArrayList gA_ValidMaps = null;
int gI_ValidMaps = 1;

// current wr stats
float gF_WRTime[STYLE_LIMIT][TRACKS_SIZE];
int gI_WRRecordID[STYLE_LIMIT][TRACKS_SIZE];
char gS_WRName[STYLE_LIMIT][TRACKS_SIZE][MAX_NAME_LENGTH];
int gI_RecordAmount[STYLE_LIMIT][TRACKS_SIZE];
ArrayList gA_Leaderboard[STYLE_LIMIT][TRACKS_SIZE];
float gF_PlayerRecord[MAXPLAYERS+1][STYLE_LIMIT][TRACKS_SIZE];

// admin menu
TopMenu gH_AdminMenu = null;
TopMenuObject gH_TimerCommands = INVALID_TOPMENUOBJECT;

// table prefix
char gS_MySQLPrefix[32];

// cvars
ConVar gCV_RecordsLimit = null;
ConVar gCV_RecentLimit = null;

// timer settings
int gI_Styles = 0;
stylestrings_t gS_StyleStrings[STYLE_LIMIT];
stylesettings_t gA_StyleSettings[STYLE_LIMIT];

// chat settings
chatstrings_t gS_ChatStrings;

public Plugin myinfo =
{
	name = "[shavit] World Records",
	author = "shavit",
	description = "World records for shavit's bhop timer.",
	version = SHAVIT_VERSION,
	url = "https://github.com/shavitush/bhoptimer"
}

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	// natives
	CreateNative("Shavit_GetClientPB", Native_GetClientPB);
	CreateNative("Shavit_GetPlayerPB", Native_GetPlayerPB);
	CreateNative("Shavit_GetRankForTime", Native_GetRankForTime);
	CreateNative("Shavit_GetRecordAmount", Native_GetRecordAmount);
	CreateNative("Shavit_GetTimeForRank", Native_GetTimeForRank);
	CreateNative("Shavit_GetWorldRecord", Native_GetWorldRecord);
	CreateNative("Shavit_GetWRName", Native_GetWRName);
	CreateNative("Shavit_GetWRRecordID", Native_GetWRRecordID);
	CreateNative("Shavit_GetWRTime", Native_GetWRTime);
	CreateNative("Shavit_ReloadLeaderboards", Native_ReloadLeaderboards);
	CreateNative("Shavit_WR_DeleteMap", Native_WR_DeleteMap);

	// registers library, check "bool LibraryExists(const char[] name)" in order to use with other plugins
	RegPluginLibrary("shavit-wr");

	gB_Late = late;

	return APLRes_Success;
}

public void OnAllPluginsLoaded()
{
	if(gH_SQL == null)
	{
		Shavit_OnDatabaseLoaded();
	}
}

public void OnPluginStart()
{
	LoadTranslations("shavit-common.phrases");
	LoadTranslations("shavit-wr.phrases");

	#if defined DEBUG
	RegConsoleCmd("sm_junk", Command_Junk);
	RegConsoleCmd("sm_printleaderboards", Command_PrintLeaderboards);
	#endif

	// forwards
	gH_OnWorldRecord = CreateGlobalForward("Shavit_OnWorldRecord", ET_Event, Param_Cell, Param_Cell, Param_Cell, Param_Cell, Param_Cell, Param_Cell, Param_Cell, Param_Cell, Param_Cell, Param_Cell);
	gH_OnFinish_Post = CreateGlobalForward("Shavit_OnFinish_Post", ET_Event, Param_Cell, Param_Cell, Param_Cell, Param_Cell, Param_Cell, Param_Cell, Param_Cell, Param_Cell, Param_Cell, Param_Cell, Param_Cell);
	gH_OnWRDeleted = CreateGlobalForward("Shavit_OnWRDeleted", ET_Event, Param_Cell, Param_Cell, Param_Cell);
	gH_OnWorstRecord = CreateGlobalForward("Shavit_OnWorstRecord", ET_Event, Param_Cell, Param_Cell, Param_Cell, Param_Cell, Param_Cell, Param_Cell, Param_Cell, Param_Cell, Param_Cell);

	// player commands
	RegConsoleCmd("sm_wr", Command_WorldRecord, "View the leaderboard of a map. Usage: sm_wr [map]");
	RegConsoleCmd("sm_worldrecord", Command_WorldRecord, "View the leaderboard of a map. Usage: sm_worldrecord [map]");

	RegConsoleCmd("sm_bwr", Command_WorldRecord_Bonus, "View the leaderboard of a map. Usage: sm_bwr [map]");
	RegConsoleCmd("sm_bworldrecord", Command_WorldRecord_Bonus, "View the leaderboard of a map. Usage: sm_bworldrecord [map]");
	RegConsoleCmd("sm_bonusworldrecord", Command_WorldRecord_Bonus, "View the leaderboard of a map. Usage: sm_bonusworldrecord [map]");

	RegConsoleCmd("sm_recent", Command_RecentRecords, "View the recent #1 times set.");
	RegConsoleCmd("sm_recentrecords", Command_RecentRecords, "View the recent #1 times set.");
	RegConsoleCmd("sm_rr", Command_RecentRecords, "View the recent #1 times set.");

	// delete records
	RegAdminCmd("sm_delete", Command_Delete, ADMFLAG_RCON, "Opens a record deletion menu interface.");
	RegAdminCmd("sm_deleterecord", Command_Delete, ADMFLAG_RCON, "Opens a record deletion menu interface.");
	RegAdminCmd("sm_deleterecords", Command_Delete, ADMFLAG_RCON, "Opens a record deletion menu interface.");
	RegAdminCmd("sm_deleteall", Command_DeleteAll, ADMFLAG_RCON, "Deletes all the records for this map.");
	RegAdminCmd("sm_deletestylerecords", Command_DeleteStyleRecords, ADMFLAG_RCON, "Deletes all the records for a style.");

	// cvars
	gCV_RecordsLimit = CreateConVar("shavit_wr_recordlimit", "50", "Limit of records shown in the WR menu.\nAdvised to not set above 1,000 because scrolling through so many pages is useless.\n(And can also cause the command to take long time to run)", 0, true, 1.0);
	gCV_RecentLimit = CreateConVar("shavit_wr_recentlimit", "50", "Limit of records shown in the RR menu.", 0, true, 1.0);

	AutoExecConfig();

	// admin menu
	if(LibraryExists("adminmenu") && ((gH_AdminMenu = GetAdminTopMenu()) != null))
	{
		OnAdminMenuReady(gH_AdminMenu);
	}

	// modules
	gB_Rankings = LibraryExists("shavit-rankings");
	gB_Stats = LibraryExists("shavit-stats");

	// cache
	gA_ValidMaps = new ArrayList(192);

	SQL_SetPrefix();
}

public void OnAdminMenuCreated(Handle topmenu)
{
	if(gH_AdminMenu == null || (topmenu == gH_AdminMenu && gH_TimerCommands != INVALID_TOPMENUOBJECT))
	{
		return;
	}

	gH_TimerCommands = gH_AdminMenu.AddCategory("Timer Commands", CategoryHandler, "shavit_admin", ADMFLAG_RCON);
}

public void CategoryHandler(Handle topmenu, TopMenuAction action, TopMenuObject object_id, int param, char[] buffer, int maxlength)
{
	if(action == TopMenuAction_DisplayTitle)
	{
		FormatEx(buffer, maxlength, "%T:", "TimerCommands", param);
	}

	else if(action == TopMenuAction_DisplayOption)
	{
		FormatEx(buffer, maxlength, "%T", "TimerCommands", param);
	}
}

public void OnAdminMenuReady(Handle topmenu)
{
	if((gH_AdminMenu = GetAdminTopMenu()) != null)
	{
		if(gH_TimerCommands == INVALID_TOPMENUOBJECT)
		{
			gH_TimerCommands = gH_AdminMenu.FindCategory("Timer Commands");

			if(gH_TimerCommands == INVALID_TOPMENUOBJECT)
			{
				OnAdminMenuCreated(topmenu);
			}
		}
		
		gH_AdminMenu.AddItem("sm_deleteall", AdminMenu_DeleteAll, gH_TimerCommands, "sm_deleteall", ADMFLAG_RCON);
		gH_AdminMenu.AddItem("sm_delete", AdminMenu_Delete, gH_TimerCommands, "sm_delete", ADMFLAG_RCON);
		gH_AdminMenu.AddItem("sm_deletestylerecords", AdminMenu_DeleteStyleRecords, gH_TimerCommands, "sm_deletestylerecords", ADMFLAG_RCON);
	}
}

public void AdminMenu_Delete(Handle topmenu, TopMenuAction action, TopMenuObject object_id, int param, char[] buffer, int maxlength)
{
	if(action == TopMenuAction_DisplayOption)
	{
		FormatEx(buffer, maxlength, "%t", "DeleteSingleRecord");
	}

	else if(action == TopMenuAction_SelectOption)
	{
		Command_Delete(param, 0);
	}
}

public void AdminMenu_DeleteAll(Handle topmenu,  TopMenuAction action, TopMenuObject object_id, int param, char[] buffer, int maxlength)
{
	if(action == TopMenuAction_DisplayOption)
	{
		FormatEx(buffer, maxlength, "%t", "DeleteAllRecords");
	}

	else if(action == TopMenuAction_SelectOption)
	{
		Command_DeleteAll(param, 0);
	}
}

public void AdminMenu_DeleteStyleRecords(Handle topmenu,  TopMenuAction action, TopMenuObject object_id, int param, char[] buffer, int maxlength)
{
	if(action == TopMenuAction_DisplayOption)
	{
		FormatEx(buffer, maxlength, "%t", "DeleteStyleRecords");
	}

	else if(action == TopMenuAction_SelectOption)
	{
		Command_DeleteStyleRecords(param, 0);
	}
}

public void OnLibraryAdded(const char[] name)
{
	if(StrEqual(name, "shavit-rankings"))
	{
		gB_Rankings = true;
	}

	else if(StrEqual(name, "shavit-stats"))
	{
		gB_Stats = true;
	}
}

public void OnLibraryRemoved(const char[] name)
{
	if(StrEqual(name, "shavit-rankings"))
	{
		gB_Rankings = false;
	}

	else if(StrEqual(name, "shavit-stats"))
	{
		gB_Stats = false;
	}

	else if(StrEqual(name, "adminmenu"))
	{
		delete gH_AdminMenu;
	}
}

public void OnMapStart()
{
	if(gH_SQL == null || !gB_Connected)
	{
		return;
	}

	GetCurrentMap(gS_Map, 160);
	GetMapDisplayName(gS_Map, gS_Map, 160);

	UpdateWRCache();

	char sLowerCase[160];
	strcopy(sLowerCase, 160, gS_Map);

	for(int i = 0; i < strlen(sLowerCase); i++)
	{
		if(!IsCharUpper(sLowerCase[i]))
		{
			sLowerCase[i] = CharToLower(sLowerCase[i]);
		}
	}

	gA_ValidMaps.Clear();
	gA_ValidMaps.PushString(sLowerCase);
	gI_ValidMaps = 1;

	char sQuery[128];
	FormatEx(sQuery, 128, "SELECT map FROM %smapzones GROUP BY map;", gS_MySQLPrefix);
	gH_SQL.Query(SQL_UpdateMaps_Callback, sQuery, 0, DBPrio_Low);

	if(gB_Late)
	{
		Shavit_OnStyleConfigLoaded(-1);
		Shavit_OnChatConfigLoaded();
	}
}

public void SQL_UpdateMaps_Callback(Database db, DBResultSet results, const char[] error, any data)
{
	if(results == null)
	{
		LogError("Timer (WR maps cache update) SQL query failed. Reason: %s", error);

		return;
	}

	while(results.FetchRow())
	{
		char sMap[192];
		results.FetchString(0, sMap, 192);

		char sLowerCase[128];
		strcopy(sLowerCase, 128, sMap);

		for(int i = 0; i < strlen(sLowerCase); i++)
		{
			if(!IsCharUpper(sLowerCase[i]))
			{
				sLowerCase[i] = CharToLower(sLowerCase[i]);
			}
		}

		if(gA_ValidMaps.FindString(sLowerCase) == -1)
		{
			gA_ValidMaps.PushString(sLowerCase);
			gI_ValidMaps++;
		}
	}

	SortADTArray(gA_ValidMaps, Sort_Ascending, Sort_String);
}

public void Shavit_OnStyleConfigLoaded(int styles)
{
	if(styles == -1)
	{
		styles = Shavit_GetStyleCount();
	}

	for(int i = 0; i < styles; i++)
	{
		Shavit_GetStyleSettings(i, gA_StyleSettings[i]);
		Shavit_GetStyleStrings(i, sStyleName, gS_StyleStrings[i].sStyleName, sizeof(stylestrings_t::sStyleName));
		Shavit_GetStyleStrings(i, sShortName, gS_StyleStrings[i].sShortName, sizeof(stylestrings_t::sShortName));
	}

	// arrays
	for(int i = 0; i < STYLE_LIMIT; i++)
	{
		for(int j = 0; j < TRACKS_SIZE; j++)
		{
			if(i < styles)
			{
				if(gA_Leaderboard[i][j] == null)
				{
					gA_Leaderboard[i][j] = new ArrayList();
				}

				gA_Leaderboard[i][j].Clear();
				gI_RecordAmount[i][j] = 0;
			}

			else
			{
				delete gA_Leaderboard[i][j];
			}
		}
	}

	gI_Styles = styles;
}

public void Shavit_OnChatConfigLoaded()
{
	Shavit_GetChatStrings(sMessagePrefix, gS_ChatStrings.sPrefix, sizeof(chatstrings_t::sPrefix));
	Shavit_GetChatStrings(sMessageText, gS_ChatStrings.sText, sizeof(chatstrings_t::sText));
	Shavit_GetChatStrings(sMessageWarning, gS_ChatStrings.sWarning, sizeof(chatstrings_t::sWarning));
	Shavit_GetChatStrings(sMessageVariable, gS_ChatStrings.sVariable, sizeof(chatstrings_t::sVariable));
	Shavit_GetChatStrings(sMessageVariable2, gS_ChatStrings.sVariable2, sizeof(chatstrings_t::sVariable2));
	Shavit_GetChatStrings(sMessageStyle, gS_ChatStrings.sStyle, sizeof(chatstrings_t::sStyle));
}

public void OnClientPutInServer(int client)
{
	gA_WRCache[client].bPendingMenu = false;

	for(int i = 0; i < gI_Styles; i++)
	{
		for(int j = 0; j < TRACKS_SIZE; j++)
		{
			gF_PlayerRecord[client][i][j] = 0.0;
		}
	}

	if(!IsClientConnected(client) || IsFakeClient(client) || gH_SQL == null)
	{
		return;
	}

	UpdateClientCache(client);
}

void UpdateClientCache(int client)
{
	char sAuthID[32];
	GetClientAuthId(client, AuthId_Steam3, sAuthID, 32);

	char sQuery[256];
	FormatEx(sQuery, 256, "SELECT time, style, track FROM %splayertimes WHERE map = '%s' AND auth = '%s';", gS_MySQLPrefix, gS_Map, sAuthID);
	gH_SQL.Query(SQL_UpdateCache_Callback, sQuery, GetClientSerial(client), DBPrio_High);
}

public void SQL_UpdateCache_Callback(Database db, DBResultSet results, const char[] error, any data)
{
	if(results == null)
	{
		LogError("Timer (PB cache update) SQL query failed. Reason: %s", error);

		return;
	}

	int client = GetClientFromSerial(data);

	if(client == 0)
	{
		return;
	}

	while(results.FetchRow())
	{
		int style = results.FetchInt(1);
		int track = results.FetchInt(2);

		if(style >= gI_Styles || style < 0 || track >= TRACKS_SIZE)
		{
			continue;
		}

		gF_PlayerRecord[client][style][track] = results.FetchFloat(0);
	}
}

void UpdateWRCache()
{
	char sQuery[512];
	// thanks Ollie Jones from stackoverflow! http://stackoverflow.com/a/36239523/5335680
	// was a bit confused with this one :s

	if(gB_MySQL)
	{
		FormatEx(sQuery, 512, "SELECT p.style, p.id, TRUNCATE(LEAST(s.time, p.time), 3), u.name, p.track FROM %splayertimes p JOIN(SELECT style, MIN(time) time, map, track FROM %splayertimes WHERE map = '%s' GROUP BY style, track ORDER BY date ASC) s ON p.style = s.style AND p.time = s.time AND p.map = s.map JOIN %susers u ON p.auth = u.auth GROUP BY p.style, p.track ORDER BY date ASC;", gS_MySQLPrefix, gS_MySQLPrefix, gS_Map, gS_MySQLPrefix);
	}

	// sorry, LEAST() isn't available for SQLITE!
	else
	{
		FormatEx(sQuery, 512, "SELECT p.style, p.id, s.time, u.name, p.track FROM %splayertimes p JOIN(SELECT style, MIN(time) time, map, track FROM %splayertimes WHERE map = '%s' GROUP BY style, track) s ON p.style = s.style AND p.time = s.time AND p.map = s.map AND s.track = p.track JOIN %susers u ON p.auth = u.auth GROUP BY p.style, p.track;", gS_MySQLPrefix, gS_MySQLPrefix, gS_Map, gS_MySQLPrefix);
	}

	gH_SQL.Query(SQL_UpdateWRCache_Callback, sQuery, 0, DBPrio_Low);
}

public void SQL_UpdateWRCache_Callback(Database db, DBResultSet results, const char[] error, any data)
{
	if(results == null)
	{
		LogError("Timer (WR cache update) SQL query failed. Reason: %s", error);

		return;
	}

	// reset cache
	for(int i = 0; i < gI_Styles; i++)
	{
		for(int j = 0; j < TRACKS_SIZE; j++)
		{
			strcopy(gS_WRName[i][j], MAX_NAME_LENGTH, "invalid");
			gF_WRTime[i][j] = 0.0;
			gI_RecordAmount[i][j] = 0;
		}
	}

	// setup cache again, dynamically and not hardcoded
	while(results.FetchRow())
	{
		int style = results.FetchInt(0);

		if(style >= gI_Styles || style < 0 || gA_StyleSettings[style].bUnranked)
		{
			continue;
		}

		int track = results.FetchInt(4);

		gI_WRRecordID[style][track] = results.FetchInt(1);
		gF_WRTime[style][track] = results.FetchFloat(2);
		results.FetchString(3, gS_WRName[style][track], MAX_NAME_LENGTH);
		ReplaceString(gS_WRName[style][track], MAX_NAME_LENGTH, "#", "?");
	}

	UpdateLeaderboards();
}

public int Native_GetWorldRecord(Handle handler, int numParams)
{
	return view_as<int>(gF_WRTime[GetNativeCell(1)][GetNativeCell(2)]);
}

public int Native_GetWRTime(Handle handler, int numParams)
{
	SetNativeCellRef(2, gF_WRTime[GetNativeCell(1)][GetNativeCell(3)]);
}

public int Native_ReloadLeaderboards(Handle handler, int numParams)
{
	UpdateLeaderboards();
	UpdateWRCache();
}

public int Native_GetWRRecordID(Handle handler, int numParams)
{
	SetNativeCellRef(2, gI_WRRecordID[GetNativeCell(1)][GetNativeCell(3)]);
}

public int Native_GetWRName(Handle handler, int numParams)
{
	SetNativeString(2, gS_WRName[GetNativeCell(1)][GetNativeCell(4)], GetNativeCell(3));
}

public int Native_GetClientPB(Handle handler, int numParams)
{
	return view_as<int>(gF_PlayerRecord[GetNativeCell(1)][GetNativeCell(2)][GetNativeCell(3)]);
}

public int Native_GetPlayerPB(Handle handler, int numParams)
{
	SetNativeCellRef(3, gF_PlayerRecord[GetNativeCell(1)][GetNativeCell(2)][GetNativeCell(4)]);
}

public int Native_GetRankForTime(Handle handler, int numParams)
{
	int style = GetNativeCell(1);
	int track = GetNativeCell(3);

	if(gA_Leaderboard[style][track] == null || gA_Leaderboard[style][track].Length == 0)
	{
		return 1;
	}

	return GetRankForTime(style, GetNativeCell(2), track);
}

public int Native_GetRecordAmount(Handle handler, int numParams)
{
	return gI_RecordAmount[GetNativeCell(1)][GetNativeCell(2)];
}

public int Native_GetTimeForRank(Handle handler, int numParams)
{
	int style = GetNativeCell(1);
	int rank = GetNativeCell(2);
	int track = GetNativeCell(3);

	#if defined DEBUG
	Shavit_PrintToChatAll("style %d | rank %d | track %d | amount %d", style, rank, track, gI_RecordAmount[style][track]);
	#endif

	if(rank > gI_RecordAmount[style][track])
	{
		return view_as<int>(0.0);
	}

	return view_as<int>(gA_Leaderboard[style][track].Get(rank - 1));
}

public int Native_WR_DeleteMap(Handle handler, int numParams)
{
	char sMap[160];
	GetNativeString(1, sMap, 160);

	char sQuery[256];
	FormatEx(sQuery, 256, "DELETE FROM %splayertimes WHERE map = '%s';", gS_MySQLPrefix, sMap);
	gH_SQL.Query(SQL_DeleteMap_Callback, sQuery, StrEqual(gS_Map, sMap, false), DBPrio_High);
}

public void SQL_DeleteMap_Callback(Database db, DBResultSet results, const char[] error, any data)
{
	if(results == null)
	{
		LogError("Timer (WR deletemap) SQL query failed. Reason: %s", error);

		return;
	}

	if(view_as<bool>(data))
	{
		OnMapStart();

		for(int i = 1; i <= MaxClients; i++)
		{
			OnClientPutInServer(i);
		}
	}
}

#if defined DEBUG
// debug
public Action Command_Junk(int client, int args)
{
	char sQuery[256];

	char sAuth[32];
	GetClientAuthId(client, AuthId_Steam3, sAuth, 32);
	FormatEx(sQuery, 256, "INSERT INTO %splayertimes (auth, map, time, jumps, date, style, strafes, sync) VALUES ('%s', '%s', %.03f, %d, %d, 0, %d, %.02f);", gS_MySQLPrefix, sAuth, gS_Map, GetRandomFloat(10.0, 20.0), GetRandomInt(5, 15), GetTime(), GetRandomInt(5, 15), GetRandomFloat(50.0, 99.99));

	SQL_LockDatabase(gH_SQL);
	SQL_FastQuery(gH_SQL, sQuery);
	SQL_UnlockDatabase(gH_SQL);

	return Plugin_Handled;
}

public Action Command_PrintLeaderboards(int client, int args)
{
	ReplyToCommand(client, "Track: Main - Style: 0");
	ReplyToCommand(client, "Current PB: %f", gF_PlayerRecord[client][0][0]);
	ReplyToCommand(client, "Count: %d", gI_RecordAmount[0][0]);
	ReplyToCommand(client, "Rank: %d", Shavit_GetRankForTime(0, gF_PlayerRecord[client][0][0], 0));

	for(int i = 0; i < gI_RecordAmount[0][0]; i++)
	{
		ReplyToCommand(client, "#%d: %f", i, gA_Leaderboard[0][0].Get(i));
	}

	return Plugin_Handled;
}
#endif

int GetTrackRecordCount(int track)
{
	int count = 0;

	for(int i = 0; i < gI_Styles; i++)
	{
		count += gI_RecordAmount[i][track];
	}

	return count;
}

public Action Command_Delete(int client, int args)
{
	if(!IsValidClient(client))
	{
		return Plugin_Handled;
	}

	Menu menu = new Menu(MenuHandler_Delete_First);
	menu.SetTitle("%T\n ", "DeleteTrackSingle", client);

	for(int i = 0; i < TRACKS_SIZE; i++)
	{
		char sInfo[8];
		IntToString(i, sInfo, 8);

		int records = GetTrackRecordCount(i);

		char sTrack[64];
		GetTrackName(client, i, sTrack, 64);

		if(records > 0)
		{
			Format(sTrack, 64, "%s (%T: %d)", sTrack, "WRRecord", client, records);
		}

		menu.AddItem(sInfo, sTrack, (records > 0)? ITEMDRAW_DEFAULT:ITEMDRAW_DISABLED);
	}

	menu.ExitButton = true;
	menu.Display(client, 20);

	return Plugin_Handled;
}

public int MenuHandler_Delete_First(Menu menu, MenuAction action, int param1, int param2)
{
	if(action == MenuAction_Select)
	{
		char info[16];
		menu.GetItem(param2, info, 16);
		gA_WRCache[param1].iLastTrack = StringToInt(info);

		DeleteSubmenu(param1);
	}

	else if(action == MenuAction_End)
	{
		delete menu;
	}

	return 0;
}

void DeleteSubmenu(int client)
{
	Menu menu = new Menu(MenuHandler_Delete);
	menu.SetTitle("%T\n ", "DeleteMenuTitle", client);

	int[] styles = new int[gI_Styles];
	Shavit_GetOrderedStyles(styles, gI_Styles);

	for(int i = 0; i < gI_Styles; i++)
	{
		int iStyle = styles[i];

		char sInfo[8];
		IntToString(iStyle, sInfo, 8);

		char sDisplay[64];
		FormatEx(sDisplay, 64, "%s (%T: %d)", gS_StyleStrings[iStyle].sStyleName, "WRRecord", client, gI_RecordAmount[iStyle][gA_WRCache[client].iLastTrack]);

		menu.AddItem(sInfo, sDisplay, (gI_RecordAmount[iStyle][gA_WRCache[client].iLastTrack] > 0)? ITEMDRAW_DEFAULT:ITEMDRAW_DISABLED);
	}

	menu.ExitButton = true;
	menu.Display(client, 20);
}

public Action Command_DeleteAll(int client, int args)
{
	if(!IsValidClient(client))
	{
		return Plugin_Handled;
	}

	Menu menu = new Menu(MenuHandler_DeleteAll_First);
	menu.SetTitle("%T\n ", "DeleteTrackAll", client);

	for(int i = 0; i < TRACKS_SIZE; i++)
	{
		char sInfo[8];
		IntToString(i, sInfo, 8);

		int iRecords = GetTrackRecordCount(i);

		char sTrack[64];
		GetTrackName(client, i, sTrack, 64);

		if(iRecords > 0)
		{
			Format(sTrack, 64, "%s (%T: %d)", sTrack, "WRRecord", client, iRecords);
		}

		menu.AddItem(sInfo, sTrack, (iRecords > 0)? ITEMDRAW_DEFAULT:ITEMDRAW_DISABLED);
	}

	menu.ExitButton = true;
	menu.Display(client, 20);

	return Plugin_Handled;
}

public int MenuHandler_DeleteAll_First(Menu menu, MenuAction action, int param1, int param2)
{
	if(action == MenuAction_Select)
	{
		char sInfo[8];
		menu.GetItem(param2, sInfo, 8);
		int iTrack = gA_WRCache[param1].iLastTrack = StringToInt(sInfo);

		char sTrack[64];
		GetTrackName(param1, iTrack, sTrack, 64);

		Menu subMenu = new Menu(MenuHandler_DeleteAll_Second);
		subMenu.SetTitle("%T\n ", "DeleteTrackAllStyle", param1, sTrack);

		int[] styles = new int[gI_Styles];
		Shavit_GetOrderedStyles(styles, gI_Styles);

		for(int i = 0; i < gI_Styles; i++)
		{
			int iStyle = styles[i];

			char sStyle[64];
			strcopy(sStyle, 64, gS_StyleStrings[iStyle].sStyleName);

			IntToString(iStyle, sInfo, 8);

			int iRecords = gI_RecordAmount[iStyle][iTrack];

			if(iRecords > 0)
			{
				Format(sStyle, 64, "%s (%T: %d)", sStyle, "WRRecord", param1, iRecords);
			}

			subMenu.AddItem(sInfo, sStyle, (iRecords > 0)? ITEMDRAW_DEFAULT:ITEMDRAW_DISABLED);
		}

		subMenu.ExitButton = true;
		subMenu.Display(param1, 20);
	}

	else if(action == MenuAction_End)
	{
		delete menu;
	}

	return 0;
}

public int MenuHandler_DeleteAll_Second(Menu menu, MenuAction action, int param1, int param2)
{
	if(action == MenuAction_Select)
	{
		char sInfo[8];
		menu.GetItem(param2, sInfo, 8);
		gA_WRCache[param1].iLastStyle = StringToInt(sInfo);

		DeleteAllSubmenu(param1);
	}

	else if(action == MenuAction_End)
	{
		delete menu;
	}

	return 0;
}

void DeleteAllSubmenu(int client)
{
	char sTrack[32];
	GetTrackName(client, gA_WRCache[client].iLastTrack, sTrack, 32);

	Menu menu = new Menu(MenuHandler_DeleteAll);
	menu.SetTitle("%T\n ", "DeleteAllRecordsMenuTitle", client, gS_Map, sTrack, gS_StyleStrings[gA_WRCache[client].iLastStyle].sStyleName);

	char sMenuItem[64];

	for(int i = 1; i <= GetRandomInt(1, 4); i++)
	{
		FormatEx(sMenuItem, 64, "%T", "MenuResponseNo", client);
		menu.AddItem("-1", sMenuItem);
	}

	FormatEx(sMenuItem, 64, "%T", "MenuResponseYes", client);
	menu.AddItem("yes", sMenuItem);

	for(int i = 1; i <= GetRandomInt(1, 3); i++)
	{
		FormatEx(sMenuItem, 64, "%T", "MenuResponseNo", client);
		menu.AddItem("-1", sMenuItem);
	}

	menu.ExitButton = true;
	menu.Display(client, 20);
}

public int MenuHandler_DeleteAll(Menu menu, MenuAction action, int param1, int param2)
{
	if(action == MenuAction_Select)
	{
		char info[16];
		menu.GetItem(param2, info, 16);

		if(StringToInt(info) == -1)
		{
			Shavit_PrintToChat(param1, "%T", "DeletionAborted", param1);

			return 0;
		}

		char sTrack[32];
		GetTrackName(LANG_SERVER, gA_WRCache[param1].iLastTrack, sTrack, 32);

		Shavit_LogMessage("%L - deleted all %s track and %s style records from map `%s`.",
			param1, sTrack, gS_StyleStrings[gA_WRCache[param1].iLastStyle].sStyleName, gS_Map);

		char sQuery[256];
		FormatEx(sQuery, 256, "DELETE FROM %splayertimes WHERE map = '%s' AND style = %d AND track = %d;",
			gS_MySQLPrefix, gS_Map, gA_WRCache[param1].iLastStyle, gA_WRCache[param1].iLastTrack);

		gH_SQL.Query(DeleteAll_Callback, sQuery, GetClientSerial(param1), DBPrio_High);
	}

	else if(action == MenuAction_End)
	{
		delete menu;
	}

	return 0;
}

public Action Command_DeleteStyleRecords(int client, int args)
{
	if(!IsValidClient(client))
	{
		return Plugin_Handled;
	}

	Menu menu = new Menu(MenuHandler_DeleteStyleRecords);
	menu.SetTitle("%T\n ", "DeleteStyleRecordsRecordsMenuTitle", client, gS_Map);

	int[] styles = new int[gI_Styles];
	Shavit_GetOrderedStyles(styles, gI_Styles);

	for(int i = 0; i < gI_Styles; i++)
	{
		int iStyle = styles[i];

		if(gA_StyleSettings[iStyle].bUnranked)
		{
			continue;
		}

		char sInfo[8];
		IntToString(iStyle, sInfo, 8);

		char sDisplay[64];
		FormatEx(sDisplay, 64, "%s (%d %T)", gS_StyleStrings[iStyle].sStyleName, gI_RecordAmount[iStyle], "WRRecord", client);

		int iTotalAmount = 0;

		for(int j = 0; j < TRACKS_SIZE; j++)
		{
			iTotalAmount += gI_RecordAmount[iStyle][j];
		}

		menu.AddItem(sInfo, sDisplay, (iTotalAmount > 0)? ITEMDRAW_DEFAULT:ITEMDRAW_DISABLED);
	}

	if(menu.ItemCount == 0)
	{
		char sNoRecords[64];
		FormatEx(sNoRecords, 64, "%T", "WRMapNoRecords", client);
		menu.AddItem("-1", sNoRecords);
	}

	menu.ExitButton = true;
	menu.Display(client, 20);

	return Plugin_Handled;
}

public int MenuHandler_DeleteStyleRecords(Menu menu, MenuAction action, int param1, int param2)
{
	if(action == MenuAction_Select)
	{
		char info[16];
		menu.GetItem(param2, info, 16);

		int style = StringToInt(info);
		int iTotalAmount = 0;

		for(int j = 0; j < TRACKS_SIZE; j++)
		{
			iTotalAmount += gI_RecordAmount[style][j];
		}

		if(iTotalAmount == 0)
		{
			return 0;
		}

		char sMenuItem[128];

		Menu submenu = new Menu(MenuHandler_DeleteStyleRecords_Confirm);
		submenu.SetTitle("%T\n ", "DeleteConfirmStyle", param1, gS_StyleStrings[style].sStyleName);

		for(int i = 1; i <= GetRandomInt(1, 4); i++)
		{
			FormatEx(sMenuItem, 128, "%T", "MenuResponseNo", param1);
			submenu.AddItem("-1", sMenuItem);
		}

		FormatEx(sMenuItem, 128, "%T", "MenuResponseYesStyle", param1, gS_StyleStrings[style].sStyleName);

		IntToString(style, info, 16);
		submenu.AddItem(info, sMenuItem);

		for(int i = 1; i <= GetRandomInt(1, 3); i++)
		{
			FormatEx(sMenuItem, 128, "%T", "MenuResponseNo", param1);
			submenu.AddItem("-1", sMenuItem);
		}

		submenu.ExitButton = true;
		submenu.Display(param1, 20);
	}

	else if(action == MenuAction_End)
	{
		delete menu;
	}

	return 0;
}

public int MenuHandler_DeleteStyleRecords_Confirm(Menu menu, MenuAction action, int param1, int param2)
{
	if(action == MenuAction_Select)
	{
		char info[16];
		menu.GetItem(param2, info, 16);

		int style = StringToInt(info);

		if(style == -1)
		{
			Shavit_PrintToChat(param1, "%T", "DeletionAborted", param1);

			return 0;
		}

		Shavit_LogMessage("%L - deleted all %s style records from map `%s`.", param1, gS_StyleStrings[style].sStyleName, gS_Map);

		char sQuery[256];
		FormatEx(sQuery, 256, "DELETE FROM %splayertimes WHERE map = '%s' AND style = %d;", gS_MySQLPrefix, gS_Map, style);

		DataPack pack = new DataPack();
		pack.WriteCell(GetClientSerial(param1));
		pack.WriteCell(style);

		gH_SQL.Query(DeleteStyleRecords_Callback, sQuery, pack, DBPrio_High);
	}

	else if(action == MenuAction_End)
	{
		delete menu;
	}

	return 0;
}

public void DeleteStyleRecords_Callback(Database db, DBResultSet results, const char[] error, DataPack data)
{
	data.Reset();
	int serial = data.ReadCell();
	int style = data.ReadCell();
	delete data;

	if(results == null)
	{
		LogError("Timer (WR DeleteStyleRecords) SQL query failed. Reason: %s", error);

		return;
	}

	UpdateWRCache();

	for(int i = 1; i <= MaxClients; i++)
	{
		OnClientPutInServer(i);
	}

	int client = GetClientFromSerial(serial);

	if(client == 0)
	{
		return;
	}

	Shavit_PrintToChat(client, "%T", "DeletedRecordsStyle", client, gS_ChatStrings.sStyle, gS_StyleStrings[style].sStyleName, gS_ChatStrings.sText);
}

public int MenuHandler_Delete(Menu menu, MenuAction action, int param1, int param2)
{
	if(action == MenuAction_Select)
	{
		char info[16];
		menu.GetItem(param2, info, 16);
		gA_WRCache[param1].iLastStyle = StringToInt(info);

		OpenDelete(param1);

		UpdateLeaderboards();
	}

	else if(action == MenuAction_End)
	{
		delete menu;
	}

	return 0;
}

void OpenDelete(int client)
{
	char sQuery[512];
	FormatEx(sQuery, 512, "SELECT p.id, u.name, p.time, p.jumps FROM %splayertimes p JOIN %susers u ON p.auth = u.auth WHERE map = '%s' AND style = %d AND track = %d ORDER BY time ASC, date ASC LIMIT 1000;",
		gS_MySQLPrefix, gS_MySQLPrefix, gS_Map, gA_WRCache[client].iLastStyle, gA_WRCache[client].iLastTrack);

	gH_SQL.Query(SQL_OpenDelete_Callback, sQuery, GetClientSerial(client), DBPrio_High);
}

public void SQL_OpenDelete_Callback(Database db, DBResultSet results, const char[] error, any data)
{
	if(results == null)
	{
		LogError("Timer (WR OpenDelete) SQL query failed. Reason: %s", error);

		return;
	}

	int client = GetClientFromSerial(data);

	if(client == 0)
	{
		return;
	}

	int iStyle = gA_WRCache[client].iLastStyle;

	Menu menu = new Menu(OpenDelete_Handler);
	menu.SetTitle("%t", "ListClientRecords", gS_Map, gS_StyleStrings[iStyle].sStyleName);

	int iCount = 0;

	while(results.FetchRow())
	{
		iCount++;

		// 0 - record id, for statistic purposes.
		int id = results.FetchInt(0);
		char sID[8];
		IntToString(id, sID, 8);

		// 1 - player name
		char sName[MAX_NAME_LENGTH];
		results.FetchString(1, sName, MAX_NAME_LENGTH);
		ReplaceString(sName, MAX_NAME_LENGTH, "#", "?");

		// 2 - time
		float time = results.FetchFloat(2);
		char sTime[16];
		FormatSeconds(time, sTime, 16);

		// 3 - jumps
		int jumps = results.FetchInt(3);

		char sDisplay[128];
		FormatEx(sDisplay, 128, "#%d - %s - %s (%d jump%s)", iCount, sName, sTime, jumps, (jumps != 1)? "s":"");
		menu.AddItem(sID, sDisplay);
	}

	if(iCount == 0)
	{
		char sNoRecords[64];
		FormatEx(sNoRecords, 64, "%T", "WRMapNoRecords", client);
		menu.AddItem("-1", sNoRecords);
	}

	menu.ExitButton = true;
	menu.Display(client, 20);
}

public int OpenDelete_Handler(Menu menu, MenuAction action, int param1, int param2)
{
	if(action == MenuAction_Select)
	{
		char sInfo[16];
		menu.GetItem(param2, sInfo, 16);

		int id = StringToInt(sInfo);

		if(id != -1)
		{
			OpenDeleteMenu(param1, id);
		}
	}

	else if(action == MenuAction_End)
	{
		delete menu;
	}

	return 0;
}

void OpenDeleteMenu(int client, int id)
{
	char sMenuItem[64];

	Menu menu = new Menu(DeleteConfirm_Handler);
	menu.SetTitle("%T\n ", "DeleteConfirm", client);

	for(int i = 1; i <= GetRandomInt(1, 4); i++)
	{
		FormatEx(sMenuItem, 64, "%T", "MenuResponseNo", client);
		menu.AddItem("-1", sMenuItem);
	}

	FormatEx(sMenuItem, 64, "%T", "MenuResponseYesSingle", client);

	char sInfo[16];
	IntToString(id, sInfo, 16);
	menu.AddItem(sInfo, sMenuItem);

	for(int i = 1; i <= GetRandomInt(1, 3); i++)
	{
		FormatEx(sMenuItem, 64, "%T", "MenuResponseNo", client);
		menu.AddItem("-1", sMenuItem);
	}

	menu.ExitButton = true;
	menu.Display(client, 20);
}

public int DeleteConfirm_Handler(Menu menu, MenuAction action, int param1, int param2)
{
	if(action == MenuAction_Select)
	{
		char sInfo[16];
		menu.GetItem(param2, sInfo, 16);

		int iRecordID = StringToInt(sInfo);

		if(iRecordID == -1)
		{
			Shavit_PrintToChat(param1, "%T", "DeletionAborted", param1);

			return 0;
		}

		char sQuery[256];
		FormatEx(sQuery, 256, "SELECT u.auth, u.name, p.map, p.time, p.sync, p.perfs, p.jumps, p.strafes, p.id, p.date FROM %susers u LEFT JOIN %splayertimes p ON u.auth = p.auth WHERE p.id = %d;",
			gS_MySQLPrefix, gS_MySQLPrefix, iRecordID);

		gH_SQL.Query(GetRecordDetails_Callback, sQuery, GetClientSerial(param1), DBPrio_High);
	}

	else if(action == MenuAction_End)
	{
		delete menu;
	}

	return 0;
}

public void GetRecordDetails_Callback(Database db, DBResultSet results, const char[] error, any data)
{
	if(results == null)
	{
		LogError("Timer (WR GetRecordDetails) SQL query failed. Reason: %s", error);

		return;
	}

	int client = GetClientFromSerial(data);

	if(client == 0)
	{
		return;
	}

	if(results.FetchRow())
	{
		char sAuthID[32];
		results.FetchString(0, sAuthID, 32);

		char sName[MAX_NAME_LENGTH];
		results.FetchString(1, sName, MAX_NAME_LENGTH);

		char sMap[160];
		results.FetchString(2, sMap, 160);

		float fTime = results.FetchFloat(3);
		float fSync = results.FetchFloat(4);
		float fPerfectJumps = results.FetchFloat(5);

		int iJumps = results.FetchInt(6);
		int iStrafes = results.FetchInt(7);
		int iRecordID = results.FetchInt(8);
		int iTimestamp = results.FetchInt(9);
		
		int iStyle = gA_WRCache[client].iLastStyle;
		int iTrack = gA_WRCache[client].iLastTrack;
		bool bWRDeleted = (gI_WRRecordID[iStyle][iTrack] == iRecordID);

		// that's a big datapack ya yeet
		DataPack hPack = new DataPack();
		hPack.WriteCell(GetClientSerial(client));
		hPack.WriteString(sAuthID);
		hPack.WriteString(sName);
		hPack.WriteString(sMap);
		hPack.WriteCell(fTime);
		hPack.WriteCell(fSync);
		hPack.WriteCell(fPerfectJumps);
		hPack.WriteCell(iJumps);
		hPack.WriteCell(iStrafes);
		hPack.WriteCell(iRecordID);
		hPack.WriteCell(iTimestamp);
		hPack.WriteCell(iStyle);
		hPack.WriteCell(iTrack);
		hPack.WriteCell(bWRDeleted);

		char sQuery[256];
		FormatEx(sQuery, 256, "DELETE FROM %splayertimes WHERE id = %d;",
			gS_MySQLPrefix, iRecordID);

		gH_SQL.Query(DeleteConfirm_Callback, sQuery, hPack, DBPrio_High);
	}
}

public void DeleteConfirm_Callback(Database db, DBResultSet results, const char[] error, any data)
{
	DataPack hPack = view_as<DataPack>(data);
	hPack.Reset();

	int iSerial = hPack.ReadCell();

	char sAuthID[32];
	hPack.ReadString(sAuthID, 32);

	char sName[MAX_NAME_LENGTH];
	hPack.ReadString(sName, MAX_NAME_LENGTH);

	char sMap[160];
	hPack.ReadString(sMap, 160);

	float fTime = view_as<float>(hPack.ReadCell());
	float fSync = view_as<float>(hPack.ReadCell());
	float fPerfectJumps = view_as<float>(hPack.ReadCell());

	int iJumps = hPack.ReadCell();
	int iStrafes = hPack.ReadCell();
	int iRecordID = hPack.ReadCell();
	int iTimestamp = hPack.ReadCell();
	int iStyle = hPack.ReadCell();
	int iTrack = hPack.ReadCell();

	bool bWRDeleted = view_as<bool>(hPack.ReadCell());
	delete hPack;

	if(results == null)
	{
		LogError("Timer (WR DeleteConfirm) SQL query failed. Reason: %s", error);

		return;
	}

	if(bWRDeleted)
	{
		Call_StartForward(gH_OnWRDeleted);
		Call_PushCell(iStyle);
		Call_PushCell(iRecordID);
		Call_PushCell(iTrack);
		Call_Finish();
	}

	UpdateWRCache();

	for(int i = 1; i <= MaxClients; i++)
	{
		OnClientPutInServer(i);
	}

	int client = GetClientFromSerial(iSerial);

	char sTrack[32];
	GetTrackName(LANG_SERVER, iTrack, sTrack, 32);

	char sDate[32];
	FormatTime(sDate, 32, "%Y-%m-%d %H:%M:%S", iTimestamp);

	// above the client == 0 so log doesn't get lost if admin disconnects between deleting record and query execution
	Shavit_LogMessage("%L - deleted record. Runner: %s (%s) | Map: %s | Style: %s | Track: %s | Time: %.2f (%s) | Strafes: %d (%.1f%%) | Jumps: %d (%.1f%%) | Run date: %s | Record ID: %d",
		client, sName, sAuthID, sMap, gS_StyleStrings[iStyle].sStyleName, sTrack, fTime, (bWRDeleted)? "WR":"not WR", iStrafes, fSync, iJumps, fPerfectJumps, sDate, iRecordID);

	if(client == 0)
	{
		return;
	}

	Shavit_PrintToChat(client, "%T", "DeletedRecord", client);
}

public void DeleteAll_Callback(Database db, DBResultSet results, const char[] error, any data)
{
	if(results == null)
	{
		LogError("Timer (WR DeleteAll) SQL query failed. Reason: %s", error);

		return;
	}

	UpdateWRCache();

	for(int i = 1; i <= MaxClients; i++)
	{
		OnClientPutInServer(i);
	}

	int client = GetClientFromSerial(data);

	if(client == 0)
	{
		return;
	}

	Call_StartForward(gH_OnWRDeleted);
	Call_PushCell(gA_WRCache[client].iLastStyle);
	Call_PushCell(-1);
	Call_PushCell(gA_WRCache[client].iLastTrack);
	Call_Finish();

	Shavit_PrintToChat(client, "%T", "DeletedRecordsMap", client, gS_ChatStrings.sVariable, gS_Map, gS_ChatStrings.sText);
}

public Action Command_WorldRecord(int client, int args)
{
	if(!IsValidClient(client))
	{
		return Plugin_Handled;
	}

	if(args == 0)
	{
		strcopy(gA_WRCache[client].sClientMap, 128, gS_Map);
	}

	else
	{
		GetCmdArgString(gA_WRCache[client].sClientMap, 128);
		GuessBestMapName(gA_WRCache[client].sClientMap, gA_WRCache[client].sClientMap, 128);
	}

	return ShowWRStyleMenu(client, Track_Main);
}

public Action Command_WorldRecord_Bonus(int client, int args)
{
	if(!IsValidClient(client))
	{
		return Plugin_Handled;
	}

	if(args == 0)
	{
		strcopy(gA_WRCache[client].sClientMap, 128, gS_Map);
	}

	else
	{
		GetCmdArgString(gA_WRCache[client].sClientMap, 128);
		GuessBestMapName(gA_WRCache[client].sClientMap, gA_WRCache[client].sClientMap, 128);
	}

	return ShowWRStyleMenu(client, Track_Bonus);
}

Action ShowWRStyleMenu(int client, int track)
{
	gA_WRCache[client].iLastTrack = track;

	Menu menu = new Menu(MenuHandler_StyleChooser);
	menu.SetTitle("%T", "WRMenuTitle", client);

	int[] styles = new int[gI_Styles];
	Shavit_GetOrderedStyles(styles, gI_Styles);

	for(int i = 0; i < gI_Styles; i++)
	{
		int iStyle = styles[i];

		if(gA_StyleSettings[iStyle].bUnranked)
		{
			continue;
		}

		char sInfo[8];
		IntToString(iStyle, sInfo, 8);

		char sDisplay[64];

		if(StrEqual(gA_WRCache[client].sClientMap, gS_Map) && gF_WRTime[iStyle][track] > 0.0)
		{
			char sTime[32];
			FormatSeconds(gF_WRTime[iStyle][track], sTime, 32, false);

			FormatEx(sDisplay, 64, "%s - WR: %s", gS_StyleStrings[iStyle].sStyleName, sTime);
		}

		else
		{
			strcopy(sDisplay, 64, gS_StyleStrings[iStyle].sStyleName);
		}

		menu.AddItem(sInfo, sDisplay, (gI_RecordAmount[iStyle][track] > 0 || !StrEqual(gA_WRCache[client].sClientMap, gS_Map))? ITEMDRAW_DEFAULT:ITEMDRAW_DISABLED);
	}

	// should NEVER happen
	if(menu.ItemCount == 0)
	{
		char sMenuItem[64];
		FormatEx(sMenuItem, 64, "%T", "WRStyleNothing", client);
		menu.AddItem("-1", sMenuItem);
	}

	menu.ExitButton = true;
	menu.Display(client, 30);

	return Plugin_Handled;
}

public int MenuHandler_StyleChooser(Menu menu, MenuAction action, int param1, int param2)
{
	if(action == MenuAction_Select)
	{
		if(!IsValidClient(param1))
		{
			return 0;
		}

		char sInfo[8];
		menu.GetItem(param2, sInfo, 8);

		int iStyle = StringToInt(sInfo);

		if(iStyle == -1)
		{
			Shavit_PrintToChat(param1, "%T", "NoStyles", param1, gS_ChatStrings.sWarning, gS_ChatStrings.sText);

			return 0;
		}

		gA_WRCache[param1].iLastStyle = iStyle;

		StartWRMenu(param1, gA_WRCache[param1].sClientMap, iStyle, gA_WRCache[param1].iLastTrack);
	}

	else if(action == MenuAction_End)
	{
		delete menu;
	}

	return 0;
}

void StartWRMenu(int client, const char[] map, int style, int track)
{
	DataPack dp = new DataPack();
	dp.WriteCell(GetClientSerial(client));
	dp.WriteCell(track);
	dp.WriteString(map);

	int iLength = ((strlen(map) * 2) + 1);
	char[] sEscapedMap = new char[iLength];
	gH_SQL.Escape(map, sEscapedMap, iLength);

	char sQuery[512];
	FormatEx(sQuery, 512, "SELECT p.id, u.name, p.time, p.jumps, p.auth FROM %splayertimes p JOIN %susers u ON p.auth = u.auth WHERE map = '%s' AND style = %d AND track = %d ORDER BY time ASC, date ASC;", gS_MySQLPrefix, gS_MySQLPrefix, sEscapedMap, style, track);
	gH_SQL.Query(SQL_WR_Callback, sQuery, dp);
}

public void SQL_WR_Callback(Database db, DBResultSet results, const char[] error, DataPack data)
{
	data.Reset();
	int serial = data.ReadCell();
	int track = data.ReadCell();

	char sMap[192];
	data.ReadString(sMap, 192);

	delete data;

	if(results == null)
	{
		LogError("Timer (WR SELECT) SQL query failed. Reason: %s", error);

		return;
	}

	int client = GetClientFromSerial(serial);

	if(client == 0)
	{
		return;
	}

	char sAuth[32];
	GetClientAuthId(client, AuthId_Steam3, sAuth, 32);

	Menu menu = new Menu(WRMenu_Handler);

	int iCount = 0;
	int iMyRank = 0;

	while(results.FetchRow())
	{
		if(++iCount <= gCV_RecordsLimit.IntValue)
		{
			// 0 - record id, for statistic purposes.
			int id = results.FetchInt(0);
			char sID[8];
			IntToString(id, sID, 8);

			// 1 - player name
			char sName[MAX_NAME_LENGTH];
			results.FetchString(1, sName, MAX_NAME_LENGTH);

			// 2 - time
			float time = results.FetchFloat(2);
			char sTime[16];
			FormatSeconds(time, sTime, 16);

			// 3 - jumps
			int jumps = results.FetchInt(3);

			char sDisplay[128];
			FormatEx(sDisplay, 128, "#%d - %s - %s (%d %T)", iCount, sName, sTime, jumps, "WRJumps", client);
			menu.AddItem(sID, sDisplay);
		}

		// check if record exists in the map's top X
		char sQueryAuth[32];
		results.FetchString(4, sQueryAuth, 32);

		if(StrEqual(sQueryAuth, sAuth))
		{
			iMyRank = iCount;
		}
	}

	char sFormattedTitle[256];

	if(menu.ItemCount == 0)
	{
		menu.SetTitle("%T", "WRMap", client, sMap);
		char sNoRecords[64];
		FormatEx(sNoRecords, 64, "%T", "WRMapNoRecords", client);

		menu.AddItem("-1", sNoRecords);
	}

	else
	{
		int iStyle = gA_WRCache[client].iLastStyle;
		int iRecords = results.RowCount;

		// [32] just in case there are 150k records on a map and you're ranked 100k or something
		char sRanks[32];

		if(gF_PlayerRecord[client][iStyle][track] == 0.0 || iMyRank == 0)
		{
			FormatEx(sRanks, 32, "(%d %T)", iRecords, "WRRecord", client);
		}

		else
		{
			FormatEx(sRanks, 32, "(#%d/%d)", iMyRank, iRecords);
		}

		char sTrack[32];
		GetTrackName(client, track, sTrack, 32);

		FormatEx(sFormattedTitle, 192, "%T %s: [%s]\n%s", "WRRecordFor", client, sMap, sTrack, sRanks);
		menu.SetTitle(sFormattedTitle);
	}

	menu.ExitBackButton = true;
	menu.Display(client, 20);
}

public int WRMenu_Handler(Menu menu, MenuAction action, int param1, int param2)
{
	if(action == MenuAction_Select)
	{
		char sInfo[16];
		menu.GetItem(param2, sInfo, 16);
		int id = StringToInt(sInfo);

		if(id != -1)
		{
			OpenSubMenu(param1, id);
		}

		else
		{
			ShowWRStyleMenu(param1, gA_WRCache[param1].iLastTrack);
		}
	}

	else if(action == MenuAction_Cancel && param2 == MenuCancel_ExitBack)
	{
		ShowWRStyleMenu(param1, gA_WRCache[param1].iLastTrack);
	}

	else if(action == MenuAction_End)
	{
		delete menu;
	}

	return 0;
}

public Action Command_RecentRecords(int client, int args)
{
	if(gA_WRCache[client].bPendingMenu || !IsValidClient(client))
	{
		return Plugin_Handled;
	}

	char sQuery[512];

	FormatEx(sQuery, 512,
		"SELECT a.id, a.map, u.name, a.time, a.jumps, a.style, a.points, a.track FROM %splayertimes a " ...
		"JOIN (SELECT MIN(time) time, map, style, track FROM %splayertimes GROUP by map, style, track) b " ...
		"JOIN %susers u ON a.time = b.time AND a.auth = u.auth AND a.map = b.map AND a.style = b.style AND a.track = b.track " ...
		"ORDER BY date DESC LIMIT 100;", gS_MySQLPrefix, gS_MySQLPrefix, gS_MySQLPrefix);

	gH_SQL.Query(SQL_RR_Callback, sQuery, GetClientSerial(client), DBPrio_Low);

	gA_WRCache[client].bPendingMenu = true;

	return Plugin_Handled;
}

public void SQL_RR_Callback(Database db, DBResultSet results, const char[] error, any data)
{
	int client = GetClientFromSerial(data);

	gA_WRCache[client].bPendingMenu = false;

	if(results == null)
	{
		LogError("Timer (RR SELECT) SQL query failed. Reason: %s", error);

		return;
	}

	if(client == 0)
	{
		return;
	}

	Menu menu = new Menu(RRMenu_Handler);
	menu.SetTitle("%T:", "RecentRecords", client, gCV_RecentLimit.IntValue);

	while(results.FetchRow())
	{
		char sMap[192];
		results.FetchString(1, sMap, 192);
		
		char sName[MAX_NAME_LENGTH];
		results.FetchString(2, sName, 10);

		if(strlen(sName) == 9)
		{
			Format(sName, MAX_NAME_LENGTH, "%s...", sName);
		}

		char sTime[16];
		float time = results.FetchFloat(3);
		FormatSeconds(time, sTime, 16);

		int jumps = results.FetchInt(4);
		int style = results.FetchInt(5);
		float fPoints = results.FetchFloat(6);

		char sTrack[32];
		GetTrackName(client, results.FetchInt(7), sTrack, 32);

		char sDisplay[192];

		if(gB_Rankings && fPoints > 0.0)
		{
			FormatEx(sDisplay, 192, "[%s, %c] %s - %s @ %s (%.03f %T)", gS_StyleStrings[style].sShortName, sTrack[0], sMap, sName, sTime, fPoints, "WRPoints", client);
		}

		else
		{
			FormatEx(sDisplay, 192, "[%s, %c] %s - %s @ %s (%d %T)", gS_StyleStrings[style].sShortName, sTrack[0], sMap, sName, sTime, jumps, "WRJumps", client);
		}

		char sInfo[192];
		FormatEx(sInfo, 192, "%d;%s", results.FetchInt(0), sMap);

		menu.AddItem(sInfo, sDisplay);
	}

	if(menu.ItemCount == 0)
	{
		char sMenuItem[64];
		FormatEx(sMenuItem, 64, "%T", "WRMapNoRecords", client);
		menu.AddItem("-1", sMenuItem);
	}

	menu.ExitButton = true;
	menu.Display(client, 60);
}

public int RRMenu_Handler(Menu menu, MenuAction action, int param1, int param2)
{
	if(action == MenuAction_Select)
	{
		char sInfo[128];
		menu.GetItem(param2, sInfo, 128);

		if(StringToInt(sInfo) != -1)
		{
			char sExploded[2][128];
			ExplodeString(sInfo, ";", sExploded, 2, 128, true);

			strcopy(gA_WRCache[param1].sClientMap, 128, sExploded[1]);

			OpenSubMenu(param1, StringToInt(sExploded[0]));
		}

		else
		{
			ShowWRStyleMenu(param1, gA_WRCache[param1].iLastTrack);
		}
	}

	else if(action == MenuAction_Cancel && param2 == MenuCancel_ExitBack)
	{
		ShowWRStyleMenu(param1, gA_WRCache[param1].iLastTrack);
	}

	else if(action == MenuAction_End)
	{
		delete menu;
	}

	return 0;
}

void OpenSubMenu(int client, int id)
{
	char sQuery[512];
	FormatEx(sQuery, 512, "SELECT u.name, p.time, p.jumps, p.style, u.auth, p.date, p.map, p.strafes, p.sync, p.perfs, p.points, p.track FROM %splayertimes p JOIN %susers u ON p.auth = u.auth WHERE p.id = %d LIMIT 1;", gS_MySQLPrefix, gS_MySQLPrefix, id);

	DataPack datapack = new DataPack();
	datapack.WriteCell(GetClientSerial(client));
	datapack.WriteCell(id);

	gH_SQL.Query(SQL_SubMenu_Callback, sQuery, datapack, DBPrio_High);
}

public void SQL_SubMenu_Callback(Database db, DBResultSet results, const char[] error, DataPack data)
{
	data.Reset();
	int client = GetClientFromSerial(data.ReadCell());
	int id = data.ReadCell();
	delete data;

	if(results == null)
	{
		LogError("Timer (WR SUBMENU) SQL query failed. Reason: %s", error);

		return;
	}

	if(client == 0)
	{
		return;
	}

	Menu menu = new Menu(SubMenu_Handler);

	char sFormattedTitle[256];
	char sName[MAX_NAME_LENGTH];
	char sAuthID[32];
	char sTrack[32];
	char sMap[192];

	if(results.FetchRow())
	{
		// 0 - name
		results.FetchString(0, sName, MAX_NAME_LENGTH);

		// 1 - time
		float time = results.FetchFloat(1);
		char sTime[16];
		FormatSeconds(time, sTime, 16);

		char sDisplay[128];
		FormatEx(sDisplay, 128, "%T: %s", "WRTime", client, sTime);
		menu.AddItem("-1", sDisplay);

		// 2 - jumps
		int style = results.FetchInt(3);
		int jumps = results.FetchInt(2);
		float perfs = results.FetchFloat(9);

		if(gA_StyleSettings[style].bAutobhop && perfs > 0.0)
		{
			FormatEx(sDisplay, 128, "%T: %d", "WRJumps", client, jumps);
		}

		else
		{
			FormatEx(sDisplay, 128, "%T: %d (%.2f%%)", "WRJumps", client, jumps, perfs);
		}

		menu.AddItem("-1", sDisplay);

		// 3 - style
		FormatEx(sDisplay, 128, "%T: %s", "WRStyle", client, gS_StyleStrings[style].sStyleName);
		menu.AddItem("-1", sDisplay);

		// 6 - map
		results.FetchString(6, sMap, 192);
		
		float fPoints = results.FetchFloat(10);

		if(gB_Rankings && fPoints > 0.0)
		{
			FormatEx(sDisplay, 128, "%T: %.03f", "WRPointsCap", client, fPoints);
			menu.AddItem("-1", sDisplay);
		}

		// 4 - steamid3
		results.FetchString(4, sAuthID, 32);

		// 5 - date
		char sDate[32];
		results.FetchString(5, sDate, 32);

		if(sDate[4] != '-')
		{
			FormatTime(sDate, 32, "%Y-%m-%d %H:%M:%S", StringToInt(sDate));
		}

		FormatEx(sDisplay, 128, "%T: %s", "WRDate", client, sDate);
		menu.AddItem("-1", sDisplay);

		int strafes = results.FetchInt(7);
		float sync = results.FetchFloat(8);

		if(jumps > 0 || strafes > 0)
		{
			FormatEx(sDisplay, 128, (sync != -1.0)? "%T: %d (%.02f%%)":"%T: %d", "WRStrafes", client, strafes, sync);
			menu.AddItem("-1", sDisplay);
		}

		char sMenuItem[64];
		FormatEx(sMenuItem, 64, "%T", "WRPlayerStats", client);

		char sInfo[32];
		FormatEx(sInfo, 32, "0;%s", sAuthID);

		if(gB_Stats)
		{
			menu.AddItem(sInfo, sMenuItem);
		}

		if(CheckCommandAccess(client, "sm_delete", ADMFLAG_RCON))
		{
			FormatEx(sMenuItem, 64, "%T", "WRDeleteRecord", client);
			FormatEx(sInfo, 32, "1;%d", id);
			menu.AddItem(sInfo, sMenuItem);
		}

		GetTrackName(client, results.FetchInt(11), sTrack, 32);
	}

	else
	{
		char sMenuItem[64];
		FormatEx(sMenuItem, 64, "%T", "DatabaseError", client);
		menu.AddItem("-1", sMenuItem);
	}

	if(strlen(sName) > 0)
	{
		FormatEx(sFormattedTitle, 256, "%s %s\n--- %s: [%s]", sName, sAuthID, sMap, sTrack);
	}

	else
	{
		FormatEx(sFormattedTitle, 256, "%T", "Error", client);
	}

	menu.SetTitle(sFormattedTitle);
	menu.ExitBackButton = true;
	menu.Display(client, 20);
}

public int SubMenu_Handler(Menu menu, MenuAction action, int param1, int param2)
{
	if(action == MenuAction_Select)
	{
		char sInfo[32];
		menu.GetItem(param2, sInfo, 32);

		if(gB_Stats && StringToInt(sInfo) != -1)
		{
			char sExploded[2][32];
			ExplodeString(sInfo, ";", sExploded, 2, 32, true);

			int first = StringToInt(sExploded[0]);

			switch(first)
			{
				case 0:
				{
					Shavit_OpenStatsMenu(param1, sExploded[1]);
				}

				case 1:
				{
					OpenDeleteMenu(param1, StringToInt(sExploded[1]));
				}
			}
		}

		else
		{
			StartWRMenu(param1, gA_WRCache[param1].sClientMap, gA_WRCache[param1].iLastStyle, gA_WRCache[param1].iLastTrack);
		}
	}

	else if(action == MenuAction_Cancel && param2 == MenuCancel_ExitBack)
	{
		StartWRMenu(param1, gA_WRCache[param1].sClientMap, gA_WRCache[param1].iLastStyle, gA_WRCache[param1].iLastTrack);
	}

	else if(action == MenuAction_End)
	{
		delete menu;
	}

	return 0;
}

public void Shavit_OnDatabaseLoaded()
{
	gH_SQL = Shavit_GetDatabase();
	SetSQLInfo();
}

public Action CheckForSQLInfo(Handle Timer)
{
	return SetSQLInfo();
}

Action SetSQLInfo()
{
	if(gH_SQL == null)
	{
		gH_SQL = Shavit_GetDatabase();

		CreateTimer(0.5, CheckForSQLInfo);
	}

	else
	{
		SQL_DBConnect();

		return Plugin_Stop;
	}

	return Plugin_Continue;
}

void SQL_SetPrefix()
{
	char sFile[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, sFile, PLATFORM_MAX_PATH, "configs/shavit-prefix.txt");

	File fFile = OpenFile(sFile, "r");

	if(fFile == null)
	{
		SetFailState("Cannot open \"configs/shavit-prefix.txt\". Make sure this file exists and that the server has read permissions to it.");
	}
	
	char sLine[PLATFORM_MAX_PATH*2];

	while(fFile.ReadLine(sLine, PLATFORM_MAX_PATH*2))
	{
		TrimString(sLine);
		strcopy(gS_MySQLPrefix, 32, sLine);

		break;
	}

	delete fFile;
}

void SQL_DBConnect()
{
	char sDriver[8];
	gH_SQL.Driver.GetIdentifier(sDriver, 8);
	gB_MySQL = StrEqual(sDriver, "mysql", false);

	char sQuery[512];

	if(gB_MySQL)
	{
		FormatEx(sQuery, 512, "CREATE TABLE IF NOT EXISTS `%splayertimes` (`id` INT NOT NULL AUTO_INCREMENT, `auth` CHAR(32), `map` CHAR(128), `time` FLOAT, `jumps` INT, `style` TINYINT, `date` CHAR(16), `strafes` INT, `sync` FLOAT, `points` FLOAT NOT NULL DEFAULT 0, `track` TINYINT NOT NULL DEFAULT 0, `perfs` FLOAT DEFAULT 0, PRIMARY KEY (`id`), INDEX `map` (`map`, `style`, `track`), INDEX `auth` (`auth`, `date`, `points`), INDEX `time` (`time`)) ENGINE=INNODB;", gS_MySQLPrefix);
	}

	else
	{
		FormatEx(sQuery, 512, "CREATE TABLE IF NOT EXISTS `%splayertimes` (`id` INTEGER PRIMARY KEY, `auth` CHAR(32), `map` CHAR(128), `time` FLOAT, `jumps` INT, `style` TINYINT, `date` CHAR(16), `strafes` INT, `sync` FLOAT, `points` FLOAT NOT NULL DEFAULT 0, `track` TINYINT NOT NULL DEFAULT 0, `perfs` FLOAT DEFAULT 0);", gS_MySQLPrefix);
	}

	gH_SQL.Query(SQL_CreateTable_Callback, sQuery, 0, DBPrio_High);
}

public void SQL_CreateTable_Callback(Database db, DBResultSet results, const char[] error, any data)
{
	if(results == null)
	{
		LogError("Timer (WR module) error! Users' times table creation failed. Reason: %s", error);

		return;
	}

	if(gB_Late)
	{
		for(int i = 1; i <= MaxClients; i++)
		{
			OnClientPutInServer(i);
		}

		gB_Late = false;
	}

	char sQuery[64];
	FormatEx(sQuery, 64, "SELECT strafes FROM %splayertimes LIMIT 1;", gS_MySQLPrefix);
	gH_SQL.Query(SQL_TableMigration1_Callback, sQuery);

	if(gB_MySQL) // this isn't possible in sqlite
	{
		FormatEx(sQuery, 64, "ALTER TABLE %splayertimes MODIFY date CHAR(16);", gS_MySQLPrefix);
		gH_SQL.Query(SQL_AlterTable2_Callback, sQuery);
	}

	FormatEx(sQuery, 64, "SELECT points FROM %splayertimes LIMIT 1;", gS_MySQLPrefix);
	gH_SQL.Query(SQL_TableMigration3_Callback, sQuery);

	FormatEx(sQuery, 64, "SELECT track FROM %splayertimes LIMIT 1;", gS_MySQLPrefix);
	gH_SQL.Query(SQL_TableMigration4_Callback, sQuery);

	FormatEx(sQuery, 64, "SELECT perfs FROM %splayertimes LIMIT 1;", gS_MySQLPrefix);
	gH_SQL.Query(SQL_TableMigration5_Callback, sQuery, 0, DBPrio_Low);
}

public void SQL_TableMigration1_Callback(Database db, DBResultSet results, const char[] error, any data)
{
	if(results == null)
	{
		char sQuery[256];

		if(gB_MySQL)
		{
			FormatEx(sQuery, 256, "ALTER TABLE `%splayertimes` ADD (`strafes` INT NOT NULL DEFAULT 0, `sync` FLOAT NOT NULL DEFAULT 0);", gS_MySQLPrefix);
			gH_SQL.Query(SQL_AlterTable1_Callback, sQuery);
		}

		else
		{
			FormatEx(sQuery, 256, "ALTER TABLE `%splayertimes` ADD COLUMN `strafes` INT NOT NULL DEFAULT 0;", gS_MySQLPrefix);
			gH_SQL.Query(SQL_AlterTable1_Callback, sQuery);

			FormatEx(sQuery, 256, "ALTER TABLE `%splayertimes` ADD COLUMN `sync` FLOAT NOT NULL DEFAULT 0;", gS_MySQLPrefix);
			gH_SQL.Query(SQL_AlterTable1_Callback, sQuery);
		}
	}
}

public void SQL_AlterTable1_Callback(Database db, DBResultSet results, const char[] error, any data)
{
	if(results == null)
	{
		LogError("Timer (WR module) error! Times' table migration (1) failed. Reason: %s", error);
	}
}

public void SQL_AlterTable2_Callback(Database db, DBResultSet results, const char[] error, any data)
{
	if(results == null)
	{
		LogError("Timer (WR module) error! Times' table migration (2) failed. Reason: %s", error);
	}
}

public void SQL_TableMigration3_Callback(Database db, DBResultSet results, const char[] error, any data)
{
	if(results == null)
	{
		char sQuery[256];
		FormatEx(sQuery, 256, "ALTER TABLE `%splayertimes` ADD %s;", gS_MySQLPrefix, (gB_MySQL)? "(`points` FLOAT NOT NULL DEFAULT 0)":"COLUMN `points` FLOAT NOT NULL DEFAULT 0");
		gH_SQL.Query(SQL_AlterTable3_Callback, sQuery);
	}
}

public void SQL_AlterTable3_Callback(Database db, DBResultSet results, const char[] error, any data)
{
	if(results == null)
	{
		LogError("Timer (WR module) error! Times' table migration (3) failed. Reason: %s", error);
	}
}

public void SQL_TableMigration4_Callback(Database db, DBResultSet results, const char[] error, any data)
{
	if(results == null)
	{
		char sQuery[256];
		FormatEx(sQuery, 256, "ALTER TABLE `%splayertimes` ADD %s;", gS_MySQLPrefix, (gB_MySQL)? "(`track` INT NOT NULL DEFAULT 0)":"COLUMN `track` INT NOT NULL DEFAULT 0");
		gH_SQL.Query(SQL_AlterTable4_Callback, sQuery);
	}
}

public void SQL_AlterTable4_Callback(Database db, DBResultSet results, const char[] error, any data)
{
	if(results == null)
	{
		LogError("Timer (WR module) error! Times' table migration (4) failed. Reason: %s", error);
	}
}

public void SQL_TableMigration5_Callback(Database db, DBResultSet results, const char[] error, any data)
{
	if(results == null)
	{
		char sQuery[256];

		if(gB_MySQL)
		{
			FormatEx(sQuery, 256, "ALTER TABLE `%splayertimes` ADD (`perfs` FLOAT DEFAULT 0);", gS_MySQLPrefix);
		}

		else
		{
			FormatEx(sQuery, 256, "ALTER TABLE `%splayertimes` ADD COLUMN `perfs` FLOAT DEFAULT 0;", gS_MySQLPrefix);
		}

		gH_SQL.Query(SQL_AlterTable5_Callback, sQuery);

		return;
	}

	gB_Connected = true;
	OnMapStart();
}

public void SQL_AlterTable5_Callback(Database db, DBResultSet results, const char[] error, any data)
{
	if(results == null)
	{
		LogError("Timer (WR module) error! Times' table migration (5) failed. Reason: %s", error);

		return;
	}

	gB_Connected = true;
	OnMapStart();
}

public void Shavit_OnFinish(int client, int style, float time, int jumps, int strafes, float sync, int track, float oldtime, float perfs)
{
	char sTime[32];
	FormatSeconds(time, sTime, 32);

	char sTrack[32];
	GetTrackName(LANG_SERVER, track, sTrack, 32);

	// 0 - no query
	// 1 - insert
	// 2 - update
	int overwrite = 0;

	if(gA_StyleSettings[style].bUnranked || Shavit_IsPracticeMode(client))
	{
		overwrite = 0; // ugly way of not writing to database
	}

	else if(gF_PlayerRecord[client][style][track] == 0.0)
	{
		overwrite = 1;
	}

	else if(time <= gF_PlayerRecord[client][style][track])
	{
		overwrite = 2;
	}

	if(overwrite > 0 && (time < gF_WRTime[style][track] || gF_WRTime[style][track] == 0.0)) // WR?
	{
		float oldwr = gF_WRTime[style][track];
		gF_WRTime[style][track] = time;

		Call_StartForward(gH_OnWorldRecord);
		Call_PushCell(client);
		Call_PushCell(style);
		Call_PushCell(time);
		Call_PushCell(jumps);
		Call_PushCell(strafes);
		Call_PushCell(sync);
		Call_PushCell(track);
		Call_PushCell(oldwr);
		Call_PushCell(oldtime);
		Call_PushCell(perfs);
		Call_Finish();

		#if defined DEBUG
		Shavit_PrintToChat(client, "old: %.01f new: %.01f", oldwr, time);
		#endif
	}

	int iRank = GetRankForTime(style, time, track);

	if(iRank >= gI_RecordAmount[style][track])
	{
		Call_StartForward(gH_OnWorstRecord);
		Call_PushCell(client);
		Call_PushCell(style);
		Call_PushCell(time);
		Call_PushCell(jumps);
		Call_PushCell(strafes);
		Call_PushCell(sync);
		Call_PushCell(track);
		Call_PushCell(oldtime);
		Call_PushCell(perfs);
		Call_Finish();
	}

	float fDifference = (gF_PlayerRecord[client][style][track] - time);

	if(fDifference < 0.0)
	{
		fDifference = -fDifference;
	}

	char sDifference[16];
	FormatSeconds(fDifference, sDifference, 16, true);

	char sSync[32]; // 32 because colors
	FormatEx(sSync, 32, (sync != -1.0)? " @ %s%.02f%%":"", gS_ChatStrings.sVariable, sync);

	if(overwrite > 0)
	{
		char sAuthID[32];
		GetClientAuthId(client, AuthId_Steam3, sAuthID, 32);

		char sQuery[512];

		if(overwrite == 1) // insert
		{
			Shavit_PrintToChatAll("%s[%s]%s %T", gS_ChatStrings.sVariable, sTrack, gS_ChatStrings.sText, "FirstCompletion", LANG_SERVER, gS_ChatStrings.sVariable2, client, gS_ChatStrings.sText, gS_ChatStrings.sStyle, gS_StyleStrings[style].sStyleName, gS_ChatStrings.sText, gS_ChatStrings.sVariable2, sTime, gS_ChatStrings.sText, gS_ChatStrings.sVariable, iRank, gS_ChatStrings.sText, jumps, strafes, sSync, gS_ChatStrings.sText);

			if(gH_SQL == null)
			{
				return;
			}

			FormatEx(sQuery, 512, "INSERT INTO %splayertimes (auth, map, time, jumps, date, style, strafes, sync, points, track, perfs) VALUES ('%s', '%s', %.03f, %d, %d, %d, %d, %.2f, 0.0, %d, %.2f);", gS_MySQLPrefix, sAuthID, gS_Map, time, jumps, GetTime(), style, strafes, sync, track, perfs);
		}

		else // update
		{
			Shavit_PrintToChatAll("%s[%s]%s %T", gS_ChatStrings.sVariable, sTrack, gS_ChatStrings.sText, "NotFirstCompletion", LANG_SERVER, gS_ChatStrings.sVariable2, client, gS_ChatStrings.sText, gS_ChatStrings.sStyle, gS_StyleStrings[style].sStyleName, gS_ChatStrings.sText, gS_ChatStrings.sVariable2, sTime, gS_ChatStrings.sText, gS_ChatStrings.sVariable, iRank, gS_ChatStrings.sText, jumps, strafes, sSync, gS_ChatStrings.sText, gS_ChatStrings.sWarning, sDifference);

			FormatEx(sQuery, 512, "UPDATE %splayertimes SET time = %.03f, jumps = %d, date = %d, strafes = %d, sync = %.02f, points = 0.0, perfs = %.2f WHERE map = '%s' AND auth = '%s' AND style = %d AND track = %d;", gS_MySQLPrefix, time, jumps, GetTime(), strafes, sync, perfs, gS_Map, sAuthID, style, track);
		}

		gH_SQL.Query(SQL_OnFinish_Callback, sQuery, GetClientSerial(client), DBPrio_High);

		Call_StartForward(gH_OnFinish_Post);
		Call_PushCell(client);
		Call_PushCell(style);
		Call_PushCell(time);
		Call_PushCell(jumps);
		Call_PushCell(strafes);
		Call_PushCell(sync);
		Call_PushCell(iRank);
		Call_PushCell(overwrite);
		Call_PushCell(track);
		Call_PushCell(oldtime);
		Call_PushCell(perfs);
		Call_Finish();

		gF_PlayerRecord[client][style][track] = time;
	}

	else if(overwrite == 0 && !gA_StyleSettings[style].bUnranked)
	{
		Shavit_PrintToChat(client, "%s[%s]%s %T", gS_ChatStrings.sVariable, sTrack, gS_ChatStrings.sText, "WorseTime", client, gS_ChatStrings.sStyle, gS_StyleStrings[style].sStyleName, gS_ChatStrings.sText, gS_ChatStrings.sVariable2, sTime, gS_ChatStrings.sText, jumps, strafes, sSync, gS_ChatStrings.sText, sDifference);
	}

	else
	{
		Shavit_PrintToChat(client, "%s[%s]%s] %T", gS_ChatStrings.sVariable, sTrack, gS_ChatStrings.sText, "UnrankedTime", client, gS_ChatStrings.sStyle, gS_StyleStrings[style].sStyleName, gS_ChatStrings.sText, gS_ChatStrings.sVariable2, sTime, gS_ChatStrings.sText, jumps, strafes, sSync, gS_ChatStrings.sText);
	}
}

public void SQL_OnFinish_Callback(Database db, DBResultSet results, const char[] error, any data)
{
	if(results == null)
	{
		LogError("Timer (WR OnFinish) SQL query failed. Reason: %s", error);

		return;
	}

	int client = GetClientFromSerial(data);

	if(client == 0)
	{
		return;
	}

	UpdateWRCache();
	UpdateClientCache(client);
}

void UpdateLeaderboards()
{
	char sQuery[192];
	FormatEx(sQuery, 192, "SELECT style, time, track FROM %splayertimes WHERE map = '%s' ORDER BY time ASC, date ASC LIMIT 1000;", gS_MySQLPrefix, gS_Map);
	gH_SQL.Query(SQL_UpdateLeaderboards_Callback, sQuery, 0);
}

public void SQL_UpdateLeaderboards_Callback(Database db, DBResultSet results, const char[] error, any data)
{
	if(results == null)
	{
		LogError("Timer (WR UpdateLeaderboards) SQL query failed. Reason: %s", error);

		return;
	}

	for(int i = 0; i < gI_Styles; i++)
	{
		for(int j = 0; j < TRACKS_SIZE; j++)
		{
			gI_RecordAmount[i][j] = 0;
			gA_Leaderboard[i][j].Clear();
		}
	}

	while(results.FetchRow())
	{
		int style = results.FetchInt(0);
		int track = results.FetchInt(2);

		if(style >= gI_Styles || gA_StyleSettings[style].bUnranked || track >= TRACKS_SIZE)
		{
			continue;
		}

		gA_Leaderboard[style][track].Push(results.FetchFloat(1));
	}

	for(int i = 0; i < gI_Styles; i++)
	{
		if(i >= gI_Styles || gA_StyleSettings[i].bUnranked)
		{
			continue;
		}

		for(int j = 0; j < TRACKS_SIZE; j++)
		{
			SortADTArray(gA_Leaderboard[i][j], Sort_Ascending, Sort_Float);
			gI_RecordAmount[i][j] = gA_Leaderboard[i][j].Length;
		}
	}
}

int GetRankForTime(int style, float time, int track)
{
	if(time <= gF_WRTime[style][track] || gI_RecordAmount[style][track] <= 0)
	{
		return 1;
	}

	if(gA_Leaderboard[style][track] != null && gA_Leaderboard[style][track].Length > 0)
	{
		for(int i = 0; i < gI_RecordAmount[style][track]; i++)
		{
			if(time <= gA_Leaderboard[style][track].Get(i))
			{
				return ++i;
			}
		}
	}

	return (gI_RecordAmount[style][track] + 1);
}

void GuessBestMapName(const char[] input, char[] output, int size)
{
	if(gA_ValidMaps.FindString(input) != -1)
	{
		strcopy(output, size, input);

		return;
	}

	char sCache[128];

	for(int i = 0; i < gI_ValidMaps; i++)
	{
		gA_ValidMaps.GetString(i, sCache, 128);

		if(StrContains(sCache, input) != -1)
		{
			strcopy(output, size, sCache);

			return;
		}
	}
}

void GetTrackName(int client, int track, char[] output, int size)
{
	if(track < 0 || track >= TRACKS_SIZE)
	{
		FormatEx(output, size, "%T", "Track_Unknown", client);

		return;
	}

	static char sTrack[16];
	FormatEx(sTrack, 16, "Track_%d", track);
	FormatEx(output, size, "%T", sTrack, client);
}
