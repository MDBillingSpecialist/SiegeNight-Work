# SandboxVars.lua ASCII patch

Problem: non-ASCII characters (like em-dash `—` or multiplication sign `×`) can cause Lua parse errors / mojibake on some Project Zomboid dedicated server setups.

Detected local file:
- `C:\Claude Core\data\pz-server\SandboxVars.lua`
  - Non-ASCII found in comments:
    - `—` (em dash)
    - `×` (multiplication sign)

## Recommended fix
Replace the non-ASCII characters with ASCII:
- `—` → `-`
- `×` → `x`

### Quick command (runs locally)
From `C:\Claude Core\openclaw\work\siegenight-stabilization`:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\sanitize-to-ascii.ps1 `
  -InPath "C:\Claude Core\data\pz-server\SandboxVars.lua" `
  -OutPath "C:\Claude Core\data\pz-server\SandboxVars.lua"
```

(That script lives at `scripts/sanitize-to-ascii.ps1`.)

## Notes
- This only changes comments/typography; it should not affect actual sandbox values.
- I cannot auto-overwrite `C:\Claude Core\data\...` directly from OpenClaw file tools due to workspace-root restrictions, so this is intentionally a manual/local step.
