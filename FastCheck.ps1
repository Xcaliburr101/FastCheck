<#
.SYNOPSIS
    Full System Hardware, Network, and Health Report (PowerShell 5.1 Compatible).
.DESCRIPTION
    Uses CIM queries with WMI fallback when CIM returns no data,
    inline ternary logic, and a unified visual display engine.
#>

Clear-Host

# --- Permission Check ---
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# --- Define standard colors ---
$ColorHeader = "Cyan"
$ColorKey = "White"
$ColorValue = "Gray"
$ColorAccent = "DarkGray"

# --- Core Display Functions ---
function Show-Row ([string]$Label, $Value, [string]$PassColor = "Gray") {
    if ([string]::IsNullOrWhiteSpace($Value)) {
        $DisplayValue = "N/A"
        $DisplayColor = "Gray"
    } else {
        $DisplayValue = $Value
        $DisplayColor = $PassColor
    }
    # {0,-20} keeps everything perfectly aligned
    Write-Host (" {0,-20}: " -f $Label) -ForegroundColor $ColorKey -NoNewline
    Write-Host $DisplayValue -ForegroundColor $DisplayColor
}

function Show-Header ([string]$Title) {
    Write-Host "`n$Title" -ForegroundColor $ColorHeader
}

# Prefer CIM; fall back to legacy WMI when CIM returns no instances
function Get-CimOrWmiInstance {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ClassName,
        [string[]]$Property,
        [string]$Namespace = 'root\cimv2',
        [string]$Filter,
        [switch]$First
    )

    $cimParams = @{ ClassName = $ClassName }
    if ($Namespace -and $Namespace -notmatch '^root\\cimv2$') { $cimParams.Namespace = $Namespace }
    if ($Property) { $cimParams.Property = $Property }
    if ($Filter) { $cimParams.Filter = $Filter }

    $instances = @()
    try { $instances = @(Get-CimInstance @cimParams -ErrorAction Stop) } catch { }

    if ($instances.Count -eq 0) {
        $wmiParams = @{ Class = $ClassName }
        if ($Namespace -and $Namespace -notmatch '^root\\cimv2$') { $wmiParams.Namespace = $Namespace }
        if ($Property) { $wmiParams.Property = $Property }
        if ($Filter) { $wmiParams.Filter = $Filter }
        try { $instances = @(Get-WmiObject @wmiParams -ErrorAction Stop) } catch { }
    }

    if ($First) { return $instances | Select-Object -First 1 }
    return $instances
}

# ==============================================================================
# HARDWARE & SYSTEM CHECKS
# ==============================================================================

# --- System & OS ---
Show-Header "System & OS"
$System = Get-CimOrWmiInstance -ClassName Win32_ComputerSystem -Property Manufacturer, Model -First
$OS = Get-CimOrWmiInstance -ClassName Win32_OperatingSystem -Property Caption, BuildNumber -First

#License Check
$licenseKey = (Get-CimOrWmiInstance -ClassName SoftwareLicensingService -Property OA3xOriginalProductKey -First).OA3xOriginalProductKey
if ([string]::IsNullOrWhiteSpace($licenseKey)) {
    $licenseKey = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SoftwareProtectionPlatform" -ErrorAction SilentlyContinue).BackupProductKeyDefault
}

Show-Row "System" "$($System.Manufacturer) $($System.Model)" $ColorValue
Show-Row "Windows Licence" $licenseKey $ColorAccent
Show-Row "OS" "$($OS.Caption) (Build $($OS.BuildNumber))" $ColorAccent
Show-Row "Build" "$((Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion").DisplayVersion)" $ColorAccent

# --- CPU ---
Show-Header "CPU"
$CPU = Get-CimOrWmiInstance -ClassName Win32_Processor -Property Name, NumberOfCores, NumberOfLogicalProcessors -First

# Temperature Check 
$thermalZones = Get-CimOrWmiInstance -Namespace 'root\cimv2' -ClassName Win32_PerfFormattedData_Counters_ThermalZoneInformation
$maxTemp = 0

foreach ($zone in $thermalZones) {
    # High Precision Temperature
    $currentTemp = [math]::round($zone.HighPrecisionTemperature / 100.0, 1)
    # Track the highest zone temp to represent the CPU package
    if ($currentTemp -gt $maxTemp) { $maxTemp = $currentTemp }
}

# Display Results
Show-Row "Name" "$($CPU.Name.Trim())" $ColorValue
Show-Row "Cores" "$($CPU.NumberOfCores) (Logical: $($CPU.NumberOfLogicalProcessors))" $ColorAccent

# Handle cases where temp might be 0 (some desktops/VMs don't report this via WMI)
if ($maxTemp -gt 0) {
    $TempColor = if ($maxTemp -gt 85) { "Red" } elseif ($maxTemp -gt 70) { "Yellow" } else { "Green" }
    Show-Row "Temperature" "$maxTemp °C" $TempColor
} else {
    Show-Row "Temperature" "Not Reported" $ColorAccent
}
# --- BIOS ---
Show-Header "BIOS"
$BIOS = Get-CimOrWmiInstance -ClassName Win32_BIOS -Property Manufacturer, Name, SerialNumber -First
Show-Row "Version" "$($BIOS.Manufacturer) $($BIOS.Name)" $ColorValue
Show-Row "Serial" "$($BIOS.SerialNumber)" $ColorAccent

# --- Memory ---
Show-Header "Memory"
$MemorySticks = @(Get-CimOrWmiInstance -ClassName Win32_PhysicalMemory -Property MemoryType, SMBIOSMemoryType, Capacity, DeviceLocator, BankLabel, Speed, PartNumber, ConfiguredClockSpeed)

if ($MemorySticks.Count -gt 0) {
    $MemoryTypeMap = @{ 
        "0"  = "Unknown/Onboard"; "20" = "DDR"; "21" = "DDR2"; "24" = "DDR3"; 
        "26" = "DDR4"; "30" = "DDR5"; "34" = "DDR5" 
    }

    $rawType = $MemorySticks[0].MemoryType
    if ($rawType -eq 0 -or $null -eq $rawType) { $rawType = $MemorySticks[0].SMBIOSMemoryType }
    
    $mType = if ($MemoryTypeMap["$rawType"]) { $MemoryTypeMap["$rawType"] } else { "LPDDR / Onboard" }
    Show-Row "Type" $mType $ColorValue

    foreach ($Stick in $MemorySticks) {
        $CapGB = [Math]::Round($Stick.Capacity / 1GB)
        
        # --- Physical Location Logic ---
        $Locator = if ($Stick.DeviceLocator) { $Stick.DeviceLocator.Trim() } else { "Onboard" }
        $Bank = if ($Stick.BankLabel) { $Stick.BankLabel.Trim() } else { "" }
        
        # Combine them
        $LocationDisplay = if ($Bank -and $Bank -ne $Locator) { "$Locator ($Bank)" } else { $Locator }

        # Speed Mismatch Check (Red if throttled)
        $IsThrottled = $Stick.ConfiguredClockSpeed -lt $Stick.Speed
        $SpeedColor = if ($IsThrottled) { "Red" } else { $ColorValue }
        
        # Display Row
        Show-Row "Slot/Location" "$($LocationDisplay.PadRight(18)) ($CapGB GB @ $($Stick.ConfiguredClockSpeed)MHz)" $SpeedColor
        
        if ($IsThrottled) {
            Show-Row "  Warning" "RAM rated for $($Stick.Speed)MHz" "Yellow"
        }

        if (![string]::IsNullOrWhiteSpace($Stick.PartNumber)) {
            Show-Row "  Part" "$($Stick.PartNumber.Trim())" $ColorAccent
        }
    }
} else {
    Show-Row "Status" "[!!] No physical memory data returned" "Yellow"
}

# --- Display Adapters ---
Show-Header "Display Adapters"
$gpus = Get-CimOrWmiInstance -ClassName Win32_VideoController |
    Where-Object {
        $name = $_.Name -replace '\s+', ' '
        $name -match '(?i)(AMD|Radeon|Mesa|Intel|GeForce|RTX|NVIDIA|Quadro|Titan|GTX|GT|MX|Arc|Iris|UHD|HD Graphics|Radeon|RX|Vega|Navi|RDNA)' -and
        $name -notmatch '(?i)(Microsoft Basic|Standard|Generic|Virtual|Remote|Software|WDDM)'
    }

foreach ($gpu in $gpus) {
    $vramGB = if ($gpu.AdapterRAM) { [math]::Round($gpu.AdapterRAM / 1GB, 2) } else { 0 }
    $resolution = ""
    if ($gpu.CurrentHorizontalResolution -gt 0 -and $gpu.CurrentVerticalResolution -gt 0) {
        $resolution = "$($gpu.CurrentHorizontalResolution) x $($gpu.CurrentVerticalResolution)"
    }
    
    Show-Row "- Name" "$($gpu.Name)" $ColorValue
    Show-Row "  DriverVersion" "$($gpu.DriverVersion)" $ColorAccent
    Show-Row "  Resolution" "$resolution" $ColorAccent
    Show-Row "  VRAM" "$vramGB GB" $ColorAccent
}

# --- Screen ---
Show-Header "Screen"
$monitors = Get-CimOrWmiInstance -Namespace root\wmi -ClassName WmiMonitorBasicDisplayParams
if ($monitors) {
    foreach ($monitor in $monitors) {
        $widthCm = $monitor.MaxHorizontalImageSize
        $heightCm = $monitor.MaxVerticalImageSize
        if ($widthCm -gt 0 -and $heightCm -gt 0) {
            $diagonalInches = [Math]::Round(([Math]::Sqrt([Math]::Pow($widthCm, 2) + [Math]::Pow($heightCm, 2)) / 2.54), 1)
            Show-Row "Monitor" "$widthCm x $heightCm cm ($diagonalInches inches)" $ColorValue
        }
    }
} else {
    Show-Row "Monitor" "Not Detected" "Red"
}

# --- External Management (Autopilot/MDM) ---
Show-Header "External Management"
$autopilotKey = "HKLM:\SOFTWARE\Microsoft\Provisioning\Diagnostics\Autopilot"
$mdmKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MDM"
$tenantDomain = ""
$isLocked = 0

if (Test-Path $autopilotKey) {
    $tenantDomain = (Get-ItemProperty -Path $autopilotKey -ErrorAction SilentlyContinue).CloudAssignedTenantDomain
}
if (Test-Path $mdmKey) {
    $isLocked = (Get-ItemProperty -Path $mdmKey -Name "EnrollmentLocked" -ErrorAction SilentlyContinue).EnrollmentLocked
}

if (![string]::IsNullOrWhiteSpace($tenantDomain)) {
    Show-Row "Autopilot" "[!!] ENROLLED to: $($tenantDomain.ToUpper())" "Red"
    if ($isLocked -eq 1) { Show-Row "Security" "[!!] Enrollment is LOCKED." "Yellow" }
} else {
    Show-Row "Autopilot" "[OK] No Profile Detected" "Green"
}

# --- Bitlocker ---
Show-Header "Bitlocker"
if ($isAdmin) {
    $blv = Get-BitLockerVolume -MountPoint "C:" -ErrorAction SilentlyContinue
    if ($blv) {
        if ($blv.VolumeStatus -eq "FullyDecrypted") {
            Show-Row "Status" "[OK] C: is fully decrypted" "Green"
        } elseif ($blv.VolumeStatus -eq "DecryptionInProgress") {
            Show-Row "Status" "[!!] Decryption in progress ($($blv.EncryptionPercentage)%)" "Yellow"
        } else {
            Show-Row "Status" "[!!] Encryption detected. Initiating decryption..." "Red"
            Disable-BitLocker -MountPoint "C:" -ErrorAction SilentlyContinue | Out-Null
        }
    } else {
         Show-Row "Status" "Not Enabled / No Volume Found" "Green"
    }
} else {
    Show-Row "Status" "Admin rights required for BitLocker check" $ColorAccent
}

# --- Storage ---
Show-Header "Storage (Local SSDs)"
$Disks = Get-PhysicalDisk | Where-Object MediaType -eq 'SSD'

if (-not $Disks) {
    Show-Row "Status" "No SSDs found on this system." "Yellow"
} else {
    foreach ($Disk in $Disks) {
        $SizeGB = [math]::Round($Disk.Size / 1GB, 2)
        $AllocatedGB = [math]::Round($Disk.AllocatedSize / 1GB, 2)
        $AllocatedPct = if ($Disk.Size -gt 0) { [math]::Round(($Disk.AllocatedSize / $Disk.Size) * 100, 1) } else { 0 }
        $UnallocatedPct = 100 - $AllocatedPct
        $AllocColor = if ($UnallocatedPct -lt 5) { $ColorValue } else { "Red" }

        Show-Row "Drive" "$($Disk.FriendlyName)" $ColorValue
        Show-Row "  Status" "$($Disk.OperationalStatus) | Health: $($Disk.HealthStatus) | Size: $SizeGB GB" $ColorAccent
        Show-Row "  Allocation" "$AllocatedGB GB Allocated ($UnallocatedPct% Unallocated Raw Space)" $AllocColor

        if ($isAdmin) {
            $Counter = $Disk | Get-StorageReliabilityCounter -ErrorAction SilentlyContinue
            if ($Counter) {
                $Temp = if ($Counter.Temperature) { "$($Counter.Temperature) C°" } else { "N/A" }
                $PowerOnHours = if ($Counter.PowerOnHours) { $Counter.PowerOnHours } else { "N/A" }
                $WriteErrors = if ($null -ne $Counter.WriteErrorsTotal) { $Counter.WriteErrorsTotal } else { "0" }
                $Wear = if ($null -ne $Counter.Wear) { "$($Counter.Wear)%" } else { "N/A" }
                Show-Row "  Metrics" "Temp: $Temp | Power On Hours: $PowerOnHours | Write Errors: $WriteErrors | Wear: $Wear" $ColorAccent
            } else {
                Show-Row "  Metrics" "SMART/Reliability data not supported by driver." $ColorAccent
            }
        }
    }
}

# --- Battery & Voltage ---
Show-Header "Battery & Voltage"
$Battery = Get-CimOrWmiInstance -ClassName Win32_Battery -Property DesignCapacity, FullChargeCapacity, DeviceID, Name, EstimatedChargeRemaining, DesignVoltage -First

if ($Battery) {
    $WMIHealthPct = 0
    if ($Battery.DesignCapacity -gt 0) {
        $WMIHealthPct = [Math]::Round(($Battery.FullChargeCapacity / $Battery.DesignCapacity) * 100, 0)
    }
    
    $Source = "WMI"

    # XML Fallback
    if ($WMIHealthPct -eq 0) {
        $TempFile = "$env:TEMP\battery-report.xml"
        powercfg /batteryreport /XML /OUTPUT "$TempFile" | Out-Null
        try {
            [xml]$BatteryReport = Get-Content -Path $TempFile -ErrorAction SilentlyContinue
            Remove-Item -Path $TempFile -Force -ErrorAction SilentlyContinue
            $XMLBattery = $BatteryReport.BatteryReport.Batteries.Battery | Select-Object -First 1
            if ($XMLBattery -and $XMLBattery.DesignCapacity -gt 0) {
                $WMIHealthPct = [Math]::Round(($XMLBattery.FullChargeCapacity / $XMLBattery.DesignCapacity) * 100, 0)
                $Source = "powercfg Fallback"
            }
        } catch { }
    }
    
    Show-Row "- ID" "$($Battery.DeviceID)" $ColorValue
    Show-Row "  Name" "$($Battery.Name)" $ColorAccent
    Show-Row "  Charge" "$($Battery.EstimatedChargeRemaining)%" $ColorAccent
    
    if ($WMIHealthPct -gt 0) {
        Show-Row "  Health" "$WMIHealthPct% ($Source)" "Yellow"
    } else {
        Show-Row "  Health" "Health data unavailable" "Red"
    }

    # Voltage Check
    $bStatus = Get-CimOrWmiInstance -Namespace root\wmi -ClassName BatteryStatus -Property Voltage -First
    if ($bStatus -and $Battery.DesignVoltage) {
        $voltage = $bStatus.Voltage / 1000
        $designVoltage = $Battery.DesignVoltage / 1000
        $difference = [Math]::Abs($voltage - $designVoltage)
        $tolerance = 0.5 

        if ($difference -gt $tolerance) {
            Show-Row "  Voltage" "[!!] Deviation too high: $difference V (Design: $designVoltage V, Current: $voltage V)" "Red"
        } else {
            Show-Row "  Voltage" "$voltage V (Design: $designVoltage V)" "White"
        }
    }
} else {
    Show-Row "Status" "No battery detected." "Red"
}

# --- Network Test ---
Show-Header "Network Test"
try {
    $ping = (New-Object Net.NetworkInformation.Ping).Send("www.google.com", 2000)
    if ($ping.Status -eq "Success") {
        Show-Row "Connection" "Online ($($ping.RoundtripTime)ms)" "White"
    } else {
        Show-Row "Connection" "[!!] No Reply" "Yellow"
    }
} catch { Show-Row "Connection" "[!!] Error" "Red" }

# --- Problems Check ---
function Get-ErrorDescription {
    param ($errorCode)
    switch ($errorCode) {
        1 { "This device is not configured correctly." }
        2 { "Windows cannot load the driver for this device." }
        3 { "The driver for this device might be corrupted." }
        10 { "This device cannot start." }
        18 { "Reinstall the drivers for this device." }
        22 { "This device is disabled." }
        28 { "The drivers for this device are not installed." }
        31 { "Windows cannot load the drivers required for this device." }
        default { "Unknown error." }
    }
}

Show-Header "Device Manager Problems"
$devices = Get-CimOrWmiInstance -ClassName Win32_PnPEntity -Property Name, ConfigManagerErrorCode
$problematicDevices = $devices | Where-Object {
    $_.ConfigManagerErrorCode -ne 0 -and $_.ConfigManagerErrorCode -ne 22
}

if ($problematicDevices) {
    $problematicDevices | ForEach-Object {
        Show-Row "Device" "$($_.Name)" "Yellow"
        Show-Row "  Error Code" "$($_.ConfigManagerErrorCode) - $(Get-ErrorDescription $_.ConfigManagerErrorCode)" "Yellow"
        Write-Host " -------------------------------------------------" -ForegroundColor DarkGray
    }
} else {
    Show-Row "Status" "All devices are functioning properly" "Green"
}

# --- HP Software Check ---
Show-Header "Bloatware Check"
$manufacturer = if ($System.Manufacturer) { $System.Manufacturer } else { "Unknown" }

if ($manufacturer -notmatch "\bHP\b|Hewlett-Packard|Hewlett Packard") {
    Show-Row "Check" "$manufacturer Detected, Checking for residual HP software..." $ColorAccent

    $registryPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )

    $hpSoftware = Get-ItemProperty -Path $registryPaths -ErrorAction SilentlyContinue |
        Where-Object {
            ($_.DisplayName -match "\bHP\b|Hewlett-Packard|Hewlett Packard") -or
            ($_.Publisher -match "\bHP\b|Hewlett-Packard|Hewlett Packard")
        } | Select-Object -ExpandProperty DisplayName -Unique | Where-Object { ![string]::IsNullOrWhiteSpace($_) }

    if ($hpSoftware) {
        Show-Row "Status" "[!!] HP software found on a non-HP system!" "Red"
        foreach ($app in $hpSoftware) { Show-Row "  Found" $app "Yellow" }
    } else {
        Show-Row "Status" "No HP software found on this device." "White"
    }
} else {
     Show-Row "Status" "System is an HP. Skipping HP bloatware check." "Green"
}


# --- Software Health Report Table ---
Write-Host ""
Write-Progress -Activity "Software Check" -Status "Checking Software and winget Updates..."

function Get-DumpCount {
    $count = 0
    $paths = @("$env:LOCALAPPDATA\CrashDumps", "$env:SystemRoot\Minidump")
    foreach ($p in $paths) { if (Test-Path $p) { $count += (Get-ChildItem "$p\*.dmp" -ErrorAction SilentlyContinue).Count } }
    return $count
}

$apps = @()
$appxAvailable = $false
try {
    Import-Module Appx -ErrorAction Stop
    $apps = @(Get-AppxPackage -ErrorAction Stop)
    $appxAvailable = $true
} catch {
    # Appx unavailable on Server Core, some OEM SKUs, or restricted shells
}

$badApps = if ($appxAvailable) { ($apps | Where-Object { $_.Status -ne "Ok" }).Count } else { 0 }

$wingetData = @(winget upgrade --include-unknown --accept-source-agreements --disable-interactivity 2>$null)
$wCount = 0
$dash = $wingetData | Select-String -Pattern "^-{10,}" | Select-Object -First 1
if ($dash) { 
    for ($i = $dash.LineNumber; $i -lt $wingetData.Count; $i++) {
        if (![string]::IsNullOrWhiteSpace($wingetData[$i])) { $wCount++ }
    }
}

$sec = 0; $drv = 0
try {
    Write-Progress -Activity "Software Check" -Status " Checking Windows Updates"
    $searcher = (New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher()
    $pending = $searcher.Search("IsInstalled=0 and IsHidden=0").Updates
    foreach ($u in $pending) {
        $cats = $u.Categories | Select-Object -ExpandProperty Name
        if ($cats -match "Security") { $sec++ } elseif ($cats -match "Driver") { $drv++ }
    }
} catch {}

$dumps = Get-DumpCount
Write-Progress -Activity "Software Check" -Completed

$Report = New-Object System.Collections.Generic.List[PSObject]
$appxStatus = if (-not $appxAvailable) { "[--]" } elseif ($badApps -gt 0) { "[!!]" } else { "[OK]" }
$appxDetails = if (-not $appxAvailable) { "Appx not supported on this platform" } elseif ($badApps -gt 0) { "$badApps non-ok" } else { "All Healthy" }
$Report.Add([PSCustomObject]@{ Component="Windows Apps"; Status=$appxStatus; Total=$apps.Count; Details=$appxDetails })
$Report.Add([PSCustomObject]@{ Component="Winget"; Status=$(if($wCount -gt 0){"[!!]"}else{"[OK]"}); Total=$wCount; Details="Upgrades available" })
$Report.Add([PSCustomObject]@{ Component="Win Security"; Status=$(if($sec -gt 0){"[!!]"}else{"[OK]"}); Total=$sec; Details="Pending patches" })
$Report.Add([PSCustomObject]@{ Component="Win Drivers"; Status=$(if($drv -gt 0){"[!!]"}else{"[OK]"}); Total=$drv; Details="Pending updates" })
$Report.Add([PSCustomObject]@{ Component="System Health"; Status=$(if($dumps -gt 0){"[!!]"}else{"[OK]"}); Total=$dumps; Details=$(if($dumps -gt 0){"Crash dumps found!"}else{"No crashes"}) })

Show-Header "System Software Report"
$Report | Format-Table -AutoSize

Write-Host ""
pause