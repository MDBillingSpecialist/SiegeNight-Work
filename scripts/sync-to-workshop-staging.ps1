param(
  [string]$RepoRoot = "C:\Claude Core\openclaw\work\siegenight-stabilization",
  [string]$StagingRoot = "C:\Users\theth\Zomboid\Workshop\SiegeNight"
)

$ErrorActionPreference = "Stop"

$srcMod = Join-Path $RepoRoot "Contents\mods\SiegeNight"
$dstMod = Join-Path $StagingRoot "Contents\mods\SiegeNight"

if(!(Test-Path $srcMod)){
  throw "Source mod folder not found: $srcMod"
}

# Ensure staging skeleton exists
New-Item -ItemType Directory -Force -Path (Join-Path $StagingRoot "Contents\mods") | Out-Null

# Hard-remove destination to avoid nested mod-in-mod packaging
if(Test-Path $dstMod){
  Remove-Item -Recurse -Force $dstMod
}
New-Item -ItemType Directory -Force -Path $dstMod | Out-Null

Copy-Item -Recurse -Force (Join-Path $srcMod "*") $dstMod

# Copy upload metadata files
foreach($f in @("upload.vdf","description.txt","workshop.txt","preview.png")){
  $src = Join-Path $RepoRoot $f
  $dst = Join-Path $StagingRoot $f
  if(Test-Path $src){
    Copy-Item -Force $src $dst
  }
}

# Basic sanity checks
$nested = Get-ChildItem $dstMod -Directory -Recurse | Where-Object { $_.Name -eq "SiegeNight" }
if($nested){
  Write-Host "ERROR: Found nested SiegeNight folder(s) inside staging mod:" -ForegroundColor Red
  $nested | Select-Object -ExpandProperty FullName | ForEach-Object { Write-Host "  $_" }
  throw "Nested mod folder detected"
}

$verLine = Select-String -Path (Join-Path $dstMod "media\lua\shared\SiegeNight_Shared.lua") -Pattern "SN.VERSION" | Select-Object -First 1
Write-Host "Staging sync complete. $($verLine.Line)" -ForegroundColor Green
