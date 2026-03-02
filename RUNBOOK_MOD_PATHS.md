# SiegeNight – Paths & Workflow (single source of truth)

## Source of truth (GitHub repo)
- Repo root: `C:\Claude Core\openclaw\work\siegenight-stabilization`
- Mod folder: `Contents\mods\SiegeNight\`

All code changes should happen here if you want them tracked in Git.

## Upload staging (SteamCMD content folder)
- Staging root: `C:\Users\theth\Zomboid\Workshop\SiegeNight\`
- Mod folder (uploaded): `Contents\mods\SiegeNight\`

SteamCMD uploads whatever `upload.vdf` points at. This is **not** Git-tracked.

## Dedicated server workshop download (runtime)
- `C:\SteamCMD\steamapps\common\Project Zomboid Dedicated Server\steamapps\workshop\content\108600\3669589584\mods\SiegeNight\`

This is what the dedicated server runs when using `WorkshopItems=3669589584` + `Mods=SiegeNight`.

## Local override (avoid during MP testing)
- `C:\Users\theth\Zomboid\mods\SiegeNight\`

If this exists, it can cause "which version is running" confusion. Prefer deleting/disabling it during MP testing.

## Scripts
From the repo root:
- Copy repo -> staging (for upload):
  - `./sync-to-staging.ps1`
- Copy staging -> repo (if Claude Code edited staging):
  - `./sync-from-staging.ps1`

## Suggested release gate (before workshop push)
1) Run `./sync-to-staging.ps1`
2) Dedicated server boot: no `KahluaException` / `LexState.lexerror` referencing SiegeNight
3) In-game: `!siege status` works; panel loads; mini-horde spawns are visible to all players in MP test
4) Only then upload via SteamCMD
