param(
  [string]$RepoRoot = (Split-Path -Parent $MyInvocation.MyCommand.Path),
  [string]$StagingRoot = "C:\Users\theth\Zomboid\Workshop\SiegeNight",
  [switch]$VerifyOnly
)

$ErrorActionPreference = 'Stop'

$srcMod = Join-Path $StagingRoot "Contents\mods\SiegeNight"
$dstMod = Join-Path $RepoRoot "Contents\mods\SiegeNight"

if(!(Test-Path $srcMod)){
  throw "Staging mod folder not found: $srcMod"
}

function Get-SNVersion($sharedPath){
  if(!(Test-Path $sharedPath)){ return $null }
  $m = Select-String -Path $sharedPath -Pattern 'SN\.VERSION\s*=\s*"([0-9\.]+)"' | Select-Object -First 1
  if(!$m){ return $null }
  return $m.Matches[0].Groups[1].Value
}

$srcShared = Join-Path $srcMod "media\lua\shared\SiegeNight_Shared.lua"
$srcVersion = Get-SNVersion $srcShared
if(!$srcVersion){ throw "Could not detect SN.VERSION from: $srcShared" }

Write-Host "Staging source:" -ForegroundColor Cyan
Write-Host "  $srcMod"
Write-Host "  Version: $srcVersion"

if($VerifyOnly){
  Write-Host "VerifyOnly set; not copying." -ForegroundColor Yellow
  exit 0
}

# Replace repo dest fully (avoid stale files)
if(Test-Path $dstMod){
  Remove-Item -Recurse -Force $dstMod
}
New-Item -ItemType Directory -Force -Path $dstMod | Out-Null
Copy-Item -Recurse -Force (Join-Path $srcMod '*') $dstMod

# Also sync upload.vdf + description/workshop files if they exist
foreach($f in @('upload.vdf','description.txt','workshop.txt')){
  $src = Join-Path $StagingRoot $f
  $dst = Join-Path $RepoRoot $f
  if(Test-Path $src){
    Copy-Item -Force $src $dst
  }
}

$dstShared = Join-Path $dstMod "media\lua\shared\SiegeNight_Shared.lua"
$dstVersion = Get-SNVersion $dstShared

Write-Host "Repo destination:" -ForegroundColor Cyan
Write-Host "  $dstMod"
Write-Host "  Version: $dstVersion"

if($dstVersion -ne $srcVersion){
  throw "Version mismatch after copy. staging=$srcVersion repo=$dstVersion"
}

Write-Host "OK: staging -> repo synced" -ForegroundColor Green
