param(
  [string]$RepoRoot = (Resolve-Path ".").Path,
  [string]$StagingRoot = "C:\Users\theth\Zomboid\Workshop\SiegeNight",
  [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'

$srcMod = Join-Path $StagingRoot "Contents\mods\SiegeNight"
$dstMod = Join-Path $RepoRoot "Contents\mods\SiegeNight"

if(!(Test-Path $srcMod)){
  throw "Staging mod folder not found: $srcMod"
}

Write-Host "Staging mod:  $srcMod"
Write-Host "Repo mod:     $dstMod"

if(Test-Path $dstMod){
  if($WhatIf){
    Write-Host "[WhatIf] Would remove $dstMod"
  } else {
    Remove-Item -Recurse -Force $dstMod
  }
}

if(!$WhatIf){
  New-Item -ItemType Directory -Force -Path $dstMod | Out-Null
  Copy-Item -Recurse -Force (Join-Path $srcMod "*") $dstMod
}

# Copy meta files back if present in staging
$meta = @('upload.vdf','workshop.txt','description.txt')
foreach($m in $meta){
  $src = Join-Path $StagingRoot $m
  $dst = Join-Path $RepoRoot $m
  if(Test-Path $src){
    if($WhatIf){
      Write-Host "[WhatIf] Would copy $src -> $dst"
    } else {
      Copy-Item -Force $src $dst
    }
  }
}

# Verify version in repo
$shared = Join-Path $dstMod "media\lua\shared\SiegeNight_Shared.lua"
if(Test-Path $shared){
  $verLine = Select-String -Path $shared -Pattern 'SN\.VERSION\s*=\s*"' | Select-Object -First 1
  Write-Host "Repo version: $($verLine.Line)"
} else {
  Write-Warning "Could not find $shared to verify version"
}

Write-Host "OK"