param(
  [string]$ZomboidCacheDir = "C:\Users\theth\Zomboid",
  [string]$ServerRoot = "C:\SteamCMD\steamapps\common\Project Zomboid Dedicated Server",
  [int]$WaitSeconds = 20
)

$ErrorActionPreference = "Stop"

Write-Host "Validating dedicated server load (SiegeNight)..." -ForegroundColor Cyan

# Find running dedi java
$proc = Get-CimInstance Win32_Process -Filter "Name='java.exe'" |
  Where-Object { $_.CommandLine -match 'zombie\.network\.GameServer' } |
  Select-Object -First 1

if($proc){
  Write-Host "Stopping dedi java pid=$($proc.ProcessId)..." -ForegroundColor Yellow
  try {
    Stop-Process -Id $proc.ProcessId -Force
    Start-Sleep -Seconds 2
  } catch {
    Write-Host "WARN: failed to stop java (need admin?): $($_.Exception.Message)" -ForegroundColor Yellow
    Write-Host "Continue anyway (may produce mixed logs)." -ForegroundColor Yellow
  }
}

Write-Host "Starting dedicated server..." -ForegroundColor Cyan
Start-Process cmd.exe -ArgumentList "/c cd /d `"$ServerRoot`" && StartServer64.bat" -WorkingDirectory $ServerRoot

Write-Host "Waiting $WaitSeconds seconds for boot..." -ForegroundColor Cyan
Start-Sleep -Seconds $WaitSeconds

$logDir = Join-Path $ZomboidCacheDir "Logs"
$log = Get-ChildItem $logDir -Filter "*DebugLog-server*" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if(-not $log){ throw "No DebugLog-server found in $logDir" }

Write-Host "Latest log: $($log.FullName)" -ForegroundColor Gray

$lines = Get-Content $log.FullName -Tail 400

$loadLine = $lines | Select-String -Pattern "loading \\SiegeNight" | Select-Object -Last 1
$kahlua = $lines | Select-String -Pattern "KahluaException: SiegeNight_Server\.lua|LexState\.lexerror" | Select-Object -First 20
$snLine = $lines | Select-String -Pattern "\[SiegeNight\].*\(v" | Select-Object -First 5

if($loadLine){ Write-Host $loadLine.Line -ForegroundColor Green }
if($snLine){ $snLine | ForEach-Object { Write-Host $_.Line -ForegroundColor Green } }

if($kahlua){
  Write-Host "FAIL: SiegeNight parse/runtime errors detected:" -ForegroundColor Red
  $kahlua | ForEach-Object { Write-Host $_.Line -ForegroundColor Red }
  exit 1
}

Write-Host "OK: no SiegeNight_Server.lua exceptions detected in tail." -ForegroundColor Green
