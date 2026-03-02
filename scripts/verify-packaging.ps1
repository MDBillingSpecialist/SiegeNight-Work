param(
  [string]$StagingRoot = "C:\Users\theth\Zomboid\Workshop\SiegeNight"
)

$ErrorActionPreference = "Stop"

$content = Join-Path $StagingRoot "Contents"
$mods = Join-Path $content "mods"
$mod = Join-Path $mods "SiegeNight"

if(!(Test-Path $content)){ throw "Missing staging Contents folder: $content" }
if(!(Test-Path $mods)){ throw "Missing staging mods folder: $mods" }
if(!(Test-Path $mod)){ throw "Missing staging mod folder: $mod" }

# No nested SiegeNight folder
$nested = Get-ChildItem $mod -Directory -Recurse | Where-Object { $_.Name -eq "SiegeNight" }
if($nested){
  Write-Host "FAIL: nested SiegeNight folder detected" -ForegroundColor Red
  $nested | Select-Object -ExpandProperty FullName | ForEach-Object { Write-Host $_ }
  exit 1
}

# Must have mod.info
if(!(Test-Path (Join-Path $mod "mod.info"))){
  Write-Host "FAIL: missing mod.info" -ForegroundColor Red
  exit 1
}

# Print version
$ver = (Select-String -Path (Join-Path $mod "media\lua\shared\SiegeNight_Shared.lua") -Pattern "SN.VERSION" | Select-Object -First 1).Line
$modver = (Select-String -Path (Join-Path $mod "mod.info") -Pattern "modversion" | Select-Object -First 1).Line
Write-Host "OK: $ver | $modver" -ForegroundColor Green
