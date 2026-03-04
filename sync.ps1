# SiegeNight sync.ps1 — Syncs B42 source to Workshop B41 fallback + local test mod
# Source of truth: Workshop\...\42\media\

$src     = 'C:\Users\theth\Zomboid\Workshop\SiegeNight\Contents\mods\SiegeNight\42\media'
$srcRoot = 'C:\Users\theth\Zomboid\Workshop\SiegeNight\Contents\mods\SiegeNight'
$b41     = 'C:\Users\theth\Zomboid\Workshop\SiegeNight\Contents\mods\SiegeNight\media'
$locRoot = 'C:\Users\theth\Zomboid\mods\SiegeNight'
$loc42   = 'C:\Users\theth\Zomboid\mods\SiegeNight\42\media'
$locB41  = 'C:\Users\theth\Zomboid\mods\SiegeNight\media'

# --- Media files to sync (relative to media\ dirs) ---
$files = @(
    'lua\server\SiegeNight_Server.lua',
    'lua\server\SiegeNight_MiniHorde.lua',
    'lua\client\SiegeNight_Client.lua',
    'lua\client\SiegeNight_Commands.lua',
    'lua\client\SiegeNight_Debug.lua',
    'lua\client\SiegeNight_Panel.lua',
    'lua\shared\SiegeNight_Shared.lua',
    'lua\shared\Translate\EN\Sandbox_EN.txt',
    'sandbox-options.txt'
)

# --- Check for optional UI_EN.txt ---
$uiEN = Join-Path $src 'lua\shared\Translate\EN\UI_EN.txt'
if (Test-Path $uiEN) {
    $files += 'lua\shared\Translate\EN\UI_EN.txt'
}

# --- Root files to sync (mod.info, poster) ---
$rootFiles = @(
    'mod.info',
    'poster.png'
)
$rootSubdirs = @(
    '',    # root level
    '42'   # 42\ subdirectory
)

# --- Stale files to remove from all targets ---
$staleFiles = @(
    'lua\server\SiegeNight_Clothing.lua',
    'lua\server\SiegeNight_Loot.lua',
    'lua\client\SiegeNight_Panel_v2512.lua.bak'
)

# ============================================================
Write-Host '=== SOURCE FILES ===' -ForegroundColor Cyan
foreach ($file in $files) {
    $p = Join-Path $src $file
    if (Test-Path $p) {
        $sz = (Get-Item $p).Length
        Write-Host "  OK: $file ($sz bytes)"
    } else {
        Write-Host "  MISSING: $file" -ForegroundColor Red
    }
}

# ============================================================
# Copy media files to all 3 targets
$targets = @(
    @{ Name = 'Workshop B41'; Path = $b41 },
    @{ Name = 'Local B42';    Path = $loc42 },
    @{ Name = 'Local B41';    Path = $locB41 }
)

foreach ($target in $targets) {
    Write-Host ''
    Write-Host "=== COPYING TO $($target.Name) ===" -ForegroundColor Cyan
    foreach ($file in $files) {
        $srcPath = Join-Path $src $file
        $dstPath = Join-Path $target.Path $file
        $dstDir = Split-Path $dstPath -Parent
        if (-not (Test-Path $dstDir)) { New-Item -ItemType Directory -Path $dstDir -Force | Out-Null }
        Copy-Item -Path $srcPath -Destination $dstPath -Force
        $sz = (Get-Item $dstPath).Length
        Write-Host "  Copied: $file ($sz bytes)"
    }
}

# ============================================================
# Copy mod.info + poster.png to local (root and 42\)
Write-Host ''
Write-Host '=== COPYING ROOT FILES TO LOCAL ===' -ForegroundColor Cyan
foreach ($subdir in $rootSubdirs) {
    foreach ($rootFile in $rootFiles) {
        if ($subdir -eq '') {
            $srcFile = Join-Path $srcRoot $rootFile
            $dstFile = Join-Path $locRoot $rootFile
        } else {
            $srcFile = Join-Path $srcRoot (Join-Path $subdir $rootFile)
            $dstFile = Join-Path $locRoot (Join-Path $subdir $rootFile)
        }
        if (Test-Path $srcFile) {
            $dstDir = Split-Path $dstFile -Parent
            if (-not (Test-Path $dstDir)) { New-Item -ItemType Directory -Path $dstDir -Force | Out-Null }
            Copy-Item -Path $srcFile -Destination $dstFile -Force
            $label = if ($subdir -eq '') { $rootFile } else { "$subdir\$rootFile" }
            Write-Host "  Copied: $label"
        }
    }
}

# ============================================================
# Clean stale files from ALL media targets (B41, local B42, local B41)
$cleanTargets = @(
    @{ Name = 'Workshop B41'; Path = $b41 },
    @{ Name = 'Local B42';    Path = $loc42 },
    @{ Name = 'Local B41';    Path = $locB41 }
)

Write-Host ''
Write-Host '=== CLEANING STALE FILES ===' -ForegroundColor Cyan
foreach ($ct in $cleanTargets) {
    foreach ($stale in $staleFiles) {
        $stalePath = Join-Path $ct.Path $stale
        if (Test-Path $stalePath) {
            Remove-Item $stalePath -Force
            Write-Host "  REMOVED ($($ct.Name)): $stale" -ForegroundColor Yellow
        }
    }
}

# ============================================================
# Verification: compare all targets against source
Write-Host ''
Write-Host '=== VERIFICATION ===' -ForegroundColor Cyan
$allMatch = $true
foreach ($file in $files) {
    $srcSz  = (Get-Item (Join-Path $src $file)).Length
    $b41Sz  = (Get-Item (Join-Path $b41 $file)).Length
    $l42Sz  = (Get-Item (Join-Path $loc42 $file)).Length
    $lB41Sz = (Get-Item (Join-Path $locB41 $file)).Length
    $match = ($srcSz -eq $b41Sz) -and ($srcSz -eq $l42Sz) -and ($srcSz -eq $lB41Sz)
    $status = if ($match) { 'MATCH' } else { 'MISMATCH' }
    if (-not $match) { $allMatch = $false }
    Write-Host "  $status : $file  src=$srcSz  wB41=$b41Sz  l42=$l42Sz  lB41=$lB41Sz"
}

# Verify mod.info versions
Write-Host ''
Write-Host '=== MOD.INFO VERSIONS ===' -ForegroundColor Cyan
$infoFiles = @(
    (Join-Path $srcRoot 'mod.info'),
    (Join-Path $srcRoot '42\mod.info'),
    (Join-Path $locRoot 'mod.info'),
    (Join-Path $locRoot '42\mod.info')
)
foreach ($info in $infoFiles) {
    if (Test-Path $info) {
        $ver = (Get-Content $info | Where-Object { $_ -match '^modversion=' }) -replace 'modversion=',''
        Write-Host "  $info => $ver"
    }
}

Write-Host ''
if ($allMatch) {
    Write-Host '=== ALL FILES MATCH ===' -ForegroundColor Green
} else {
    Write-Host '=== MISMATCH DETECTED ===' -ForegroundColor Red
}
