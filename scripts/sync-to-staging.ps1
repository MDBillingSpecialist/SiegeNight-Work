param(
  [string]$RepoMod = "C:\Claude Core\openclaw\work\siegenight-stabilization\Contents\mods\SiegeNight",
  [string]$StagingMod = "C:\Users\theth\Zomboid\Workshop\SiegeNight\Contents\mods\SiegeNight"
)

$ErrorActionPreference = 'Stop'

if(!(Test-Path $RepoMod)){
  throw "Repo mod folder not found: $RepoMod"
}

# Remove staging mod completely to avoid accidental nesting / stale files
if(Test-Path $StagingMod){
  Remove-Item -Recurse -Force $StagingMod
}
New-Item -ItemType Directory -Force -Path $StagingMod | Out-Null
Copy-Item -Recurse -Force (Join-Path $RepoMod '*') $StagingMod

# Validate
& "$PSScriptRoot\validate-workshop-content.ps1" -ContentFolder "C:\Users\theth\Zomboid\Workshop\SiegeNight\Contents"
