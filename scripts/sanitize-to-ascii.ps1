param(
  [Parameter(Mandatory=$true)][string]$InPath,
  [Parameter(Mandatory=$true)][string]$OutPath
)

# Replaces a few common Unicode punctuation chars with ASCII equivalents.
# Intended for PZ Lua / config files where non-ASCII can break parsing.
# NOTE: Avoid using this on SteamCMD Workshop KeyValues .vdf files; if a tool has previously serialized newlines/escapes, rewriting may break KeyValues parsing.

if (-not (Test-Path -LiteralPath $InPath)) {
  throw "Input file not found: $InPath"
}

$bytes = [System.IO.File]::ReadAllBytes($InPath)
$text  = [System.Text.Encoding]::UTF8.GetString($bytes)

# Normalize line endings and strip BOM-ish weirdness if any.
$text = $text -replace "\r\n", "\n"

# Replace common offenders
$text = $text.Replace([char]0x2014, "-")   # em dash —
$text = $text.Replace([char]0x2013, "-")   # en dash –
$text = $text.Replace([char]0x00D7, "x")   # multiplication sign ×
$text = $text.Replace([char]0x2018, "'")   # ‘
$text = $text.Replace([char]0x2019, "'")   # ’
$text = $text.Replace([char]0x201C, '"')    # “
$text = $text.Replace([char]0x201D, '"')    # ”
# Use string replace for ellipsis (…)
$text = $text.Replace("…", "...")

# Final guard: drop any remaining non-ASCII characters by replacing with '?'
# (We prefer explicit replacements above; this is last-resort.)
$sb = New-Object System.Text.StringBuilder
foreach ($ch in $text.ToCharArray()) {
  if ([int][char]$ch -le 127) {
    [void]$sb.Append($ch)
  } else {
    [void]$sb.Append('?')
  }
}

$out = $sb.ToString() -replace "\n", "`r`n"

$dir = Split-Path -Parent $OutPath
if ($dir -and -not (Test-Path -LiteralPath $dir)) {
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
}

[System.IO.File]::WriteAllText($OutPath, $out, [System.Text.Encoding]::ASCII)

Write-Host "Wrote ASCII-sanitized file:" $OutPath
