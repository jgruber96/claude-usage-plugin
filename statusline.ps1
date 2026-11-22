# Claude Code status line: model, folder, and plan usage (5-hour session and
# 7-day week) with a pace indicator for each.
#
# Reads the JSON Claude Code passes on stdin and uses only its rate_limits
# data. No network, no credentials, no token counting.
#
# Works on Windows PowerShell 5.1. This file is plain ASCII on purpose: 5.1
# reads a script without a byte-order mark as ANSI, so the bar and separator
# characters are built from code points instead of typed in.

$ErrorActionPreference = 'Stop'

$Esc       = [string][char]27
$BarFull   = [string][char]0x2588   # full block
$BarEmpty  = [string][char]0x2591   # light shade
$Sep       = [string][char]0x2502   # thin vertical line
$Dot       = [string][char]0x00B7   # middle dot
$BarCells  = 8
$PaceSlack = 3                      # points either side that count as "on pace"

$Grey   = '90'
$Green  = '32'
$Orange = '38;5;208'

function Paint([string]$Code, [string]$Text) {
    return "${Esc}[${Code}m${Text}${Esc}[0m"
}

function Read-Number($Value) {
    # Returns a double, or $null when the value is missing or not a number.
    if ($null -eq $Value) { return $null }
    $n = 0.0
    $ok = [double]::TryParse(
        [string]$Value,
        [Globalization.NumberStyles]::Float,
        [Globalization.CultureInfo]::InvariantCulture,
        [ref]$n)
    if ($ok) { return $n }
    return $null
}

function Round-Int([double]$Value) {
    return [int][math]::Round($Value, [MidpointRounding]::AwayFromZero)
}

function Format-Left([double]$Seconds) {
    $m = [math]::Floor($Seconds / 60)
    if ($m -lt 1) { return '<1m' }
    $d  = [math]::Floor($m / 1440)
    $h  = [math]::Floor(($m % 1440) / 60)
    $mm = $m % 60
    if ($d -ge 1) { return "${d}d ${h}h" }
    if ($h -ge 1) { return "${h}h ${mm}m" }
    return "${mm}m"
}

function Format-Window([string]$Label, $Window, [double]$WindowSeconds, [double]$Now) {
    $missing = (Paint $Grey "$Label -")
    if ($null -eq $Window) { return $missing }

    $used = Read-Number $Window.used_percentage
    if ($null -eq $used) { return $missing }

    $reset = Read-Number $Window.resets_at
    # A window whose reset time has passed holds last window's numbers.
    if ($null -ne $reset -and $reset -le $Now) { return $missing }

    $shown  = [math]::Max(0, [math]::Min(100, $used))
    $filled = Round-Int ($shown / 100 * $BarCells)
    $bar    = ($BarFull * $filled) + (Paint $Grey ($BarEmpty * ($BarCells - $filled)))
    $text   = "$Label $(Round-Int $used)% $bar"

    if ($null -eq $reset) { return $text }

    $remaining = [math]::Min($reset - $Now, $WindowSeconds)
    $elapsed   = ($WindowSeconds - $remaining) / $WindowSeconds * 100
    $diff      = $used - $elapsed
    $points    = Round-Int $diff

    if ([math]::Abs($diff) -le $PaceSlack) { $colour = $Grey }
    elseif ($diff -lt 0)                   { $colour = $Green }
    else                                   { $colour = $Orange }

    if ($points -gt 0) { $pace = "+$points%" } else { $pace = "$points%" }

    return "$text $(Paint $colour $pace) $(Paint $Grey "$Dot $(Format-Left $remaining) left")"
}

$line = 'Claude'
try {
    # Read and write UTF-8 bytes directly so the result does not depend on the
    # console code page.
    $reader = New-Object System.IO.StreamReader([Console]::OpenStandardInput(), [Text.Encoding]::UTF8)
    $raw = $reader.ReadToEnd()

    $data = $null
    if ($raw -and $raw.Trim()) {
        try { $data = $raw | ConvertFrom-Json } catch { $data = $null }
    }

    $model  = $null
    $folder = $null
    $limits = $null
    if ($null -ne $data) {
        if ($data.model) { $model = $data.model.display_name }
        $dir = $null
        if ($data.workspace) { $dir = $data.workspace.current_dir }
        if (-not $dir) { $dir = $data.cwd }
        if ($dir) {
            $folder = ([string]$dir).TrimEnd('\', '/') -replace '^.*[\\/]', ''
            if (-not $folder) { $folder = [string]$dir }
        }
        $limits = $data.rate_limits
    }
    if (-not $model) { $model = 'Claude' }

    $five = $null
    $week = $null
    if ($null -ne $limits) {
        $five = $limits.five_hour
        $week = $limits.seven_day
    }

    $now = [double][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

    $head = [string]$model
    if ($folder) { $head = "$head $(Paint $Grey $Dot) $folder" }

    $bar  = Paint $Grey $Sep
    $line = "$head $bar " +
            (Format-Window 'session' $five (5 * 3600) $now) +
            " $bar " +
            (Format-Window 'week' $week (7 * 86400) $now)
} catch {
    # Never show an error or a blank line; fall back to whatever was built.
}

$bytes  = [Text.Encoding]::UTF8.GetBytes($line + "`n")
$stdout = [Console]::OpenStandardOutput()
$stdout.Write($bytes, 0, $bytes.Length)
$stdout.Flush()
exit 0
