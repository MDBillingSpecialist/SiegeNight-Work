# SiegeNight MP Stabilization Test Plan (B42 Dedicated)

## Goal
Confirm the current stabilization build in real dedicated MP:
- no Lua parse/boot errors
- no invisible/split siege zombies
- schedule guard prevents "siege every day"
- mini-horde gunfire cap behaves
- corpse sanity prevents "dead-but-moving" / unlootable SiegeNight zombies

## Current staged version
- **v2.6.19**

## Setup
1) Dedicated server uses Workshop item (or local workshop staging).
2) Fresh log folder cleared so newest `*DebugLog-server*` is unambiguous.
3) 3 clients connect (A/B/C). Prefer one player near base, one 30-80 tiles away, one far (200+ tiles).

## Gate 1 - boot
- Run `scripts/validate-dedi-load.ps1` and verify log line:
  - `[SiegeNight] SiegeNight loaded (v2.6.19)`
- No `KahluaException` / `LexState.lexerror` mentioning SiegeNight.

## Gate 2 - commands
- In chat: `!siege status` and `!siege next` respond for all players.

## Gate 3 - forced siege visibility
- Admin: `!siege start`
- Verify:
  - all players see waves progress
  - zombies exist/are attackable for all clients (no "invisible to some players")
  - special zombies (sprinter/breaker/tank) show correct visuals/stats for all clients

## Gate 4 - mini-horde gunfire cap
- On a non-siege day:
  - Fire sustained shots for 1-2 minutes, then stop.
  - Confirm mini-horde triggers at most once per 10-minute window due to cap.
  - Confirm no rapid chain-triggering.

## Gate 5 - schedule guard (migrated save)
- Use an existing save that previously exhibited "siege every day".
- Fast-forward multiple days (or wait) and confirm:
  - `nextSiegeDay` advances properly after DAWN -> IDLE
  - no stuck state causes daily sieges

## Gate 6 - corpse sanity (key repro)
Try to reproduce the MP report:
- SiegeNight-spawned zombies can become "killed but still moving" and the corpse cannot be looted.

During this test, watch the **server log** for debug lines:
- `CorpseSanity: forceKill (siege) ...`
- `CorpseSanity: forceKill (mini) ...`

If the bug reproduces, capture:
- server `console.txt` excerpt around the kill moment (include any `CorpseSanity:` lines)
- affected client `console.txt`
- whether the zombie was siege / mini-horde / special

## Evidence to capture (always)
- Server log excerpt around state transitions (IDLE->WARNING->ACTIVE->DAWN->IDLE)
- Any client console errors from SiegeNight
- Short clips/screenshots if invisibility reproduces
