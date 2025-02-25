#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_AUTHOR "HelpMe (Modified by Claude)"
#define PLUGIN_VERSION "2.2"

#define TRIGGER_NAME "nobuild_entity"
#define MAX_SEARCH_DIST 600.0
#define MAX_BEAM_POINTS 8
#define HEIGHT_ADJUST_INCREMENT 8.0  // Amount to adjust height per scroll
#define DOUBLE_CLICK_TIME 0.3  // Time window in seconds for double click

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

bool g_bAllowOutline = true;
Database g_Database;

int g_iLaserMaterial = -1;
int g_iHaloMaterial = -1;

// Custom sizes storage
float g_fMinBounds[MAXPLAYERS + 1][3];
float g_fMaxBounds[MAXPLAYERS + 1][3];
float g_fAreaCenter[MAXPLAYERS + 1][3];  // Store the calculated center of the area
char g_sAllowSentry[MAXPLAYERS + 1] = "0";
char g_sAllowDispenser[MAXPLAYERS + 1] = "0";
char g_sAllowTeleporters[MAXPLAYERS + 1] = "0";
char g_sTeamNum[MAXPLAYERS + 1] = "0";
float g_fLastClickTime[MAXPLAYERS + 1] = { 0.0, ... };

// Custom area creation tracking
bool g_bCreatingArea[MAXPLAYERS + 1] = { false, ... };
int g_iAreaStep[MAXPLAYERS + 1] = { 0, ... };
float g_fAreaPoints[MAXPLAYERS + 1][2][3]; // Two points: start and end
int g_iPreviewEntities[MAXPLAYERS + 1] = { INVALID_ENT_REFERENCE, ... };
Handle g_hPreviewTimer[MAXPLAYERS + 1] = { null, ... };

// Track vertical offset for height adjustment with scroll wheel
float g_fVerticalOffset[MAXPLAYERS + 1] = { 0.0, ... };

// Global array to track previous button states
int g_iPreviousButtons[MAXPLAYERS + 1] = { 0, ... };

public Plugin myinfo = 
{
  name = "[TF2] No-Build Areas", 
  author = PLUGIN_AUTHOR, 
  description = "Allows creating custom-sized no-build areas on TF2 maps", 
  version = PLUGIN_VERSION, 
  url = "https://forums.alliedmods.net/showthread.php?p=2537267"
};

public void OnPluginStart()
{
  HookEvent("teamplay_round_start", Event_OnRoundStart);
  HookEvent("player_disconnect", Event_OnPlayerDisconnect);
  
  CreateConVar("sm_nobuild_version", PLUGIN_VERSION, "Custom no-build areas version", FCVAR_SPONLY | FCVAR_REPLICATED | FCVAR_NOTIFY);
  
  RegAdminCmd("sm_nobuild", CMD_NoBuild, ADMFLAG_ROOT, "Opens the nobuild menu.");
  RegAdminCmd("sm_shownobuild", CMD_ShowNoBuild, ADMFLAG_ROOT, "Shows all nobuild areas for 10 seconds to the client");
  RegAdminCmd("sm_cancelarea", CMD_CancelArea, ADMFLAG_ROOT, "Cancels the current area creation");
  
  // Hook mouse wheel commands globally
  AddCommandListener(Command_InvNext, "invnext");
  AddCommandListener(Command_InvPrev, "invprev");
  
  ConnectToDatabase();
  
  for (int i = 1; i <= MaxClients; i++)
  {
    if (IsClientInGame(i))
    {
      SDKHook(i, SDKHook_PreThink, OnClientPreThink);
    }
  }
}

public void OnClientPutInServer(int client)
{
  SDKHook(client, SDKHook_PreThink, OnClientPreThink);
  g_iPreviousButtons[client] = 0;
  g_fVerticalOffset[client] = 0.0;
}

public void OnMapStart()
{
  g_iLaserMaterial = PrecacheModel("materials/sprites/laser.vmt");
  g_iHaloMaterial = PrecacheModel("materials/sprites/halo01.vmt");
  PrecacheModel("models/props_2fort/miningcrate002.mdl", true);
  
  // Precache the feedback sound
  PrecacheSound("buttons/button14.wav", true);
}

public void OnMapEnd()
{
  KillAllNobuild();
  for (int i = 1; i <= MaxClients; i++)
  {
    CleanupPreview(i);
  }
}

public Action Event_OnPlayerDisconnect(Event event, const char[] name, bool dontBroadcast)
{
  int client = GetClientOfUserId(event.GetInt("userid"));
  if (client > 0)
  {
    CleanupPreview(client);
    g_bCreatingArea[client] = false;
    g_iAreaStep[client] = 0;
    g_fVerticalOffset[client] = 0.0;
  }
  
  return Plugin_Continue;
}

public Action CMD_CancelArea(int client, int args)
{
  if (g_bCreatingArea[client])
  {
    g_bCreatingArea[client] = false;
    g_iAreaStep[client] = 0;
    g_fVerticalOffset[client] = 0.0;
    CleanupPreview(client);
    PrintToChat(client, "\x04[NoBuilds]\x01 Area creation canceled.");
  }
  else
  {
    PrintToChat(client, "\x04[NoBuilds]\x01 You are not creating a area.");
  }
  
  return Plugin_Handled;
}

void CleanupPreview(int client)
{
  // Kill preview timer
  if (g_hPreviewTimer[client] != null)
  {
    delete g_hPreviewTimer[client];
    g_hPreviewTimer[client] = null;
  }
  
  // Remove preview entity
  if (g_iPreviewEntities[client] != INVALID_ENT_REFERENCE)
  {
    int entity = EntRefToEntIndex(g_iPreviewEntities[client]);
    if (entity != INVALID_ENT_REFERENCE)
    {
      RemoveEntity(entity);
    }
    g_iPreviewEntities[client] = INVALID_ENT_REFERENCE;
  }
}

void ConnectToDatabase()
{
  if (SQL_CheckConfig("nobuildareas"))
  {
    Database.Connect(SQL_OnConnect, "nobuildareas");
  }
  else
  {
    SetFailState("Can't find 'nobuildareas' entry in sourcemod/configs/databases.cfg!");
  }
}

public void SQL_OnConnect(Database db, const char[] error, any data)
{
  if (db == null)
  {
    LogError("Failed to connect! Error: %s", error);
    PrintToServer("Failed to connect: %s", error);
    SetFailState("SQL Error. See error logs for details.");
    return;
  }
  else
  {
    g_Database = db;
    g_Database.Query(SQL_ErrorCheck, "SET NAMES 'utf8'");
    g_Database.Query(SQL_ErrorCheck, 
      "CREATE TABLE IF NOT EXISTS nobuildareas ("
      ..."locX VARCHAR(32), "
      ..."locY VARCHAR(32), "
      ..."locZ VARCHAR(32), "
      ..."minX VARCHAR(32), "
      ..."minY VARCHAR(32), "
      ..."minZ VARCHAR(32), "
      ..."maxX VARCHAR(32), "
      ..."maxY VARCHAR(32), "
      ..."maxZ VARCHAR(32), "
      ..."allowsentry VARCHAR(16), "
      ..."allowdispenser VARCHAR(16), "
      ..."allowteleporters VARCHAR(16), "
      ..."teamnum VARCHAR(16), "
      ..."map VARCHAR(150)"
      ...");"
      );
  }
}

public void SQL_ErrorCheck(Database db, DBResultSet results, const char[] error, any data)
{
  if (error[0] != '\0')
  {
    LogError("SQL Error: %s", error);
  }
}

public Action Event_OnRoundStart(Event event, const char[] name, bool dontBroadcast)
{
  char mapname[50];
  GetCurrentMap(mapname, sizeof(mapname));
  
  char query[128];
  g_Database.Format(query, sizeof(query), "SELECT * FROM nobuildareas WHERE map = '%s';", mapname);
  g_Database.Query(SQL_OnGetTrigger, query);
  return Plugin_Continue;
}

public void SQL_OnGetTrigger(Database db, DBResultSet results, const char[] error, any data)
{
  if (db == null)
  {
    LogError("Query failed! %s", error);
    return;
  }

  if (results.RowCount == 0)
  {
    return;
  }

  while (results.FetchRow())
  {
    float pos[3];
    float minbounds[3];
    float maxbounds[3];
    char allowsentry[16];
    char allowdispenser[16];
    char allowteleporters[16];
    char teamnum[16];
    pos[0] = results.FetchFloat(0);
    pos[1] = results.FetchFloat(1);
    pos[2] = results.FetchFloat(2);
    minbounds[0] = results.FetchFloat(3);
    minbounds[1] = results.FetchFloat(4);
    minbounds[2] = results.FetchFloat(5);
    maxbounds[0] = results.FetchFloat(6);
    maxbounds[1] = results.FetchFloat(7);
    maxbounds[2] = results.FetchFloat(8);
    results.FetchString(9, allowsentry, sizeof(allowsentry));
    results.FetchString(10, allowdispenser, sizeof(allowdispenser));
    results.FetchString(11, allowteleporters, sizeof(allowteleporters));
    results.FetchString(12, teamnum, sizeof(teamnum));
    InsertTrigger(pos, minbounds, maxbounds, allowsentry, allowdispenser, allowteleporters, teamnum);
  }
}

public Action CMD_NoBuild(int client, int args)
{
  Menu menu = new Menu(Nobuild_Menu);
  menu.SetTitle("No-Build Menu:");
  menu.AddItem("0", "Create no-build area", ITEMDRAW_DEFAULT);
  menu.AddItem("1", "Delete nearest no-build area", ITEMDRAW_DEFAULT);
  menu.Display(client, 20);
  
  return Plugin_Handled;
}

public int Nobuild_Menu(Menu menu, MenuAction action, int param1, int param2)
{
  if (action == MenuAction_Select)
  {
    char option[32];
    menu.GetItem(param2, option, sizeof(option));
    int choice = StringToInt(option);
    
    switch (choice)
    {
      case 0: // Create custom area
      {
        StartAreaCreation(param1);
      }
      case 1: // Delete nearest area
      {
        DeleteTrigger(param1);
      }
    }
  }
  else if (action == MenuAction_End)
  {
    delete menu;
  }
  
  return 0;
}

void StartAreaCreation(int client)
{
  // Reset any existing area creation
  CleanupPreview(client);
  
  g_bCreatingArea[client] = true;
  g_iAreaStep[client] = 1;
  g_fVerticalOffset[client] = 0.0;
  g_fLastClickTime[client] = 0.0;
  
  PrintToChat(client, "\x04[NoBuilds]\x01 Point at a location and \x05double-click left mouse\x01 to set a corner.");
  PrintToChat(client, "\x04[NoBuilds]\x01 Use \x05right-click\x01 to raise height and \x05left-click\x01 to lower height.");
  PrintToChat(client, "\x04[NoBuilds]\x01 Current height offset: \x030\x01 units");
  PrintToChat(client, "\x04[NoBuilds]\x01 Use \x02/sm_cancelarea\x01 to cancel.");
  
  // Start preview timer
  g_hPreviewTimer[client] = CreateTimer(0.1, Timer_AreaPreview, client, TIMER_REPEAT);
}

public Action Timer_AreaPreview(Handle timer, int client)
{
  if (!IsClientInGame(client) || !g_bCreatingArea[client])
  {
    delete g_hPreviewTimer[client];
    return Plugin_Stop;
  }
  
  float eyePos[3], eyeAng[3], endPos[3];
  GetClientEyePosition(client, eyePos);
  GetClientEyeAngles(client, eyeAng);
  
  TR_TraceRayFilter(eyePos, eyeAng, MASK_SOLID, RayType_Infinite, TraceFilterPlayers);
  
  if (TR_DidHit())
  {
    TR_GetEndPosition(endPos);
    
    // Apply vertical offset for height adjustment
    endPos[2] += g_fVerticalOffset[client];
    
    // Round to whole numbers for cleaner display
    for (int i = 0; i < 3; i++)
    {
      endPos[i] = float(RoundToFloor(endPos[i]));
    }
    
    // Show a marker at the current aim position with appropriate color
    int color[4] = {0, 255, 0, 255}; // Green for point 1
    if (g_iAreaStep[client] == 2)
    {
      color = {255, 165, 0, 255}; // Orange for point 2
    }
    
    TE_SetupBeamRingPoint(endPos, 5.0, 8.0, g_iLaserMaterial, g_iHaloMaterial, 0, 15, 0.1, 2.0, 0.0, color, 1, 0);
    TE_SendToClient(client);
    
    // If we have both points, preview the area
    if (g_iAreaStep[client] == 2)
    {
      float mins[3], maxs[3], center[3];
      
      // Calculate area bounds
      for (int i = 0; i < 3; i++)
      {
        mins[i] = (g_fAreaPoints[client][0][i] < endPos[i]) ? g_fAreaPoints[client][0][i] : endPos[i];
        maxs[i] = (g_fAreaPoints[client][0][i] > endPos[i]) ? g_fAreaPoints[client][0][i] : endPos[i];
      }
      
      // Calculate center
      for (int i = 0; i < 3; i++)
      {
        center[i] = (mins[i] + maxs[i]) / 2.0;
      }
      
      // Adjust mins and maxs to be relative to center
      float relMins[3], relMaxs[3];
      for (int i = 0; i < 3; i++)
      {
        relMins[i] = mins[i] - center[i];
        relMaxs[i] = maxs[i] - center[i];
      }
      
      // Draw preview box
      int Color[4] = { 0, 255, 255, 255 }; // Cyan
      TE_SendBeamBoxToClient(client, mins, maxs, g_iLaserMaterial, g_iHaloMaterial, 0, 30, 0.1, 3.0, 3.0, 2, 1.0, Color, 0);
      
      // Display dimensions
      float width = maxs[0] - mins[0];
      float length = maxs[1] - mins[1];
      float height = maxs[2] - mins[2];
      
      // Show dimensions to client
      PrintHintText(client, "Area Dimensions: %.0f x %.0f x %.0f units", width, length, height);
    }
    else
    {
      // Show current vertical offset when in first step
      PrintHintText(client, "Height offset: %.0f units (Use scroll wheel to adjust)", g_fVerticalOffset[client]);
    }
  }
  
  return Plugin_Continue;
}

public Action Command_InvNext(int client, const char[] command, int args)
{
  if (client <= 0 || !IsClientInGame(client) || !g_bCreatingArea[client])
    return Plugin_Continue;
  
  // Scroll up - increase height
  g_fVerticalOffset[client] += HEIGHT_ADJUST_INCREMENT;
  PrintHintText(client, "Height offset: %.0f units", g_fVerticalOffset[client]);
  
  // Block the original command from executing
  return Plugin_Handled;
}

public Action Command_InvPrev(int client, const char[] command, int args)
{
  if (client <= 0 || !IsClientInGame(client) || !g_bCreatingArea[client])
    return Plugin_Continue;
  
  // Scroll down - decrease height
  g_fVerticalOffset[client] -= HEIGHT_ADJUST_INCREMENT;
  PrintHintText(client, "Height offset: %.0f units", g_fVerticalOffset[client]);
  
  // Block the original command from executing
  return Plugin_Handled;
}

public Action OnClientPreThink(int client)
{
  if (!IsClientInGame(client) || !g_bCreatingArea[client])
    return Plugin_Continue;
  
  // Get current buttons
  int currentButtons = GetClientButtons(client);
  
  // Mouse1 (left click) for increasing height
  if ((currentButtons & IN_ATTACK) && !(g_iPreviousButtons[client] & IN_ATTACK))
  {
    float currentTime = GetGameTime();
    float timeSinceLastClick = currentTime - g_fLastClickTime[client];
    
    // Check for double click to set point
    if (timeSinceLastClick <= DOUBLE_CLICK_TIME)
    {
      ProcessAreaClick(client);
      // Reset time to avoid triple-click issues
      g_fLastClickTime[client] = 0.0;
    }
    else
    {
      // Not a double click, increase height
      g_fVerticalOffset[client] += HEIGHT_ADJUST_INCREMENT;
      PrintHintText(client, "Height: %.0f units | Mouse1 ↓ Mouse2 ↑ | Double-click to set", g_fVerticalOffset[client]);
      EmitSoundToClient(client, "buttons/button14.wav", _, _, SNDLEVEL_NORMAL);
      
      // Save this click time
      g_fLastClickTime[client] = currentTime;
    }
  }
  
  // Mouse2 (right click) for decreasing height
  if ((currentButtons & IN_ATTACK2) && !(g_iPreviousButtons[client] & IN_ATTACK2))
  {
    g_fVerticalOffset[client] -= HEIGHT_ADJUST_INCREMENT;
    PrintHintText(client, "Height: %.0f units | Mouse1 ↓ Mouse2 ↑ | Double-click to set", g_fVerticalOffset[client]);
    EmitSoundToClient(client, "buttons/button14.wav", _, _, SNDLEVEL_NORMAL);
  }
  
  // Store current button state for next frame
  g_iPreviousButtons[client] = currentButtons;
  
  return Plugin_Continue;
}

void ProcessAreaClick(int client)
{
  float eyePos[3], eyeAng[3], endPos[3];
  GetClientEyePosition(client, eyePos);
  GetClientEyeAngles(client, eyeAng);
  
  TR_TraceRayFilter(eyePos, eyeAng, MASK_SOLID, RayType_Infinite, TraceFilterPlayers);
  
  if (TR_DidHit())
  {
    TR_GetEndPosition(endPos);
    
    // Apply vertical offset
    endPos[2] += g_fVerticalOffset[client];
    
    // Round to whole numbers
    for (int i = 0; i < 3; i++)
    {
      endPos[i] = float(RoundToFloor(endPos[i]));
    }
    
    if (g_iAreaStep[client] == 1)
    {
      // Set first point
      for (int i = 0; i < 3; i++)
      {
        g_fAreaPoints[client][0][i] = endPos[i];
      }
      
      PrintToChat(client, "\x04[NoBuilds]\x01 First corner set at: %.0f, %.0f, %.0f (offset: %.0f)", 
        endPos[0], endPos[1], endPos[2] - g_fVerticalOffset[client], g_fVerticalOffset[client]);
      PrintToChat(client, "\x04[NoBuilds]\x01 Now point at second corner and double-click again.");
      
      // Reset vertical offset for consistency between points
      // (comment out the next line if you want to keep the same height offset)
      g_fVerticalOffset[client] = 0.0;
      
      g_iAreaStep[client] = 2;
    }
    else if (g_iAreaStep[client] == 2)
    {
      // Set second point
      for (int i = 0; i < 3; i++)
      {
        g_fAreaPoints[client][1][i] = endPos[i];
      }
      
      PrintToChat(client, "\x04[NoBuilds]\x01 Second corner set at: %.0f, %.0f, %.0f (offset: %.0f)", 
        endPos[0], endPos[1], endPos[2] - g_fVerticalOffset[client], g_fVerticalOffset[client]);
      
      // Calculate area dimensions
      float mins[3], maxs[3];
      
      // Get min and max for each coordinate
      for (int i = 0; i < 3; i++)
      {
        mins[i] = (g_fAreaPoints[client][0][i] < g_fAreaPoints[client][1][i]) ? g_fAreaPoints[client][0][i] : g_fAreaPoints[client][1][i];
        maxs[i] = (g_fAreaPoints[client][0][i] > g_fAreaPoints[client][1][i]) ? g_fAreaPoints[client][0][i] : g_fAreaPoints[client][1][i];
      }
      
      // Calculate center
      for (int i = 0; i < 3; i++)
      {
        g_fAreaCenter[client][i] = (mins[i] + maxs[i]) / 2.0;
      }
      
      // Set bounds relative to center
      for (int i = 0; i < 3; i++)
      {
        g_fMinBounds[client][i] = mins[i] - g_fAreaCenter[client][i];
        g_fMaxBounds[client][i] = maxs[i] - g_fAreaCenter[client][i];
      }
      
      // Cleanup
      CleanupPreview(client);
      g_bCreatingArea[client] = false;
      g_iAreaStep[client] = 0;
      g_fVerticalOffset[client] = 0.0;
      
      // Proceed to team selection
      Nobuild_Menu_3(client);
    }
  }
}

public bool TraceFilterPlayers(int entity, int contentsMask)
{
  return entity > MaxClients;
}

public Action Nobuild_Menu_3(int client)
{
  Menu menu = new Menu(Nobuild_Menu_Team);
  menu.SetTitle("What team to disallow:");
  menu.AddItem("0", "Both", ITEMDRAW_DEFAULT);
  menu.AddItem("1", "Red", ITEMDRAW_DEFAULT);
  menu.AddItem("2", "Blue", ITEMDRAW_DEFAULT);
  menu.Display(client, 20);
  
  return Plugin_Handled;
}

public int Nobuild_Menu_Team(Menu menu, MenuAction action, int param1, int param2)
{
  char tmp[32];
  int selected;
  
  if (action == MenuAction_Select)
  {
    menu.GetItem(param2, tmp, sizeof(tmp));
    selected = StringToInt(tmp);
    
    switch (selected)
    {
      case 0: Format(g_sTeamNum[param1], sizeof(g_sTeamNum), "0");
      case 1: Format(g_sTeamNum[param1], sizeof(g_sTeamNum), "2");
      case 2: Format(g_sTeamNum[param1], sizeof(g_sTeamNum), "3");
    }
    
    Nobuild_Menu_4(param1);
  }
  else if (action == MenuAction_End)
  {
    delete menu;
  }
  
  return 0;
}

public Action Nobuild_Menu_4(int client)
{
  Menu menu = new Menu(Nobuild_Menu_Buildings);
  menu.SetTitle("What buildings to allow:");
  menu.AddItem("0", "Allow None");
  menu.AddItem("1", "Sentries");
  menu.AddItem("2", "Dispensers");
  menu.AddItem("3", "Telporters");
  menu.AddItem("4", "Sentries and Dispensers");
  menu.AddItem("5", "Sentries and Teleporters"); 
  menu.AddItem("6", "Dispensers and Teleporters");
  menu.Display(client, 20);
  
  return Plugin_Handled;
}

public int Nobuild_Menu_Buildings(Menu menu, MenuAction action, int param1, int param2)
{
  if (action == MenuAction_Select)
  {
    char tmp[32];
    menu.GetItem(param2, tmp, sizeof(tmp));
    int selected = StringToInt(tmp);
    
    // Reset all values first
    Format(g_sAllowSentry[param1], sizeof(g_sAllowSentry), "0");
    Format(g_sAllowDispenser[param1], sizeof(g_sAllowDispenser), "0"); 
    Format(g_sAllowTeleporters[param1], sizeof(g_sAllowTeleporters), "0");
    
    // Set only the allowed buildings based on selection
    switch (selected)
    {
      case 1: Format(g_sAllowSentry[param1], sizeof(g_sAllowSentry), "1");            // Only Sentries
      case 2: Format(g_sAllowDispenser[param1], sizeof(g_sAllowDispenser), "1");      // Only Dispensers
      case 3: Format(g_sAllowTeleporters[param1], sizeof(g_sAllowTeleporters), "1");  // Only Teleporters
      case 4: // Sentries and Dispensers
      {
        Format(g_sAllowSentry[param1], sizeof(g_sAllowSentry), "1");
        Format(g_sAllowDispenser[param1], sizeof(g_sAllowDispenser), "1");
      }
      case 5: // Sentries and Teleporters
      {
        Format(g_sAllowSentry[param1], sizeof(g_sAllowSentry), "1");
        Format(g_sAllowTeleporters[param1], sizeof(g_sAllowTeleporters), "1");
      }
      case 6: // Dispensers and Teleporters
      {
        Format(g_sAllowDispenser[param1], sizeof(g_sAllowDispenser), "1");
        Format(g_sAllowTeleporters[param1], sizeof(g_sAllowTeleporters), "1");
      }
      // case 0: All buildings disallowed (already set by default)
    }
    
    // Show confirmation menu
    Menu confirmMenu = new Menu(Nobuild_Menu_Confirm);
    confirmMenu.SetTitle("Create this no-build area?");
    
    // Calculate area dimensions
    float width = g_fMaxBounds[param1][0] - g_fMinBounds[param1][0];
    float length = g_fMaxBounds[param1][1] - g_fMinBounds[param1][1]; 
    float height = g_fMaxBounds[param1][2] - g_fMinBounds[param1][2];
    
    // Determine team string
    char teamStr[32];
    switch (StringToInt(g_sTeamNum[param1]))
    {
      case 2: strcopy(teamStr, sizeof(teamStr), "RED Team");
      case 3: strcopy(teamStr, sizeof(teamStr), "BLU Team");
      default: strcopy(teamStr, sizeof(teamStr), "Both Teams");
    }
    
    // Determine allowed buildings string
    char allowedStr[128];
    bool sentry = StrEqual(g_sAllowSentry[param1], "1");
    bool dispenser = StrEqual(g_sAllowDispenser[param1], "1");
    bool teleporter = StrEqual(g_sAllowTeleporters[param1], "1");
    
    if (sentry && dispenser && teleporter)
      strcopy(allowedStr, sizeof(allowedStr), "All buildings allowed");
    else if (!sentry && !dispenser && !teleporter)
      strcopy(allowedStr, sizeof(allowedStr), "No buildings allowed");
    else
    {
      // Build string for partial permissions
      bool first = true;
      strcopy(allowedStr, sizeof(allowedStr), "Only ");
      
      if (sentry)
      {
        StrCat(allowedStr, sizeof(allowedStr), "Sentries");
        first = false;
      }
      
      if (dispenser)
      {
        if (!first) StrCat(allowedStr, sizeof(allowedStr), first ? "" : " and ");
        StrCat(allowedStr, sizeof(allowedStr), "Dispensers");
        first = false;
      }
      
      if (teleporter)
      {
        if (!first) StrCat(allowedStr, sizeof(allowedStr), first ? "" : " and ");
        StrCat(allowedStr, sizeof(allowedStr), "Teleporters");
      }
      
      StrCat(allowedStr, sizeof(allowedStr), " allowed");
    }
    
    // Add menu items
    char infoText[255];
    Format(infoText, sizeof(infoText), "Size: %.0f x %.0f x %.0f units", width, length, height);
    confirmMenu.AddItem("info_size", infoText, ITEMDRAW_DISABLED);
    
    Format(infoText, sizeof(infoText), "Team: %s", teamStr);
    confirmMenu.AddItem("info_team", infoText, ITEMDRAW_DISABLED);
    
    Format(infoText, sizeof(infoText), "Buildings: %s", allowedStr);
    confirmMenu.AddItem("info_allowed", infoText, ITEMDRAW_DISABLED);
    
    // Show the position of the area
    Format(infoText, sizeof(infoText), "Position: %.0f, %.0f, %.0f", 
      g_fAreaCenter[param1][0], g_fAreaCenter[param1][1], g_fAreaCenter[param1][2]);
    confirmMenu.AddItem("info_position", infoText, ITEMDRAW_DISABLED);
    
    confirmMenu.AddItem("yes", "Create Area");
    confirmMenu.AddItem("no", "Cancel");
    
    confirmMenu.Display(param1, 20);
  }
  else if (action == MenuAction_End)
  {
    delete menu;
  }
  
  return 0;
}

public int Nobuild_Menu_Confirm(Menu menu, MenuAction action, int param1, int param2)
{
  if (action == MenuAction_Select)
  {
    char option[32];
    menu.GetItem(param2, option, sizeof(option));
    
    if (StrEqual(option, "yes"))
    {
      CreateTrigger(param1);
      PrintToChat(param1, "\x04[NoBuilds]\x01 No-build area created successfully!");
      
      // Show the new area outline
      CMD_ShowNoBuild(param1, 0);
    }
    else
    {
      PrintToChat(param1, "\x04[NoBuilds]\x01 Area creation cancelled.");
    }
  }
  else if (action == MenuAction_End)
  {
    delete menu;
  }
  
  return 0;
}

void CreateTrigger(int client)
{
  if (GetEntityCount() >= GetMaxEntities() - MAXPLAYERS)
  {
    PrintToChat(client, "\x04[NoBuilds]\x01 Entity limit is reached. Can't spawn more nobuild areas on this map.");
    return;
  }
  
  // Use the calculated center position instead of player position
  float pos[3];
  pos[0] = g_fAreaCenter[client][0];
  pos[1] = g_fAreaCenter[client][1];
  pos[2] = g_fAreaCenter[client][2];
  
  InsertTrigger(pos, g_fMinBounds[client], g_fMaxBounds[client], g_sAllowSentry[client], g_sAllowDispenser[client], g_sAllowTeleporters[client], g_sTeamNum[client]);
  InsertOutline(pos, g_fMinBounds[client], g_fMaxBounds[client]);
  
  char mapname[150];
  GetCurrentMap(mapname, sizeof(mapname));
  
  char query[256];
  g_Database.Format(query, sizeof(query), "INSERT INTO nobuildareas VALUES ('%f', '%f', '%f', '%f', '%f', '%f', '%f', '%f', '%f', '%s', '%s', '%s', '%s', '%s');", 
    pos[0], pos[1], pos[2], 
    g_fMinBounds[client][0], g_fMinBounds[client][1], g_fMinBounds[client][2], 
    g_fMaxBounds[client][0], g_fMaxBounds[client][1], g_fMaxBounds[client][2], 
    g_sAllowSentry[client], g_sAllowDispenser[client], g_sAllowTeleporters[client], g_sTeamNum[client], 
    mapname);
  
  g_Database.Query(SQL_OnSavedTrigger, query, GetClientUserId(client));
  return;
}

public void SQL_OnSavedTrigger(Database db, DBResultSet results, const char[] error, int userid)
{
  if (db == null)
  {
    LogError("Query failed! %s", error);
    return;
  }

  PrintToChat(GetClientOfUserId(userid), "\x04[NoBuilds]\x01 No-build area added to database!");
}

void DeleteTrigger(int client)
{
  char name[64];
  float entPos[3], cliPos[3];
  
  int aux_ent, closest = -1;
  float aux_dist, closest_dist = -1.0;
  
  GetClientAbsOrigin(client, cliPos);
  
  int MaxEntities = GetMaxEntities();
  for (aux_ent = MaxClients; aux_ent < MaxEntities; aux_ent++)
  {
    if (!IsValidEntity(aux_ent))
    {
      continue;
    }
    
    GetEntPropString(aux_ent, Prop_Data, "m_iName", name, sizeof(name));
    if (StrEqual(name, TRIGGER_NAME, false))
    {
      GetEntPropVector(aux_ent, Prop_Data, "m_vecOrigin", entPos);
      aux_dist = GetVectorDistance(entPos, cliPos, false);
      if (closest_dist > aux_dist || closest_dist == -1.0)
      {
        closest = aux_ent;
        closest_dist = aux_dist;
      }
    }
  }
  
  if (closest != -1 && closest_dist < MAX_SEARCH_DIST)
  {
    GetEntPropVector(closest, Prop_Send, "m_vecOrigin", entPos);
    
    // Draw the area outline before deleting
    float mins[3], maxs[3];
    GetEntPropVector(closest, Prop_Send, "m_vecMins", mins);
    GetEntPropVector(closest, Prop_Send, "m_vecMaxs", maxs);
    
    // Calculate absolute coordinates for the box corners
    float absMin[3], absMax[3];
    for (int i = 0; i < 3; i++)
    {
      absMin[i] = entPos[i] + mins[i];
      absMax[i] = entPos[i] + maxs[i];
    }
    
    int Color[4] = { 255, 0, 0, 255 }; // Red for deletion
    TE_SendBeamBoxToClient(client, absMin, absMax, g_iLaserMaterial, g_iHaloMaterial, 0, 30, 2.0, 5.0, 5.0, 2, 1.0, Color, 0);
    
    // Confirm deletion
    Menu confirmMenu = new Menu(DeleteConfirm_Menu);
    SetMenuTitle(confirmMenu, "Delete this No-Build Area?");
    
    // Store entity reference in a hidden info field
    char entityRef[16];
    IntToString(EntIndexToEntRef(closest), entityRef, sizeof(entityRef));
    
    AddMenuItem(confirmMenu, entityRef, "Yes, Delete It");
    AddMenuItem(confirmMenu, "no", "No, Cancel");
    
    confirmMenu.Display(client, 10);
  }
  else
  {
    PrintToChat(client, "\x04[NoBuilds]\x01 There isn't any near nobuild areas to delete.");
  }
}

public int DeleteConfirm_Menu(Menu menu, MenuAction action, int param1, int param2)
{
  char info[32];
  
  if (action == MenuAction_Select)
  {
    GetMenuItem(menu, param2, info, sizeof(info));
    
    if (!StrEqual(info, "no"))
    {
      // Convert string back to entity reference
      int entRef = StringToInt(info);
      int entity = EntRefToEntIndex(entRef);
      
      if (entity != INVALID_ENT_REFERENCE)
      {
        float entPos[3];
        GetEntPropVector(entity, Prop_Send, "m_vecOrigin", entPos);
        
        char query[256];
        g_Database.Format(query, sizeof(query), "DELETE FROM nobuildareas WHERE locX = '%f' AND locY = '%f' AND locZ = '%f';", entPos[0], entPos[1], entPos[2]);
        g_Database.Query(SQL_OnUpdateTrigger, query);
        
        RemoveEdict(entity);
        PrintToChat(param1, "\x04[NoBuilds]\x01 No-build area deleted!");
      }
      else
      {
        PrintToChat(param1, "\x04[NoBuilds]\x01 Error: The no-build area was no longer valid.");
      }
    }
    else
    {
      PrintToChat(param1, "\x04[NoBuilds]\x01 Deletion cancelled.");
    }
  }
  else if (action == MenuAction_End)
  {
    delete menu;
  }
  
  return 0;
}

public void SQL_OnUpdateTrigger(Database db, DBResultSet results, const char[] error, any data)
{
  if (db == null)
  {
    LogError("Query failed! %s", error);
  }
}

void InsertTrigger(float pos[3], float minbounds[3], float maxbounds[3], const char[] AllowSentry, const char[] AllowDispenser, const char[] AllowTeleporters, const char[] TeamNum)
{
  int entindex = CreateEntityByName("func_nobuild");
  if (entindex != -1)
  {
    DispatchKeyValue(entindex, "targetname", TRIGGER_NAME);
    DispatchKeyValue(entindex, "AllowSentry", AllowSentry);
    DispatchKeyValue(entindex, "AllowDispenser", AllowDispenser);
    DispatchKeyValue(entindex, "AllowTeleporters", AllowTeleporters);
    DispatchKeyValue(entindex, "TeamNum", TeamNum);
  }
  DispatchSpawn(entindex);
  ActivateEntity(entindex);
  
  TeleportEntity(entindex, pos, NULL_VECTOR, NULL_VECTOR);
  
  SetEntityModel(entindex, "models/props_2fort/miningcrate002.mdl");
  
  SetEntPropVector(entindex, Prop_Send, "m_vecMins", minbounds);
  SetEntPropVector(entindex, Prop_Send, "m_vecMaxs", maxbounds);
  
  SetEntProp(entindex, Prop_Send, "m_nSolidType", 2);
  
  int enteffects = GetEntProp(entindex, Prop_Send, "m_fEffects");
  enteffects |= 32;
  SetEntProp(entindex, Prop_Send, "m_fEffects", enteffects);
}

public Action CMD_ShowNoBuild(int client, int args)
{
  if (g_bAllowOutline == true)
  {
    ReplyToCommand(client, "\x04[NoBuilds]\x01 Showing all nobuild areas for 10 seconds");
    g_bAllowOutline = false;
    CreateTimer(10.0, Disallow_CMD_ShowNoBuild);
    
    char mapname[50];
    GetCurrentMap(mapname, sizeof(mapname));
    
    char query[256];
    g_Database.Format(query, sizeof(query), "SELECT * FROM nobuildareas WHERE map = '%s';", mapname);
    
    g_Database.Query(SQL_OnGetOutline, query);
    return Plugin_Continue;
  }
  else
  {
    ReplyToCommand(client, "\x04[NoBuilds]\x01 Already showing the nobuild areas");
  }
  
  return Plugin_Continue;
}

public Action Disallow_CMD_ShowNoBuild(Handle timer)
{
  g_bAllowOutline = true;
  return Plugin_Continue;
}

public void SQL_OnGetOutline(Database db, DBResultSet results, const char[] error, any data)
{
  if (db == null)
  {
    LogError("Query failed! %s", error);
    return;
  }

  if (results.RowCount == 0)
  {
    return;
  }

  while (results.FetchRow())
  {
    float pos[3];
    float minbounds[3];
    float maxbounds[3];
    pos[0] = results.FetchFloat(0);
    pos[1] = results.FetchFloat(1);
    pos[2] = results.FetchFloat(2);
    minbounds[0] = results.FetchFloat(3);
    minbounds[1] = results.FetchFloat(4);
    minbounds[2] = results.FetchFloat(5);
    maxbounds[0] = results.FetchFloat(6);
    maxbounds[1] = results.FetchFloat(7);
    maxbounds[2] = results.FetchFloat(8);
    InsertOutline(pos, minbounds, maxbounds);
  }
}

void InsertOutline(float pos[3], float minbounds[3], float maxbounds[3])
{
  int Color[4] = { 255, 255, 255, 255 };
  float vector1[3];
  float vector2[3];
  
  for (int i = 0; i < 3; i++)
  {
    vector1[i] = pos[i] + minbounds[i];
    vector2[i] = pos[i] + maxbounds[i];
  }
  
  for (int client = 1; client <= MaxClients; client++)
  {
    if (IsClientInGame(client) && IsClientConnected(client))
    {
      TE_SendBeamBoxToClient(client, vector1, vector2, g_iLaserMaterial, g_iHaloMaterial, 0, 30, 10.0, 5.0, 5.0, 2, 1.0, Color, 0);
    }
  }
}

// Improved beam box rendering
stock void TE_SendBeamBoxToClient(int client, float uppercorner[3], float bottomcorner[3], int ModelIndex, int HaloIndex, int StartFrame, int FrameRate, float Life, float Width, float EndWidth, int FadeLength, float Amplitude, int Color[4], int Speed)
{
  // Create the additional corners of the box
  float tc1[3];
  float tc2[3];
  float tc3[3];
  float tc4[3];
  float tc5[3];
  float tc6[3];
  
  tc1[0] = bottomcorner[0];
  tc1[1] = uppercorner[1];
  tc1[2] = uppercorner[2];
  
  tc2[0] = uppercorner[0];
  tc2[1] = bottomcorner[1];
  tc2[2] = uppercorner[2];
  
  tc3[0] = uppercorner[0];
  tc3[1] = uppercorner[1];
  tc3[2] = bottomcorner[2];
  
  tc4[0] = uppercorner[0];
  tc4[1] = bottomcorner[1];
  tc4[2] = bottomcorner[2];
  
  tc5[0] = bottomcorner[0];
  tc5[1] = uppercorner[1];
  tc5[2] = bottomcorner[2];
  
  tc6[0] = bottomcorner[0];
  tc6[1] = bottomcorner[1];
  tc6[2] = uppercorner[2];
  
  // Draw all the edges
  TE_SetupBeamPoints(uppercorner, tc1, ModelIndex, HaloIndex, StartFrame, FrameRate, Life, Width, EndWidth, FadeLength, Amplitude, Color, Speed);
  TE_SendToClient(client);
  TE_SetupBeamPoints(uppercorner, tc2, ModelIndex, HaloIndex, StartFrame, FrameRate, Life, Width, EndWidth, FadeLength, Amplitude, Color, Speed);
  TE_SendToClient(client);
  TE_SetupBeamPoints(uppercorner, tc3, ModelIndex, HaloIndex, StartFrame, FrameRate, Life, Width, EndWidth, FadeLength, Amplitude, Color, Speed);
  TE_SendToClient(client);
  TE_SetupBeamPoints(tc6, tc1, ModelIndex, HaloIndex, StartFrame, FrameRate, Life, Width, EndWidth, FadeLength, Amplitude, Color, Speed);
  TE_SendToClient(client);
  TE_SetupBeamPoints(tc6, tc2, ModelIndex, HaloIndex, StartFrame, FrameRate, Life, Width, EndWidth, FadeLength, Amplitude, Color, Speed);
  TE_SendToClient(client);
  TE_SetupBeamPoints(tc6, bottomcorner, ModelIndex, HaloIndex, StartFrame, FrameRate, Life, Width, EndWidth, FadeLength, Amplitude, Color, Speed);
  TE_SendToClient(client);
  TE_SetupBeamPoints(tc4, bottomcorner, ModelIndex, HaloIndex, StartFrame, FrameRate, Life, Width, EndWidth, FadeLength, Amplitude, Color, Speed);
  TE_SendToClient(client);
  TE_SetupBeamPoints(tc5, bottomcorner, ModelIndex, HaloIndex, StartFrame, FrameRate, Life, Width, EndWidth, FadeLength, Amplitude, Color, Speed);
  TE_SendToClient(client);
  TE_SetupBeamPoints(tc5, tc1, ModelIndex, HaloIndex, StartFrame, FrameRate, Life, Width, EndWidth, FadeLength, Amplitude, Color, Speed);
  TE_SendToClient(client);
  TE_SetupBeamPoints(tc5, tc3, ModelIndex, HaloIndex, StartFrame, FrameRate, Life, Width, EndWidth, FadeLength, Amplitude, Color, Speed);
  TE_SendToClient(client);
  TE_SetupBeamPoints(tc4, tc3, ModelIndex, HaloIndex, StartFrame, FrameRate, Life, Width, EndWidth, FadeLength, Amplitude, Color, Speed);
  TE_SendToClient(client);
  TE_SetupBeamPoints(tc4, tc2, ModelIndex, HaloIndex, StartFrame, FrameRate, Life, Width, EndWidth, FadeLength, Amplitude, Color, Speed);
  TE_SendToClient(client);
}

// Just to be safe
void KillAllNobuild()
{
  char name[64];
  
  int aux_ent;
  
  int MaxEntities = GetMaxEntities();
  for (aux_ent = MaxClients; aux_ent < MaxEntities; aux_ent++)
  {
    if (!IsValidEntity(aux_ent))
      continue;
    GetEntPropString(aux_ent, Prop_Data, "m_iName", name, sizeof(name));
    if (StrEqual(name, TRIGGER_NAME, false))
    {
      RemoveEdict(aux_ent);
    }
  }
}