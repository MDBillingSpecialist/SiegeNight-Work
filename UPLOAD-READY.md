# Upload readiness — SiegeNight v2.5.43 (2026-03-03)

## What’s staged
- Workshop staging folder: `C:\Users\theth\Zomboid\Workshop\SiegeNight\Contents`
- `upload.vdf` changenote: v2.5.43
- `description.txt` includes v2.5.42+ changelog entries.

## Key fix in 2.5.43
- MP: force all SiegeNight spawns to use base health 1.0 (don’t pass boosted health into `addZombiesInOutfit`).
- MP: client no longer sets zombie health in `SyncSpecial` (server authoritative).
- Goal: fix Binco report: “killed but still moving” + unlootable mod-spawned horde zombies.

## Verification scripts
- `scripts/verify-packaging.ps1` → OK (SN.VERSION + modversion 2.5.43)
- `scripts/validate-workshop-content.ps1` → OK (staging contains 2.5.43)
- `scripts/validate-dedi-load.ps1` → OK (mod loads; no parse errors)

## Remaining gates
- Real 3-player dedicated repro to confirm no corpse/loot desync.

## Upload command (interactive)
```powershell
& "C:\steamcmd\steamcmd.exe" +login <steam_user> <steam_pass> <steam_guard_if_needed> +workshop_build_item "C:\Users\theth\Zomboid\Workshop\SiegeNight\upload.vdf" +quit
```

## Git status
- Local branch is ahead of origin by 2 commits (needs `git push` before/after workshop upload if you want the repo to match Workshop).
