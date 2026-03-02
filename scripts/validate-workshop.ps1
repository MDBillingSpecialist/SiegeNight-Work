param(
  [string]$ContentFolder = "C:\Users\theth\Zomboid\Workshop\SiegeNight\Contents"
)

$ErrorActionPreference = 'Stop'

function Fail($msg){
  Write-Error $msg
  exit 1
}

if(!(Test-Path $ContentFolder)){
  Fail "ContentFolder not found: $ContentFolder"
}

$modsDir = Join-Path $ContentFolder 'mods'
$modDir  = Join-Path $modsDir 'SiegeNight'

if(!(Test-Path $modsDir)) { Fail "Missing mods/ folder under content folder: $modsDir" }
if(!(Test-Path $modDir))  { Fail "Missing mods/SiegeNight folder under content folder: $modDir" }

$modInfo = Join-Path $modDir 'mod.info'
if(!(Test-Path $modInfo)) { Fail "Missing mod.info at: $modInfo" }

# Detect nested SiegeNight/SiegeNight issue
$nested = Get-ChildItem $modDir -Recurse -Directory -ErrorAction SilentlyContinue | Where-Object { $_.FullName -match "\\SiegeNight\\SiegeNight(\\|$)" }
if($nested){
  Write-Host "Found nested SiegeNight/SiegeNight directories:" -ForegroundColor Red
  $nested | Select-Object -ExpandProperty FullName
  Fail "Invalid packaging: nested SiegeNight folder detected"
}

# Basic version sanity
$shared = Join-Path $modDir 'media\lua\shared\SiegeNight_Shared.lua'
if(Test-Path $shared){
  $verLine = Select-String -Path $shared -Pattern 'SN\.VERSION\s*=\s*"([0-9\.]+)"' | Select-Object -First 1
  if($verLine){
    Write-Host ("Version: " + $verLine.Line.Trim())
  }
}

Write-Host "Workshop content validation: OK" -ForegroundColor Green
