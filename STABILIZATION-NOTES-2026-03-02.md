# SiegeNight stabilization notes (2026-03-02)

Work dir: `C:\Claude Core\openclaw\work\siegenight-stabilization`

## Fixes applied

### Mini-horde gunfire cap reset
- `SiegeNight_MiniHorde.lua`: reset `SN_MH_GunfireHeatThisTick = 0` at start of `onEveryTenMinutes()`.
- Applied to both `media/` and `42/media/` copies.

### Special zombie corpse bug (stuck downed / immortal corpses)
- `SiegeNight_Server.lua`:
  - Fixed accidental duplicate function header: `local function forceKillZombie(z)local function forceKillZombie(z)`.
  - Added periodic tick call of `specialCorpseSanityTick(siegeZombies)` while ACTIVE (`CORPSE_SANITY_INTERVAL=30`).
- Applied to both `media/` and `42/media/` copies.

### Critical runtime error fix
- `spawnOneZombie`: replaced `if player then zombie:pathToSound(...) end` with `aggroPlayer` (the correct variable).
- Repath loop: replaced `if player then ... end` with `if entry.player then ... end`.
- Applied to both `media/` and `42/media/` copies.

## Next
- Validate daily schedule guard behavior in live server logs (nextSiegeDay vs isSiegeDay fallback; restart mid-day transitions).
- Run MP test focusing on special zombies getting knocked down repeatedly and verifying they fully die + leave sane corpse.
