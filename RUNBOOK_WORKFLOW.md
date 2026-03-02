# SiegeNight workflow (single source of truth)

## Goal
Avoid "multiple SiegeNight copies" causing uploads + dedi tests to run different code than GitHub.

## Source of truth
- **GitHub repo working copy:** `C:\Claude Core\openclaw\work\siegenight-stabilization\Contents\mods\SiegeNight`

## SteamCMD upload staging
- **Staging folder (SteamCMD builds from this):** `C:\Users\theth\Zomboid\Workshop\SiegeNight\Contents\mods\SiegeNight`

## Dedicated server runtime workshop download
- **Dedi workshop download:**
  `C:\SteamCMD\steamapps\common\Project Zomboid Dedicated Server\steamapps\workshop\content\108600\3669589584\mods\SiegeNight`

## Scripts
From repo root:

### Sync repo → staging (recommended before upload)
```powershell
.\sync-to-staging.ps1
```
This also verifies `SN.VERSION` and SHA256 of `SiegeNight_Server.lua`.

### Sync staging → repo (only if you edited staging directly)
```powershell
.\sync-from-staging.ps1
```

## Release gate (don’t upload until these pass)
1) Clean dedi boot: no `KahluaException` / `LexState.lexerror` for SiegeNight
2) `!siege status` responds
3) Siege panel loads (no "world data not loaded")
4) MP mini-horde: spawned zombies are visible to all players (or explicitly expected behavior documented)

