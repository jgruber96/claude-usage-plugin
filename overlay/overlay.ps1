# Plan usage overlay: a small always-on-top card showing the 5-hour session
# and 7-day weekly limits, each with a usage bar and a pace line above it.
#
# It is its own window, not part of Claude, so it stays in view across the
# Chat and Code tabs. By default it shows only while a Claude window is in
# front, and it is anchored to the bottom-left of the Claude window so it moves
# with it. Drag it to set its place there; right-click to lock that place,
# to stop anchoring, or to close.
#
# The figures come from %USERPROFILE%\.claude\plan-usage.json, which the
# plan-usage mod writes whenever a Claude Code session measures usage. No
# network, no credentials. Times left and pace are recomputed here, so they
# keep moving between writes; the percentages only change when a Claude Code
# session reports new ones.
#
# Plain ASCII on purpose: Windows PowerShell 5.1 reads a script without a
# byte-order mark as ANSI.
#
#   overlay.ps1                    run the overlay
#   overlay.ps1 -Snapshot out.png  draw once to a PNG and exit (for checking)
#   overlay.ps1 -Data file.json    read another data file

param(
    [string]$Data = (Join-Path $env:USERPROFILE '.claude\plan-usage.json'),
    [string]$Snapshot = '',
    [double]$Now = 0   # Unix seconds; 0 means the real clock (tests pass a fixed one)
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

$PaceSlack = 3     # points either side that count as "on pace"
$NearLimit = 80    # percent used from which the limit counts as close
$StaleAfter = 900  # seconds after which the reading is marked as old
$BarWidth  = 330.0 # the card is this plus 30 for its padding and border
$SettingsPath = Join-Path $env:LOCALAPPDATA 'plan-usage-overlay.json'

$Known = [ordered]@{
    five_hour = @{ Label = 'Session limit'; Seconds = 5 * 3600 }
    seven_day = @{ Label = 'Weekly';        Seconds = 7 * 86400 }
}

$Colors = @{
    Card   = '#F2262624'
    Edge   = '#3D3D3A'
    Text   = '#ECEBE6'
    Dim    = '#9C9A92'
    Track  = '#47474380'
    Blue   = '#4A8FE8'
    Yellow = '#E0B050'
    Green  = '#5FB37A'
    Orange = '#E09A3C'
    Red    = '#D9534F'
    Grey   = '#9A9A9A'
}
# Track is written RRGGBBAA above for readability; WPF wants AARRGGBB.
$Colors.Track = '#80474743'

function Get-Brush([string]$Hex) {
    return (New-Object Windows.Media.BrushConverter).ConvertFromString($Hex)
}

function Get-NowSeconds {
    if ($Now -gt 0) { return $Now }
    return [double][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
}

function Format-Span([double]$Seconds) {
    $m = [math]::Floor($Seconds / 60)
    if ($m -lt 1) { return '<1 min' }
    $d  = [math]::Floor($m / 1440)
    $h  = [math]::Floor(($m % 1440) / 60)
    $mm = $m % 60
    if ($d -ge 1) { return "$d d $h hr" }
    if ($h -ge 1) { return "$h hr $mm min" }
    return "$mm min"
}

function Format-Tokens([double]$N) {
    $inv = [Globalization.CultureInfo]::InvariantCulture
    if ($N -ge 1000000) { return ($N / 1000000).ToString('0.#', $inv) + 'M' }
    if ($N -ge 1000)    { return ($N / 1000).ToString('0.#', $inv) + 'k' }
    return [string][int]$N
}

function Read-Usage {
    # Returns $null when there is no usable file yet.
    try {
        if (-not (Test-Path -LiteralPath $Data)) { return $null }
        $raw = [IO.File]::ReadAllText($Data)
        if (-not $raw.Trim()) { return $null }
        return $raw | ConvertFrom-Json
    } catch { return $null }
}

function Measure-Window([string]$Kind, $Window, [double]$NowSec) {
    $known = $Known[$Kind]
    $r = @{ Kind = $Kind; Label = $known.Label; HasReading = $false; Status = 'on'; IsNear = $false }
    if ($null -eq $Window) { return $r }

    $used = 0.0
    if (-not [double]::TryParse([string]$Window.percentUsed, [Globalization.NumberStyles]::Float,
            [Globalization.CultureInfo]::InvariantCulture, [ref]$used)) { return $r }

    $reset = $null
    if ($Window.resetsAt) {
        try {
            # ConvertFrom-Json may already have turned the timestamp into a DateTime.
            if ($Window.resetsAt -is [datetime]) { $reset = [DateTimeOffset]$Window.resetsAt.ToUniversalTime() }
            else {
                $reset = [DateTimeOffset]::Parse([string]$Window.resetsAt,
                    [Globalization.CultureInfo]::InvariantCulture,
                    [Globalization.DateTimeStyles]::AssumeUniversal)
            }
        } catch { $reset = $null }
    }
    # A window whose reset time has passed holds last window's numbers.
    if ($null -ne $reset -and $reset.ToUnixTimeSeconds() -le $NowSec) { return $r }

    $r.HasReading = $true
    $r.Percent = [int][math]::Round($used, [MidpointRounding]::AwayFromZero)
    $r.Used    = [math]::Max(0, [math]::Min(100, $used))
    $r.IsNear  = $used -ge $NearLimit
    if ($null -eq $reset) { return $r }

    $remaining = [math]::Min($reset.ToUnixTimeSeconds() - $NowSec, $known.Seconds)
    $elapsed   = ($known.Seconds - $remaining) / $known.Seconds * 100
    $diff      = $used - $elapsed

    $r.Remaining = $remaining
    $r.ResetAt   = $reset.ToLocalTime()
    $r.Elapsed   = $elapsed
    $r.Points    = [int][math]::Round($diff, [MidpointRounding]::AwayFromZero)
    if ([math]::Abs($diff) -le $PaceSlack) { $r.Status = 'on' }
    elseif ($diff -lt 0)                   { $r.Status = 'under' }
    else                                   { $r.Status = 'over' }
    return $r
}

function Get-PaceText($r) {
    if ($null -eq $r.Points) { return '' }
    if ($r.Status -eq 'on') { return 'On pace' }
    $n = [math]::Abs($r.Points)
    if ($r.Points -lt 0) { return "$n% under pace" }
    return "$n% over pace"
}

function Get-PaceColor($r) {
    if ($r.Status -eq 'under') { return $Colors.Green }
    if ($r.Status -eq 'over') { if ($r.IsNear) { return $Colors.Red } else { return $Colors.Orange } }
    return $Colors.Dim
}

function Get-LineColor($r) {
    if ($r.Status -eq 'on') { return $Colors.Grey }
    return Get-PaceColor $r
}

function Get-ResetText($r) {
    if ($null -eq $r.Remaining) { return '' }
    # Within a day the time left reads best; further out, the day and time.
    if ($r.Remaining -lt 86400) { return "Resets in $(Format-Span $r.Remaining)" }
    return 'Resets ' + $r.ResetAt.ToString('ddd h:mm tt', [Globalization.CultureInfo]::InvariantCulture)
}

function New-Text([string]$Text, [double]$Size, [string]$Color, [string]$Weight = 'Normal') {
    $t = New-Object Windows.Controls.TextBlock
    $t.Text = $Text
    $t.FontSize = $Size
    $t.Foreground = Get-Brush $Color
    $t.FontWeight = $Weight
    return $t
}

function New-Row($Left, $Right) {
    $dock = New-Object Windows.Controls.DockPanel
    $dock.LastChildFill = $false
    [Windows.Controls.DockPanel]::SetDock($Left, 'Left')
    [Windows.Controls.DockPanel]::SetDock($Right, 'Right')
    [void]$dock.Children.Add($Left)
    [void]$dock.Children.Add($Right)
    return $dock
}

function New-Bar([double]$Width, [double]$Height, [string]$Color) {
    $b = New-Object Windows.Controls.Border
    $b.Width = [math]::Max(0, $Width)
    $b.Height = $Height
    $b.CornerRadius = New-Object Windows.CornerRadius ($Height / 2)
    $b.Background = Get-Brush $Color
    $b.HorizontalAlignment = 'Left'
    return $b
}

function Get-Fill([double]$Percent, [double]$Min) {
    if ($Percent -le 0) { return 0 }
    return [math]::Max($Min, $BarWidth * [math]::Min(100, $Percent) / 100)
}

function New-Bars($r) {
    $stack = New-Object Windows.Controls.StackPanel
    $stack.Margin = '0,4,0,3'

    if ($null -ne $r.Elapsed) {
        # The pace line: grey as far as usage and time agree, coloured between.
        $line = New-Object Windows.Controls.Grid
        $line.Margin = '0,0,0,2'
        $used = Get-Fill $r.Used 3
        $gone = Get-Fill $r.Elapsed 3
        [void]$line.Children.Add((New-Bar $BarWidth 3 $Colors.Track))
        [void]$line.Children.Add((New-Bar ([math]::Max($used, $gone)) 3 (Get-LineColor $r)))
        [void]$line.Children.Add((New-Bar ([math]::Min($used, $gone)) 3 $Colors.Grey))
        [void]$stack.Children.Add($line)
    }

    $bar = New-Object Windows.Controls.Grid
    $fill = $Colors.Blue
    if ($r.IsNear) { $fill = $Colors.Yellow }
    [void]$bar.Children.Add((New-Bar $BarWidth 7 $Colors.Track))
    [void]$bar.Children.Add((New-Bar (Get-Fill $r.Used 7) 7 $fill))
    [void]$stack.Children.Add($bar)
    return $stack
}

function Update-Card($Panel) {
    $Panel.Children.Clear()
    $nowSec = Get-NowSeconds
    $usage = Read-Usage

    $readings = @()
    foreach ($kind in $Known.Keys) {
        $window = $null
        if ($null -ne $usage -and $null -ne $usage.windows) {
            $window = @($usage.windows) | Where-Object { $_.kind -eq $kind } | Select-Object -First 1
        }
        $readings += , (Measure-Window $kind $window $nowSec)
    }

    # The week's pace is the one worth planning by; the session's stands in.
    $paced = $null
    foreach ($r in $readings) { if ($null -ne $r.Points) { $paced = $r } }

    $title = New-Text 'Usage' 14 $Colors.Text 'SemiBold'
    if ($null -ne $paced) { $pace = New-Text (Get-PaceText $paced) 11 (Get-PaceColor $paced) }
    else { $pace = New-Text '' 11 $Colors.Dim }
    $pace.VerticalAlignment = 'Center'
    [void]$Panel.Children.Add((New-Row $title $pace))

    # Context is one session's, unlike the limits: the Claude Code session that
    # measured last. The folder beside the token count says which one.
    $percent = $null
    if ($null -ne $usage -and $null -ne $usage.context -and $null -ne $usage.context.percent) {
        $percent = [double]$usage.context.percent
    }
    if ($null -ne $percent) {
        $c = @{ Used = [math]::Max(0, [math]::Min(100, $percent)); IsNear = $percent -ge 90; Elapsed = $null }
        $block = New-Object Windows.Controls.StackPanel
        $block.Margin = '0,9,0,0'
        $shown = [int][math]::Round($percent, [MidpointRounding]::AwayFromZero)
        [void]$block.Children.Add((New-Row (New-Text 'Context' 12.5 $Colors.Text 'Medium') (New-Text "$shown% used" 12 $Colors.Dim)))
        [void]$block.Children.Add((New-Bars $c))
        $tokens = ''
        if ($null -ne $usage.context.window) {
            $tokens = Format-Tokens ([double]$usage.context.window)
            if ($null -ne $usage.context.tokens) { $tokens = "$(Format-Tokens ([double]$usage.context.tokens)) / $tokens" }
        }
        $folder = [string]$usage.folder
        if ($folder.Length -gt 30) { $folder = $folder.Substring(0, 29) + '...' }
        [void]$block.Children.Add((New-Row (New-Text $tokens 11 $Colors.Dim) (New-Text $folder 11 $Colors.Dim)))
        [void]$Panel.Children.Add($block)
    }

    foreach ($r in $readings) {
        $block = New-Object Windows.Controls.StackPanel
        $block.Margin = '0,9,0,0'
        $label = New-Text $r.Label 12.5 $Colors.Text 'Medium'
        if ($r.HasReading) {
            [void]$block.Children.Add((New-Row $label (New-Text "$($r.Percent)% used" 12 $Colors.Dim)))
            [void]$block.Children.Add((New-Bars $r))
            $own = New-Text '' 11 $Colors.Dim
            if ($null -ne $r.Points -and $r -ne $paced) { $own = New-Text (Get-PaceText $r) 11 (Get-PaceColor $r) }
            [void]$block.Children.Add((New-Row (New-Text (Get-ResetText $r) 11 $Colors.Dim) $own))
        } else {
            [void]$block.Children.Add((New-Row $label (New-Text 'no reading' 12 $Colors.Dim)))
        }
        [void]$Panel.Children.Add($block)
    }

    $note = ''
    if ($null -eq $usage) { $note = 'Waiting for a Claude Code session' }
    else {
        $age = $nowSec - ([double]$usage.at / 1000)
        if ($age -gt $StaleAfter) { $note = "Read $(Format-Span $age) ago" }
    }
    if ($note) {
        $foot = New-Text $note 10.5 $Colors.Dim
        $foot.Margin = '0,8,0,0'
        [void]$Panel.Children.Add($foot)
    }
}

function New-Card {
    $panel = New-Object Windows.Controls.StackPanel
    $card = New-Object Windows.Controls.Border
    $card.CornerRadius = New-Object Windows.CornerRadius 12
    $card.Background = Get-Brush $Colors.Card
    $card.BorderBrush = Get-Brush $Colors.Edge
    $card.BorderThickness = 1
    $card.Padding = '14,11,14,12'
    $card.Width = $BarWidth + 30
    $card.Child = $panel
    [Windows.Documents.TextElement]::SetFontFamily($card, (New-Object Windows.Media.FontFamily 'Segoe UI'))
    return @{ Card = $card; Panel = $panel }
}

# --- Snapshot mode: draw once to a PNG, no window -------------------------------
if ($Snapshot) {
    $ui = New-Card
    Update-Card $ui.Panel
    $ui.Card.Measure((New-Object Windows.Size ([double]::PositiveInfinity, [double]::PositiveInfinity)))
    $size = $ui.Card.DesiredSize
    $ui.Card.Arrange((New-Object Windows.Rect (0, 0, $size.Width, $size.Height)))
    $ui.Card.UpdateLayout()
    $scale = 2
    $bmp = New-Object Windows.Media.Imaging.RenderTargetBitmap (
        [int]($size.Width * $scale), [int]($size.Height * $scale), (96 * $scale), (96 * $scale),
        [Windows.Media.PixelFormats]::Pbgra32)
    $bmp.Render($ui.Card)
    $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder
    [void]$enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bmp))
    $out = [IO.File]::Create($Snapshot)
    try { $enc.Save($out) } finally { $out.Close() }
    exit 0
}

# --- One overlay at a time ----------------------------------------------------
$created = $false
$mutex = New-Object Threading.Mutex ($true, 'PlanUsageOverlay', [ref]$created)
if (-not $created) { exit 0 }

Add-Type -Namespace PlanUsage -Name Native -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
[DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hWnd);
[DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
'@

function Read-Settings {
    try { return [IO.File]::ReadAllText($SettingsPath) | ConvertFrom-Json } catch { return $null }
}

function Get-Setting($Name, $Default) {
    if ($null -ne $settings -and $null -ne $settings.$Name) { return $settings.$Name }
    return $Default
}

$settings = Read-Settings
# Anchored: the card keeps its place relative to the bottom-left corner of the
# Claude window and moves with it. Not anchored: it stays where it is put on
# the screen. Either way it shows only while a Claude window is in front.
$script:anchored = [bool](Get-Setting 'anchored' $true)
$script:dx = [double](Get-Setting 'dx' 10)     # from the Claude window's left edge
$script:dy = [double](Get-Setting 'dy' 236)    # from its bottom edge up to the card's top
$script:claude = [IntPtr]::Zero               # the Claude window being followed
$script:dragging = $false
$script:locked = [bool](Get-Setting 'locked' $false)   # locked: dragging does nothing
$script:frontId = 0
$script:frontName = ''

$ui = New-Card
$window = New-Object Windows.Window
$window.Title = 'Plan usage'
$window.WindowStyle = 'None'
$window.AllowsTransparency = $true
$window.Background = [Windows.Media.Brushes]::Transparent
$window.ResizeMode = 'NoResize'
$window.Topmost = $true
$window.ShowInTaskbar = $false
$window.ShowActivated = $false
$window.SizeToContent = 'WidthAndHeight'
$window.WindowStartupLocation = 'Manual'
$window.Opacity = 0
$window.Content = $ui.Card

function Save-Settings {
    try {
        $json = @{
            left = $window.Left; top = $window.Top
            anchored = $script:anchored; dx = $script:dx; dy = $script:dy
            locked = $script:locked
        } | ConvertTo-Json
        [IO.File]::WriteAllText($SettingsPath, $json)
    } catch { }
}

# The followed Claude window's rectangle in WPF units, or $null when there is
# none to follow (closed or minimized).
function Get-ClaudeRect {
    $h = $script:claude
    if ($h -eq [IntPtr]::Zero) { return $null }
    if (-not [PlanUsage.Native]::IsWindow($h)) { $script:claude = [IntPtr]::Zero; return $null }
    if ([PlanUsage.Native]::IsIconic($h)) { return $null }
    $r = New-Object PlanUsage.Native+RECT
    if (-not [PlanUsage.Native]::GetWindowRect($h, [ref]$r)) { return $null }
    $sx = 1.0; $sy = 1.0
    $source = [Windows.PresentationSource]::FromVisual($window)
    if ($null -ne $source -and $null -ne $source.CompositionTarget) {
        $sx = $source.CompositionTarget.TransformFromDevice.M11
        $sy = $source.CompositionTarget.TransformFromDevice.M22
    }
    return @{ Left = $r.Left * $sx; Top = $r.Top * $sy; Right = $r.Right * $sx; Bottom = $r.Bottom * $sy }
}

Update-Card $ui.Panel

$area = [Windows.SystemParameters]::WorkArea
$window.Left = [double](Get-Setting 'left' ($area.Left + 12))
$window.Top  = [double](Get-Setting 'top' ($area.Bottom - 230))
if ($window.Left -lt [Windows.SystemParameters]::VirtualScreenLeft -or
    $window.Top  -lt [Windows.SystemParameters]::VirtualScreenTop -or
    $window.Left -gt ([Windows.SystemParameters]::VirtualScreenLeft + [Windows.SystemParameters]::VirtualScreenWidth - 40) -or
    $window.Top  -gt ([Windows.SystemParameters]::VirtualScreenTop + [Windows.SystemParameters]::VirtualScreenHeight - 40)) {
    $window.Left = $area.Left + 12
    $window.Top  = $area.Bottom - 230
}

$window.Add_MouseLeftButtonDown({
    if ($script:locked) { return }
    $script:dragging = $true
    try { $window.DragMove() } catch { }
    $script:dragging = $false
    # Where it was dropped becomes its place: relative to Claude when anchored.
    if ($script:anchored) {
        $rect = Get-ClaudeRect
        if ($null -ne $rect) {
            $script:dx = $window.Left - $rect.Left
            $script:dy = $rect.Bottom - $window.Top
        }
    }
    Save-Settings
})

$menu = New-Object Windows.Controls.ContextMenu
$itemAnchor = New-Object Windows.Controls.MenuItem
$itemAnchor.Header = 'Anchor to the Claude window'
$itemAnchor.IsCheckable = $true
$itemAnchor.IsChecked = $script:anchored
$itemAnchor.Add_Click({ $script:anchored = $itemAnchor.IsChecked; Save-Settings })
$itemLock = New-Object Windows.Controls.MenuItem
$itemLock.Header = 'Lock position'
$itemLock.IsCheckable = $true
$itemLock.IsChecked = $script:locked
$itemLock.Add_Click({ $script:locked = $itemLock.IsChecked; Save-Settings })
$itemClose = New-Object Windows.Controls.MenuItem
$itemClose.Header = 'Close'
$itemClose.Add_Click({ $window.Close() })
[void]$menu.Items.Add($itemAnchor)
[void]$menu.Items.Add($itemLock)
[void]$menu.Items.Add($itemClose)
$window.ContextMenu = $menu

# Redraw every 20 seconds, and at once when the data file changes.
$redraw = New-Object Windows.Threading.DispatcherTimer
$redraw.Interval = [TimeSpan]::FromSeconds(20)
$redraw.Add_Tick({ try { Update-Card $ui.Panel } catch { } })
$redraw.Start()

$script:stamp = $null
$script:ticks = 0

# Follow the Claude window, and show only while it (or this card) is in front.
$watch = New-Object Windows.Threading.DispatcherTimer
$watch.Interval = [TimeSpan]::FromMilliseconds(30)
$watch.Add_Tick({
    try {
        $script:ticks++
        if ($script:ticks % 15 -eq 0) {
            $stamp = $null
            if (Test-Path -LiteralPath $Data) { $stamp = (Get-Item -LiteralPath $Data).LastWriteTimeUtc }
            if ($stamp -ne $script:stamp) { $script:stamp = $stamp; Update-Card $ui.Panel }
        }

        $show = $menu.IsOpen -or $script:dragging
        $frontWindow = [PlanUsage.Native]::GetForegroundWindow()
        $front = 0
        [void][PlanUsage.Native]::GetWindowThreadProcessId($frontWindow, [ref]$front)
        if ($front -eq $PID) { $show = $true }
        elseif ($front -ne 0) {
            if ($front -ne $script:frontId) {
                $script:frontId = $front
                $script:frontName = (Get-Process -Id $front -ErrorAction SilentlyContinue).ProcessName
            }
            if ($script:frontName -eq 'claude') {
                $show = $true
                # Follow the main window, not a small dialog or popup of Claude's.
                $r = New-Object PlanUsage.Native+RECT
                if ([PlanUsage.Native]::GetWindowRect($frontWindow, [ref]$r) -and
                    ($r.Right - $r.Left) -ge 600 -and ($r.Bottom - $r.Top) -ge 400) {
                    $script:claude = $frontWindow
                }
            }
        }

        if ($script:anchored) {
            $rect = Get-ClaudeRect
            if ($null -eq $rect) { $show = $false }
            elseif (-not $script:dragging) {
                # Keep the card inside the window when it is made small.
                $left = [math]::Max($rect.Left, [math]::Min($rect.Left + $script:dx, $rect.Right - $window.ActualWidth))
                $top  = [math]::Max($rect.Top,  [math]::Min($rect.Bottom - $script:dy, $rect.Bottom - $window.ActualHeight))
                if ([math]::Abs($window.Left - $left) -gt 0.5) { $window.Left = $left }
                if ([math]::Abs($window.Top - $top) -gt 0.5)   { $window.Top = $top }
            }
        }

        if ($show) { $window.Opacity = 1; $window.IsHitTestVisible = $true }
        else       { $window.Opacity = 0; $window.IsHitTestVisible = $false }
    } catch { }
})
$watch.Start()

$window.Add_Closed({ $redraw.Stop(); $watch.Stop(); Save-Settings })
[void]$window.ShowDialog()
$mutex.ReleaseMutex()
