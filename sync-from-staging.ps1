param(
  [string]$RepoRoot = "$(Split-Path -Parent $MyInvocation.MyCommand.Path)",
  [string]$StagingRoot = "C:\Users\theth\Zomboid\Workshop\SiegeNight",
  [switch]$NoClean
)

$ErrorActionPreference = "Stop"

$srcMod = Join-Path $StagingRoot "Contents\mods\SiegeNight"
$dstMod = Join-Path $RepoRoot "Contents\mods\SiegeNight"

if(!(Test-Path $srcMod)){
  throw "Staging mod folder not found: $srcMod"
}

if((Test-Path $dstMod) -and (-not $NoClean)){
  Remove-Item -Recurse -Force $dstMod
}

New-Item -ItemType Directory -Force -Path $dstMod | Out-Null
Copy-Item -Recurse -Force (Join-Path $srcMod "*") $dstMod

# Pull workshop upload metadata back too (if present)
foreach($f in @("upload.vdf","workshop.txt","description.txt")){
  $src = Join-Path $StagingRoot $f
  if(Test-Path $src){
    Copy-Item -Force $src (Join-Path $RepoRoot $f)
  }
}

Write-Host "Synced SiegeNight staging -> repo" -ForegroundColor Green
Write-Host "  Staging: $srcMod"
Write-Host "  Repo:    $dstMod"
