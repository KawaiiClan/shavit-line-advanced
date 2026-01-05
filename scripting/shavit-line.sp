#include <clientprefs>
#include <closestpos>
#include <sdktools>
#include <sdkhooks>
#include <dhooks>
#include <shavit>
#include <sourcemod>

#pragma semicolon 1
#pragma newdecls required

#define COLORS_NUMBER 9

enum
{
	Red,
	Orange,
	Green,
	Cyan,
	White,
	Yellow,
	Blue,
	Purple,
	Pink
};

char g_sColorStrs[][] =
{
	"Red",
	"Orange",
	"Green",
	"Cyan",
	"White",
	"Yellow",
	"Blue",
	"Purple",
	"Pink"
};

int g_iColorInts[][] =
{
	{255, 0, 0},
	{255, 165, 0},
	{0, 255, 0},
	{0, 255, 255},
	{255, 255, 255},
	{255, 255, 0},
	{0, 0, 255},
	{128, 0, 128},
	{238, 0, 255}
};

#define SKIPFRAMES 5
#define SEC_AHEAD 7
#define SEC_UPDATE_DELAY 1.5

#define DUCKCOLOR 0
#define NODUCKCOLOR 1
#define LINECOLOR 2
#define ENABLED 3
#define FLATMODE 4
#define TRACK_IDX 5
#define STYLE_IDX 6
#define CMD_NUM 7
#define EDIT_ELEMENT 8
#define EDIT_COLOR 9

#define SETTINGS_NUMBER 5

#define TE_TIME 1.0
#define TE_MIN 0.5
#define TE_MAX 0.5

#define ELEMENT_NUMBER 3

char g_sElementStrings[][] =
{
	"Duck Box",
	"No Duck Box",
	"Line"
};

enum
{
	DuckBox,
	NoDuckBox,
	Line
}

enum OSType
{
	OSUnknown = 0,
	OSWindows = 1,
	OSLinux = 2
};

stylestrings_t g_sStyleStrings[STYLE_LIMIT];

bool g_bLate = false;
int g_iStyles;

OSType gOSType;
EngineVersion gEngineVer;

int sprite;
ArrayList g_hReplayFrames[STYLE_LIMIT][TRACKS_SIZE];
ClosestPos g_hClosestPos[STYLE_LIMIT][TRACKS_SIZE];

int g_iIntCache[MAXPLAYERS + 1][10];
Cookie g_hSettings[SETTINGS_NUMBER];

int gTELimitData;
Address gTELimitAddress;

public Plugin myinfo =
{
	name = "[shavit] Line",
	author = "enimmy, olivia",
	description = "Shows the WR route with a path on the ground. Use the command sm_line to toggle.",
	version = "0.3",
	url = "https://github.com/KawaiiClan/shavit-line-advanced"
};

public void OnPluginStart()
{
	g_hSettings[DUCKCOLOR] = new Cookie("shavit_line_duckcolor", "", CookieAccess_Private);
	g_hSettings[NODUCKCOLOR] = new Cookie("shavit_line_noduckcolor", "", CookieAccess_Private);
	g_hSettings[LINECOLOR] = new Cookie("shavit_line_linecolor", "", CookieAccess_Private);
	g_hSettings[ENABLED] = new Cookie("shavit_line_enabled", "", CookieAccess_Private);
	g_hSettings[FLATMODE] = new Cookie("shavit_line_flatmode", "", CookieAccess_Private);

	RegConsoleCmd("sm_line", LineCmd);

	GameData gconf = new GameData("shavit-line.games");
	gOSType = view_as<OSType>(GameConfGetOffset(gconf, "OSType"));
	if(gOSType == OSUnknown)
		SetFailState("Failed to get OS type. Make sure gamedata file is in gamedata folder, and you are using windows or linux. Your Current OS Type is %d", gOSType);

	gEngineVer = GetEngineVersion();
	if(gEngineVer == Engine_CSS)
		BytePatchTELimit(gconf);

	if(LibraryExists("shavit-replay-playback"))
		Shavit_OnReplaysLoaded();

	if(g_bLate)
	{
		for (int i = 1; i <= MaxClients; i++)
		{
			if(!IsClientConnected(i) || !IsClientInGame(i) || IsFakeClient(i))
				continue;

			if(AreClientCookiesCached(i))
				OnClientCookiesCached(i);
		}
		Shavit_OnStyleConfigLoaded(-1);
	}
}

public void Shavit_OnStyleConfigLoaded(int styles)
{
	if(styles == -1)
		styles = Shavit_GetStyleCount();
 
	for(int i = 0; i < styles; i++)
		Shavit_GetStyleStrings(i, sStyleName, g_sStyleStrings[i].sStyleName, sizeof(stylestrings_t::sStyleName));

	g_iStyles = styles;
}

public void OnPluginEnd()
{
	if (gTELimitAddress == Address_Null)
		return;

	StoreToAddress(gTELimitAddress, gTELimitData, NumberType_Int8);
}

public void OnMapEnd()
{
	for (int i  = 0; i < STYLE_LIMIT; i++)
	{
		for (int j = 0; j < TRACKS_SIZE; j++)
		{
			delete g_hClosestPos[i][j];
			delete g_hReplayFrames[i][j];
		}
	}
}

stock void BytePatchTELimit(Handle gconf)
{
	gTELimitAddress = GameConfGetAddress(gconf, "TELimit");
	if (gTELimitAddress == Address_Null)
		SetFailState("Failed to get address of \"TELimit\".");

	gTELimitData = LoadFromAddress(gTELimitAddress, NumberType_Int8);

	if (gOSType == OSWindows)
		StoreToAddress(gTELimitAddress, 0xFF, NumberType_Int8);
	else if (gOSType == OSLinux)
		StoreToAddress(gTELimitAddress, 0x02, NumberType_Int8);
	else
		SetFailState("Failed to store address of \"TELimit\".");
}

public void OnClientCookiesCached(int client)
{
	char strCookie[256];
	for(int i = 0; i < SETTINGS_NUMBER; i++)
	{
		GetClientCookie(client, g_hSettings[i], strCookie, sizeof(strCookie));
		if(strCookie[0] == '\0')
		{
			PushDefaultSettings(client);
			break;
		}
		g_iIntCache[client][i] = StringToInt(strCookie);
	}
	UpdateTrackStyle(client);
}

public void Shavit_OnReplaysLoaded()
{
	for(int style = 0; style < STYLE_LIMIT; style++)
		for(int track = 0; track < TRACKS_SIZE; track++)
			LoadReplay(style, track);
}

public void LoadReplay(int style, int track)
{
	delete g_hClosestPos[style][track];
	delete g_hReplayFrames[style][track];
	ArrayList list = Shavit_GetReplayFrames(style, track);
	g_hReplayFrames[style][track] = new ArrayList(sizeof(frame_t));

	if(!list)
		return;

	frame_t aFrame;
	bool hitGround = false;

	for(int i = 0; i < list.Length; i++)
	{
		list.GetArray(i, aFrame, sizeof(frame_t));
		if (aFrame.flags & FL_ONGROUND && !hitGround)
			hitGround = true;
		else
			hitGround = false;

		if (hitGround || i % SKIPFRAMES == 0)
			g_hReplayFrames[style][track].PushArray(aFrame);
	}

	g_hClosestPos[style][track] = new ClosestPos(g_hReplayFrames[style][track], 0, 0, Shavit_GetReplayFrameCount(style, track));
	delete list;
}

public void Shavit_OnStyleChanged(int client, int oldstyle, int newstyle, int track, bool manual)
{
	g_iIntCache[client][TRACK_IDX] = track;

	if(Shavit_GetReplayFrameCount(newstyle, track) > 0)
	{
		g_iIntCache[client][STYLE_IDX] = newstyle;
		return;
	}
	else if(Shavit_GetStyleSettingBool(newstyle, "kzcheckpoints"))
	{
		int startStyle = Shavit_GetStyleSettingInt(newstyle, "kzcheckpoints_onstart");
		int teleStyle = Shavit_GetStyleSettingInt(newstyle, "kzcheckpoints_ontele");
		if(teleStyle > -1)
		{
			if(Shavit_GetReplayFrameCount(teleStyle, track) > 0)
				g_iIntCache[client][STYLE_IDX] = teleStyle;
			else
				g_iIntCache[client][STYLE_IDX] = 0;
		}
		else if(startStyle > -1)
		{
			if(Shavit_GetReplayFrameCount(startStyle, track) > 0)
				g_iIntCache[client][STYLE_IDX] = startStyle;
			else
				g_iIntCache[client][STYLE_IDX] = 0;
		}
	}
	else
		g_iIntCache[client][STYLE_IDX] = 0;
}

public void Shavit_OnTrackChanged(int client, int oldtrack, int newtrack)
{
	g_iIntCache[client][TRACK_IDX] = newtrack;
}

public void Shavit_OnReplaySaved(int client, int style, float time, int jumps, int strafes, float sync, int track, float oldtime, float perfs, float avgvel, float maxvel, int timestamp, bool isbestreplay, bool istoolong, ArrayList replaypaths, ArrayList frames, int preframes, int postframes, const char[] name)
{
	delete g_hClosestPos[style][track];
	delete g_hReplayFrames[style][track];
	g_hReplayFrames[style][track] = new ArrayList(sizeof(frame_t));

	if(!frames)
		return;

	frame_t aFrame;
	bool hitGround = false;

	for(int i = 0; i < frames.Length; i++)
	{
		frames.GetArray(i, aFrame, sizeof(frame_t));
		if (aFrame.flags & FL_ONGROUND && !hitGround)
			hitGround = true;
		else
			hitGround = false;

		if (hitGround || i % SKIPFRAMES == 0)
			g_hReplayFrames[style][track].PushArray(aFrame);
	}

	g_hClosestPos[style][track] = new ClosestPos(g_hReplayFrames[style][track], 0, 0, frames.Length);
}
	
public void OnConfigsExecuted()
{
	sprite = PrecacheModel("sprites/laserbeam.vmt");
}

Action LineCmd(int client, int args)
{
	if(IsValidClient(client))
		ShowToggleMenu(client);
	return Plugin_Handled;
}

void ShowToggleMenu(int client)
{
	Menu menu = CreateMenu(LinesMenu_Callback);
	SetMenuTitle(menu, "Line Settings\n ");
	AddMenuItem(menu, "enabled", (g_iIntCache[client][ENABLED]) ? "[X] Enabled":"[  ] Enabled");
	AddMenuItem(menu, "flatmode", (g_iIntCache[client][FLATMODE]) ? "[X] Flat Mode":"[  ] Flat Mode");

	char sMessage[128];
	Format(sMessage, sizeof(sMessage), "Style: %s", g_sStyleStrings[g_iIntCache[client][STYLE_IDX]].sStyleName);
	AddMenuItem(menu, "style", sMessage);
	AddMenuItem(menu, "colors", "Colors");
	DisplayMenu(menu, client, MENU_TIME_FOREVER);
}

public int LinesMenu_Callback (Menu menu, MenuAction action, int client, int option)
{
	if(action == MenuAction_Select)
	{
		char info[32];
		GetMenuItem(menu, option, info, sizeof(info));

		if(StrEqual(info, "enabled"))
			g_iIntCache[client][ENABLED] = !g_iIntCache[client][ENABLED];
		else if(StrEqual(info, "flatmode"))
			g_iIntCache[client][FLATMODE] = !g_iIntCache[client][FLATMODE];
		else if(StrEqual(info, "style"))
		{
			SelectStyleMenu(client);
			return Plugin_Handled;
		}
		else if(StrEqual(info, "colors")) {
			ShowColorOptionsMenu(client);
			return Plugin_Handled;
		}
		PushCookies(client);
		ShowToggleMenu(client);
	}
	else if(action == MenuAction_End)
		delete menu;
	return Plugin_Handled;
}

void SelectStyleMenu(int client)
{
	Menu menu = new Menu(SelectStyleMenuHandler);
	SetMenuTitle(menu, "Line Style\n ");

	int[] iOrderedStyles = new int[g_iStyles];
	Shavit_GetOrderedStyles(iOrderedStyles, g_iStyles);

	for(int j = 0; j < g_iStyles; j++)
	{
		int iStyle = iOrderedStyles[j];
		char sStyleID[8];
		IntToString(iStyle, sStyleID, sizeof(sStyleID));
		menu.AddItem(sStyleID, g_sStyleStrings[iStyle].sStyleName);
	}

	menu.ExitBackButton = true;
	menu.ExitButton = true;
	DisplayMenu(menu, client, MENU_TIME_FOREVER);
}

public int SelectStyleMenuHandler(Menu menu, MenuAction action, int param1, int param2)
{
	if(action == MenuAction_Select)
	{
		char sStyleID[8];
		menu.GetItem(param2, sStyleID, sizeof(sStyleID));
		int iStyleID = StringToInt(sStyleID);

		if(0 <= iStyleID <= g_iStyles)
		{
			g_iIntCache[param1][STYLE_IDX] = iStyleID;
			ShowToggleMenu(param1);
		}
		else
		{
			g_iIntCache[param1][STYLE_IDX] = 0;
			Shavit_PrintToChat(param1, "Invalid style, please try again");
			SelectStyleMenu(param1);
		}
	}
	else if(action == MenuAction_Cancel)
	{
		if(param2 == MenuCancel_ExitBack)
			ShowToggleMenu(param1);
	}
	else if(action == MenuAction_End)
		delete menu;

	return Plugin_Handled;
}

void ShowColorOptionsMenu(int client)
{
	Menu menu = CreateMenu(LinesColors_Callback);
	SetMenuTitle(menu, "Line Colors\n ");

	char sMessage[256];
	Format(sMessage, sizeof(sMessage), "Editing: %s", g_sElementStrings[g_iIntCache[client][EDIT_ELEMENT]]);
	AddMenuItem(menu, "editbox", sMessage);

	Format(sMessage, sizeof(sMessage), "Color: %s\n ", g_sColorStrs[g_iIntCache[client][g_iIntCache[client][EDIT_ELEMENT]]]);
	AddMenuItem(menu, "editcolor", sMessage);

	AddMenuItem(menu, "reset", "Reset Defaults");
	
	menu.ExitBackButton = true;
	DisplayMenu(menu, client, MENU_TIME_FOREVER);
}

public int LinesColors_Callback(Menu menu, MenuAction action, int client, int option)
{
	if(action == MenuAction_Select)
	{
		char info[32];
		GetMenuItem(menu, option, info, sizeof(info));

		if(StrEqual(info, "editbox"))
		{
			g_iIntCache[client][EDIT_ELEMENT]++;

			if(g_iIntCache[client][EDIT_ELEMENT] >= ELEMENT_NUMBER)
				g_iIntCache[client][EDIT_ELEMENT] = 0;
		}
		else if(StrEqual(info, "editcolor"))
		{
			g_iIntCache[client][EDIT_COLOR]++;

			if(g_iIntCache[client][EDIT_COLOR] >= sizeof(g_sColorStrs))
				g_iIntCache[client][EDIT_COLOR] = 0;

			g_iIntCache[client][g_iIntCache[client][EDIT_ELEMENT]] = g_iIntCache[client][EDIT_COLOR];
			PushCookies(client);
		}
		else if(StrEqual(info, "reset"))
			PushDefaultColors(client);

		ShowColorOptionsMenu(client);
	}
	else if(action == MenuAction_Cancel)
		if(option == MenuCancel_ExitBack)
			ShowToggleMenu(client);
	else if(action == MenuAction_End)
		delete menu;

	return 0;
}

void PushDefaultSettings(int client)
{
	g_iIntCache[client][ENABLED] = 0;
	g_iIntCache[client][FLATMODE] = 0;
	g_iIntCache[client][STYLE_IDX] = 0;
	g_iIntCache[client][DUCKCOLOR] = Purple;
	g_iIntCache[client][NODUCKCOLOR] = Pink;
	g_iIntCache[client][LINECOLOR] = White;
	UpdateTrackStyle(client);
}

void PushDefaultColors(int client)
{
	g_iIntCache[client][DUCKCOLOR] = Purple;
	g_iIntCache[client][NODUCKCOLOR] = Pink;
	g_iIntCache[client][LINECOLOR] = White;
	PushCookies(client);
}

void PushCookies(int client)
{
	for(int i = 0; i < SETTINGS_NUMBER; i++)
		SetCookie(client, g_hSettings[i], g_iIntCache[client][i]);
}

void SetCookie(int client, Cookie hCookie, int n)
{
	char strCookie[64];
	IntToString(n, strCookie, sizeof(strCookie));
	SetClientCookie(client, hCookie, strCookie);
}

public Action OnPlayerRunCmd(int client)
{
	if(!IsValidClient(client) || !g_iIntCache[client][ENABLED])
		return Plugin_Continue;

	if((++g_iIntCache[client][CMD_NUM] % 60) != 0)
		return Plugin_Continue;
	g_iIntCache[client][CMD_NUM] = 0;

	ArrayList list = g_hReplayFrames[g_iIntCache[client][STYLE_IDX]][g_iIntCache[client][TRACK_IDX]];
	if(list.Length == 0)
		return Plugin_Continue;

	float pos[3];
	GetClientAbsOrigin(client, pos);
	int closeframe = max(0, (g_hClosestPos[g_iIntCache[client][STYLE_IDX]][g_iIntCache[client][TRACK_IDX]].Find(pos)) - 30);
	int endframe = min(list.Length, closeframe + 125);

	int flags;
	frame_t aFrame;
	list.GetArray(closeframe, aFrame, sizeof(frame_t));
	pos = aFrame.pos;
	bool firstFlatDraw = true;
	for(int i = closeframe; i < endframe; i++)
	{
		list.GetArray(i, aFrame, 8);
		aFrame.pos[2] += 2.5;
		if(aFrame.flags & FL_ONGROUND && !(flags & FL_ONGROUND))
		{
			DrawBox(client, aFrame.pos, g_iColorInts[g_iIntCache[client][(flags & FL_DUCKING) ? DUCKCOLOR:NODUCKCOLOR]]);

			if(!firstFlatDraw)
				DrawBeam(client, pos, aFrame.pos, TE_TIME, TE_MIN, TE_MAX, g_iColorInts[g_iIntCache[client][LINECOLOR]], 0.0, 0);
			firstFlatDraw = false;

			pos = aFrame.pos;
		}

		if(!g_iIntCache[client][FLATMODE])
		{
			DrawBeam(client, pos, aFrame.pos, TE_TIME, TE_MIN, TE_MAX, g_iColorInts[g_iIntCache[client][LINECOLOR]], 0.0, 0);
			pos = aFrame.pos;
		}

		flags = aFrame.flags;
	}
	return Plugin_Continue;
}

float box_offset[4][2] =
{
	{-10.0, 10.0},
	{10.0, 10.0},
	{-10.0, -10.0},
	{10.0, -10.0},
};

void DrawBox(int client, float pos[3], int color[3])
{
	float square[4][3];
	for(int z = 0; z < 4; z++)
	{
		square[z][0] = pos[0] + (box_offset[z][0]);
		square[z][1] = pos[1] + (box_offset[z][1]);
		square[z][2] = pos[2];
	}

	DrawBeam(client, square[0], square[1], TE_TIME, TE_MIN, TE_MAX, color, 0.0, 0);
	DrawBeam(client, square[0], square[2], TE_TIME, TE_MIN, TE_MAX, color, 0.0, 0);
	DrawBeam(client, square[2], square[3], TE_TIME, TE_MIN, TE_MAX, color, 0.0, 0);
	DrawBeam(client, square[1], square[3], TE_TIME, TE_MIN, TE_MAX, color, 0.0, 0);
}

void DrawBeam(int client, float startvec[3], float endvec[3], float life, float width, float endwidth, int color[3], float amplitude, int speed)
{
	int sendColor[4];
	for(int i = 0; i < 3; i++)
		sendColor[i] = color[i];

	sendColor[3] = 255;

	TE_SetupBeamPoints(startvec, endvec, sprite, 0, 0, 66, life, width, endwidth, 0, amplitude, sendColor, speed);
	TE_SendToClient(client);
}

int min(int a, int b)
{
	return a < b ? a : b;
}

int max(int a, int b)
{
	return a > b ? a : b;
}

void UpdateTrackStyle(int client)
{
	g_iIntCache[client][TRACK_IDX] = Shavit_GetClientTrack(client);
	g_iIntCache[client][STYLE_IDX] = Shavit_GetBhopStyle(client);
}
