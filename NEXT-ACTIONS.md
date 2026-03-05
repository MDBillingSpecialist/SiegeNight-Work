# SiegeNight stabilization - next actions

## Upload blocker
- SteamCMD upload still requires interactive login (publishing account). Previous error: **Access Denied**.

## Current staged version
- **2.6.19** staged in `C:\Users\theth\Zomboid\Workshop\SiegeNight\Contents`

## Current mitigation staged (not MP-verified yet)
- Corpse sanity expanded beyond specials:
  - Siege-side sanity tick now applies to any zombie tagged with `SN_SpecialType` OR `SN_Siege` OR `SN_MiniHorde`.
- Mini-horde sanity tick added:
  - While a mini-horde job is active, periodically force-kill any tagged `SN_MiniHorde` zombie that stays knocked-down/on-floor >2s without becoming dead.
- Debug logging:
  - When corpse sanity force-kills a zombie, emit a `CorpseSanity: forceKill` debug line to help identify remaining MP cases.

## Priority validation (MP)
1) Repro the MP report:
   - "killed but still moving" zombies
   - corpse cannot be looted
   - confirm whether it affects all mod-spawned zombies or only specials (latest report says all horde zombies)
   - capture: client `console.txt` + server `console.txt` around the kill moment
   - note whether the zombie was: siege / mini-horde / bonus

2) Dedicated MP smoke test (3 players preferred):
   - mini-horde spawns visible to all
   - siege spawns visible to all
   - no invisible zombies regression

3) Migrated save test:
   - confirm schedule guard holds (no "siege every day")
   - validate `nextSiegeDay` lifecycle across restart

## Dedi sanity check note
- `scripts/validate-dedi-load.ps1` only reports what the last dedicated server boot logged.
  If it still shows an older version, the dedi has not restarted since the latest staging sync.

## When ready to ship
Run SteamCMD upload with creds:
```powershell
& "C:\steamcmd\steamcmd.exe" +login <steam_user> <steam_pass> <steam_guard_if_needed> +workshop_build_item "C:\Users\theth\Zomboid\Workshop\SiegeNight\upload.vdf" +quit
```
