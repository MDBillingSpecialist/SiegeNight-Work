# Draft reply to Steam comment (Binco) — MP dead-but-moving / unlootable

Hey — thanks for the detailed report.

Quick clarifier that would really help narrow this down:
- Does it happen to **all SiegeNight horde spawns**, or only the **specials** (sprinters/breakers/tanks)?
- If you can, do you remember whether the zombie was a **siege wave spawn** vs a **mini-horde** spawn?

I just pushed a potential fix (v2.5.43) aimed at MP corpse/loot desync:
- Special zombie **health is no longer set client-side** (server stays authoritative).
- All SiegeNight spawns now use **base spawn health = 1.0**; extra health is applied server-side only for specials.

If you’re able to repro on 2.5.43, tell me:
- whether the zombie was a special or normal
- your server host type (dedicated vs listen)
- and whether it was only unlootable for some players or everyone

That should let me lock it down fast.
