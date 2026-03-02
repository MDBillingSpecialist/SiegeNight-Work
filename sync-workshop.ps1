param(
  [string]$RepoMod = "C:\Claude Core\openclaw\work\siegenight-stabilization\Contents\mods\SiegeNight",
  [string]$StagingMod = "C:\Users\theth\Zomboid\Workshop\SiegeNight\Contents\mods\SiegeNight",
  [string]$StagingRoot = "C:\Users\theth\Zomboid\Workshop\SiegeNight",
  [string]$RepoRoot = "C:\Claude Core\openclaw\work\siegenight-stabilization"
)

$ErrorActionPreference = 'Stop'

function Get-SNVersion([string]$modRoot){
  $shared = Join-Path $modRoot 'media\lua\shared\SiegeNight_Shared.lua'
  if(!(Test-Path $shared)){ return $null }
  $line = (Select-String -Path $shared -Pattern 'SN\.VERSION' | Select-Object -First 1).Line
  return $line
}

Write-Host "Repo mod:     $RepoMod"
Write-Host "Staging mod:  $StagingMod"

if(!(Test-Path $RepoMod)){
  throw "Repo mod not found: $RepoMod"
}

# Clean staging mod folder and copy in a way that avoids nesting SiegeNight/SiegeNight
if(Test-Path $StagingMod){
  Remove-Item -Recurse -Force $StagingMod
}
New-Item -ItemType Directory -Force -Path $StagingMod | Out-Null
Copy-Item -Recurse -Force (Join-Path $RepoMod '*') $StagingMod

# Copy metadata files used by steamcmd
Copy-Item -Force (Join-Path $RepoRoot 'upload.vdf') (Join-Path $StagingRoot 'upload.vdf')
Copy-Item -Force (Join-Path $RepoRoot 'description.txt') (Join-Path $StagingRoot 'description.txt')
Copy-Item -Force (Join-Path $RepoRoot 'workshop.txt') (Join-Path $StagingRoot 'workshop.txt')

Write-Host "Repo version:    $(Get-SNVersion $RepoMod)"
Write-Host "Staging version: $(Get-SNVersion $StagingMod)"

# Quick structure sanity check
$nested = Join-Path $StagingMod 'SiegeNight'
if(Test-Path $nested){
  throw "BAD STRUCTURE: staging contains nested SiegeNight folder: $nested"
}

Write-Host "OK: staging synced."
