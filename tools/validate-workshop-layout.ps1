param(
  [string]$ContentsRoot = "C:\Users\theth\Zomboid\Workshop\SiegeNight\Contents"
)

$ErrorActionPreference = 'Stop'

function Assert($cond, [string]$msg){ if(-not $cond){ throw $msg } }

Write-Host "Validating SiegeNight workshop layout..." -ForegroundColor Cyan
Write-Host "Root: $ContentsRoot"

Assert (Test-Path $ContentsRoot) "ContentsRoot not found: $ContentsRoot"
Assert (Test-Path (Join-Path $ContentsRoot 'mods')) "Missing 'mods' folder under ContentsRoot"
Assert (Test-Path (Join-Path $ContentsRoot 'mods\SiegeNight')) "Missing 'mods\\SiegeNight' folder under ContentsRoot"

$modRoot = Join-Path $ContentsRoot 'mods\SiegeNight'

# Guard against 'mods/SiegeNight/SiegeNight' nesting
$nested = Join-Path $modRoot 'SiegeNight'
Assert (-not (Test-Path $nested)) "BAD PACKAGING: Found nested folder: $nested"

# Basic expected folders
foreach($d in @('media','common','42')){
  Assert (Test-Path (Join-Path $modRoot $d)) "Missing expected folder under mod root: $d"
}

# Version checks
$shared = Join-Path $modRoot 'media\lua\shared\SiegeNight_Shared.lua'
$modInfo = Join-Path $modRoot 'mod.info'
Assert (Test-Path $shared) "Missing: $shared"
Assert (Test-Path $modInfo) "Missing: $modInfo"

$verLine = (Select-String -Path $shared -Pattern 'SN\.VERSION\s*=\s*"' | Select-Object -First 1).Line
$modVerLine = (Select-String -Path $modInfo -Pattern '^modversion=' | Select-Object -First 1).Line

Write-Host "Shared: $verLine"
Write-Host "mod.info: $modVerLine"

Write-Host "OK: layout + version sanity passed." -ForegroundColor Green
