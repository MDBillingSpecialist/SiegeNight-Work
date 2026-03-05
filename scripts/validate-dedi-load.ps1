param(
  [string]$LogRoot = "C:\Users\theth\Zomboid\Logs",
  [string]$DediRoot = "C:\SteamCMD\steamapps\common\Project Zomboid Dedicated Server"
)

$ErrorActionPreference = 'Stop'

function Fail($msg){
  Write-Host "FAIL: $msg" -ForegroundColor Red
  exit 1
}

# Find newest debug server log that actually includes SiegeNight load lines.
# (Sometimes a new server log exists for a different run/world without this mod.)
$logs = Get-ChildItem $LogRoot -Filter "*DebugLog-server*" -ErrorAction SilentlyContinue |
  Sort-Object LastWriteTime -Descending

if(!$logs -or $logs.Count -eq 0){
  Fail "No *DebugLog-server* files found in $LogRoot"
}

$log = $null
foreach($candidate in $logs){
  $txt = Get-Content $candidate.FullName -Raw
  if($txt -match "loading \\SiegeNight"){
    $log = $candidate
    break
  }
}

if(!$log){
  Write-Host "WARN: No recent server logs show 'loading \\SiegeNight' (checked $($logs.Count) logs in $LogRoot)." -ForegroundColor Yellow
  Write-Host "      Will still scan the newest log for SiegeNight parse errors." -ForegroundColor Yellow
  $log = $logs | Select-Object -First 1
}

# Parse errors that prevent module load
$parseErr = Select-String -Path $log.FullName -Pattern "KahluaException:.*SiegeNight_Server.lua|LexState\.lexerror" -SimpleMatch -ErrorAction SilentlyContinue | Select-Object -First 1
if($parseErr){
  Fail "SiegeNight parse/exception detected in $($log.Name): $($parseErr.Line.Trim())"
}

# If mod prints a version marker, show it.
# Prefer the newest version marker if multiple are present in the log.
$verLines = Select-String -Path $log.FullName -Pattern "\[SiegeNight\].*\(v" -ErrorAction SilentlyContinue
$verLine = $null
if($verLines){ $verLine = $verLines | Select-Object -Last 1 }

if($verLine){
  Write-Host "OK: $($log.Name)" -ForegroundColor Green
  Write-Host "  $($verLine.Line.Trim())" -ForegroundColor Green
} else {
  Write-Host "OK: $($log.Name) (no version marker found, but no SiegeNight parse errors)" -ForegroundColor Green
}

Write-Host "Dedicated load validation: OK" -ForegroundColor Green
