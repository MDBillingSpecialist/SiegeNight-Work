$src   = 'C:\Users\theth\Zomboid\Workshop\SiegeNight\Contents\mods\SiegeNight\42\media'
$dest1 = 'C:\Users\theth\Zomboid\Workshop\SiegeNight\Contents\mods\SiegeNight\media'
$dest2 = 'C:\Users\theth\Zomboid\mods\SiegeNight\media'

# Ensure all target directories exist
$targetDirs = @(
    "$dest1",
    "$dest1\lua\shared\Translate\EN",
    "$dest1\lua\server",
    "$dest1\lua\client",
    "$dest2",
    "$dest2\lua\shared\Translate\EN",
    "$dest2\lua\server",
    "$dest2\lua\client"
)
foreach ($d in $targetDirs) {
    New-Item -ItemType Directory -Force -Path $d | Out-Null
}

# Files to sync (relative paths)
$files = @(
    'sandbox-options.txt',
    'lua\shared\SiegeNight_Shared.lua',
    'lua\shared\Translate\EN\Sandbox_EN.txt',
    'lua\server\SiegeNight_Server.lua',
    'lua\client\SiegeNight_Client.lua',
    'lua\client\SiegeNight_Debug.lua'
)

# Copy each file to both destinations
foreach ($f in $files) {
    Copy-Item -Path "$src\$f" -Destination "$dest1\$f" -Force
    Copy-Item -Path "$src\$f" -Destination "$dest2\$f" -Force
    Write-Host "Copied: $f"
}

Write-Host ''
Write-Host '=== Verification: File sizes across all 3 locations ==='
Write-Host ''

# Build a table of file sizes for verification
$results = @()
foreach ($f in $files) {
    $srcFile = Get-Item "$src\$f"
    $d1File  = Get-Item "$dest1\$f"
    $d2File  = Get-Item "$dest2\$f"
    $results += [PSCustomObject]@{
        File        = $f
        Source_B42  = $srcFile.Length
        Dest1_B41   = $d1File.Length
        Dest2_Local = $d2File.Length
        Match       = if ($srcFile.Length -eq $d1File.Length -and $srcFile.Length -eq $d2File.Length) { 'OK' } else { 'MISMATCH' }
    }
}
$results | Format-Table -AutoSize
