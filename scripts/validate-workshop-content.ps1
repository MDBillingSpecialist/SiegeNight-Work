param(
  [string]$ContentFolder = "C:\Users\theth\Zomboid\Workshop\SiegeNight\Contents"
)

$ErrorActionPreference = 'Stop'

function Fail($msg){
  Write-Error $msg
  exit 1
}

if(!(Test-Path $ContentFolder)){
  Fail "ContentFolder does not exist: $ContentFolder"
}

$modsDir = Join-Path $ContentFolder 'mods'
if(!(Test-Path $modsDir)){
  Fail "Missing mods/ folder under contentfolder: $modsDir"
}

$modDir = Join-Path $modsDir 'SiegeNight'
if(!(Test-Path $modDir)){
  Fail "Missing mods/SiegeNight folder: $modDir"
}

$nested = Get-ChildItem -Recurse -Directory $modDir | Where-Object { $_.FullName -match 'SiegeNight\\SiegeNight' } | Select-Object -First 1
if($nested){
  Fail "Detected nested SiegeNight folder (packaging bug): $($nested.FullName)"
}

$shared = Join-Path $modDir 'media\lua\shared\SiegeNight_Shared.lua'
if(!(Test-Path $shared)){
  Fail "Missing shared file: $shared"
}

$versionLine = (Select-String -Path $shared -Pattern 'SN\.VERSION' | Select-Object -First 1).Line
if(!$versionLine){
  Fail "Could not find SN.VERSION in $shared"
}

$modInfo = Join-Path $modDir 'mod.info'
if(!(Test-Path $modInfo)){
  Fail "Missing mod.info: $modInfo"
}

$modVersionLine = (Select-String -Path $modInfo -Pattern '^modversion=' | Select-Object -First 1).Line

Write-Host "OK: $modDir"
Write-Host "  $versionLine"
Write-Host "  $modVersionLine"
