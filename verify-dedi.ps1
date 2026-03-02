param(
  [string]$LogDir = "C:\Users\theth\Zomboid\Logs"
)

$ErrorActionPreference = 'Stop'

$log = Get-ChildItem $LogDir -Filter "*DebugLog-server*" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if(!$log){
  throw "No DebugLog-server logs found in $LogDir"
}

Write-Host "Latest server log: $($log.FullName)"

$patterns = @(
  'loading \\SiegeNight',
  '\\[SiegeNight\\]',
  'KahluaException: SiegeNight_Server.lua',
  'LexState\.lexerror'
)

Select-String -Path $log.FullName -Pattern $patterns | Select-Object -First 200
