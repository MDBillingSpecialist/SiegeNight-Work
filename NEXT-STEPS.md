# SiegeNight stabilization — next steps

## Immediate
- Upload **v2.5.43** to Workshop once SteamCMD credentials are available (current blocker: Access Denied without publisher login).

## Verification gates
1) Dedicated server boots cleanly (no SiegeNight parse errors)
2) `!siege status` responds
3) Siege panel loads
4) 3-player dedicated MP repro:
   - confirm no invisible zombies
   - confirm Binco report fixed: no “dead-but-moving / unlootable” bodies

## Investigation notes (Binco report)
- Suspected root: MP client/server state desync around death/corpse + loot interaction, likely aggravated by:
  - spawning with non-1.0 healthMult in `addZombiesInOutfit`, and/or
  - setting zombie health client-side during SyncSpecial.
- Mitigation shipped in v2.5.43:
  - healthMult forced to 1.0 on all SiegeNight spawns
  - SyncSpecial no longer sets health client-side

## Steam reply draft
- See `DRAFT_STEAM_REPLY.md`
