param(
  [string]$RepoRoot = "$(Split-Path -Parent $MyInvocation.MyCommand.Path)",
  [string]$StagingRoot = "C:\Users\theth\Zomboid\Workshop\SiegeNight",
  [switch]$NoClean
)

$ErrorActionPreference = "Stop"

$srcMod = Join-Path $RepoRoot "Contents\mods\SiegeNight"
$dstMod = Join-Path $StagingRoot "Contents\mods\SiegeNight"

if(!(Test-Path $srcMod)){
  throw "Source mod folder not found: $srcMod"
}

# Ensure staging folders exist
New-Item -ItemType Directory -Force -Path (Join-Path $StagingRoot "Contents\mods") | Out-Null

if((Test-Path $dstMod) -and (-not $NoClean)){
  Remove-Item -Recurse -Force $dstMod
}

New-Item -ItemType Directory -Force -Path $dstMod | Out-Null
Copy-Item -Recurse -Force (Join-Path $srcMod "*") $dstMod

# Copy workshop upload metadata files (if present in repo root)
foreach($f in @("upload.vdf","workshop.txt","description.txt","preview.png")){
  $src = Join-Path $RepoRoot $f
  if(Test-Path $src){
    Copy-Item -Force $src (Join-Path $StagingRoot $f)
  }
}

# Validate version + hashes
$srcShared = Join-Path $srcMod "media\lua\shared\SiegeNight_Shared.lua"
$dstShared = Join-Path $dstMod "media\lua\shared\SiegeNight_Shared.lua"
$srcVer = (Select-String -Path $srcShared -Pattern 'SN\.VERSION\s*=\s*"([0-9\.]+)"' | Select-Object -First 1).Matches.Groups[1].Value
$dstVer = (Select-String -Path $dstShared -Pattern 'SN\.VERSION\s*=\s*"([0-9\.]+)"' | Select-Object -First 1).Matches.Groups[1].Value

$srcHash = (Get-FileHash (Join-Path $srcMod "media\lua\server\SiegeNight_Server.lua") -Algorithm SHA256).Hash
$dstHash = (Get-FileHash (Join-Path $dstMod "media\lua\server\SiegeNight_Server.lua") -Algorithm SHA256).Hash

Write-Host "Synced SiegeNight repo -> staging" -ForegroundColor Green
Write-Host "  Repo:    $srcMod"
Write-Host "  Staging: $dstMod"
Write-Host "  Version: $srcVer (repo) -> $dstVer (staging)"
Write-Host "  Server.lua SHA256: $srcHash (repo) -> $dstHash (staging)"

if($srcVer -ne $dstVer){ throw "Version mismatch after copy: repo=$srcVer staging=$dstVer" }
if($srcHash -ne $dstHash){ throw "Hash mismatch after copy (SiegeNight_Server.lua)" }
