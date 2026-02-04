#pragma semicolon 1
#pragma newdecls required

// ================================================================
// Includes
// ================================================================

#include <sourcemod>
#include <dhooks>

// ================================================================
// Info
// ================================================================

public Plugin myinfo = {
    name = "pSilent Fix",
    author = "RenardDev",
    description = "pSilent Fix",
    version = "1.4.0",
    url = "https://github.com/RenardDev/L4D2-pSilentFix"
};

// ================================================================
// Constants
// ================================================================

enum {
    ANGLE_PITCH = 0,
    ANGLE_YAW = 1,
    ANGLE_ROLL = 2
};

// ================================================================
// ConVars
// ================================================================

ConVar g_ConVarEnable;
ConVar g_ConVarTickWindow;
ConVar g_ConVarFireDelta;

// ================================================================
// DHooks
// ================================================================

GameData g_hGameData;

DynamicHook g_hHookProcessUserCmds;

DynamicDetour g_hDetourFireBullet;
DynamicDetour g_hDetourTEFireBullets;

bool g_bDetourFireBulletEnabled = false;
bool g_bDetourTEFireBulletsEnabled = false;

// Per-client hook id
int g_nHookIDProcessUserCmdsPre[MAXPLAYERS + 1] = { INVALID_HOOK_ID, ... };

// ================================================================
// State
// ================================================================

bool g_bEyeAnglesValid[MAXPLAYERS + 1];
int g_nEyeAnglesTick[MAXPLAYERS + 1];
float g_flEyeAngles[MAXPLAYERS + 1][3];

// ================================================================
// Utils
// ================================================================

static bool IsValidClient(int nClient) {
    if ((nClient <= 0) || (nClient > MaxClients)) {
        return false;
    }

    if (!IsClientInGame(nClient) || IsFakeClient(nClient)) {
        return false;
    }

    return true;
}

static int ClampInt(int nValue, int nMin, int nMax) {
    if (nValue < nMin) {
        return nMin;
    }

    if (nValue > nMax) {
        return nMax;
    }

    return nValue;
}

static void CopyAngles(float flDst[3], const float flSrc[3]) {
    flDst[0] = flSrc[0];
    flDst[1] = flSrc[1];
    flDst[2] = flSrc[2];
}

// ================================================================
// QAngle address read/write
// ================================================================

static float ReadFloat(Address pAddress) {
    return view_as<float>(LoadFromAddress(pAddress, NumberType_Int32));
}

static void WriteFloat(Address pAddress, float flValue) {
    StoreToAddress(pAddress, view_as<int>(flValue), NumberType_Int32);
}

static void ReadQAngle(Address pAngleAddress, float flAngles[3]) {
    flAngles[ANGLE_PITCH] = ReadFloat(pAngleAddress + view_as<Address>(0));
    flAngles[ANGLE_YAW] = ReadFloat(pAngleAddress + view_as<Address>(4));
    flAngles[ANGLE_ROLL] = ReadFloat(pAngleAddress + view_as<Address>(8));
}

static void WriteQAngle(Address pAngleAddress, const float flAngles[3]) {
    WriteFloat(pAngleAddress + view_as<Address>(0), flAngles[ANGLE_PITCH]);
    WriteFloat(pAngleAddress + view_as<Address>(4), flAngles[ANGLE_YAW]);
    WriteFloat(pAngleAddress + view_as<Address>(8), flAngles[ANGLE_ROLL]);
}

// wrap 360 -> [-180..180]
static float AngleDifference(float flA, float flB) {
    float flDifference = flA - flB;

    while (flDifference > 180.0) {
        flDifference -= 360.0;
    }

    while (flDifference < -180.0) {
        flDifference += 360.0;
    }

    return flDifference;
}

// max(|dpitch|, |dyaw|)
static float AngleDistanceMax(const float flA[3], const float flB[3]) {
    float flDeltaPitch = FloatAbs(AngleDifference(flA[ANGLE_PITCH], flB[ANGLE_PITCH]));
    float flDeltaYaw = FloatAbs(AngleDifference(flA[ANGLE_YAW],   flB[ANGLE_YAW]));

    return (flDeltaPitch > flDeltaYaw) ? flDeltaPitch : flDeltaYaw;
}

// ================================================================
// State helpers
// ================================================================

static void ResetClientState(int nClient) {
    g_bEyeAnglesValid[nClient] = false;
    g_nEyeAnglesTick[nClient] = 0;

    g_flEyeAngles[nClient][ANGLE_PITCH] = 0.0;
    g_flEyeAngles[nClient][ANGLE_YAW] = 0.0;
    g_flEyeAngles[nClient][ANGLE_ROLL] = 0.0;
}

static bool HasFreshEyeAngles(int nClient, int nTickNow, int nWindowTicks) {
    if (!g_bEyeAnglesValid[nClient]) {
        return false;
    }

    int nDeltaTicks = nTickNow - g_nEyeAnglesTick[nClient];
    if (nDeltaTicks < 0) {
        return false;
    }

    return nDeltaTicks <= nWindowTicks;
}

// ================================================================
// Detours enable/disable
// ================================================================

static void ApplyDetours(bool bEnable) {
    if (bEnable) {
        if ((!g_bDetourTEFireBulletsEnabled) && (g_hDetourTEFireBullets != null)) {
            g_bDetourTEFireBulletsEnabled = g_hDetourTEFireBullets.Enable(Hook_Pre, Detour_TE_FireBullets_Pre);
            if (!g_bDetourTEFireBulletsEnabled) {
                LogError("Failed to enable TE_FireBullets detour");
            }
        }

        if ((!g_bDetourFireBulletEnabled) && (g_hDetourFireBullet != null)) {
            g_bDetourFireBulletEnabled = g_hDetourFireBullet.Enable(Hook_Pre, Detour_FireBullet_Pre);
            if (!g_bDetourFireBulletEnabled) {
                LogError("Failed to enable CTerrorPlayer::FireBullet detour");
            }
        }

        return;
    }

    if (g_bDetourTEFireBulletsEnabled && (g_hDetourTEFireBullets != null)) {
        if (!g_hDetourTEFireBullets.Disable(Hook_Pre, Detour_TE_FireBullets_Pre)) {
            LogError("Failed to disable TE_FireBullets detour");
        }
    }

    g_bDetourTEFireBulletsEnabled = false;

    if (g_bDetourFireBulletEnabled && (g_hDetourFireBullet != null)) {
        if (!g_hDetourFireBullet.Disable(Hook_Pre, Detour_FireBullet_Pre)) {
            LogError("Failed to disable CTerrorPlayer::FireBullet detour");
        }
    }

    g_bDetourFireBulletEnabled = false;
}

// ================================================================
// Hook management
// ================================================================

static void UnHookClient(int nClient) {
    if (g_nHookIDProcessUserCmdsPre[nClient] != INVALID_HOOK_ID) {
        DynamicHook.RemoveHook(g_nHookIDProcessUserCmdsPre[nClient]);
        g_nHookIDProcessUserCmdsPre[nClient] = INVALID_HOOK_ID;
    }

    ResetClientState(nClient);
}

static void HookClient(int nClient) {
    if (!IsValidClient(nClient)) {
        return;
    }

    UnHookClient(nClient);

    if (g_hHookProcessUserCmds == null) {
        return;
    }

    g_nHookIDProcessUserCmdsPre[nClient] = g_hHookProcessUserCmds.HookEntity(Hook_Pre, nClient, Hook_ProcessUserCmds_Pre);
    if (g_nHookIDProcessUserCmdsPre[nClient] == INVALID_HOOK_ID) {
        LogError("Failed to hook ProcessUsercmds PRE (client=%d)", nClient);
        return;
    }
}

static void HookAllClients() {
    for (int nClient = 1; nClient <= MaxClients; nClient++) {
        if (IsValidClient(nClient)) {
            HookClient(nClient);
        } else {
            UnHookClient(nClient);
        }
    }
}

static void UnHookAllClients() {
    for (int nClient = 1; nClient <= MaxClients; nClient++) {
        UnHookClient(nClient);
    }
}

static void ApplyEnableState() {
    bool bEnable = g_ConVarEnable.BoolValue;

    if (bEnable) {
        HookAllClients();
    } else {
        UnHookAllClients();
    }

    ApplyDetours(bEnable);
}

// ================================================================
// ConVar change hooks
// ================================================================

public void OnConVarChanged_Enable(ConVar hConVar, const char[] szOldValue, const char[] szNewValue) {
    ApplyEnableState();
}

// ================================================================
// Plugin lifecycle
// ================================================================

public void OnPluginStart() {
    for (int i = 0; i <= MAXPLAYERS; i++) {
        g_nHookIDProcessUserCmdsPre[i] = INVALID_HOOK_ID;
        ResetClientState(i);
    }

    g_ConVarEnable = CreateConVar(
        "sm_psilentfix_enable", "1",
        "Enable pSilent Fix",
        FCVAR_NOTIFY, true, 0.0, true, 1.0
    );

    g_ConVarTickWindow = CreateConVar(
        "sm_psilentfix_tick_window", "2",
        "Use stored eye angles up to N ticks old (0=current tick only)",
        FCVAR_NOTIFY, true, 0.0, true, 8.0
    );

    g_ConVarFireDelta = CreateConVar(
        "sm_psilentfix_fire_delta", "7.0",
        "Override angles only if max(|dpitch|,|dyaw|) between orig and eye >= this (degrees)",
        FCVAR_NOTIFY, true, 0.0, true, 180.0
    );

    AutoExecConfig(true, "psilentfix");

    g_hGameData = new GameData("psilentfix.l4d2");
    if (g_hGameData == null) {
        SetFailState("Failed to load gamedata: psilentfix.l4d2");
    }

    g_hHookProcessUserCmds = DynamicHook.FromConf(g_hGameData, "CBasePlayer::ProcessUsercmds");
    if (g_hHookProcessUserCmds == null) {
        SetFailState("Failed to find function in gamedata: CBasePlayer::ProcessUsercmds");
    }

    g_hDetourTEFireBullets = DynamicDetour.FromConf(g_hGameData, "TE_FireBullets");
    if (g_hDetourTEFireBullets == null) {
        SetFailState("Failed to find function in gamedata: TE_FireBullets");
    }

    g_hDetourFireBullet = DynamicDetour.FromConf(g_hGameData, "CTerrorPlayer::FireBullet");
    if (g_hDetourFireBullet == null) {
        SetFailState("Failed to find function in gamedata: CTerrorPlayer::FireBullet");
    }

    g_ConVarEnable.AddChangeHook(OnConVarChanged_Enable);

    ApplyEnableState();
}

public void OnPluginEnd() {
    UnHookAllClients();
    ApplyDetours(false);

    if (g_hDetourFireBullet != null) {
        delete g_hDetourFireBullet;
    }

    if (g_hDetourTEFireBullets != null) {
        delete g_hDetourTEFireBullets;
    }

    if (g_hHookProcessUserCmds != null) {
        delete g_hHookProcessUserCmds;
    }

    if (g_hGameData != null) {
        delete g_hGameData;
    }
}

public void OnMapStart() {
    for (int nClient = 1; nClient <= MaxClients; nClient++) {
        ResetClientState(nClient);
    }

    ApplyEnableState();
}

public void OnClientPutInServer(int nClient) {
    if (!g_ConVarEnable.BoolValue) {
        return;
    }

    HookClient(nClient);
}

public void OnClientDisconnect(int nClient) {
    UnHookClient(nClient);
}

// ================================================================
// DHooks: ProcessUsercmds
// ================================================================

public MRESReturn Hook_ProcessUserCmds_Pre(int nClient, DHookParam hParams) {
    if (!g_ConVarEnable.BoolValue) {
        return MRES_Ignored;
    }

    if (!IsValidClient(nClient)) {
        return MRES_Ignored;
    }

    float flEyeAnglesNow[3];
    GetClientEyeAngles(nClient, flEyeAnglesNow);

    CopyAngles(g_flEyeAngles[nClient], flEyeAnglesNow);
    g_nEyeAnglesTick[nClient] = GetGameTickCount();
    g_bEyeAnglesValid[nClient] = true;

    return MRES_Ignored;
}

// ================================================================
// Detour: TE_FireBullets (cdecl)
// ================================================================

public MRESReturn Detour_TE_FireBullets_Pre(DHookParam hParams) {
    if (!g_ConVarEnable.BoolValue) {
        return MRES_Ignored;
    }

    // args:
    // 1) iPlayerIndex
    // 2) vOrigin (ptr)
    // 3) vAngles (ptr)

    int nClient = hParams.Get(1);

    if (!IsValidClient(nClient)) {
        return MRES_Ignored;
    }

    if (hParams.IsNull(3)) {
        return MRES_Ignored;
    }

    Address pAngleAddress = hParams.GetAddress(3);

    int nTickNow = GetGameTickCount();
    int nWindowTicks = ClampInt(g_ConVarTickWindow.IntValue, 0, 8);

    if (!HasFreshEyeAngles(nClient, nTickNow, nWindowTicks)) {
        return MRES_Ignored;
    }

    float flOriginalAngles[3];
    ReadQAngle(pAngleAddress, flOriginalAngles);

    float flEyeAngles[3];
    flEyeAngles[ANGLE_PITCH] = g_flEyeAngles[nClient][ANGLE_PITCH];
    flEyeAngles[ANGLE_YAW] = g_flEyeAngles[nClient][ANGLE_YAW];
    flEyeAngles[ANGLE_ROLL] = g_flEyeAngles[nClient][ANGLE_ROLL];

    float flDistance = AngleDistanceMax(flOriginalAngles, flEyeAngles);
    float flThreshold = g_ConVarFireDelta.FloatValue;

    if (flDistance < flThreshold) {
        return MRES_Ignored;
    }

    WriteQAngle(pAngleAddress, flEyeAngles);

    return MRES_Ignored;
}

// ================================================================
// Detour: CTerrorPlayer::FireBullet (thiscall)
// ================================================================

public MRESReturn Detour_FireBullet_Pre(int nClient, DHookParam hParams) {
    if (!g_ConVarEnable.BoolValue) {
        return MRES_Ignored;
    }

    if (!IsValidClient(nClient)) {
        return MRES_Ignored;
    }

    // args: pos0 (1), pos1 (2), pos2 (3), angles* (4), clip (5), seed (6)

    if (hParams.IsNull(4)) {
        return MRES_Ignored;
    }

    Address pAngleAddress = hParams.GetAddress(4);

    int nTickNow = GetGameTickCount();
    int nWindowTicks = ClampInt(g_ConVarTickWindow.IntValue, 0, 8);

    if (!HasFreshEyeAngles(nClient, nTickNow, nWindowTicks)) {
        return MRES_Ignored;
    }

    float flOriginalAngles[3];
    ReadQAngle(pAngleAddress, flOriginalAngles);

    float flEyeAngles[3];
    flEyeAngles[ANGLE_PITCH] = g_flEyeAngles[nClient][ANGLE_PITCH];
    flEyeAngles[ANGLE_YAW] = g_flEyeAngles[nClient][ANGLE_YAW];
    flEyeAngles[ANGLE_ROLL] = g_flEyeAngles[nClient][ANGLE_ROLL];

    float flDistance = AngleDistanceMax(flOriginalAngles, flEyeAngles);
    float flThreshold = g_ConVarFireDelta.FloatValue;

    if (flDistance < flThreshold) {
        return MRES_Ignored;
    }

    WriteQAngle(pAngleAddress, flEyeAngles);

    return MRES_Ignored;
}
