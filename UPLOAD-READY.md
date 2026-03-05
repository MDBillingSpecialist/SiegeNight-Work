# Upload readiness — SiegeNight v2.5.45 (2026-03-04)

## What’s staged
- Workshop staging folder: `C:\Users\theth\Zomboid\Workshop\SiegeNight\Contents`
- `workshop.txt` updated to v2.5.45 changelog
- NOTE: `upload.vdf` changenote should be updated to v2.5.45 before running SteamCMD.

## Key fixes in 2.5.45
- Mini-horde dedi: prevent "nonstop" mini-hordes by ensuring the cooldown logic actually sees active spawn jobs.
  - Fix: `activeMiniHordes` is now declared before `onEveryTenMinutes()` uses it.
  - Also: clamp cooldownMinutes/threshold to sane minimums.
- MP stability: keep base health spawn (1.0) for all horde spawns; do not set health client-side in `SyncSpecial`.
- Dedi safety: removed stray non-ASCII punctuation from Lua comments (reduces `LexState.lexerror` risk).

## Verification scripts
- `scripts/verify-packaging.ps1` → OK (SN.VERSION + modversion 2.5.45)
- `scripts/validate-workshop-content.ps1` → OK (staging contains 2.5.45)
- `scripts/validate-dedi-load.ps1` → OK (mod loads; no parse errors)

## Remaining gates
- Real 3-player dedicated repro to confirm no corpse/loot desync.

## Upload command (interactive)
```powershell
& "C:\steamcmd\steamcmd.exe" +login <steam_user> <steam_pass> <steam_guard_if_needed> +workshop_build_item "C:\Users\theth\Zomboid\Workshop\SiegeNight\upload.vdf" +quit
```

## Git status
- Repo has been pushed; local branch should match origin.
