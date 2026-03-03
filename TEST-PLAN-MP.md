# SiegeNight MP Stabilization Test Plan (B42 Dedicated)

## Goal
Confirm v2.5.41 fixes in real dedicated MP:
- no Lua parse/boot errors
- no invisible/split siege zombies
- schedule guard prevents “siege every day”
- mini-horde gunfire cap behaves
- special corpse sanity tick prevents stuck/downed specials lingering

## Setup
1) Dedicated server uses Workshop item (or local workshop staging).
2) Fresh log folder cleared so newest `*DebugLog-server*` is unambiguous.
3) 3 clients connect (A/B/C). Prefer one player near base, one 30-80 tiles away, one far (200+ tiles).

## Gate 1 — boot
- Run `scripts/validate-dedi-load.ps1` and verify log line:
  - `[SiegeNight] SiegeNight loaded (v2.5.41)`
- No `KahluaException` / `LexState.lexerror` mentioning SiegeNight.

## Gate 2 — commands
- In chat: `!siege status` and `!siege next` respond for all players.

## Gate 3 — forced siege visibility
- Admin: `!siege start`
- Verify:
  - all players see waves progress
  - zombies exist/are attackable for all clients (no “invisible to some players”)
  - special zombies (sprinter/breaker/tank) show correct visuals/stats for all clients

## Gate 4 — mini-horde gunfire cap
- On a non-siege day:
  - Fire sustained shots for 1-2 minutes, then stop.
  - Confirm mini-horde triggers at most once per 10-minute window due to cap.
  - Confirm no rapid chain-triggering.

## Gate 5 — schedule guard (migrated save)
- Use an existing save that previously exhibited “siege every day”.
- Fast-forward multiple days (or wait) and confirm:
  - `nextSiegeDay` advances properly after DAWN → IDLE
  - no stuck state causes daily sieges

## Gate 6 — special corpse sanity
- During an active siege, ensure at least one special is downed/killed.
- Confirm corpse does not remain in broken/stuck state indefinitely.

## Evidence to capture
- Server log excerpt around state transitions (IDLE→WARNING→ACTIVE→DAWN→IDLE)
- Any client console errors from SiegeNight
- Short clips/screenshots if invisibility reproduces
