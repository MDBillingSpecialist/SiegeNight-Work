# Upload blocker - SteamCMD (SiegeNight)

## Symptom
SteamCMD workshop upload fails with:
- `ERROR! Failed to initialize build on server (Access Denied)`

## Repro
```powershell
& "C:\steamcmd\steamcmd.exe" +login anonymous +workshop_build_item "C:\Users\theth\Zomboid\Workshop\SiegeNight\upload.vdf" +quit
```

## Notes
- Anonymous cannot upload (expected).
- Must run SteamCMD with the *publishing* Steam account. If Steam Guard is enabled, it needs the interactive code.
- Recent failures logged in: `C:\steamcmd\logs\workshop_log.txt`

## Working state (historical)
`workshop_log.txt` shows successful uploads on 2026-03-02 and 2026-03-05 00:58/01:51 when the publishing account `U:1:84845957` was used.
