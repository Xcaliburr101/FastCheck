#Requires -Version 5.1
<#
.SYNOPSIS
    FastCheck diagnostic backend — structured data for GUI consumption.
#>

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

function Get-ErrorDescription {
    param ($ErrorCode)
    switch ($ErrorCode) {
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

function Get-DumpCount {
    $count = 0
    $paths = @("$env:LOCALAPPDATA\CrashDumps", "$env:SystemRoot\Minidump")
    foreach ($p in $paths) {
        if (Test-Path $p) {
            $count += (Get-ChildItem "$p\*.dmp" -ErrorAction SilentlyContinue).Count
        }
    }
    return $count
}

function Convert-BracketStatusToSeverity {
    param([string]$Status)
    if ($Status -match '\[\!\!\]') { return 'Error' }
    if ($Status -match '\[--\]') { return 'NotAvailable' }
    if ($Status -match '\[OK\]') { return 'OK' }
    return 'Info'
}

function Get-FastCheckContext {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
    [PSCustomObject]@{
        IsAdmin = $isAdmin
        RunAt   = Get-Date
    }
}

function Get-SystemOsInfo {
    $system = Get-CimOrWmiInstance -ClassName Win32_ComputerSystem -Property Manufacturer, Model -First
    $os = Get-CimOrWmiInstance -ClassName Win32_OperatingSystem -Property Caption, BuildNumber -First

    $licenseKey = (Get-CimOrWmiInstance -ClassName SoftwareLicensingService -Property OA3xOriginalProductKey -First).OA3xOriginalProductKey
    if ([string]::IsNullOrWhiteSpace($licenseKey)) {
        $licenseKey = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SoftwareProtectionPlatform" -ErrorAction SilentlyContinue).BackupProductKeyDefault
    }

    $displayVersion = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -ErrorAction SilentlyContinue).DisplayVersion

    [PSCustomObject]@{
        Manufacturer   = $system.Manufacturer
        Model          = $system.Model
        SystemDisplay  = "$($system.Manufacturer) $($system.Model)".Trim()
        LicenseKey     = $licenseKey
        OsCaption      = $os.Caption
        BuildNumber    = $os.BuildNumber
        OsDisplay      = "$($os.Caption) (Build $($os.BuildNumber))"
        DisplayVersion = $displayVersion
        Severity       = 'Info'
    }
}

function Get-CpuInfo {
    $cpu = Get-CimOrWmiInstance -ClassName Win32_Processor -Property Name, NumberOfCores, NumberOfLogicalProcessors -First

    $thermalZones = Get-CimOrWmiInstance -Namespace 'root\cimv2' -ClassName Win32_PerfFormattedData_Counters_ThermalZoneInformation
    $maxTemp = 0
    foreach ($zone in $thermalZones) {
        $currentTemp = [math]::Round($zone.HighPrecisionTemperature / 100.0, 1)
        if ($currentTemp -gt $maxTemp) { $maxTemp = $currentTemp }
    }

    $tempSeverity = 'NotAvailable'
    $tempDisplay = 'Not Reported'
    if ($maxTemp -gt 0) {
        $tempDisplay = "$maxTemp °C"
        if ($maxTemp -gt 85) { $tempSeverity = 'Error' }
        elseif ($maxTemp -gt 70) { $tempSeverity = 'Warning' }
        else { $tempSeverity = 'OK' }
    }

    [PSCustomObject]@{
        Name                  = if ($cpu.Name) { $cpu.Name.Trim() } else { $null }
        NumberOfCores         = $cpu.NumberOfCores
        NumberOfLogicalProcessors = $cpu.NumberOfLogicalProcessors
        CoresDisplay          = "$($cpu.NumberOfCores) (Logical: $($cpu.NumberOfLogicalProcessors))"
        TemperatureC          = if ($maxTemp -gt 0) { $maxTemp } else { $null }
        TemperatureDisplay    = $tempDisplay
        TemperatureSeverity   = $tempSeverity
        Severity              = $tempSeverity
    }
}

function Get-BiosInfo {
    $bios = Get-CimOrWmiInstance -ClassName Win32_BIOS -Property Manufacturer, Name, SerialNumber -First
    [PSCustomObject]@{
        Manufacturer  = $bios.Manufacturer
        Name          = $bios.Name
        VersionDisplay = "$($bios.Manufacturer) $($bios.Name)".Trim()
        SerialNumber  = $bios.SerialNumber
        Severity      = 'Info'
    }
}

function Get-MemoryInfo {
    $memorySticks = @(Get-CimOrWmiInstance -ClassName Win32_PhysicalMemory -Property MemoryType, SMBIOSMemoryType, Capacity, DeviceLocator, BankLabel, Speed, PartNumber, ConfiguredClockSpeed)

    if ($memorySticks.Count -eq 0) {
        return [PSCustomObject]@{
            MemoryType     = $null
            Sticks         = @()
            Status         = 'No physical memory data returned'
            Severity       = 'Warning'
        }
    }

    $memoryTypeMap = @{
        "0"  = "Unknown/Onboard"; "20" = "DDR"; "21" = "DDR2"; "24" = "DDR3"
        "26" = "DDR4"; "30" = "DDR5"; "34" = "DDR5"
    }

    $rawType = $memorySticks[0].MemoryType
    if ($rawType -eq 0 -or $null -eq $rawType) { $rawType = $memorySticks[0].SMBIOSMemoryType }
    $mType = if ($memoryTypeMap["$rawType"]) { $memoryTypeMap["$rawType"] } else { "LPDDR / Onboard" }

    $sticks = foreach ($stick in $memorySticks) {
        $capGB = [Math]::Round($stick.Capacity / 1GB)
        $locator = if ($stick.DeviceLocator) { $stick.DeviceLocator.Trim() } else { "Onboard" }
        $bank = if ($stick.BankLabel) { $stick.BankLabel.Trim() } else { "" }
        $locationDisplay = if ($bank -and $bank -ne $locator) { "$locator ($bank)" } else { $locator }
        $isThrottled = $stick.ConfiguredClockSpeed -lt $stick.Speed

        [PSCustomObject]@{
            Location           = $locationDisplay
            CapacityGB         = $capGB
            ConfiguredClockMHz = $stick.ConfiguredClockSpeed
            RatedClockMHz      = $stick.Speed
            SlotDisplay        = "$($locationDisplay.PadRight(18)) ($capGB GB @ $($stick.ConfiguredClockSpeed)MHz)"
            PartNumber         = if (![string]::IsNullOrWhiteSpace($stick.PartNumber)) { $stick.PartNumber.Trim() } else { $null }
            IsThrottled        = $isThrottled
            ThrottleWarning    = if ($isThrottled) { "RAM rated for $($stick.Speed)MHz" } else { $null }
            Severity           = if ($isThrottled) { 'Error' } else { 'OK' }
        }
    }

    $overallSeverity = if (($sticks | Where-Object { $_.IsThrottled }).Count -gt 0) { 'Warning' } else { 'OK' }

    [PSCustomObject]@{
        MemoryType = $mType
        Sticks     = @($sticks)
        Severity   = $overallSeverity
    }
}

function Get-DisplayAdapterInfo {
    $gpus = @(Get-CimOrWmiInstance -ClassName Win32_VideoController |
        Where-Object {
            $name = $_.Name -replace '\s+', ' '
            $name -match '(?i)(AMD|Radeon|Mesa|Intel|GeForce|RTX|NVIDIA|Quadro|Titan|GTX|GT|MX|Arc|Iris|UHD|HD Graphics|Radeon|RX|Vega|Navi|RDNA)' -and
            $name -notmatch '(?i)(Microsoft Basic|Standard|Generic|Virtual|Remote|Software|WDDM)'
        })

    foreach ($gpu in $gpus) {
        $vramGB = if ($gpu.AdapterRAM) { [math]::Round($gpu.AdapterRAM / 1GB, 2) } else { 0 }
        $resolution = ""
        if ($gpu.CurrentHorizontalResolution -gt 0 -and $gpu.CurrentVerticalResolution -gt 0) {
            $resolution = "$($gpu.CurrentHorizontalResolution) x $($gpu.CurrentVerticalResolution)"
        }

        [PSCustomObject]@{
            Name           = $gpu.Name
            DriverVersion  = $gpu.DriverVersion
            Resolution     = $resolution
            VramGB         = $vramGB
            VramDisplay    = "$vramGB GB"
            Severity       = 'Info'
        }
    }
}

function Get-ScreenInfo {
    $monitors = @(Get-CimOrWmiInstance -Namespace root\wmi -ClassName WmiMonitorBasicDisplayParams)

    if ($monitors.Count -eq 0) {
        return @([PSCustomObject]@{
            WidthCm          = $null
            HeightCm         = $null
            DiagonalInches   = $null
            Display          = 'Not Detected'
            Severity         = 'Error'
        })
    }

    $results = @()
    foreach ($monitor in $monitors) {
        $widthCm = $monitor.MaxHorizontalImageSize
        $heightCm = $monitor.MaxVerticalImageSize
        if ($widthCm -gt 0 -and $heightCm -gt 0) {
            $diagonalInches = [Math]::Round(([Math]::Sqrt([Math]::Pow($widthCm, 2) + [Math]::Pow($heightCm, 2)) / 2.54), 1)
            $results += [PSCustomObject]@{
                WidthCm        = $widthCm
                HeightCm       = $heightCm
                DiagonalInches = $diagonalInches
                Display        = "$widthCm x $heightCm cm ($diagonalInches inches)"
                Severity       = 'OK'
            }
        }
    }

    if ($results.Count -eq 0) {
        return @([PSCustomObject]@{
            Display  = 'Not Detected'
            Severity = 'Error'
        })
    }
    return $results
}

function Get-ExternalManagementInfo {
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
        $severity = 'Error'
        $autopilotStatus = "ENROLLED to: $($tenantDomain.ToUpper())"
    } else {
        $severity = 'OK'
        $autopilotStatus = 'No Profile Detected'
    }

    [PSCustomObject]@{
        TenantDomain       = $tenantDomain
        AutopilotStatus    = $autopilotStatus
        EnrollmentLocked   = ($isLocked -eq 1)
        EnrollmentLockNote = if ($isLocked -eq 1) { 'Enrollment is LOCKED.' } else { $null }
        Severity           = $severity
    }
}

function Get-BitLockerInfo {
    param(
        [bool]$IsAdmin,
        [scriptblock]$OnBitLockerConfirm
    )

    if (-not $IsAdmin) {
        return [PSCustomObject]@{
            Status              = 'Admin rights required for BitLocker check'
            VolumeStatus        = $null
            EncryptionPercentage = $null
            ActionTaken         = 'None'
            Severity            = 'Info'
        }
    }

    $blv = Get-BitLockerVolume -MountPoint "C:" -ErrorAction SilentlyContinue
    if (-not $blv) {
        return [PSCustomObject]@{
            Status              = 'Not Enabled / No Volume Found'
            VolumeStatus        = $null
            EncryptionPercentage = $null
            ActionTaken         = 'None'
            Severity            = 'OK'
        }
    }

    if ($blv.VolumeStatus -eq 'FullyDecrypted') {
        return [PSCustomObject]@{
            Status              = 'C: is fully decrypted'
            VolumeStatus        = $blv.VolumeStatus
            EncryptionPercentage = $blv.EncryptionPercentage
            ActionTaken         = 'None'
            Severity            = 'OK'
        }
    }

    if ($blv.VolumeStatus -eq 'DecryptionInProgress') {
        return [PSCustomObject]@{
            Status              = "Decryption in progress ($($blv.EncryptionPercentage)%)"
            VolumeStatus        = $blv.VolumeStatus
            EncryptionPercentage = $blv.EncryptionPercentage
            ActionTaken         = 'AlreadyDecrypting'
            Severity            = 'Warning'
        }
    }

    $confirmed = $false
    if ($OnBitLockerConfirm) {
        $confirmed = [bool](& $OnBitLockerConfirm)
    }

    if ($confirmed) {
        Disable-BitLocker -MountPoint "C:" -ErrorAction SilentlyContinue | Out-Null
        return [PSCustomObject]@{
            Status              = 'Encryption detected. Decryption initiated.'
            VolumeStatus        = $blv.VolumeStatus
            EncryptionPercentage = $blv.EncryptionPercentage
            ActionTaken         = 'DecryptInitiated'
            Severity            = 'Error'
        }
    }

    return [PSCustomObject]@{
        Status              = 'Encryption detected. User declined decryption.'
        VolumeStatus        = $blv.VolumeStatus
        EncryptionPercentage = $blv.EncryptionPercentage
        ActionTaken         = 'None'
        Severity            = 'Error'
    }
}

function Get-SecureBootInfo {
    param([bool]$IsAdmin)

    if (-not $IsAdmin) {
        return [PSCustomObject]@{
            Enabled  = $null
            Status   = 'Admin rights required for Secure Boot check'
            Severity = 'Info'
        }
    }

    try {
        $enabled = Confirm-SecureBootUEFI
        [PSCustomObject]@{
            Enabled  = $enabled
            Status   = if ($enabled) { 'Secure Boot is enabled' } else { 'Secure Boot is disabled' }
            Severity = if ($enabled) { 'OK' } else { 'Warning' }
        }
    } catch {
        [PSCustomObject]@{
            Enabled  = $null
            Status   = $_.Exception.Message
            Severity = 'NotAvailable'
        }
    }
}

function Get-StorageInfo {
    param([bool]$IsAdmin)

    $disks = @(Get-PhysicalDisk | Where-Object MediaType -eq 'SSD')

    if ($disks.Count -eq 0) {
        return @([PSCustomObject]@{
            FriendlyName     = $null
            Status           = 'No SSDs found on this system.'
            Severity         = 'Warning'
        })
    }

    foreach ($disk in $disks) {
        $sizeGB = [math]::Round($disk.Size / 1GB, 2)
        $allocatedGB = [math]::Round($disk.AllocatedSize / 1GB, 2)
        $allocatedPct = if ($disk.Size -gt 0) { [math]::Round(($disk.AllocatedSize / $disk.Size) * 100, 1) } else { 0 }
        $unallocatedPct = 100 - $allocatedPct
        $allocSeverity = if ($unallocatedPct -lt 5) { 'OK' } else { 'Error' }

        $metrics = $null
        $metricsNote = $null
        if ($IsAdmin) {
            $counter = $disk | Get-StorageReliabilityCounter -ErrorAction SilentlyContinue
            if ($counter) {
                $temp = if ($counter.Temperature) { "$($counter.Temperature) C°" } else { "N/A" }
                $powerOnHours = if ($counter.PowerOnHours) { $counter.PowerOnHours } else { "N/A" }
                $writeErrors = if ($null -ne $counter.WriteErrorsTotal) { $counter.WriteErrorsTotal } else { "0" }
                $wear = if ($null -ne $counter.Wear) { "$($counter.Wear)%" } else { "N/A" }
                $metrics = "Temp: $temp | Power On Hours: $powerOnHours | Write Errors: $writeErrors | Wear: $wear"
            } else {
                $metricsNote = 'SMART/Reliability data not supported by driver.'
            }
        } else {
            $metricsNote = 'Admin rights required for reliability metrics.'
        }

        [PSCustomObject]@{
            FriendlyName       = $disk.FriendlyName
            OperationalStatus  = $disk.OperationalStatus
            HealthStatus       = $disk.HealthStatus
            SizeGB             = $sizeGB
            StatusDisplay      = "$($disk.OperationalStatus) | Health: $($disk.HealthStatus) | Size: $sizeGB GB"
            AllocatedGB        = $allocatedGB
            UnallocatedPct     = $unallocatedPct
            AllocationDisplay  = "$allocatedGB GB Allocated ($unallocatedPct% Unallocated Raw Space)"
            AllocationSeverity = $allocSeverity
            Metrics            = $metrics
            MetricsNote        = $metricsNote
            Severity           = $allocSeverity
        }
    }
}

function Get-BatteryInfo {
    $battery = Get-CimOrWmiInstance -ClassName Win32_Battery -Property DesignCapacity, FullChargeCapacity, DeviceID, Name, EstimatedChargeRemaining, DesignVoltage -First

    if (-not $battery) {
        return [PSCustomObject]@{
            Detected           = $false
            Status             = 'No battery detected.'
            Severity           = 'Error'
        }
    }

    $wmiHealthPct = 0
    if ($battery.DesignCapacity -gt 0) {
        $wmiHealthPct = [Math]::Round(($battery.FullChargeCapacity / $battery.DesignCapacity) * 100, 0)
    }

    $source = 'WMI'
    if ($wmiHealthPct -eq 0) {
        $tempFile = "$env:TEMP\battery-report.xml"
        powercfg /batteryreport /XML /OUTPUT "$tempFile" | Out-Null
        try {
            [xml]$batteryReport = Get-Content -Path $tempFile -ErrorAction SilentlyContinue
            Remove-Item -Path $tempFile -Force -ErrorAction SilentlyContinue
            $xmlBattery = $batteryReport.BatteryReport.Batteries.Battery | Select-Object -First 1
            if ($xmlBattery -and $xmlBattery.DesignCapacity -gt 0) {
                $wmiHealthPct = [Math]::Round(($xmlBattery.FullChargeCapacity / $xmlBattery.DesignCapacity) * 100, 0)
                $source = 'powercfg Fallback'
            }
        } catch { }
    }

    $healthSeverity = if ($wmiHealthPct -gt 0) { 'Warning' } else { 'Error' }
    $healthDisplay = if ($wmiHealthPct -gt 0) { "$wmiHealthPct% ($source)" } else { 'Health data unavailable' }

    $voltageDisplay = $null
    $voltageSeverity = 'Info'
    $bStatus = Get-CimOrWmiInstance -Namespace root\wmi -ClassName BatteryStatus -Property Voltage -First
    if ($bStatus -and $battery.DesignVoltage) {
        $voltage = $bStatus.Voltage / 1000
        $designVoltage = $battery.DesignVoltage / 1000
        $difference = [Math]::Abs($voltage - $designVoltage)
        $tolerance = 0.5

        if ($difference -gt $tolerance) {
            $voltageDisplay = "Deviation too high: $difference V (Design: $designVoltage V, Current: $voltage V)"
            $voltageSeverity = 'Error'
        } else {
            $voltageDisplay = "$voltage V (Design: $designVoltage V)"
            $voltageSeverity = 'OK'
        }
    }

    [PSCustomObject]@{
        Detected              = $true
        DeviceID              = $battery.DeviceID
        Name                  = $battery.Name
        ChargePercent         = $battery.EstimatedChargeRemaining
        HealthPercent         = if ($wmiHealthPct -gt 0) { $wmiHealthPct } else { $null }
        HealthSource          = $source
        HealthDisplay         = $healthDisplay
        HealthSeverity        = $healthSeverity
        VoltageDisplay        = $voltageDisplay
        VoltageSeverity       = $voltageSeverity
        Severity              = if ($voltageSeverity -eq 'Error' -or $healthSeverity -eq 'Error') { 'Error' } else { 'Warning' }
    }
}

function Test-NetworkConnectivity {
    try {
        $ping = (New-Object Net.NetworkInformation.Ping).Send("www.google.com", 2000)
        if ($ping.Status -eq "Success") {
            [PSCustomObject]@{
                Online          = $true
                RoundtripMs     = $ping.RoundtripTime
                Status          = "Online ($($ping.RoundtripTime)ms)"
                Severity        = 'OK'
            }
        } else {
            [PSCustomObject]@{
                Online      = $false
                Status      = 'No Reply'
                Severity    = 'Warning'
            }
        }
    } catch {
        [PSCustomObject]@{
            Online   = $false
            Status   = 'Error'
            Severity = 'Error'
        }
    }
}

function Get-DeviceManagerProblems {
    $devices = @(Get-CimOrWmiInstance -ClassName Win32_PnPEntity -Property Name, ConfigManagerErrorCode)
    $problematic = @($devices | Where-Object {
        $_.ConfigManagerErrorCode -ne 0 -and $_.ConfigManagerErrorCode -ne 22
    })

    if ($problematic.Count -eq 0) {
        return [PSCustomObject]@{
            Devices  = @()
            Status   = 'All devices are functioning properly'
            Severity = 'OK'
        }
    }

    $deviceList = foreach ($d in $problematic) {
        [PSCustomObject]@{
            Name        = $d.Name
            ErrorCode   = $d.ConfigManagerErrorCode
            ErrorText   = Get-ErrorDescription $d.ConfigManagerErrorCode
            Severity    = 'Warning'
        }
    }

    [PSCustomObject]@{
        Devices  = @($deviceList)
        Status   = "$($deviceList.Count) problematic device(s)"
        Severity = 'Warning'
    }
}

function Get-HpBloatwareCheck {
    param([string]$Manufacturer)

    $manufacturer = if ($Manufacturer) { $Manufacturer } else { 'Unknown' }

    if ($manufacturer -match "\bHP\b|Hewlett-Packard|Hewlett Packard") {
        return [PSCustomObject]@{
            Skipped      = $true
            Manufacturer = $manufacturer
            Status       = 'System is an HP. Skipping HP bloatware check.'
            FoundApps    = @()
            Severity     = 'OK'
        }
    }

    $registryPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )

    $hpSoftware = @(Get-ItemProperty -Path $registryPaths -ErrorAction SilentlyContinue |
        Where-Object {
            ($_.DisplayName -match "\bHP\b|Hewlett-Packard|Hewlett Packard") -or
            ($_.Publisher -match "\bHP\b|Hewlett-Packard|Hewlett Packard")
        } | Select-Object -ExpandProperty DisplayName -Unique |
        Where-Object { ![string]::IsNullOrWhiteSpace($_) })

    if ($hpSoftware.Count -gt 0) {
        return [PSCustomObject]@{
            Skipped      = $false
            Manufacturer = $manufacturer
            Status       = 'HP software found on a non-HP system!'
            FoundApps    = $hpSoftware
            Severity     = 'Error'
        }
    }

    [PSCustomObject]@{
        Skipped      = $false
        Manufacturer = $manufacturer
        Status       = 'No HP software found on this device.'
        FoundApps    = @()
        Severity     = 'OK'
    }
}

function Invoke-WithTimeout {
    param(
        [Parameter(Mandatory)]
        [scriptblock]$JobScript,
        [int]$TimeoutSeconds = 25
    )
    $job = Start-Job -ScriptBlock $JobScript
    $completed = Wait-Job -Job $job -Timeout $TimeoutSeconds
    if (-not $completed) {
        Stop-Job -Job $job -ErrorAction SilentlyContinue
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        return [PSCustomObject]@{ TimedOut = $true; Result = $null }
    }
    $result = Receive-Job -Job $job -ErrorAction SilentlyContinue
    Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    [PSCustomObject]@{ TimedOut = $false; Result = $result }
}

function Get-AppxHealthInfo {
    $apps = @()
    $appxAvailable = $false
    try {
        Import-Module Appx -ErrorAction Stop
        $apps = @(Get-AppxPackage -ErrorAction Stop)
        $appxAvailable = $true
    } catch { }

    $badApps = if ($appxAvailable) { ($apps | Where-Object { $_.Status -ne 'Ok' }).Count } else { 0 }
    $appxStatus = if (-not $appxAvailable) { '[--]' } elseif ($badApps -gt 0) { '[!!]' } else { '[OK]' }
    $appxDetails = if (-not $appxAvailable) { 'Appx not supported on this platform' } elseif ($badApps -gt 0) { "$badApps non-ok" } else { 'All Healthy' }

    [PSCustomObject]@{
        Component = 'Windows Apps'
        Status    = $appxStatus
        Total     = $apps.Count
        Details   = $appxDetails
        Severity  = Convert-BracketStatusToSeverity $appxStatus
    }
}

function Get-WingetUpgradeInfo {
    $wingetData = @(winget upgrade --include-unknown --accept-source-agreements --disable-interactivity 2>$null)
    $wCount = 0
    $dash = $wingetData | Select-String -Pattern '^-{10,}' | Select-Object -First 1
    if ($dash) {
        for ($i = $dash.LineNumber; $i -lt $wingetData.Count; $i++) {
            if (![string]::IsNullOrWhiteSpace($wingetData[$i])) { $wCount++ }
        }
    }
    [PSCustomObject]@{
        Component = 'Winget'
        Status    = if ($wCount -gt 0) { '[!!]' } else { '[OK]' }
        Total     = $wCount
        Details   = 'Upgrades available'
        Severity  = if ($wCount -gt 0) { 'Error' } else { 'OK' }
    }
}

function Get-WindowsUpdatePendingInfo {
    $sec = 0
    $drv = 0
    $searcher = (New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher()
    $pending = $searcher.Search('IsInstalled=0 and IsHidden=0').Updates
    foreach ($u in $pending) {
        $cats = $u.Categories | Select-Object -ExpandProperty Name
        if ($cats -match 'Security') { $sec++ }
        elseif ($cats -match 'Driver') { $drv++ }
    }
    @(
        [PSCustomObject]@{
            Component = 'Win Security'
            Status    = if ($sec -gt 0) { '[!!]' } else { '[OK]' }
            Total     = $sec
            Details   = 'Pending patches'
            Severity  = if ($sec -gt 0) { 'Error' } else { 'OK' }
        },
        [PSCustomObject]@{
            Component = 'Win Drivers'
            Status    = if ($drv -gt 0) { '[!!]' } else { '[OK]' }
            Total     = $drv
            Details   = 'Pending updates'
            Severity  = if ($drv -gt 0) { 'Error' } else { 'OK' }
        }
    )
}

function Get-CrashDumpHealthInfo {
    $dumps = Get-DumpCount
    [PSCustomObject]@{
        Component = 'System Health'
        Status    = if ($dumps -gt 0) { '[!!]' } else { '[OK]' }
        Total     = $dumps
        Details   = if ($dumps -gt 0) { 'Crash dumps found!' } else { 'No crashes' }
        Severity  = if ($dumps -gt 0) { 'Error' } else { 'OK' }
    }
}

function Get-SkippedSoftwareRow {
    param([string]$Component)
    [PSCustomObject]@{
        Component = $Component
        Status    = '[--]'
        Total     = 0
        Details   = 'Skipped (Quick Scan)'
        Severity  = 'NotAvailable'
    }
}

function Get-SoftwareHealthInfo {
    param(
        [ValidateSet('Quick', 'Full')]
        [string]$ScanMode = 'Quick',
        [scriptblock]$OnLogLine
    )

    $log = {
        param($msg)
        if ($OnLogLine) { & $OnLogLine $msg 'Info' }
    }

    $rowList = [System.Collections.Generic.List[object]]::new()

    & $log 'Software: checking Windows Apps (Appx)...'
    $appxResult = Invoke-WithTimeout -JobScript { Get-AppxHealthInfo } -TimeoutSeconds 20
    if ($appxResult.TimedOut) {
        & $log 'Software: Appx check timed out after 20s'
        [void]$rowList.Add([PSCustomObject]@{
            Component = 'Windows Apps'; Status = '[--]'; Total = 0
            Details = 'Timed out after 20s'; Severity = 'Warning'
        })
    } else {
        [void]$rowList.Add($appxResult.Result)
        & $log 'Software: Appx check complete'
    }

    if ($ScanMode -eq 'Quick') {
        [void]$rowList.Add((Get-SkippedSoftwareRow -Component 'Winget'))
        [void]$rowList.Add((Get-SkippedSoftwareRow -Component 'Win Security'))
        [void]$rowList.Add((Get-SkippedSoftwareRow -Component 'Win Drivers'))
        & $log 'Software: winget and Windows Update skipped (Quick Scan)'
    } else {
        & $log 'Software: starting winget, Windows Update (parallel)...'
        $wingetJob = Start-Job -ScriptBlock { Get-WingetUpgradeInfo }
        $wuJob = Start-Job -ScriptBlock {
            try { Get-WindowsUpdatePendingInfo } catch { @() }
        }

        $wingetWait = Wait-Job -Job $wingetJob -Timeout 25
        if ($wingetWait) {
            $wingetRow = Receive-Job -Job $wingetJob
            Remove-Job -Job $wingetJob -Force
            [void]$rowList.Add($wingetRow)
            & $log 'Software: winget check complete'
        } else {
            Stop-Job -Job $wingetJob -ErrorAction SilentlyContinue
            Remove-Job -Job $wingetJob -Force -ErrorAction SilentlyContinue
            & $log 'Software: winget timed out after 25s'
            [void]$rowList.Add([PSCustomObject]@{
                Component = 'Winget'; Status = '[--]'; Total = 0
                Details = 'Timed out after 25s'; Severity = 'Warning'
            })
        }

        $wuWait = Wait-Job -Job $wuJob -Timeout 45
        if ($wuWait) {
            $wuRows = @(Receive-Job -Job $wuJob)
            Remove-Job -Job $wuJob -Force
            foreach ($r in $wuRows) { [void]$rowList.Add($r) }
            & $log 'Software: Windows Update check complete'
        } else {
            Stop-Job -Job $wuJob -ErrorAction SilentlyContinue
            Remove-Job -Job $wuJob -Force -ErrorAction SilentlyContinue
            & $log 'Software: Windows Update timed out after 45s'
            [void]$rowList.Add([PSCustomObject]@{
                Component = 'Win Security'; Status = '[--]'; Total = 0
                Details = 'Timed out after 45s'; Severity = 'Warning'
            })
            [void]$rowList.Add([PSCustomObject]@{
                Component = 'Win Drivers'; Status = '[--]'; Total = 0
                Details = 'Timed out after 45s'; Severity = 'Warning'
            })
        }
    }

    & $log 'Software: counting crash dumps...'
    [void]$rowList.Add((Get-CrashDumpHealthInfo))

    $rows = @($rowList)
    $overallSeverity = if (($rows | Where-Object { $_.Severity -in @('Error', 'Warning') }).Count -gt 0) { 'Warning' } else { 'OK' }

    [PSCustomObject]@{
        Rows     = $rows
        Severity = $overallSeverity
    }
}

function Get-FastCheckLogicalSectionCount {
    return 15
}

function Invoke-FastCheckDiagnostics {
    param(
        [Parameter(Mandatory)]
        $Context,
        [scriptblock]$OnProgress,
        [scriptblock]$OnBitLockerConfirm,
        [scriptblock]$OnSectionComplete,
        [scriptblock]$OnLogLine,
        [scriptblock]$ShouldCancel,
        [ValidateSet('Quick', 'Full')]
        [string]$ScanMode = 'Quick'
    )

    $errors = [System.Collections.Generic.List[string]]::new()
    $report = [ordered]@{}

    $emitSection = {
        param($Name, $Data)
        if ($null -eq $Data) { return }
        $cards = @(Convert-FastCheckSectionToCards -SectionName $Name -SectionData $Data)
        foreach ($card in $cards) {
            if ($OnSectionComplete) {
                & $OnSectionComplete $card.Title $Data $card.Rows $card.Severity
            }
        }
    }

    $invokeSection = {
        param($Name, $Script, $ReportKey)
        if ($ShouldCancel -and (& $ShouldCancel)) {
            if ($OnLogLine) { & $OnLogLine 'Scan cancelled' 'Warning' }
            return $null
        }
        if ($OnProgress) { & $OnProgress $Name }
        if ($OnLogLine) { & $OnLogLine "Starting: $Name" 'Info' }
        try {
            $result = & $Script
            $report[$ReportKey] = $result
            & $emitSection $Name $result
            if ($OnLogLine) { & $OnLogLine "Completed: $Name" 'Info' }
            return $result
        } catch {
            $errors.Add("${Name}: $($_.Exception.Message)")
            $err = [PSCustomObject]@{ Error = $_.Exception.Message; Severity = 'Error' }
            $report[$ReportKey] = $err
            & $emitSection $Name $err
            if ($OnLogLine) { & $OnLogLine "Error in ${Name}: $($_.Exception.Message)" 'Error' }
            return $err
        }
    }

    $systemOs = & $invokeSection 'System & OS' { Get-SystemOsInfo } 'SystemOs'

    $null = & $invokeSection 'CPU' { Get-CpuInfo } 'Cpu'
    $null = & $invokeSection 'BIOS' { Get-BiosInfo } 'Bios'
    $null = & $invokeSection 'Memory' { Get-MemoryInfo } 'Memory'
    $null = & $invokeSection 'Display Adapters' { @(Get-DisplayAdapterInfo) } 'DisplayAdapters'
    $null = & $invokeSection 'Screen' { @(Get-ScreenInfo) } 'Screen'
    $null = & $invokeSection 'External Management' { Get-ExternalManagementInfo } 'ExternalManagement'
    $null = & $invokeSection 'BitLocker' {
        Get-BitLockerInfo -IsAdmin $Context.IsAdmin -OnBitLockerConfirm $OnBitLockerConfirm
    } 'BitLocker'
    $null = & $invokeSection 'Secure Boot' { Get-SecureBootInfo -IsAdmin $Context.IsAdmin } 'SecureBoot'
    $null = & $invokeSection 'Storage' { @(Get-StorageInfo -IsAdmin $Context.IsAdmin) } 'Storage'
    $null = & $invokeSection 'Battery & Voltage' { Get-BatteryInfo } 'Battery'
    $null = & $invokeSection 'Network' { Test-NetworkConnectivity } 'Network'
    $null = & $invokeSection 'Device Manager' { Get-DeviceManagerProblems } 'DeviceProblems'
    $null = & $invokeSection 'Bloatware Check' {
        Get-HpBloatwareCheck -Manufacturer $systemOs.Manufacturer
    } 'HpBloatware'
    $null = & $invokeSection 'Software Health' {
        Get-SoftwareHealthInfo -ScanMode $ScanMode -OnLogLine $OnLogLine
    } 'SoftwareHealth'

    [PSCustomObject]@{
        Context  = $Context
        Report   = [PSCustomObject]$report
        Errors   = @($errors)
        ScanMode = $ScanMode
    }
}

function New-FastCheckRow {
    param($Label, $Value, $Severity = 'Info')
    if ([string]::IsNullOrWhiteSpace($Value)) { $Value = 'N/A' }
    [PSCustomObject]@{ Name = $Label; Value = [string]$Value; Severity = $Severity }
}

function Convert-FastCheckSectionToCards {
    param(
        [Parameter(Mandatory)]
        [string]$SectionName,
        $SectionData
    )

    $cards = [System.Collections.Generic.List[object]]::new()

    $addCard = {
        param($Title, $Rows, $Severity = 'Info')
        $validRows = @($Rows | Where-Object { $null -ne $_ })
        if ($validRows.Count -eq 0) { return }
        [void]$cards.Add([PSCustomObject]@{
            Title    = $Title
            Severity = $Severity
            Rows     = $validRows
        })
    }

    if ($SectionData.Error) {
        & $addCard $SectionName @(
            (New-FastCheckRow -Label 'Error' -Value $SectionData.Error -Severity 'Error')
        ) 'Error'
        return @($cards)
    }

    switch ($SectionName) {
        'System & OS' {
            & $addCard $SectionName @(
                (New-FastCheckRow 'System' $SectionData.SystemDisplay)
                (New-FastCheckRow 'Windows Licence' $SectionData.LicenseKey)
                (New-FastCheckRow 'OS' $SectionData.OsDisplay)
                (New-FastCheckRow 'Build' $SectionData.DisplayVersion)
            ) 'Info'
        }
        'CPU' {
            & $addCard $SectionName @(
                (New-FastCheckRow 'Name' $SectionData.Name)
                (New-FastCheckRow 'Cores' $SectionData.CoresDisplay)
                (New-FastCheckRow 'Temperature' $SectionData.TemperatureDisplay $SectionData.TemperatureSeverity)
            ) $SectionData.TemperatureSeverity
        }
        'BIOS' {
            & $addCard $SectionName @(
                (New-FastCheckRow 'Version' $SectionData.VersionDisplay)
                (New-FastCheckRow 'Serial' $SectionData.SerialNumber)
            ) 'Info'
        }
        'Memory' {
            $rows = @((New-FastCheckRow 'Type' $SectionData.MemoryType))
            if ($SectionData.Sticks) {
                foreach ($stick in $SectionData.Sticks) {
                    $rows += New-FastCheckRow 'Slot/Location' $stick.SlotDisplay $stick.Severity
                    if ($stick.ThrottleWarning) { $rows += New-FastCheckRow 'Warning' $stick.ThrottleWarning 'Warning' }
                    if ($stick.PartNumber) { $rows += New-FastCheckRow 'Part' $stick.PartNumber 'Info' }
                }
            } elseif ($SectionData.Status) {
                $rows += New-FastCheckRow 'Status' $SectionData.Status $SectionData.Severity
            }
            & $addCard $SectionName $rows $SectionData.Severity
        }
        'Display Adapters' {
            foreach ($gpu in @($SectionData)) {
                & $addCard "GPU: $($gpu.Name)" @(
                    (New-FastCheckRow 'Name' $gpu.Name)
                    (New-FastCheckRow 'DriverVersion' $gpu.DriverVersion)
                    (New-FastCheckRow 'Resolution' $gpu.Resolution)
                    (New-FastCheckRow 'VRAM' $gpu.VramDisplay)
                ) 'Info'
            }
        }
        'Screen' {
            foreach ($mon in @($SectionData)) {
                & $addCard 'Screen' @(
                    (New-FastCheckRow 'Monitor' $mon.Display $mon.Severity)
                ) $mon.Severity
            }
        }
        'External Management' {
            $rows = @(New-FastCheckRow 'Autopilot' $SectionData.AutopilotStatus $SectionData.Severity)
            if ($SectionData.EnrollmentLockNote) {
                $rows += New-FastCheckRow 'Security' $SectionData.EnrollmentLockNote 'Warning'
            }
            & $addCard $SectionName $rows $SectionData.Severity
        }
        'BitLocker' {
            & $addCard $SectionName @(
                (New-FastCheckRow 'Status' $SectionData.Status $SectionData.Severity)
                (New-FastCheckRow 'Action' $SectionData.ActionTaken $SectionData.Severity)
            ) $SectionData.Severity
        }
        'Secure Boot' {
            $enabled = if ($null -ne $SectionData.Enabled) { $SectionData.Enabled } else { 'N/A' }
            & $addCard $SectionName @(
                (New-FastCheckRow 'Status' $SectionData.Status $SectionData.Severity)
                (New-FastCheckRow 'Enabled' $enabled $SectionData.Severity)
            ) $SectionData.Severity
        }
        'Storage' {
            foreach ($disk in @($SectionData)) {
                if ($disk.FriendlyName) {
                    & $addCard "Drive: $($disk.FriendlyName)" @(
                        (New-FastCheckRow 'Status' $disk.StatusDisplay)
                        (New-FastCheckRow 'Allocation' $disk.AllocationDisplay $disk.AllocationSeverity)
                        (New-FastCheckRow 'Metrics' $(if ($disk.Metrics) { $disk.Metrics } else { $disk.MetricsNote }))
                    ) $disk.Severity
                } else {
                    & $addCard 'Storage' @(
                        (New-FastCheckRow 'Status' $disk.Status $disk.Severity)
                    ) $disk.Severity
                }
            }
        }
        'Battery & Voltage' {
            if ($SectionData.Detected) {
                $rows = @(
                    (New-FastCheckRow 'ID' $SectionData.DeviceID)
                    (New-FastCheckRow 'Name' $SectionData.Name)
                    (New-FastCheckRow 'Charge' "$($SectionData.ChargePercent)%")
                    (New-FastCheckRow 'Health' $SectionData.HealthDisplay $SectionData.HealthSeverity)
                )
                if ($SectionData.VoltageDisplay) {
                    $rows += New-FastCheckRow 'Voltage' $SectionData.VoltageDisplay $SectionData.VoltageSeverity
                }
                & $addCard $SectionName $rows $SectionData.Severity
            } else {
                & $addCard $SectionName @(
                    (New-FastCheckRow 'Status' $SectionData.Status $SectionData.Severity)
                ) $SectionData.Severity
            }
        }
        'Network' {
            & $addCard $SectionName @(
                (New-FastCheckRow 'Connection' $SectionData.Status $SectionData.Severity)
            ) $SectionData.Severity
        }
        'Device Manager' {
            if ($SectionData.Devices -and $SectionData.Devices.Count -gt 0) {
                $rows = @()
                foreach ($d in $SectionData.Devices) {
                    $rows += New-FastCheckRow 'Device' $d.Name $d.Severity
                    $rows += New-FastCheckRow 'Error Code' "$($d.ErrorCode) - $($d.ErrorText)" $d.Severity
                }
                & $addCard 'Device Manager Problems' $rows $SectionData.Severity
            } else {
                & $addCard 'Device Manager Problems' @(
                    (New-FastCheckRow 'Status' $SectionData.Status $SectionData.Severity)
                ) $SectionData.Severity
            }
        }
        'Bloatware Check' {
            $rows = @(New-FastCheckRow 'Status' $SectionData.Status $SectionData.Severity)
            foreach ($app in @($SectionData.FoundApps)) {
                $rows += New-FastCheckRow 'Found' $app 'Warning'
            }
            & $addCard $SectionName $rows $SectionData.Severity
        }
        'Software Health' {
            $swRows = foreach ($row in $SectionData.Rows) {
                New-FastCheckRow $row.Component "$($row.Status) | Total: $($row.Total) | $($row.Details)" $row.Severity
            }
            & $addCard $SectionName $swRows $SectionData.Severity
        }
        default {
            & $addCard $SectionName @(
                (New-FastCheckRow 'Data' ($SectionData | Out-String))
            ) 'Info'
        }
    }

    return @($cards)
}

function Convert-FastCheckReportToTreeItems {
    param($DiagnosticResult)

    $items = [System.Collections.Generic.List[object]]::new()

    $addSection = {
        param($Title, $Rows, $Severity = 'Info')
        $section = [PSCustomObject]@{
            Name     = $Title
            Value    = ''
            Severity = $Severity
            Children = [System.Collections.Generic.List[object]]::new()
        }
        foreach ($row in $Rows) {
            if ($null -eq $row) { continue }
            [void]$section.Children.Add([PSCustomObject]@{
                Name = $row.Name; Value = $row.Value; Severity = $row.Severity; Children = $null
            })
        }
        if ($section.Children.Count -gt 0) {
            [void]$items.Add($section)
        }
    }

    $r = $DiagnosticResult.Report
    $sectionMap = @(
        @{ Name = 'System & OS'; Key = 'SystemOs' }
        @{ Name = 'CPU'; Key = 'Cpu' }
        @{ Name = 'BIOS'; Key = 'Bios' }
        @{ Name = 'Memory'; Key = 'Memory' }
        @{ Name = 'Display Adapters'; Key = 'DisplayAdapters' }
        @{ Name = 'Screen'; Key = 'Screen' }
        @{ Name = 'External Management'; Key = 'ExternalManagement' }
        @{ Name = 'BitLocker'; Key = 'BitLocker' }
        @{ Name = 'Secure Boot'; Key = 'SecureBoot' }
        @{ Name = 'Storage'; Key = 'Storage' }
        @{ Name = 'Battery & Voltage'; Key = 'Battery' }
        @{ Name = 'Network'; Key = 'Network' }
        @{ Name = 'Device Manager'; Key = 'DeviceProblems' }
        @{ Name = 'Bloatware Check'; Key = 'HpBloatware' }
        @{ Name = 'Software Health'; Key = 'SoftwareHealth' }
    )

    foreach ($entry in $sectionMap) {
        $data = $r.($entry.Key)
        if ($null -eq $data) { continue }
        $cards = @(Convert-FastCheckSectionToCards -SectionName $entry.Name -SectionData $data)
        foreach ($card in $cards) {
            & $addSection $card.Title $card.Rows $card.Severity
        }
    }

    return @($items)
}
