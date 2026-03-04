# Next steps (SiegeNight stabilization)

## Current state (local worktree)
- Staged version: **2.5.43**
- Dedicated load validation: OK (log shows `[SiegeNight] SiegeNight loaded (v2.5.43)`)
- Workshop staging folder updated: `C:\Users\theth\Zomboid\Workshop\SiegeNight\Contents`

## Outstanding external actions
1) **Push to GitHub** (repo is ahead of origin/main by 1 commit)
   - `git push`
   - NOTE: this is an external action; do it when Austin says go.

2) **Steam Workshop upload** (still requires interactive SteamCMD login)
   - `C:\steamcmd\steamcmd.exe +login <user> <pass> <guard> +workshop_build_item "C:\Users\theth\Zomboid\Workshop\SiegeNight\upload.vdf" +quit`

## MP bug to validate (Binco)
- Symptom: mod-spawned horde zombies can be “killed but still moving” + unlootable.
- Mitigations now in 2.5.43:
  - Don’t set zombie health client-side on SyncSpecial.
  - Don’t pass boosted base health into `addZombiesInOutfit`; keep spawn healthMult at 1.0.
- Need real 2-3 player dedicated repro to confirm fix.
