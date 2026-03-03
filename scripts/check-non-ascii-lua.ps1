param(
  [string]$Root = (Resolve-Path "..").Path
)

$ErrorActionPreference = 'Stop'

$luaFiles = Get-ChildItem -Path $Root -Recurse -File -Include *.lua

$bad = @()
foreach($f in $luaFiles){
  $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
  $count = 0
  foreach($b in $bytes){ if($b -gt 127){ $count++ } }
  if($count -gt 0){
    $bad += [pscustomobject]@{ File = $f.FullName; NonAsciiBytes = $count }
  }
}

if($bad.Count -gt 0){
  Write-Host "FOUND non-ASCII bytes in Lua files:" -ForegroundColor Red
  $bad | Sort-Object NonAsciiBytes -Descending | Format-Table -AutoSize
  exit 1
}

Write-Host "OK: no non-ASCII bytes in .lua under $Root" -ForegroundColor Green
