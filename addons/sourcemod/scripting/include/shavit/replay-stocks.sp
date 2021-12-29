
stock bool Shavit_ReplayEnabledStyle(int style)
{
	return !Shavit_GetStyleSettingBool(style, "unranked") && !Shavit_GetStyleSettingBool(style, "noreplay");
}

stock bool Shavit_GetReplayFolderPath_Stock(char buffer[PLATFORM_MAX_PATH])
{
	char sPath[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, sPath, PLATFORM_MAX_PATH, "configs/shavit-replay.cfg");

	KeyValues kv = new KeyValues("shavit-replay");
	
	if (!kv.ImportFromFile(sPath))
	{
		delete kv;
		return false;
	}

	kv.GetString("replayfolder", buffer, PLATFORM_MAX_PATH, "{SM}/data/replaybot");

	if (StrContains(buffer, "{SM}") != -1)
	{
		ReplaceString(buffer, PLATFORM_MAX_PATH, "{SM}/", "");
		BuildPath(Path_SM, buffer, PLATFORM_MAX_PATH, "%s", buffer);
	}

	delete kv;
	return true;
}

stock void Shavit_Replay_CreateDirectories(const char[] sReplayFolder, int styles)
{
	if (!DirExists(sReplayFolder) && !CreateDirectory(sReplayFolder, 511))
	{
		SetFailState("Failed to create replay folder (%s). Make sure you have file permissions", sReplayFolder);
	}

	char sPath[PLATFORM_MAX_PATH];
	FormatEx(sPath, PLATFORM_MAX_PATH, "%s/copy", sReplayFolder);

	if (!DirExists(sPath) && !CreateDirectory(sPath, 511))
	{
		SetFailState("Failed to create replay copy folder (%s). Make sure you have file permissions", sPath);
	}

	for(int i = 0; i < styles; i++)
	{
		if (!Shavit_ReplayEnabledStyle(i))
		{
			continue;
		}

		FormatEx(sPath, PLATFORM_MAX_PATH, "%s/%d", sReplayFolder, i);

		if (!DirExists(sPath) && !CreateDirectory(sPath, 511))
		{
			SetFailState("Failed to create replay style folder (%s). Make sure you have file permissions", sPath);
		}
	}

	// Test to see if replay file creation even works...
	FormatEx(sPath, sizeof(sPath), "%s/0/faketestfile_69.replay", sReplayFolder);
	File fTest = OpenFile(sPath, "wb+");
	CloseHandle(fTest);

	if (fTest == null)
	{
		SetFailState("Failed to write to replay folder (%s). Make sure you have file permissions.", sReplayFolder);
	}
}