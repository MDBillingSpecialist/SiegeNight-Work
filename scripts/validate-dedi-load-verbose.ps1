param(
  [string]$LogRoot = "C:\Users\theth\Zomboid\Logs",
  [int]$MaxLogsToScan = 40
)

$ErrorActionPreference = 'Stop'

function Fail($msg){
  Write-Host "FAIL: $msg" -ForegroundColor Red
  exit 1
}

$logs = Get-ChildItem $LogRoot -Filter "*DebugLog-server*" -ErrorAction SilentlyContinue |
  Sort-Object LastWriteTime -Descending |
  Select-Object -First $MaxLogsToScan

if(!$logs -or $logs.Count -eq 0){
  Fail "No *DebugLog-server* files found in $LogRoot"
}

Write-Host "Scanning $($logs.Count) logs..." -ForegroundColor Cyan

foreach($log in $logs){
  $verLine = Select-String -Path $log.FullName -Pattern "\[SiegeNight\].*\(v" -ErrorAction SilentlyContinue | Select-Object -First 1
  if($verLine){
    Write-Host "FOUND: $($log.Name)" -ForegroundColor Green
    Write-Host "  $($verLine.Line.Trim())" -ForegroundColor Green
  }
}

Write-Host "Done." -ForegroundColor Cyan
