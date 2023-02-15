#include <sourcemod>
#include <webcon>
#include <SteamWorks>

#pragma semicolon 1
#pragma newdecls required

#define SESSION_ID_LENGTH 33
#define SESSION_TIMEOUT 86400
#define SESSION_REAP_INTERVAL 600

#define CLAIMED_ID_BASE "http://steamcommunity.com/openid/id/"

ConVar managerUrl;

WebResponse indexResponse;
WebResponse steamRedirectResponse;
WebResponse topSecretResponse;
WebResponse loginRedirectResponse;
WebResponse forbiddenResponse;
WebResponse notFoundResponse;

enum CheckAuthenticationState:
{
	CheckAuthenticationState_Pending,
	CheckAuthenticationState_Error,
	CheckAuthenticationState_Forged,
	CheckAuthenticationState_Valid,
};

// We can't use a named enum here because Pawn considers named enums starting with an uppercase letter to be strongly-typed
// (and thus it won't coerce to int when we need it). The ugly _MAX element is a slightly better trade-off than breaking style.
enum
{
	CheckAuthenticationData_Connection,
	CheckAuthenticationData_State,
	CheckAuthenticationData_SteamId,

	CheckAuthenticationData_MAX,
};

ArrayList pendingCheckAuthenticationRequests;

StringMap sessions;

public void OnPluginStart()
{
	if (!Web_RegisterRequestHandler("manager", OnWebRequest, "Manager", "Management Panel")) {
		SetFailState("Failed to register request handler.");
	}

	managerUrl = CreateConVar("webmanager_url", "", "Canonical URL for Web Manager. Must include trailing slash.");
	managerUrl.AddChangeHook(OnManagerUrlChanged);

	AutoExecConfig();

	RegAdminCmd("webmanager_dump_sessions", OnDumpSessionsCommand, ADMFLAG_ROOT, "Prints active Web Manager sessions.");

	indexResponse = new WebStringResponse("<!DOCTYPE html>\n<a href=\"login\">Login</a><br><a href=\"secret\">Secret</a>");
	indexResponse.AddHeader(WebHeader_ContentType, "text/html; charset=UTF-8");

	steamRedirectResponse = new WebStringResponse("The silly server admin needs to configure webmanager_url.");
	steamRedirectResponse.AddHeader(WebHeader_ContentType, "text/plain; charset=UTF-8");

	topSecretResponse = new WebStringResponse("This is Top Secret!");
	topSecretResponse.AddHeader(WebHeader_ContentType, "text/plain; charset=UTF-8");

	loginRedirectResponse = new WebStringResponse("This action requires authentication.");
	loginRedirectResponse.AddHeader(WebHeader_ContentType, "text/plain; charset=UTF-8");

	forbiddenResponse = new WebStringResponse("Forbidden");
	forbiddenResponse.AddHeader(WebHeader_ContentType, "text/plain; charset=UTF-8");

	notFoundResponse = new WebStringResponse("Not Found");
	notFoundResponse.AddHeader(WebHeader_ContentType, "text/plain; charset=UTF-8");

	pendingCheckAuthenticationRequests = new ArrayList(CheckAuthenticationData_MAX);

	sessions = new StringMap();

	CreateTimer(SESSION_REAP_INTERVAL.0, OnReapSessionTimer, _, TIMER_REPEAT);
}

public void OnManagerUrlChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	if (newValue[0] == '\0') {
		return;
	}

	char buffer[1024];
	FormatEx(buffer, sizeof(buffer), "https://steamcommunity.com/openid/login?openid.ns=http://specs.openid.net/auth/2.0&openid.mode=checkid_setup&openid.claimed_id=http://specs.openid.net/auth/2.0/identifier_select&openid.identity=http://specs.openid.net/auth/2.0/identifier_select&openid.return_to=%slogin&openid.realm=%s", newValue, newValue);

	delete steamRedirectResponse;

	steamRedirectResponse = new WebStringResponse("Redirecting to Steam...");
	steamRedirectResponse.AddHeader(WebHeader_ContentType, "text/plain; charset=UTF-8");
	steamRedirectResponse.AddHeader(WebHeader_SetCookie, "id=; Expires=Thu, 01 Jan 1970 00:00:00 GMT; HttpOnly");
	steamRedirectResponse.AddHeader(WebHeader_Location, buffer);

	FormatEx(buffer, sizeof(buffer), "%slogin", newValue);

	loginRedirectResponse.RemoveHeader(WebHeader_Location);
	loginRedirectResponse.AddHeader(WebHeader_Location, buffer);
}

public Action OnDumpSessionsCommand(int client, int args)
{
	StringMapSnapshot snapshot = sessions.Snapshot();

	int i = snapshot.Length;
	int display = 0;
	while (--i >= 0) {
		char id[SESSION_ID_LENGTH];
		snapshot.GetKey(i, id, sizeof(id));

		DataPack sessionPack;
		if (!sessions.GetValue(id, sessionPack)) {
			continue;
		}

		sessionPack.Reset();

		int lastActive = sessionPack.ReadCell();
		int age = GetTime() - lastActive;
		if (age > SESSION_TIMEOUT) {
			delete sessionPack;
			sessions.Remove(id);
			continue;
		}

		char remainingTime[9];
		int remainingSeconds = SESSION_TIMEOUT - age;
		int remainingMinutes = remainingSeconds / 60;
		int remainingHours = remainingMinutes / 60;
		FormatEx(remainingTime, sizeof(remainingTime), "%02d:%02d:%02d", remainingHours, remainingMinutes - (remainingHours * 60), remainingSeconds - (remainingMinutes * 60));

		char ip[WEB_CLIENT_ADDRESS_LENGTH];
		sessionPack.ReadString(ip, sizeof(ip));

		char steamid[32];
		sessionPack.ReadString(steamid, sizeof(steamid));

		if (display == 0) {
			ReplyToCommand(client, "     %32s %8s %15s %20s", "Session ID", "Expires", "IP", "SteamID");
		}

		ReplyToCommand(client, "%3d. %32s %8s %15s %20s", display++, id, remainingTime, ip, steamid);
	}

	if (display == 0) {
		ReplyToCommand(client, "There are no active sessions.");
	}

	delete snapshot;
	return Plugin_Handled;
}

public Action OnReapSessionTimer(Handle timer)
{
	StringMapSnapshot snapshot = sessions.Snapshot();

	int i = snapshot.Length;
	while (--i >= 0) {
		char id[SESSION_ID_LENGTH];
		snapshot.GetKey(i, id, sizeof(id));

		DataPack sessionPack;
		if (!sessions.GetValue(id, sessionPack)) {
			continue;
		}

		sessionPack.Reset();

		int lastActive = sessionPack.ReadCell();
		if ((GetTime() - lastActive) > SESSION_TIMEOUT) {
			delete sessionPack;
			sessions.Remove(id);
		}
	}

	delete snapshot;
	return Plugin_Handled;
}

public int OnOpenIdCheckAuthenticationResponse(Handle request, bool failure, bool requestSuccessful, EHTTPStatusCode statusCode, WebConnection connection)
{
	int index = pendingCheckAuthenticationRequests.FindValue(connection);
	if (index == -1) {
		PrintToServer("Got a reply for a connection we're not waiting on o:");
		delete request;
		return 0;
	}

	if (failure || !requestSuccessful || statusCode != k_EHTTPStatusCode200OK) {
		pendingCheckAuthenticationRequests.Set(index, CheckAuthenticationState_Error, CheckAuthenticationData_State);
		delete request;
		return 0;
	}

	int bodySize;
	if (!SteamWorks_GetHTTPResponseBodySize(request, bodySize)) {
		pendingCheckAuthenticationRequests.Set(index, CheckAuthenticationState_Error, CheckAuthenticationData_State);
		delete request;
		return 0;
	}

	char[] body = new char[bodySize];
	if (!SteamWorks_GetHTTPResponseBodyData(request, body, bodySize)) {
		pendingCheckAuthenticationRequests.Set(index, CheckAuthenticationState_Error, CheckAuthenticationData_State);
		delete request;
		return 0;
	}

	if (StrContains(body, "is_valid:true") == -1) {
		// Forged OpenID request.
		PrintToServer(">>> Claim FAILED verification.");
		pendingCheckAuthenticationRequests.Set(index, CheckAuthenticationState_Forged, CheckAuthenticationData_State);
		delete request;
		return 0;
	}

	// We have a winner!
	PrintToServer(">>> Claim passed verification.");
	pendingCheckAuthenticationRequests.Set(index, CheckAuthenticationState_Valid, CheckAuthenticationData_State);

	delete request;
	return 0;
}

void GenerateSessionId(char id[SESSION_ID_LENGTH])
{
	FormatEx(id, sizeof(id), "%08x%08x%08x%08x", GetURandomInt(), GetURandomInt(), GetURandomInt(), GetURandomInt());
}

bool ValidateSession(WebConnection connection, char[] buffer, int length)
{
	char id[SESSION_ID_LENGTH + 1]; // +1 to detect over-length IDs.
	connection.GetRequestData(WebRequestDataType_Cookie, "id", id, sizeof(id));

	if ((strlen(id) + 1) != SESSION_ID_LENGTH) {
		return false;
	}

	DataPack sessionPack;
	if (!sessions.GetValue(id, sessionPack)) {
		return false;
	}

	sessionPack.Reset();

	int lastActive = sessionPack.ReadCell();
	if ((GetTime() - lastActive) > SESSION_TIMEOUT) {
		return false;
	}

	char ip[WEB_CLIENT_ADDRESS_LENGTH];
	connection.GetClientAddress(ip, sizeof(ip));

	char session_ip[WEB_CLIENT_ADDRESS_LENGTH];
	sessionPack.ReadString(session_ip, sizeof(session_ip));

	if (strcmp(ip, session_ip) != 0) {
		return false;
	}

	sessionPack.ReadString(buffer, length);

	// Update the activity time.
	sessionPack.Reset();
	sessionPack.WriteCell(GetTime());

	return true;
}

bool RequireSessionAccess(WebConnection connection, bool &success, const char[] command, int flags, bool override_only = false)
{
	char steamid[32];
	if (!ValidateSession(connection, steamid, sizeof(steamid))) {
		success = connection.QueueResponse(WebStatus_Found, loginRedirectResponse);
		return false;
	}

	AdminId admin = FindAdminByIdentity(AUTHMETHOD_STEAM, steamid);

	if (admin == INVALID_ADMIN_ID) {
		success = connection.QueueResponse(WebStatus_Forbidden, forbiddenResponse);
		return false;
	}

	if (!CheckAccess(admin, command, flags, override_only)) {
		success = connection.QueueResponse(WebStatus_Forbidden, forbiddenResponse);
		return false;
	}

	return true;
}

public bool OnWebRequest(WebConnection connection, const char[] method, const char[] url)
{
	if (StrEqual(url, "/login")) {
		int index = pendingCheckAuthenticationRequests.FindValue(connection);
		if (index != -1) {
			CheckAuthenticationState state = pendingCheckAuthenticationRequests.Get(index, CheckAuthenticationData_State);
			if (state == CheckAuthenticationState_Pending) {
				// Still waiting.
				return true;
			}

			DataPack steamidPack = pendingCheckAuthenticationRequests.Get(index, CheckAuthenticationData_SteamId);
			steamidPack.Reset();

			char steamid[32];
			steamidPack.ReadString(steamid, sizeof(steamid));

			delete steamidPack;
			pendingCheckAuthenticationRequests.Erase(index);

			char buffer[256];
			if (state == CheckAuthenticationState_Valid) {
				FormatEx(buffer, sizeof(buffer), "Claim passed validation. (%s)", steamid);
			} else {
				FormatEx(buffer, sizeof(buffer), "Claim FAILED validation.");
			}

			WebStatus status = WebStatus_OK;
			WebResponse response = new WebStringResponse(buffer);
			response.AddHeader(WebHeader_ContentType, "text/plain; charset=UTF-8");

			if (state == CheckAuthenticationState_Valid) {
				char id[SESSION_ID_LENGTH];
				GenerateSessionId(id);

				char ip[WEB_CLIENT_ADDRESS_LENGTH];
				connection.GetClientAddress(ip, sizeof(ip));

				DataPack sessionPack = new DataPack();
				sessionPack.WriteCell(GetTime());
				sessionPack.WriteString(ip);
				sessionPack.WriteString(steamid);

				sessions.SetValue(id, sessionPack);

				FormatEx(buffer, sizeof(buffer), "id=%s; HttpOnly", id);
				response.AddHeader(WebHeader_SetCookie, buffer);

				char return_url[1024];
				managerUrl.GetString(return_url, sizeof(return_url));
				StrCat(return_url, sizeof(return_url), "secret");
				response.AddHeader(WebHeader_Location, return_url);

				status = WebStatus_Found;
			} else {
				response.AddHeader(WebHeader_SetCookie, "id=; Expires=Thu, 01 Jan 1970 00:00:00 GMT; HttpOnly");
			}

			bool success = connection.QueueResponse(status, response);
			delete response;
			return success;
		}

		char id[SESSION_ID_LENGTH + 1]; // +1 to detect over-length IDs.
		connection.GetRequestData(WebRequestDataType_Cookie, "id", id, sizeof(id));

		DataPack sessionPack;
		if ((strlen(id) + 1) == SESSION_ID_LENGTH && sessions.GetValue(id, sessionPack)) {
			// Burninate the user's session if they have one.
			// All responses out of here will either clear the cookie or create a new session.
			delete sessionPack;
			sessions.Remove(id);
		}

		char openid_mode[256];
		if (!connection.GetRequestData(WebRequestDataType_Get, "openid.mode", openid_mode, sizeof(openid_mode)) || strcmp(openid_mode, "id_res") != 0) {
			return connection.QueueResponse(WebStatus_Found, steamRedirectResponse);
		}

		char return_to[1024];
		managerUrl.GetString(return_to, sizeof(return_to));
		StrCat(return_to, sizeof(return_to), "login");

		char openid_return_to[1024];
		if (!connection.GetRequestData(WebRequestDataType_Get, "openid.return_to", openid_return_to, sizeof(openid_return_to)) || strcmp(openid_return_to, return_to) != 0) {
			return connection.QueueResponse(WebStatus_Found, steamRedirectResponse);
		}

		char openid_claimed_id[1024];
		if (!connection.GetRequestData(WebRequestDataType_Get, "openid.claimed_id", openid_claimed_id, sizeof(openid_claimed_id)) || strncmp(openid_claimed_id, CLAIMED_ID_BASE, strlen(CLAIMED_ID_BASE)) != 0) {
			return connection.QueueResponse(WebStatus_Found, steamRedirectResponse);
		}

		char steamid[32];
		strcopy(steamid, sizeof(steamid), openid_claimed_id[strlen(CLAIMED_ID_BASE)]);

		PrintToServer(">>> Received valid-looking claim for '%s', waiting for verification...", steamid);

		DataPack steamidPack = new DataPack();
		steamidPack.WriteString(steamid);

		index = pendingCheckAuthenticationRequests.Push(connection);
		pendingCheckAuthenticationRequests.Set(index, CheckAuthenticationState_Pending, CheckAuthenticationData_State);
		pendingCheckAuthenticationRequests.Set(index, steamidPack, CheckAuthenticationData_SteamId);

		// We don't have a sane way of iterating over all the params sent, but it should only be a subset of these.
		// "mode" is excluded because it needs to be added with a different value.
		// "return_to" and "claimed_id" are excluded because we need them anyway and can avoid copying them twice.
		char openid_fields[][] = {"openid.ns", "openid.op_endpoint", "openid.identity", "openid.response_nonce", "openid.invalidate_handle", "openid.assoc_handle", "openid.signed", "openid.sig"};

		Handle request = SteamWorks_CreateHTTPRequest(k_EHTTPMethodPOST, "https://steamcommunity.com/openid/login");

		SteamWorks_SetHTTPRequestContextValue(request, connection);
		SteamWorks_SetHTTPCallbacks(request, OnOpenIdCheckAuthenticationResponse);

		SteamWorks_SetHTTPRequestGetOrPostParameter(request, "openid.mode", "check_authentication");

		SteamWorks_SetHTTPRequestGetOrPostParameter(request, "openid.return_to", openid_return_to);
		SteamWorks_SetHTTPRequestGetOrPostParameter(request, "openid.claimed_id", openid_claimed_id);

		for (int i = 0; i < sizeof(openid_fields); ++i) {
			char openid_field[1024];
			if (!connection.GetRequestData(WebRequestDataType_Get, openid_fields[i], openid_field, sizeof(openid_field))) {
				continue;
			}

			SteamWorks_SetHTTPRequestGetOrPostParameter(request, openid_fields[i], openid_field);
		}

		SteamWorks_SendHTTPRequest(request);
		SteamWorks_PrioritizeHTTPRequest(request);

		// Don't queue a response, we'll get called every frame to check.
		return true;
	}

	if (StrEqual(url, "/")) {
		return connection.QueueResponse(WebStatus_OK, indexResponse);
	}

	if (StrEqual(url, "/secret")) {
		bool success;
		if (!RequireSessionAccess(connection, success, "sm_rcon", ADMFLAG_RCON)) {
			return success;
		}

		return connection.QueueResponse(WebStatus_OK, topSecretResponse);
	}

	return connection.QueueResponse(WebStatus_NotFound, notFoundResponse);
}
