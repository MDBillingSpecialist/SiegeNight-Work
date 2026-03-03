param(
  [string]$LogRoot = "C:\Users\theth\Zomboid\Logs",
  [string]$DediRoot = "C:\SteamCMD\steamapps\common\Project Zomboid Dedicated Server"
)

$ErrorActionPreference = 'Stop'

function Fail($msg){
  Write-Host "FAIL: $msg" -ForegroundColor Red
  exit 1
}

# Find newest debug server log
$log = Get-ChildItem $LogRoot -Filter "*DebugLog-server*" -ErrorAction SilentlyContinue |
  Sort-Object LastWriteTime -Descending |
  Select-Object -First 1

if(!$log){
  Fail "No *DebugLog-server* files found in $LogRoot"
}

$txt = Get-Content $log.FullName -Raw

if($txt -notmatch "loading \\SiegeNight"){
  Fail "Latest server log does not show 'loading \\SiegeNight' ($($log.Name))"
}

# Parse errors that prevent module load
$parseErr = Select-String -Path $log.FullName -Pattern "KahluaException:.*SiegeNight_Server.lua|LexState\.lexerror" -SimpleMatch -ErrorAction SilentlyContinue | Select-Object -First 1
if($parseErr){
  Fail "SiegeNight parse/exception detected in $($log.Name): $($parseErr.Line.Trim())"
}

# If mod prints a version marker, show it
$verLine = Select-String -Path $log.FullName -Pattern "\[SiegeNight\].*\(v" -ErrorAction SilentlyContinue | Select-Object -First 1
if($verLine){
  Write-Host "OK: $($log.Name)" -ForegroundColor Green
  Write-Host "  $($verLine.Line.Trim())" -ForegroundColor Green
} else {
  Write-Host "OK: $($log.Name) (no version marker found, but no SiegeNight parse errors)" -ForegroundColor Green
}

Write-Host "Dedicated load validation: OK" -ForegroundColor Green
