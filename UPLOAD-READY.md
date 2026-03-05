# Upload readiness - SiegeNight v2.6.19 (2026-03-05)

## What's staged
- Workshop staging folder: `C:\Users\theth\Zomboid\Workshop\SiegeNight\Contents`
- `workshop.txt` version: **2.6.19**
- `upload.vdf` changenote: updated for **2.6.19**

## Key fixes included
- Mini-horde dedi: prevent "nonstop" mini-hordes by ensuring the cooldown logic actually sees active spawn jobs.
  - Fix: `activeMiniHordes` declared before `onEveryTenMinutes()` uses it.
  - Defensive normalization/clamping of cooldownMinutes/threshold.
- MP stability: keep base health spawn (1.0) for all horde spawns; do not set health client-side in `SyncSpecial`.
- Corpse/loot desync mitigation (MP):
  - Siege-side corpse sanity tick expanded from specials only -> ANY SiegeNight-tagged zombie (`SN_SpecialType` OR `SN_Siege` OR `SN_MiniHorde`).
  - Mini-horde corpse sanity tick added during active mini-horde jobs.
  - Debug logging added when corpse sanity force-kills a zombie (`CorpseSanity: forceKill ...`).
- Dedi safety: server-only Lua guarded from running on MP clients; Lua files ASCII-only.

## Verification scripts
- `scripts/verify-packaging.ps1` -> OK (SN.VERSION + modversion 2.6.19)
- `scripts/validate-workshop-content.ps1` -> OK (staging contains 2.6.19)

## Remaining gates
- Real MP dedicated repro to confirm corpse/loot desync is mitigated (grab server+client logs around the kill moment).

## Upload command (interactive)
```powershell
& "C:\steamcmd\steamcmd.exe" +login <steam_user> <steam_pass> <steam_guard_if_needed> +workshop_build_item "C:\Users\theth\Zomboid\Workshop\SiegeNight\upload.vdf" +quit
```
