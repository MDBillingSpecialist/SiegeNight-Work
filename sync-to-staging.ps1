param(
  [string]$RepoRoot = "C:\Claude Core\openclaw\work\siegenight-stabilization",
  [string]$StagingRoot = "C:\Users\theth\Zomboid\Workshop\SiegeNight"
)

$ErrorActionPreference = 'Stop'

$srcMod = Join-Path $RepoRoot "Contents\mods\SiegeNight"
$dstMod = Join-Path $StagingRoot "Contents\mods\SiegeNight"

if(!(Test-Path $srcMod)) { throw "Source mod folder not found: $srcMod" }
if(!(Test-Path $StagingRoot)) { throw "Staging root not found: $StagingRoot" }

# Ensure destination is clean so we never end up with nested SiegeNight/SiegeNight
if(Test-Path $dstMod) {
  Remove-Item -Recurse -Force $dstMod
}
New-Item -ItemType Directory -Force -Path $dstMod | Out-Null

Copy-Item -Recurse -Force (Join-Path $srcMod '*') $dstMod

# Copy workshop metadata files that steamcmd uses
Copy-Item -Force (Join-Path $RepoRoot 'upload.vdf')      (Join-Path $StagingRoot 'upload.vdf')
Copy-Item -Force (Join-Path $RepoRoot 'workshop.txt')    (Join-Path $StagingRoot 'workshop.txt')
Copy-Item -Force (Join-Path $RepoRoot 'description.txt') (Join-Path $StagingRoot 'description.txt')

# Verify version + nesting
$shared = Join-Path $dstMod 'media\lua\shared\SiegeNight_Shared.lua'
$modInfo = Join-Path $dstMod 'mod.info'

$verLine = (Select-String -Path $shared -Pattern 'SN\.VERSION' | Select-Object -First 1).Line
$modVerLine = (Select-String -Path $modInfo -Pattern '^modversion=' | Select-Object -First 1).Line

$nested = Join-Path $dstMod 'SiegeNight'
if(Test-Path $nested) { throw "NESTING BUG: found $nested" }

Write-Host "Staging sync complete."
Write-Host "  $verLine"
Write-Host "  $modVerLine"
