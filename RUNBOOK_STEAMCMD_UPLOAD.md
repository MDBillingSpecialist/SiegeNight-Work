# Runbook: SteamCMD upload (SiegeNight)

## Symptom
`Failed to initialize build on server (Access Denied)`

## Cause (observed)
SteamCMD attempts are being run under various Steam sessions (`workshop_log.txt` shows many `a:1:*` anonymous-style users). Upload only succeeds when logged in as the publishing account (`workshop_log.txt` shows success under `U:1:84845957`).

## Fix
Run SteamCMD in an interactive terminal and login as the publishing account, then run the workshop build.

### Command
```powershell
& "C:\steamcmd\steamcmd.exe" +login <steam_user> <steam_pass> <steam_guard_if_needed> +workshop_build_item "C:\Users\theth\Zomboid\Workshop\SiegeNight\upload.vdf" +quit
```

### Notes
- If Steam Guard prompts, you must type the code.
- Verify result in `C:\steamcmd\logs\workshop_log.txt`.
- If you see `Loading workshop items... [a:1:...]` and then Access Denied, you're not actually logged into the right account.
