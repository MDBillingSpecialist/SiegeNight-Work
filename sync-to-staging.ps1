param(
  [string]$RepoRoot = (Resolve-Path ".").Path,
  [string]$StagingRoot = "C:\Users\theth\Zomboid\Workshop\SiegeNight",
  [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'

$srcMod = Join-Path $RepoRoot "Contents\mods\SiegeNight"
$dstMod = Join-Path $StagingRoot "Contents\mods\SiegeNight"

if(!(Test-Path $srcMod)){
  throw "Source mod folder not found: $srcMod"
}

Write-Host "Repo mod:     $srcMod"
Write-Host "Staging mod:  $dstMod"

# Copy mod folder (clean)
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

# Copy workshop meta files from repo root if present
$meta = @('upload.vdf','workshop.txt','description.txt','preview.png')
foreach($m in $meta){
  $src = Join-Path $RepoRoot $m
  $dst = Join-Path $StagingRoot $m
  if(Test-Path $src){
    if($WhatIf){
      Write-Host "[WhatIf] Would copy $src -> $dst"
    } else {
      Copy-Item -Force $src $dst
    }
  }
}

# Verify version in staging
$shared = Join-Path $dstMod "media\lua\shared\SiegeNight_Shared.lua"
if(Test-Path $shared){
  $verLine = Select-String -Path $shared -Pattern 'SN\.VERSION\s*=\s*"' | Select-Object -First 1
  Write-Host "Staging version: $($verLine.Line)"
} else {
  Write-Warning "Could not find $shared to verify version"
}

Write-Host "OK"