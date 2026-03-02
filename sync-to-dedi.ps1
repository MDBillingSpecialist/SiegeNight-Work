param(
  [string]$RepoRoot = "C:\Claude Core\openclaw\work\siegenight-stabilization",
  [string]$DediWorkshopMod = "C:\SteamCMD\steamapps\common\Project Zomboid Dedicated Server\steamapps\workshop\content\108600\3669589584\mods\SiegeNight"
)

$ErrorActionPreference = 'Stop'

$srcMod = Join-Path $RepoRoot "Contents\mods\SiegeNight"
if(!(Test-Path $srcMod)) { throw "Source mod folder not found: $srcMod" }

if(Test-Path $DediWorkshopMod) {
  Remove-Item -Recurse -Force $DediWorkshopMod
}
New-Item -ItemType Directory -Force -Path $DediWorkshopMod | Out-Null
Copy-Item -Recurse -Force (Join-Path $srcMod '*') $DediWorkshopMod

$shared = Join-Path $DediWorkshopMod 'media\lua\shared\SiegeNight_Shared.lua'
$verLine = (Select-String -Path $shared -Pattern 'SN\.VERSION' | Select-Object -First 1).Line
Write-Host "Dedi workshop mod sync complete: $verLine"
