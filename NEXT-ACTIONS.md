# SiegeNight stabilization - next actions

## Upload blocker
- SteamCMD upload still requires interactive login (publishing account). Previous error: **Access Denied**.

## Current staged version
- **2.5.44** staged in `C:\Users\theth\Zomboid\Workshop\SiegeNight\Contents`

## Priority validation (MP)
1) Repro the new MP report:
   - "killed but still moving" zombies
   - corpse cannot be looted
   - confirm whether it affects **all** mod-spawned zombies or only **specials** (latest report says **all horde zombies**)
   - capture: client console.txt + server console.txt around the kill moment
   - note whether the zombie was: siege / mini-horde / bonus (check `md.SN_Siege` / `md.SN_MiniHorde` if we add temporary logging)

2) Dedicated MP smoke test (3 players preferred):
   - mini-horde spawns visible to all
   - siege spawns visible to all
   - no invisible zombies regression

3) Migrated save test:
   - confirm schedule guard holds (no 'siege every day')
   - validate `nextSiegeDay` lifecycle across restart

## Notes on attempted fix (2.5.43)
- Do not set zombie health client-side during `SyncSpecial`.
- Ensure all mod spawns pass `healthMult = 1.0` into `addZombiesInOutfit`; specials get health via server-side stat edits only.

## When ready to ship
- Run SteamCMD upload with creds:
  ```powershell
  & "C:\steamcmd\steamcmd.exe" +login <steam_user> <steam_pass> <steam_guard_if_needed> +workshop_build_item "C:\Users\theth\Zomboid\Workshop\SiegeNight\upload.vdf" +quit
  ```
