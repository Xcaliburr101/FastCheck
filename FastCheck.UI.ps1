#Requires -Version 5.1
<#
.SYNOPSIS
    FastCheck WPF dashboard — streaming section cards, live log, slate theme.
#>

function Get-FastCheckSeverityBrush {
    param([string]$Severity)
    switch ($Severity) {
        'OK' { return '#10B981' }
        'Warning' { return '#F59E0B' }
        'Error' { return '#EF4444' }
        'NotAvailable' { return '#64748B' }
        default { return '#38BDF8' }
    }
}

function Add-FastCheckLogLine {
    param($SharedData, [string]$Message, [string]$Level = 'Info')
    $timestamp = Get-Date -Format 'HH:mm:ss'
    $prefix = switch ($Level) {
        'Error' { '[ERR]' }
        'Warning' { '[WRN]' }
        default { '[LOG]' }
    }
    $line = "[$timestamp] $prefix $Message"
    $SharedData.Dispatcher.BeginInvoke([action]{
        $SharedData.TxtLog.AppendText("$line`n")
        if ($SharedData.LogScroll) { $SharedData.LogScroll.ScrollToEnd() }
        $lines = $SharedData.TxtLog.Text -split "`n"
        if ($lines.Count -gt 500) {
            $SharedData.TxtLog.Text = ($lines | Select-Object -Last 400) -join "`n"
        }
    }, [System.Windows.Threading.DispatcherPriority]::Background) | Out-Null
}

function Format-FastCheckDetailText {
    param([string]$Title, $Rows)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine($Title)
    [void]$sb.AppendLine(('=' * 60))
    foreach ($row in $Rows) {
        [void]$sb.AppendLine(('{0,-22}: {1}' -f $row.Name, $row.Value))
    }
    return $sb.ToString()
}

function Show-FastCheckDetailWindow {
    param(
        [string]$Title,
        [string]$BodyText
    )

        $runspace = [runspacefactory]::CreateRunspace()
        try {
            $runspace.ApartmentState = 'STA'
            $runspace.ThreadOptions = 'UseNewThread'
        } catch { }
        $runspace.Open()

    $ps = [powershell]::Create()
    $ps.Runspace = $runspace

    [void]$ps.AddScript({
        param($winTitle, $body)
        Add-Type -AssemblyName PresentationFramework
        [xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        Height="500" Width="650" Background="#0F172A"
        WindowStartupLocation="CenterScreen" FontFamily="Segoe UI">
    <Grid Margin="15">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <TextBlock Name="Hdr" FontSize="18" FontWeight="Bold" Foreground="#38BDF8" Margin="0,0,0,12"/>
        <Border Grid.Row="1" Background="#1E293B" CornerRadius="6" Padding="12">
            <ScrollViewer VerticalScrollBarVisibility="Auto">
                <TextBox Name="Body" IsReadOnly="True" AcceptsReturn="True" TextWrapping="Wrap"
                         Background="Transparent" Foreground="#E2E8F0" BorderThickness="0"
                         FontFamily="Consolas" FontSize="12"/>
            </ScrollViewer>
        </Border>
        <Button Name="BtnClose" Grid.Row="2" Content="Close" Width="100" Height="32" Margin="0,12,0,0"
                HorizontalAlignment="Right" Background="#0EA5E9" Foreground="White" BorderThickness="0"/>
    </Grid>
</Window>
"@
        $reader = New-Object System.Xml.XmlNodeReader $xaml
        $win = [Windows.Markup.XamlReader]::Load($reader)
        $win.Title = $winTitle
        $win.FindName('Hdr').Text = $winTitle
        $win.FindName('Body').Text = $body
        $win.FindName('BtnClose').Add_Click({ $win.Close() })
        [void]$win.ShowDialog()
    }).AddArgument($Title).AddArgument($BodyText)

    $ps.BeginInvoke() | Out-Null
}

function Add-FastCheckSectionCard {
    param(
        $SharedData,
        [string]$SectionTitle,
        $Rows,
        [string]$Severity = 'Info'
    )

    $accent = Get-FastCheckSeverityBrush $Severity
    $detailText = Format-FastCheckDetailText -Title $SectionTitle -Rows $Rows

    $card = New-Object System.Windows.Controls.Border
    $card.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#1E293B')
    $card.CornerRadius = New-Object System.Windows.CornerRadius 8
    $card.Padding = New-Object System.Windows.Thickness 14
    $card.Margin = New-Object System.Windows.Thickness 0, 0, 0, 10
    $card.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString($accent)
    $card.BorderThickness = New-Object System.Windows.Thickness 2, 0, 0, 0
    $card.Cursor = 'Hand'
    $card.Tag = @{ Title = $SectionTitle; Rows = $Rows; DetailText = $detailText }

    $stack = New-Object System.Windows.Controls.StackPanel

    $header = New-Object System.Windows.Controls.Grid
    $header.Margin = New-Object System.Windows.Thickness 0, 0, 0, 10
    [void]$header.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
    $col2 = New-Object System.Windows.Controls.ColumnDefinition
    $col2.Width = [System.Windows.GridLength]::Auto
    [void]$header.ColumnDefinitions.Add($col2)

    $titleBlock = New-Object System.Windows.Controls.TextBlock
    $titleBlock.Text = $SectionTitle
    $titleBlock.FontSize = 14
    $titleBlock.FontWeight = 'Bold'
    $titleBlock.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#F8FAFC')
    [System.Windows.Controls.Grid]::SetColumn($titleBlock, 0)
    [void]$header.Children.Add($titleBlock)

    $pill = New-Object System.Windows.Controls.Border
    $pill.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($accent)
    $pill.CornerRadius = New-Object System.Windows.CornerRadius 4
    $pill.Padding = New-Object System.Windows.Thickness 8, 2, 8, 2
    $pillText = New-Object System.Windows.Controls.TextBlock
    $pillText.Text = $Severity
    $pillText.Foreground = [System.Windows.Media.Brushes]::White
    $pillText.FontSize = 10
    $pillText.FontWeight = 'Bold'
    $pill.Child = $pillText
    [System.Windows.Controls.Grid]::SetColumn($pill, 1)
    [void]$header.Children.Add($pill)
    [void]$stack.Children.Add($header)

    $grid = New-Object System.Windows.Controls.Grid
    $grid.Margin = New-Object System.Windows.Thickness 0
    [void]$grid.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
    $c1 = New-Object System.Windows.Controls.ColumnDefinition
    $c1.Width = New-Object System.Windows.GridLength(180)
    [void]$grid.ColumnDefinitions.Add($c1)
    [void]$grid.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))

    $rowIndex = 0
    foreach ($row in $Rows) {
        [void]$grid.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition))
        $label = New-Object System.Windows.Controls.TextBlock
        $label.Text = $row.Name
        $label.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#94A3B8')
        $label.FontSize = 12
        $label.Margin = New-Object System.Windows.Thickness 0, 2, 8, 2
        [System.Windows.Controls.Grid]::SetRow($label, $rowIndex)
        [System.Windows.Controls.Grid]::SetColumn($label, 0)

        $value = New-Object System.Windows.Controls.TextBlock
        $value.Text = $row.Value
        $value.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString(
            (Get-FastCheckSeverityBrush $row.Severity)
        )
        $value.FontSize = 12
        $value.TextWrapping = 'Wrap'
        $value.Margin = New-Object System.Windows.Thickness 0, 2, 0, 2
        [System.Windows.Controls.Grid]::SetRow($value, $rowIndex)
        [System.Windows.Controls.Grid]::SetColumn($value, 1)

        [void]$grid.Children.Add($label)
        [void]$grid.Children.Add($value)
        $rowIndex++
    }
    [void]$stack.Children.Add($grid)

    $hint = New-Object System.Windows.Controls.TextBlock
    $hint.Text = 'Double-click for detail window'
    $hint.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#64748B')
    $hint.FontSize = 10
    $hint.Margin = New-Object System.Windows.Thickness 0, 8, 0, 0
    [void]$stack.Children.Add($hint)

    $card.Child = $stack

    $ownerSd = $SharedData
    $card.Add_MouseLeftButtonDown({
        param($sender, $e)
        if ($e.ClickCount -ge 2) {
            $tag = $sender.Tag
            Show-FastCheckDetailWindow -Title $tag.Title -BodyText $tag.DetailText
        }
    })

    [void]$SharedData.CardPanel.Children.Add($card)
}

function Start-FastCheckScan {
    param(
        $SharedData,
        [ValidateSet('Quick', 'Full')]
        [string]$ScanMode
    )

    if ($SharedData.IsScanning) { return }

    $SharedData.IsScanning = $true
    $SharedData.CancelRequested = $false
    $SharedData.CompletedSections = 0
    $SharedData.ScanMode = $ScanMode

    $SharedData.BtnQuick.IsEnabled = $false
    $SharedData.BtnFull.IsEnabled = $false
    $SharedData.BtnCancel.IsEnabled = $true
    $SharedData.LblStatus.Text = "Running $ScanMode scan..."
    $SharedData.ProgBar.IsIndeterminate = $false
    $SharedData.ProgBar.Value = 0
    $SharedData.CardPanel.Children.Clear()
    $SharedData.TxtLog.Text = "[$(Get-Date -Format 'HH:mm:ss')] FastCheck $ScanMode scan started.`n"
    $SharedData.PendingCards = [System.Collections.Queue]::Synchronized([System.Collections.Queue]::new())
    $SharedData.SectionIndex = 0

    if ($SharedData.UiTimer) { $SharedData.UiTimer.Stop() }
    $SharedData.UiTimer = New-Object System.Windows.Threading.DispatcherTimer
    $SharedData.UiTimer.Interval = [TimeSpan]::FromMilliseconds(80)
    $uiSd = $SharedData
    $SharedData.ScanFinished = $false
    $SharedData.UiTimer.Add_Tick({
        while ($uiSd.PendingCards.Count -gt 0) {
            $item = $uiSd.PendingCards.Dequeue()
            Add-FastCheckSectionCard -SharedData $uiSd -SectionTitle $item.Title -Rows $item.Rows -Severity $item.Severity
        }
        if ($uiSd.ScanFinished -and $uiSd.PendingCards.Count -eq 0) {
            $uiSd.UiTimer.Stop()
        }
    })
    $SharedData.UiTimer.Start()

    $corePath = $SharedData.CoreScriptPath
    if (-not (Test-Path -LiteralPath $corePath)) {
        Add-FastCheckLogLine -SharedData $SharedData -Message "Core not found: $corePath" -Level 'Error'
        $SharedData.IsScanning = $false
        $SharedData.BtnQuick.IsEnabled = $true
        $SharedData.BtnFull.IsEnabled = $true
        $SharedData.BtnCancel.IsEnabled = $false
        return
    }

    $corePathEscaped = $corePath.Replace("'", "''")
        $runspace = [runspacefactory]::CreateRunspace()
        try {
            $runspace.ApartmentState = 'STA'
            $runspace.ThreadOptions = 'UseNewThread'
        } catch { }
        $runspace.Open()
    $SharedData.Runspace = $runspace

    $ps = [powershell]::Create()
    $ps.Runspace = $runspace
    $SharedData.PowerShell = $ps

    [void]$ps.AddScript(". '$corePathEscaped'")
    $ps.Invoke() | Out-Null
    if ($ps.Streams.Error.Count -gt 0) {
        Add-FastCheckLogLine -SharedData $SharedData -Message ($ps.Streams.Error | Out-String) -Level 'Error'
        $SharedData.IsScanning = $false
        $SharedData.BtnQuick.IsEnabled = $true
        $SharedData.BtnFull.IsEnabled = $true
        $SharedData.BtnCancel.IsEnabled = $false
        return
    }
    $ps.Commands.Clear()

    $totalSections = Get-FastCheckLogicalSectionCount

    [void]$ps.AddScript({
        param($Sync, $Mode)

        $shouldCancel = { $Sync.CancelRequested }
        $onLog = {
            param($msg, $level)
            $Sync.Dispatcher.BeginInvoke([action]{
                $ts = Get-Date -Format 'HH:mm:ss'
                $pfx = switch ($level) { 'Error' { '[ERR]' } 'Warning' { '[WRN]' } default { '[LOG]' } }
                $Sync.TxtLog.AppendText("[$ts] $pfx $msg`n")
                if ($Sync.LogScroll) { $Sync.LogScroll.ScrollToEnd() }
            }, [System.Windows.Threading.DispatcherPriority]::Background) | Out-Null
        }
        $onProgress = {
            param($name)
            $Sync.SectionIndex = $Sync.SectionIndex + 1
            $idx = $Sync.SectionIndex
            $total = $Sync.TotalSections
            $Sync.Dispatcher.BeginInvoke([action]{
                $Sync.LblStatus.Text = "Checking: $name"
                $Sync.ProgBar.Value = [Math]::Min(100, ($idx / $total) * 100)
            }) | Out-Null
        }
        $onSection = {
            param($title, $data, $rows, $severity)
            $Sync.PendingCards.Enqueue(@{
                Title    = $title
                Rows     = $rows
                Severity = $severity
            })
        }
        $onBitLocker = {
            $choice = @($false)
            $Sync.Dispatcher.Invoke([action]{
                $r = [System.Windows.MessageBox]::Show(
                    "BitLocker encryption detected on C:. Initiate decryption?`n`nCalls Disable-BitLocker on C:.",
                    'BitLocker — Confirm',
                    [System.Windows.MessageBoxButton]::YesNo,
                    [System.Windows.MessageBoxImage]::Warning
                )
                $choice[0] = ($r -eq [System.Windows.MessageBoxResult]::Yes)
            })
            return $choice[0]
        }

        $Sync.SectionIndex = 0
        $ctx = Get-FastCheckContext
        $null = Invoke-FastCheckDiagnostics -Context $ctx -ScanMode $Mode `
            -OnProgress $onProgress -OnLogLine $onLog -OnSectionComplete $onSection `
            -OnBitLockerConfirm $onBitLocker -ShouldCancel $shouldCancel

        $Sync.Dispatcher.BeginInvoke([action]{
            $Sync.LblStatus.Text = if ($Sync.CancelRequested) { 'Scan cancelled.' } else { 'Scan complete.' }
            $Sync.ProgBar.Value = 100
            $Sync.IsScanning = $false
            $Sync.ScanFinished = $true
            $Sync.BtnQuick.IsEnabled = $true
            $Sync.BtnFull.IsEnabled = $true
            $Sync.BtnCancel.IsEnabled = $false
            if ($Sync.PowerShell) { $Sync.PowerShell.Dispose(); $Sync.PowerShell = $null }
            if ($Sync.Runspace) { $Sync.Runspace.Close(); $Sync.Runspace.Dispose(); $Sync.Runspace = $null }
        }) | Out-Null
    }).AddArgument($SharedData).AddArgument($ScanMode)

    $ps.BeginInvoke() | Out-Null
}

function Start-FastCheckGui {
    param(
        [string]$CoreScriptPath = (Join-Path $PSScriptRoot 'FastCheck.Core.ps1')
    )

    try {
        if (-not (Get-Command -Name 'Invoke-FastCheckDiagnostics' -ErrorAction SilentlyContinue)) {
            if (-not (Test-Path -LiteralPath $CoreScriptPath)) {
                throw "FastCheck.Core.ps1 not found at: $CoreScriptPath"
            }
            . $CoreScriptPath
        }

        Add-Type -AssemblyName PresentationFramework
        Add-Type -AssemblyName WindowsBase
    } catch {
        Write-Error "FastCheck failed to start: $($_.Exception.Message)"
        return
    }

    [xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="FastCheck Diagnostics" Height="800" Width="1280" MinHeight="600" MinWidth="1000"
        WindowStartupLocation="CenterScreen" Background="#0F172A" FontFamily="Segoe UI">
    <Grid Margin="16">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <StackPanel Grid.Row="0" Margin="0,0,0,8">
            <TextBlock Text="FASTCHECK SYSTEM DIAGNOSTICS" Foreground="#38BDF8" FontSize="11" FontWeight="Bold"/>
            <TextBlock Name="LblStatus" Text="Ready to scan." Foreground="#94A3B8" FontSize="16" Margin="0,4,0,0"/>
            <TextBlock Name="TxtAdmin" Foreground="#64748B" FontSize="11" Margin="0,4,0,0"/>
        </StackPanel>
        <StackPanel Grid.Row="1" Orientation="Horizontal" Margin="0,0,0,12">
            <Button Name="BtnQuick" Content="Quick Scan" Width="120" Height="36" Margin="0,0,8,0"
                    Background="#0EA5E9" Foreground="White" FontWeight="Bold" BorderThickness="0"/>
            <Button Name="BtnFull" Content="Full Scan" Width="120" Height="36" Margin="0,0,8,0"
                    Background="#334155" Foreground="White" FontWeight="Bold" BorderThickness="0"/>
            <Button Name="BtnCancel" Content="Cancel" Width="90" Height="36" IsEnabled="False"
                    Background="#475569" Foreground="White" BorderThickness="0"/>
        </StackPanel>
        <ProgressBar Name="ProgBar" Grid.Row="2" Height="10" Margin="0,0,0,12"
                     Minimum="0" Maximum="100" Value="0" Background="#334155" Foreground="#0EA5E9"/>
        <Grid Grid.Row="3">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="2*"/>
                <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>
            <Border Grid.Column="0" Background="#1E293B" CornerRadius="8" Padding="12" Margin="0,0,8,0">
                <ScrollViewer VerticalScrollBarVisibility="Auto" Name="ScrollCards">
                    <StackPanel Name="CardPanel"/>
                </ScrollViewer>
            </Border>
            <Border Grid.Column="1" Background="#1E293B" CornerRadius="8" Padding="12">
                <DockPanel>
                    <TextBlock DockPanel.Dock="Top" Text="LIVE LOG" Foreground="#38BDF8" FontSize="11"
                               FontWeight="Bold" Margin="0,0,0,8"/>
                    <ScrollViewer Name="LogScroll" VerticalScrollBarVisibility="Auto">
                        <TextBox Name="TxtLog" Text="[IDLE] Awaiting scan...`n" IsReadOnly="True"
                                 AcceptsReturn="True" TextWrapping="Wrap" Background="Transparent"
                                 Foreground="#38BDF8" BorderThickness="0" FontFamily="Consolas" FontSize="12"/>
                    </ScrollViewer>
                </DockPanel>
            </Border>
        </Grid>
    </Grid>
</Window>
"@

    $reader = New-Object System.Xml.XmlNodeReader $xaml
    $sd = [hashtable]::Synchronized(@{})
    $sd.Window = [Windows.Markup.XamlReader]::Load($reader)
    $sd.Dispatcher = $sd.Window.Dispatcher
    $sd.CoreScriptPath = $CoreScriptPath
    $sd.TotalSections = Get-FastCheckLogicalSectionCount
    $sd.IsScanning = $false
    $sd.CancelRequested = $false

    $sd.LblStatus = $sd.Window.FindName('LblStatus')
    $sd.TxtAdmin = $sd.Window.FindName('TxtAdmin')
    $sd.BtnQuick = $sd.Window.FindName('BtnQuick')
    $sd.BtnFull = $sd.Window.FindName('BtnFull')
    $sd.BtnCancel = $sd.Window.FindName('BtnCancel')
    $sd.ProgBar = $sd.Window.FindName('ProgBar')
    $sd.CardPanel = $sd.Window.FindName('CardPanel')
    $sd.TxtLog = $sd.Window.FindName('TxtLog')
    $sd.LogScroll = $sd.Window.FindName('LogScroll')
    $sd.ScrollCards = $sd.Window.FindName('ScrollCards')

    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
    $sd.TxtAdmin.Text = if ($isAdmin) { 'Running as Administrator' } else { 'Not elevated — BitLocker, Secure Boot, and SSD SMART require admin' }

    $sd.BtnQuick.Add_Click({ Start-FastCheckScan -SharedData $sd -ScanMode 'Quick' })
    $sd.BtnFull.Add_Click({ Start-FastCheckScan -SharedData $sd -ScanMode 'Full' })
    $sd.BtnCancel.Add_Click({
        if ($sd.IsScanning) {
            $sd.CancelRequested = $true
            Add-FastCheckLogLine -SharedData $sd -Message 'Cancel requested...' -Level 'Warning'
        }
    })

    [void]$sd.Window.ShowDialog()
}
