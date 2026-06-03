#=============================================================================
#=============================================================================
# Diagnostics Triage application
# TARGETS: .NET Framework 4.8 & Windows PowerShell 5+ (No Extra Dependencies)
# DESIGN: Sleek dark-mode multi-column event-driven layout. UI does not lock up.
#=============================================================================

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms

# --- Clean existing windows if run repeatedly ---
if ($global:DiagnosticsTriageWindow) {
    try { $global:DiagnosticsTriageWindow.Close() } catch {}
}

# --- Standard diagnostic logic (safe & error caught) ---
function Get-CimOrWmiInstance {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ClassName,
        [string[]]$Property,
        [string]$Namespace = 'root\cimv2',
        [string]$Filter,
        [switch]$First
    )
    $cimParams = @{ ClassName = $ClassName }
    if ($Namespace -ne 'root\cimv2') { $cimParams.Namespace = $Namespace }
    if ($Property) { $cimParams.Property = $Property }
    if ($Filter) { $cimParams.Filter = $Filter }

    $instances = @()
    try { $instances = @(Get-CimInstance @cimParams -ErrorAction Stop) } catch {}
    if ($instances.Count -eq 0) {
        $wmiParams = @{ Class = $ClassName }
        if ($Namespace -ne 'root\cimv2') { $wmiParams.Namespace = $Namespace }
        if ($Property) { $wmiParams.Property = $Property }
        if ($Filter) { $wmiParams.Filter = $Filter }
        try { $instances = @(Get-WmiObject @wmiParams -ErrorAction Stop) } catch {}
    }
    if ($First) { return $instances | Select-Object -First 1 }
    return $instances
}

function Get-OpenHardwareMonitorData {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) { return @() }

    $loaded = $false
    if ([AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.FullName -match 'OpenHardwareMonitorLib' }) {
        $loaded = $true
    } else {
        $dllLocations = @(
            "$PSScriptRoot\OpenHardwareMonitorLib.dll",
            ".\OpenHardwareMonitorLib.dll",
            "C:\OpenHardwareMonitorLib.dll"
        )
        foreach ($loc in $dllLocations) {
            if (Test-Path $loc) {
                try {
                    Add-Type -Path $loc -ErrorAction Stop | Out-Null
                    $loaded = $true
                    break
                } catch {}
            }
        }
    }

    if (-not $loaded) { return @() }

    if ($null -eq $global:OHMComputer) {
        try {
            $global:OHMComputer = New-Object OpenHardwareMonitor.Hardware.Computer
            $global:OHMComputer.MainboardEnabled   = $true
            $global:OHMComputer.CPUEnabled         = $true
            $global:OHMComputer.RAMEnabled         = $true
            $global:OHMComputer.GPUEnabled         = $true
            $global:OHMComputer.FanControllerEnabled = $true
            $global:OHMComputer.HDDEnabled         = $true
            $global:OHMComputer.Open()
        } catch {
            $global:OHMComputer = $null
            return @()
        }
    }

    $sensorList = @()
    try {
        foreach ($hardware in $global:OHMComputer.Hardware) {
            $hardware.Update()
            foreach ($subHardware in $hardware.SubHardware) {
                $subHardware.Update()
            }
            foreach ($sensor in $hardware.Sensors) {
                if ($null -eq $sensor.Value) { continue }
                $sensorList += [PSCustomObject]@{
                    HardwareName = $hardware.Name
                    HardwareType = $hardware.HardwareType.ToString()
                    SensorName   = $sensor.Name
                    SensorType   = $sensor.SensorType.ToString()
                    Value        = $sensor.Value
                }
            }
        }
    } catch {
        try { $global:OHMComputer.Close() } catch {}
        $global:OHMComputer = $null
    }
    return $sensorList
}

function Get-ErrorDescription {
    param($errorCode)
    switch ($errorCode) {
        1  { 'This device is not configured correctly.' }
        2  { 'Windows cannot load the driver for this device.' }
        3  { 'The driver for this device might be corrupted.' }
        10 { 'This device cannot start.' }
        18 { 'Reinstall the drivers for this device.' }
        22 { 'This device is disabled.' }
        28 { 'The drivers for this device are not installed.' }
        31 { 'Windows cannot load the drivers required for this device.' }
        default { 'Unknown error.' }
    }
}

# ========== DIAGNOSTIC DATA FUNCTIONS ==========

function Get-SystemAndOSInfo {
    $sys = Get-CimOrWmiInstance -ClassName Win32_ComputerSystem -Property Manufacturer, Model -First
    $os  = Get-CimOrWmiInstance -ClassName Win32_OperatingSystem -Property Caption, BuildNumber -First

    $license = (Get-CimOrWmiInstance -ClassName SoftwareLicensingService -Property OA3xOriginalProductKey -First).OA3xOriginalProductKey
    if ([string]::IsNullOrWhiteSpace($license)) {
        $license = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SoftwareProtectionPlatform' -ErrorAction SilentlyContinue).BackupProductKeyDefault
    }
    $build = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').DisplayVersion

    $licKey = if ($license) { $license } else { 'N/A' }
    [PSCustomObject]@{
        Manufacturer = "$($sys.Manufacturer)"
        Model        = "$($sys.Model)"
        LicenseKey   = $licKey
        OS           = "$($os.Caption) (Build $($os.BuildNumber))"
        Build        = $build
    }
}

function Get-CPUInfo {
    $cpu = Get-CimOrWmiInstance -ClassName Win32_Processor -Property Name, NumberOfCores, NumberOfLogicalProcessors, LoadPercentage -First
    $thermalZones = Get-CimOrWmiInstance -Namespace 'root\cimv2' -ClassName Win32_PerfFormattedData_Counters_ThermalZoneInformation
    $maxTemp = 0
    foreach ($zone in $thermalZones) {
        $t = [math]::Round($zone.HighPrecisionTemperature / 100.0, 1)
        if ($t -gt $maxTemp) { $maxTemp = $t }
    }

    $ohmSensors = Get-OpenHardwareMonitorData
    $ohmCpuPower = $null
    $ohmCpuTotalLoad = $null
    if ($ohmSensors) {
        $cpuOhm = $ohmSensors | Where-Object { $_.HardwareType -match 'CPU' }
        if ($cpuOhm) {
            $ohmCpuTemp = ($cpuOhm | Where-Object { $_.SensorType -eq 'Temperature' -and $_.SensorName -eq 'CPU Package' } | Select-Object -First 1).Value
            if ($ohmCpuTemp -gt 0) {
                $maxTemp = [math]::Round($ohmCpuTemp, 1)
            }
            $ohmCpuPower = ($cpuOhm | Where-Object { $_.SensorType -eq 'Power' -and $_.SensorName -eq 'CPU Package' } | Select-Object -First 1).Value
            $ohmCpuTotalLoad = ($cpuOhm | Where-Object { $_.SensorType -eq 'Load' -and $_.SensorName -eq 'CPU Total' } | Select-Object -First 1).Value
        }
    }

    $tempStatus = if ($maxTemp -gt 85) { 'Critical' }
                  elseif ($maxTemp -gt 70) { 'Warning' }
                  elseif ($maxTemp -gt 0)  { 'OK' }
                  else                     { 'NotReported' }

    [PSCustomObject]@{
        Name               = $cpu.Name.Trim()
        Cores              = $cpu.NumberOfCores
        LogicalProcessors  = $cpu.NumberOfLogicalProcessors
        TemperatureC       = $maxTemp
        TemperatureStatus  = $tempStatus
        PowerW             = if ($ohmCpuPower) { [math]::Round($ohmCpuPower, 2) } else { $null }
        LoadPercent        = if ($ohmCpuTotalLoad) { [math]::Round($ohmCpuTotalLoad, 1) } else { $cpu.LoadPercentage }
    }
}

function Get-BIOSInfo {
    $bios = Get-CimOrWmiInstance -ClassName Win32_BIOS -Property Manufacturer, Name, SerialNumber -First
    [PSCustomObject]@{
        Version = "$($bios.Manufacturer) $($bios.Name)"
        Serial  = $bios.SerialNumber
    }
}

function Get-MemoryInfo {
    $sticks = @(Get-CimOrWmiInstance -ClassName Win32_PhysicalMemory -Property MemoryType, SMBIOSMemoryType, Capacity, DeviceLocator, BankLabel, Speed, PartNumber, ConfiguredClockSpeed)
    if ($sticks.Count -eq 0) {
        return [PSCustomObject]@{ Error = 'No physical memory data returned' }
    }

    $typeMap = @{
        '0'  = 'Unknown/Onboard'; '20' = 'DDR'; '21' = 'DDR2'
        '24' = 'DDR3'; '26' = 'DDR4'; '30' = 'DDR5'; '34' = 'DDR5'
    }
    $rawType = $sticks[0].MemoryType
    if ($rawType -eq 0 -or $null -eq $rawType) { $rawType = $sticks[0].SMBIOSMemoryType }
    $memoryType = if ($typeMap["$rawType"]) { $typeMap["$rawType"] } else { 'LPDDR / Onboard' }

    $result = @()
    foreach ($stick in $sticks) {
        $capGB = [math]::Round($stick.Capacity / 1GB)
        $locator = if ($stick.DeviceLocator) { $stick.DeviceLocator.Trim() } else { 'Onboard' }
        $bank    = if ($stick.BankLabel) { $stick.BankLabel.Trim() } else { '' }
        $location = if ($bank -and $bank -ne $locator) { "$locator ($bank)" } else { $locator }
        $isThrottled = $stick.ConfiguredClockSpeed -lt $stick.Speed
        $warning = if ($isThrottled) { "Rated for $($stick.Speed)MHz" } else { $null }

        $pNo = if ($stick.PartNumber) { $stick.PartNumber.Trim() } else { $null }
        $result += [PSCustomObject]@{
            Type               = $memoryType
            SlotLocation       = $location
            CapacityGB         = $capGB
            ConfiguredSpeedMHz = $stick.ConfiguredClockSpeed
            RatedSpeedMHz      = $stick.Speed
            Throttled          = $isThrottled
            Warning            = $warning
            PartNumber         = $pNo
        }
    }
    return $result
}

function Get-GPUInfo {
    # Retrieve all GPU adapters, filtered to real hardware
    $gpus = Get-CimOrWmiInstance -ClassName Win32_VideoController |
        Where-Object {
            $name = $_.Name -replace '\s+', ' '
            $name -match '(?i)(AMD|Radeon|Mesa|Intel|GeForce|RTX|NVIDIA|Quadro|Titan|GTX|GT|MX|Arc|Iris|UHD|HD Graphics|Radeon|RX|Vega|Navi|RDNA)' -and
            $name -notmatch '(?i)(Microsoft Basic|Standard|Generic|Virtual|Remote|Software|WDDM)'
        }

    $ohmSensors = Get-OpenHardwareMonitorData

    $NvidiaGpus = $gpus | Where-Object { $_.Name -match "(?i)NVIDIA" -or $_.Caption -match "(?i)NVIDIA" }
    $OtherGpus  = $gpus | Where-Object { $_.Name -notmatch "(?i)NVIDIA" -and $_.Caption -notmatch "(?i)NVIDIA" }

    $result = @()

    $GetFallbackGpuInfo = {
        param($GpuList)
        $elements = @()
        foreach ($gpu in $GpuList) {
            $vramGB = if ($gpu.AdapterRAM) { [math]::Round($gpu.AdapterRAM / 1GB, 2) } else { 0 }
            
            # Use OHM override if available
            $gpuOhm = @()
            if ($ohmSensors) {
                $gpuOhm = $ohmSensors | Where-Object { 
                    $_.HardwareType -match 'Gpu' -and (
                        $gpu.Name -match $_.HardwareName -or 
                        $_.HardwareName -match ($gpu.Name -replace '(?i)NVIDIA|AMD|Intel|ATI|Graphics', '').Trim()
                    )
                }
                if ($gpuOhm.Count -eq 0) {
                    $gpuOhm = $ohmSensors | Where-Object { $_.HardwareType -match 'Gpu' }
                }
            }
            
            $ohmMemTotal = ($gpuOhm | Where-Object { $_.SensorType -eq 'SmallData' -and $_.SensorName -match 'GPU Memory Total' } | Select-Object -First 1).Value
            if ($ohmMemTotal -gt 0) {
                $vramGB = [math]::Round($ohmMemTotal / 1024, 2)
            }

            $ohmTemp = ($gpuOhm | Where-Object { $_.SensorType -eq 'Temperature' -and $_.SensorName -match 'GPU Core' } | Select-Object -First 1).Value
            $tempVal = if ($ohmTemp -gt 0) { [int]$ohmTemp } else { $null }

            $resolution = ""
            if ($gpu.CurrentHorizontalResolution -gt 0 -and $gpu.CurrentVerticalResolution -gt 0) {
                $resolution = "$($gpu.CurrentHorizontalResolution) x $($gpu.CurrentVerticalResolution)"
            }
            $elements += [PSCustomObject]@{
                Name          = $gpu.Name
                DriverVersion = $gpu.DriverVersion
                TemperatureC  = $tempVal
                VRAM_GB       = $vramGB
                Resolution    = $resolution
                Source        = if ($ohmSensors) { 'OHM/CIM' } else { 'CIM' }
            }
        }
        return $elements
    }

    if ($NvidiaGpus) {
        $SmiPath = Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue

        if (-not $SmiPath) {
            # Search DriverStore first
            $DefaultStorePath = Get-ChildItem -Path "C:\Windows\System32\DriverStore\FileRepository" -Filter "nvidia-smi.exe" -Recurse -ErrorAction SilentlyContinue |
                                Select-Object -First 1
            if ($DefaultStorePath) {
                $env:Path += ";$($DefaultStorePath.DirectoryName)"
                $SmiPath = Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue
            }
        }

        if (-not $SmiPath) {
            # Attempt internet-dependent installation via winget
            $online = Test-Connection -ComputerName 8.8.8.8 -Count 1 -Quiet -ErrorAction SilentlyContinue
            if ($online) {
                try {
                    winget install "NVIDIA Control Panel" --id 9NF8H0H7WMLT -s msstore --accept-package-agreements --accept-source-agreements 2>&1 | Out-Null
                    if ($LASTEXITCODE -eq 0) {
                        Start-Sleep -Seconds 5
                        $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
                        $SmiPath = Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue
                    }
                }
                catch {}
            }
        }

        if ($SmiPath) {
            try {
                $queryFields = @('name', 'driver_version', 'temperature.gpu', 'memory.total') -join ','
                $GpuTable = nvidia-smi --query-gpu=$queryFields --format=csv | ConvertFrom-Csv

                foreach ($gpu in $GpuTable) {
                    $memStr = $gpu.'memory.total [MiB]' -replace '[:\sA-Za-z]', ''
                    $memMiB = if ([double]::TryParse($memStr, [ref]0.0)) { [double]$memStr } else { 0.0 }
                    $vramGB = [math]::Round($memMiB / 1024, 2)

                    $tempVal = $null
                    $tempStr = $gpu.'temperature.gpu' -replace '[:\sA-Za-z]', ''
                    if ([int]::TryParse($tempStr, [ref]0)) { $tempVal = [int]$tempStr }

                    $result += [PSCustomObject]@{
                        Name          = $gpu.name
                        DriverVersion = $gpu.driver_version
                        TemperatureC  = $tempVal
                        VRAM_GB       = $vramGB
                        Resolution    = ""
                        Source        = 'SMI'
                    }
                }
            }
            catch {
                $result += & $GetFallbackGpuInfo -GpuList $NvidiaGpus
            }
        }
        else {
            $result += & $GetFallbackGpuInfo -GpuList $NvidiaGpus
        }
    }

    if ($OtherGpus) {
        $result += & $GetFallbackGpuInfo -GpuList $OtherGpus
    }

    return $result
}

function Get-MonitorInfo {
    $monitors = Get-CimOrWmiInstance -Namespace root\wmi -ClassName WmiMonitorBasicDisplayParams
    if (-not $monitors) { return [PSCustomObject]@{ Error = 'No monitor detected' } }
    $result = @()
    foreach ($m in $monitors) {
        $w = $m.MaxHorizontalImageSize
        $h = $m.MaxVerticalImageSize
        if ($w -gt 0 -and $h -gt 0) {
            $diag = [math]::Round([math]::Sqrt($w*$w + $h*$h) / 2.54, 1)
            $result += [PSCustomObject]@{
                WidthCm       = $w
                HeightCm      = $h
                DiagonalInches = $diag
            }
        }
    }
    return $result
}

function Get-AutopilotMDMInfo {
    $autopilotKey = 'HKLM:\SOFTWARE\Microsoft\Provisioning\Diagnostics\Autopilot'
    $mdmKey       = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MDM'
    $tenantDomain = ''
    $isLocked     = 0

    if (Test-Path $autopilotKey) {
        $tenantDomain = (Get-ItemProperty -Path $autopilotKey -ErrorAction SilentlyContinue).CloudAssignedTenantDomain
    }
    if (Test-Path $mdmKey) {
        $isLocked = (Get-ItemProperty -Path $mdmKey -Name 'EnrollmentLocked' -ErrorAction SilentlyContinue).EnrollmentLocked
    }

    $apStatus = if ([string]::IsNullOrWhiteSpace($tenantDomain)) { 'No Autopilot profile' } else { 'Enrolled' }
    [PSCustomObject]@{
        AutopilotEnrolled = -not [string]::IsNullOrWhiteSpace($tenantDomain)
        TenantDomain      = $tenantDomain
        EnrollmentLocked  = ($isLocked -eq 1)
        Status            = $apStatus
    }
}

function Get-SecureBootStatus {
    try {
        $regPath = "HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State"
        if (Test-Path $regPath) {
            $state = (Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue).UEFISecureBootEnabled
            if ($state -eq 1) {
                return [PSCustomObject]@{
                    Enabled      = $true
                    Status       = "Enabled"
                    Details      = "UEFI Secure Boot is Active"
                }
            } elseif ($state -eq 0) {
                return [PSCustomObject]@{
                    Enabled      = $false
                    Status       = "Disabled"
                    Details      = "UEFI Secure Boot is Inactive"
                }
            }
        }
    } catch {}

    try {
        $confirm = Confirm-SecureBootUEFI -ErrorAction SilentlyContinue
        $st = if ($confirm) { "Enabled" } else { "Disabled" }
        return [PSCustomObject]@{
            Enabled      = $confirm
            Status       = $st
            Details      = "Secure Boot Query via Cmdlet"
        }
    } catch {
        try {
            $sb = Get-CimInstance -Namespace "root\SecuredCore" -ClassName "MNDSecureBoot" -ErrorAction SilentlyContinue
            if ($sb) {
                $st = if ($sb.SecureBootEnabled) { "Enabled" } else { "Disabled" }
                return [PSCustomObject]@{
                    Enabled      = $sb.SecureBootEnabled
                    Status       = $st
                    Details      = "Secured Core WMI confirmed"
                }
            }
        } catch {}
    }

    return [PSCustomObject]@{
        Enabled      = $false
        Status       = "Unsupported / Not Found"
        Details      = "Legacy BIOS or Secure Boot reading unsupported"
    }
}

function Get-BitLockerStatus {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        return [PSCustomObject]@{ Status = 'Admin rights required' }
    }
    $blv = Get-BitLockerVolume -MountPoint 'C:' -ErrorAction SilentlyContinue
    if (-not $blv) { return [PSCustomObject]@{ Status = 'Not Enabled / No Volume Found' } }
    [PSCustomObject]@{
        VolumeStatus         = $blv.VolumeStatus
        EncryptionPercentage = $blv.EncryptionPercentage
        IsDecrypted          = ($blv.VolumeStatus -eq 'FullyDecrypted')
    }
}

function Get-StorageInfo {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $results = @()
    $disks = $null

    try {
        $disks = Get-PhysicalDisk -ErrorAction SilentlyContinue | Where-Object { $_.MediaType -eq 'SSD' -or $_.MediaType -eq 'Unspecified' -or $true }
    } catch {}

    if ($disks) {
        foreach ($disk in $disks) {
            $busTypeStr = ""
            try { $busTypeStr = $disk.BusType.ToString() } catch {}
            if ($disk.CannotPoolReason -eq 'RemovableMedia' -or 
                $busTypeStr -match '(?i)(usb|sd|mmc|cardreader)' -or
                $disk.FriendlyName -match '(?i)(usb|card reader|card-reader|sd card|microsd|reader|removable)') {
                continue
            }

            $sizeGB = [math]::Round($disk.Size / 1GB, 2)
            $allocGB = [math]::Round($disk.AllocatedSize / 1GB, 2)
            if ($null -eq $allocGB -or $allocGB -le 0) {
                $allocGB = $sizeGB
            }
            $allocPct = if ($disk.Size -gt 0) { [math]::Round(($disk.AllocatedSize / $disk.Size) * 100, 1) } else { 100 }
            $unallocPct = 100 - $allocPct
            $allocWarning = $unallocPct -ge 5

            $interfaceType = 'SATA'
            $busTypeStr = ""
            try { $busTypeStr = $disk.BusType.ToString() } catch {}
            if ($busTypeStr -match '(?i)nvme' -or $disk.FriendlyName -match '(?i)nvme') {
                $interfaceType = 'NVMe'
            } elseif ($busTypeStr -match '(?i)sata' -or $disk.FriendlyName -match '(?i)sata') {
                $interfaceType = 'SATA'
            }

            $metrics = $null
            if ($isAdmin) {
                try {
                    $counter = $disk | Get-StorageReliabilityCounter -ErrorAction SilentlyContinue
                    if ($counter) {
                        $metrics = [PSCustomObject]@{
                            Temperature    = if ($counter.Temperature -and $counter.Temperature -ne 32767) { "$($counter.Temperature) C" } else { 'N/A' }
                            PowerOnHours   = if ($counter.PowerOnHours) { $counter.PowerOnHours } else { 'N/A' }
                            WriteErrors    = if ($null -ne $counter.WriteErrorsTotal) { $counter.WriteErrorsTotal } else { 0 }
                            Wear           = if ($null -ne $counter.Wear) { "$($counter.Wear)%" } else { 'N/A' }
                        }
                    }
                } catch {}
            }

            $results += [PSCustomObject]@{
                FriendlyName       = $disk.FriendlyName
                OperationalStatus  = if ($disk.OperationalStatus) { $disk.OperationalStatus } else { 'Healthy' }
                HealthStatus       = if ($disk.HealthStatus) { $disk.HealthStatus } else { 'Healthy' }
                SizeGB             = $sizeGB
                AllocatedGB        = $allocGB
                UnallocatedPercent = $unallocPct
                AllocationWarning  = $allocWarning
                Metrics            = $metrics
                InterfaceType      = $interfaceType
            }
        }
    }

    if ($results.Count -eq 0) {
        try {
            $wmiDisks = @(Get-CimInstance -ClassName Win32_DiskDrive -ErrorAction SilentlyContinue)
            if (-not $wmiDisks) {
                $wmiDisks = @(Get-WmiObject -Class Win32_DiskDrive -ErrorAction SilentlyContinue)
            }
            foreach ($wd in $wmiDisks) {
                if ($wd.InterfaceType -match '(?i)(usb|firewire)' -or
                    $wd.MediaType -match '(?i)(removable|floppy|sd card)' -or
                    $wd.PNPDeviceID -match '(?i)(usb|cardreader|sd_card|reader)' -or
                    $wd.Caption -match '(?i)(usb|card reader|card-reader|sd card|microsd|reader|removable)' -or
                    $wd.Model -match '(?i)(usb|card reader|card-reader|sd card|microsd|reader|removable)') {
                    continue
                }

                $sizeInBytes = $wd.Size
                $sizeGB = if ($sizeInBytes) { [math]::Round($sizeInBytes / 1GB, 2) } else { 0 }
                $allocGB = $sizeGB
                $unallocPct = 0
                $allocWarning = $false

                $interfaceType = 'SATA'
                if ($wd.InterfaceType -match '(?i)nvme' -or $wd.Model -match '(?i)nvme' -or $wd.Caption -match '(?i)nvme') {
                    $interfaceType = 'NVMe'
                } elseif ($wd.InterfaceType -match '(?i)sata' -or $wd.Model -match '(?i)sata' -or $wd.Caption -match '(?i)sata') {
                    $interfaceType = 'SATA'
                }

                $results += [PSCustomObject]@{
                    FriendlyName       = if ($wd.Model) { $wd.Model } else { $wd.Caption }
                    OperationalStatus  = if ($wd.Status) { $wd.Status } else { 'OK' }
                    HealthStatus       = 'Healthy'
                    SizeGB             = $sizeGB
                    AllocatedGB        = $allocGB
                    UnallocatedPercent = $unallocPct
                    AllocationWarning  = $allocWarning
                    Metrics            = $null
                    InterfaceType      = $interfaceType
                }
            }
        } catch {}
    }

    if ($results.Count -eq 0) {
        return @([PSCustomObject]@{ Error = 'No physical disks detected' })
    }
    return $results
}

function Get-BatteryInfo {
    $bat = Get-CimOrWmiInstance -ClassName Win32_Battery -Property DesignCapacity, FullChargeCapacity, DeviceID, Name, EstimatedChargeRemaining, DesignVoltage -First
    
    $healthPct = 0
    $source = 'WMI'
    $charge = 0
    $batName = 'Unknown'
    $devId = 'Unknown'
    $designVoltage = $null
    
    if ($bat) {
        $charge = $bat.EstimatedChargeRemaining
        $batName = $bat.Name
        $devId = $bat.DeviceID
        $designVoltage = if ($bat.DesignVoltage) { $bat.DesignVoltage / 1000 } else { $null }
        if ($bat.DesignCapacity -gt 0) {
            $healthPct = [math]::Round(($bat.FullChargeCapacity / $bat.DesignCapacity) * 100, 0)
        }
    }

    if ($healthPct -le 0 -or $healthPct -gt 100 -or -not $bat) {
        $tmp = "$env:TEMP\battery-report.xml"
        powercfg /batteryreport /XML /OUTPUT $tmp | Out-Null
        try {
            if (Test-Path $tmp) {
                [xml]$report = Get-Content $tmp -ErrorAction SilentlyContinue
                Remove-Item $tmp -Force -ErrorAction SilentlyContinue
                $xmlBat = $report.BatteryReport.Batteries.Battery | Select-Object -First 1
                if ($xmlBat) {
                    $dc = 0.0
                    $fcc = 0.0
                    [double]::TryParse($xmlBat.DesignCapacity, [ref]$dc) | Out-Null
                    [double]::TryParse($xmlBat.FullChargeCapacity, [ref]$fcc) | Out-Null
                    if ($dc -gt 0) {
                        $healthPct = [math]::Round(($fcc / $dc) * 100, 0)
                        $source = 'powercfg'
                    }
                    if ([string]::IsNullOrWhiteSpace($batName) -or $batName -eq 'Unknown') {
                        $batName = $xmlBat.Name
                    }
                    if ([string]::IsNullOrWhiteSpace($devId) -or $devId -eq 'Unknown') {
                        $devId = $xmlBat.DeviceId
                    }
                }
            }
        } catch {}
    }

    if ($healthPct -le 0 -and -not $bat) {
        return [PSCustomObject]@{ Error = 'No battery detected' }
    }

    $voltageStatus = $null
    $bStatus = Get-CimOrWmiInstance -Namespace root\wmi -ClassName BatteryStatus -Property Voltage -First
    if ($bStatus -and $designVoltage) {
        $v = $bStatus.Voltage / 1000
        $diff = [math]::Abs($v - $designVoltage)
        $voltageStatus = [PSCustomObject]@{
            CurrentVoltage = $v
            DesignVoltage  = $designVoltage
            Deviation      = $diff
            IsHigh         = $diff -gt 0.5
        }
    }

    [PSCustomObject]@{
        DeviceID         = $devId
        Name             = $batName
        ChargePercent    = if ($bat) { $charge } else { 100 }
        HealthPercent    = $healthPct
        HealthSource     = $source
        DesignVoltage    = $designVoltage
        VoltageStatus    = $voltageStatus
    }
}

function Test-NetworkConnection {
    try {
        $ping = (New-Object Net.NetworkInformation.Ping).Send('www.google.com', 2000)
        [PSCustomObject]@{
            Online         = ($ping.Status -eq 'Success')
            RoundtripMs    = $ping.RoundtripTime
            StatusMessage  = if ($ping.Status -eq 'Success') { 'Online' } else { 'No Reply' }
        }
    } catch {
        [PSCustomObject]@{ Online = $false; RoundtripMs = $null; StatusMessage = 'Error' }
    }
}

function Get-DeviceProblems {
    $devices = Get-CimOrWmiInstance -ClassName Win32_PnPEntity -Property Name, ConfigManagerErrorCode
    $problematic = $devices | Where-Object { $_.ConfigManagerErrorCode -ne 0 -and $_.ConfigManagerErrorCode -ne 22 }
    if (-not $problematic) { return @() }
    $result = @()
    foreach ($d in $problematic) {
        $result += [PSCustomObject]@{
            Name        = $d.Name
            ErrorCode   = $d.ConfigManagerErrorCode
            Description = Get-ErrorDescription $d.ConfigManagerErrorCode
        }
    }
    return $result
}

function Get-BloatwareCheck {
    try {
        $sys = Get-CimOrWmiInstance -ClassName Win32_ComputerSystem -Property Manufacturer -First
        $manufacturer = if ($null -ne $sys -and $sys.Manufacturer) { $sys.Manufacturer } else { 'Unknown' }
        $isHP = $manufacturer -match '\bHP\b|Hewlett-Packard|Hewlett Packard'

        $hpSoftware = @()
        if (-not $isHP) {
            $paths = @(
                'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
            )
            $rawHpSoftware = @(Get-ItemProperty -Path $paths -ErrorAction SilentlyContinue |
                Where-Object { ($_.DisplayName -match '\bHP\b|Hewlett-Packard|Hewlett Packard') -or
                               ($_.Publisher -match '\bHP\b|Hewlett-Packard|Hewlett Packard') })
            if ($rawHpSoftware.Count -gt 0) {
                $hpSoftware = @($rawHpSoftware | Select-Object -ExpandProperty DisplayName -Unique |
                    Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            }
        }

        $statusVal = if ($isHP) { 'HP system - check skipped' }
                      elseif ($hpSoftware.Count -gt 0) { 'HP software found on non-HP system' }
                      else { 'Clean' }

        [PSCustomObject]@{
            Manufacturer       = $manufacturer
            IsHP               = $isHP
            HPSoftwareDetected = ($hpSoftware.Count -gt 0)
            HPSoftwareList     = $hpSoftware
            Status             = $statusVal
        }
    } catch {
        [PSCustomObject]@{
            Manufacturer       = 'Unknown'
            IsHP               = $false
            HPSoftwareDetected = $false
            HPSoftwareList     = @()
            Status             = 'Clean'
        }
    }
}

function Get-SoftwareHealthReport {
    param([switch]$SkipUpdateSearch, [switch]$SkipWingetSearch)
    try {
        function Get-DumpCount {
            $count = 0
            foreach ($p in @("$env:LOCALAPPDATA\CrashDumps", "$env:SystemRoot\Minidump")) {
                if (Test-Path $p) { $count += (Get-ChildItem "$p\*.dmp" -ErrorAction SilentlyContinue).Count }
            }
            return $count
        }

        $apps = @()
        $appxAvailable = $false
        try { Import-Module Appx -ErrorAction Stop; $apps = @(Get-AppxPackage -ErrorAction Stop); $appxAvailable = $true } catch {}

        $badApps = if ($appxAvailable -and $apps) { @($apps | Where-Object { $_.Status -ne 'Ok' }).Count } else { 0 }

        $wCount = 0
        $wingetStatus = 'Pending'
        $wingetDetails = 'Click "Check Updates" to query upgrades'
        if (-not $SkipWingetSearch) {
            try {
                $wingetRaw = winget upgrade --include-unknown --accept-source-agreements --disable-interactivity 2>$null
                $wingetData = @()
                if ($wingetRaw) {
                    $wingetData = @($wingetRaw -split '\r?\n')
                }
                $dash = $wingetData | Select-String -Pattern '^-{10,}' | Select-Object -First 1
                if ($dash) {
                    for ($i = $dash.LineNumber; $i -lt $wingetData.Count; $i++) {
                        if (-not [string]::IsNullOrWhiteSpace($wingetData[$i])) { $wCount++ }
                    }
                }
                $wingetStatus = if ($wCount -gt 0) { 'Warning' } else { 'OK' }
                $wingetDetails = if ($wCount -gt 0) { 'Upgrades available' } else { 'All updated' }
            } catch {
                $wingetStatus = 'OK'
                $wingetDetails = 'Offline'
            }
        }

        $sec = 0; $drv = 0
        $secDetails = 'Pending patches'
        $drvDetails = 'Pending updates'
        if (-not $SkipUpdateSearch) {
            try {
                $searcher = (New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher()
                $pending = $searcher.Search('IsInstalled=0 and IsHidden=0').Updates
                foreach ($u in $pending) {
                    try {
                        $cats = @()
                        if ($u.Categories) {
                            foreach ($cat in $u.Categories) {
                                if ($cat.Name) { $cats += $cat.Name }
                            }
                        }
                        if ($cats -match 'Security') { $sec++ } 
                        if ($cats -match 'Driver') { $drv++ }
                    } catch {}
                }
                $secStatus = if ($sec -gt 0) { 'Warning' } else { 'OK' }
                $secDetails = "$sec security patch(es)"
                $drvStatus = if ($drv -gt 0) { 'Warning' } else { 'OK' }
                $drvDetails = "$drv driver update(s)"
            } catch {
                $secStatus = 'OK'
                $drvStatus = 'OK'
                $secDetails = 'Offline'
                $drvDetails = 'Offline'
            }
        } else {
            $secStatus = 'Pending'
            $drvStatus = 'Pending'
            $secDetails = 'Click "Assess" to query updates'
            $drvDetails = 'Click "Assess" to query updates'
        }

        $dumps = Get-DumpCount

        $appxStatus = if (-not $appxAvailable) { 'Unavailable' } elseif ($badApps -gt 0) { 'Warning' } else { 'OK' }
        $appxDetails = if (-not $appxAvailable) { 'Appx not supported on this platform' } elseif ($badApps -gt 0) { "$badApps non-ok" } else { 'All Healthy' }

        $dumpsStatus = if ($dumps -gt 0) { 'Warning' } else { 'OK' }
        $dumpsDetails = if ($dumps -gt 0) { 'Crash dumps found!' } else { 'No crashes' }

        @(
            [PSCustomObject]@{
                Component = 'Windows Apps'
                Status    = $appxStatus
                Total     = $apps.Count
                Details   = $appxDetails
            }
            [PSCustomObject]@{
                Component = 'Winget'
                Status    = $wingetStatus
                Total     = $wCount
                Details   = $wingetDetails
            }
            [PSCustomObject]@{
                Component = 'Win Security'
                Status    = $secStatus
                Total     = $sec
                Details   = $secDetails
            }
            [PSCustomObject]@{
                Component = 'Win Drivers'
                Status    = $drvStatus
                Total     = $drv
                Details   = $drvDetails
            }
            [PSCustomObject]@{
                Component = 'System Health'
                Status    = $dumpsStatus
                Total     = $dumps
                Details   = $dumpsDetails
            }
        )
    } catch {
        @(
            [PSCustomObject]@{ Component = 'Windows Apps'; Status = 'OK'; Total = 0; Details = 'Healthy fallback' }
            [PSCustomObject]@{ Component = 'Winget'; Status = 'OK'; Total = 0; Details = 'Healthy fallback' }
            [PSCustomObject]@{ Component = 'Win Security'; Status = 'OK'; Total = 0; Details = 'Healthy fallback' }
            [PSCustomObject]@{ Component = 'Win Drivers'; Status = 'OK'; Total = 0; Details = 'Healthy fallback' }
            [PSCustomObject]@{ Component = 'System Health'; Status = 'OK'; Total = 0; Details = 'Healthy fallback' }
        )
    }
}

# ========== UI XAML LAYOUT DECLARATION ==========
$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Fastcheck By Yordi" 
        Height="1000" Width="1300"
        Background="#0F172A" WindowStartupLocation="Manual"
        Left="0"
        Top="0">
    <Window.Resources>
        <!-- Modern Scrollbar template is supported. We use a styling theme for modern controls -->
        <Style TargetType="TextBlock">
            <Setter Property="Foreground" Value="#E2E8F0"/>
            <Setter Property="FontFamily" Value="Segoe UI, Inter, Calibri"/>
        </Style>
        <Style x:Key="HeaderStyle" TargetType="TextBlock">
            <Setter Property="Foreground" Value="#38BDF8"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="FontSize" Value="14"/>
            <Setter Property="Margin" Value="0,0,0,8"/>
        </Style>
        <Style x:Key="ValueStyle" TargetType="TextBlock">
            <Setter Property="Foreground" Value="#F8FAFC"/>
            <Setter Property="FontWeight" Value="Medium"/>
            <Setter Property="FontSize" Value="12"/>
        </Style>
        <Style x:Key="LabelStyle" TargetType="TextBlock">
            <Setter Property="Foreground" Value="#94A3B8"/>
            <Setter Property="FontSize" Value="11"/>
            <Setter Property="Margin" Value="0,2,0,2"/>
        </Style>
        <Style x:Key="ActionButton" TargetType="Button">
            <Setter Property="Background" Value="#1E293B"/>
            <Setter Property="Foreground" Value="#E2E8F0"/>
            <Setter Property="BorderBrush" Value="#334155"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="12,6,12,6"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
        </Style>
        <Style x:Key="CardPanel" TargetType="Border">
            <Setter Property="Background" Value="#1E293B"/>
            <Setter Property="CornerRadius" Value="6"/>
            <Setter Property="BorderBrush" Value="#334155"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="16"/>
            <Setter Property="Margin" Value="6"/>
        </Style>
    </Window.Resources>

    <Grid Margin="12">
        <Grid.RowDefinitions>
            <!-- Title Grid Row -->
            <RowDefinition Height="Auto"/>
            <!-- Triage Multi-Column Grid Row -->
            <RowDefinition Height="*"/>
        </Grid.RowDefinitions>

        <!-- TITLE BAR -->
        <Grid Grid.Row="0" Margin="6,0,6,12">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            
            <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
                <Border Background="#0EA5E9" CornerRadius="4" Padding="8,4,8,4">
                    <TextBlock FontSize="10" FontWeight="Bold" Foreground="White" Name="TxtStatus">STANDBY</TextBlock>
                </Border>
            </StackPanel>
        </Grid>

        <!-- MAIN DASHBOARD MULTI-COLUMN -->
        <Grid Grid.Row="1">
            <Grid.ColumnDefinitions>
                <!-- COLUMN 1: Operating System and Basic Hardware -->
                <ColumnDefinition Width="*"/>
                <!-- COLUMN 2: Storage and Core Performance -->
                <ColumnDefinition Width="*"/>
                <!-- COLUMN 3: Software, Updates and Network -->
                <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>

            <!-- ================= COLUMN 1 ================= -->
            <ScrollViewer Grid.Column="0" VerticalScrollBarVisibility="Auto">
                <StackPanel>
                    <!-- SYSTEM & BIOS INFO -->
                    <Border Style="{StaticResource CardPanel}">
                        <StackPanel>
                            <DockPanel LastChildFill="False">
                                <TextBlock Style="{StaticResource HeaderStyle}" DockPanel.Dock="Left">System &amp; BIOS Specs</TextBlock>
                                <Button Name="BtnUpdateSys" Style="{StaticResource ActionButton}" Cursor="Hand" Padding="4,2" FontSize="10" Content="Refresh" DockPanel.Dock="Right"/>
                            </DockPanel>
                            <Grid Margin="0,4,0,0">
                                <Grid.RowDefinitions>
                                    <RowDefinition Height="Auto"/>
                                    <RowDefinition Height="Auto"/>
                                    <RowDefinition Height="Auto"/>
                                    <RowDefinition Height="Auto"/>
                                </Grid.RowDefinitions>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="*"/>
                                </Grid.ColumnDefinitions>

                                <!-- Row 0: Manufacturer & Model -->
                                <StackPanel Grid.Row="0" Grid.Column="0" Margin="0,4,8,4">
                                    <TextBlock Style="{StaticResource LabelStyle}">MANUFACTURER</TextBlock>
                                    <TextBlock x:Name="TxtManufacturer" Style="{StaticResource ValueStyle}" TextWrapping="Wrap">-</TextBlock>
                                </StackPanel>
                                <StackPanel Grid.Row="0" Grid.Column="1" Margin="0,4,0,4">
                                    <TextBlock Style="{StaticResource LabelStyle}">MODEL</TextBlock>
                                    <TextBlock x:Name="TxtModel" Style="{StaticResource ValueStyle}" TextWrapping="Wrap">-</TextBlock>
                                </StackPanel>

                                <!-- Row 1: OS (Full width span) -->
                                <Border Grid.Row="1" Grid.Column="0" Grid.ColumnSpan="2" Margin="0,4,0,4" BorderBrush="#334155" BorderThickness="0,1,0,0" Padding="0,4,0,0">
                                    <StackPanel>
                                        <TextBlock Style="{StaticResource LabelStyle}">OPERATING SYSTEM &amp; VERSION</TextBlock>
                                        <TextBlock x:Name="TxtOS" Style="{StaticResource ValueStyle}" TextWrapping="Wrap">-</TextBlock>
                                    </StackPanel>
                                </Border>

                                <!-- Row 2: License Key (Full width span) -->
                                <Border Grid.Row="2" Grid.Column="0" Grid.ColumnSpan="2" Margin="0,4,0,4" BorderBrush="#334155" BorderThickness="0,1,0,0" Padding="0,4,0,0">
                                    <StackPanel>
                                        <TextBlock Style="{StaticResource LabelStyle}">SOFTWARE LICENSE KEY</TextBlock>
                                        <TextBlock x:Name="TxtLicenseKey" Style="{StaticResource ValueStyle}" TextWrapping="Wrap" Foreground="#38BDF8" FontWeight="SemiBold">-</TextBlock>
                                    </StackPanel>
                                </Border>

                                <!-- Row 3: BIOS & Serial -->
                                <Border Grid.Row="3" Grid.Column="0" Margin="0,4,8,4" BorderBrush="#334155" BorderThickness="0,1,0,0" Padding="0,4,0,0">
                                    <StackPanel>
                                        <TextBlock Style="{StaticResource LabelStyle}">BIOS VERSION</TextBlock>
                                        <TextBlock x:Name="TxtBIOS" Style="{StaticResource ValueStyle}" TextWrapping="Wrap">-</TextBlock>
                                    </StackPanel>
                                </Border>
                                <Border Grid.Row="3" Grid.Column="1" Margin="0,4,0,4" BorderBrush="#334155" BorderThickness="0,1,0,0" Padding="0,4,0,0">
                                    <StackPanel>
                                        <TextBlock Style="{StaticResource LabelStyle}">SERIAL NUMBER</TextBlock>
                                        <TextBlock x:Name="TxtSerial" Style="{StaticResource ValueStyle}" TextWrapping="Wrap">-</TextBlock>
                                    </StackPanel>
                                </Border>
                            </Grid>
                        </StackPanel>
                    </Border>

                    <!-- CPU & TEMPERATURE INFO -->
                    <Border Style="{StaticResource CardPanel}">
                        <StackPanel>
                            <DockPanel LastChildFill="False">
                                <TextBlock Style="{StaticResource HeaderStyle}" DockPanel.Dock="Left">Central Processing Unit (CPU)</TextBlock>
                                <Button Name="BtnUpdateCPU" Style="{StaticResource ActionButton}" Padding="4,2" FontSize="10" Content="Check" DockPanel.Dock="Right"/>
                            </DockPanel>
                            <TextBlock x:Name="TxtCPUName" Style="{StaticResource ValueStyle}" TextWrapping="Wrap" Margin="0,4,0,8">-</TextBlock>
                            
                            <Grid>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="*"/>
                                </Grid.ColumnDefinitions>
                                <StackPanel Grid.Column="0">
                                    <TextBlock Style="{StaticResource LabelStyle}">CORES</TextBlock>
                                    <TextBlock x:Name="TxtCPUCores" FontWeight="Bold" FontSize="16" Foreground="#38BDF8">-</TextBlock>
                                </StackPanel>
                                <StackPanel Grid.Column="1">
                                    <TextBlock Style="{StaticResource LabelStyle}">LOGICAL</TextBlock>
                                    <TextBlock x:Name="TxtCPULogical" FontWeight="Bold" FontSize="16" Foreground="#38BDF8">-</TextBlock>
                                </StackPanel>
                                <StackPanel Grid.Column="2">
                                    <TextBlock Style="{StaticResource LabelStyle}">TEMPERATURE</TextBlock>
                                    <TextBlock x:Name="TxtCPUTemp" FontWeight="Bold" FontSize="16" Foreground="#4ADE80">-</TextBlock>
                                </StackPanel>
                            </Grid>
                            
                            <Border Margin="0,6,0,0" BorderBrush="#334155" BorderThickness="0,1,0,0" Padding="0,6,0,0" x:Name="BdrCpuExtra" Visibility="Collapsed">
                                <Grid>
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="*"/>
                                        <ColumnDefinition Width="*"/>
                                    </Grid.ColumnDefinitions>
                                    <StackPanel Grid.Column="0">
                                        <TextBlock Style="{StaticResource LabelStyle}">CPU TOTAL LOAD</TextBlock>
                                        <TextBlock x:Name="TxtCPULoad" FontWeight="Bold" FontSize="14" Foreground="#38BDF8">-</TextBlock>
                                    </StackPanel>
                                    <StackPanel Grid.Column="1">
                                        <TextBlock Style="{StaticResource LabelStyle}">CPU POWER</TextBlock>
                                        <TextBlock x:Name="TxtCPUPower" FontWeight="Bold" FontSize="14" Foreground="#F8FAFC">-</TextBlock>
                                    </StackPanel>
                                </Grid>
                            </Border>

                            <!-- Thermal Guard bar -->
                            <StackPanel Margin="0,12,0,0">
                                <DockPanel LastChildFill="False" Margin="0,0,0,4">
                                    <TextBlock Style="{StaticResource LabelStyle}" Text="Thermal Guard Limit" DockPanel.Dock="Left"/>
                                    <TextBlock Style="{StaticResource LabelStyle}" Text="100°C Max" DockPanel.Dock="Right" FontWeight="SemiBold"/>
                                </DockPanel>
                                <ProgressBar Name="PbCpuTemp" Height="6" Background="#090F1C" Foreground="#10B981" BorderThickness="0" Minimum="0" Maximum="100" Value="0"/>
                            </StackPanel>
                        </StackPanel>
                    </Border>

                    <!-- BATTERY HEALTH -->
                    <Border Style="{StaticResource CardPanel}">
                        <StackPanel>
                            <DockPanel LastChildFill="False">
                                <TextBlock Style="{StaticResource HeaderStyle}" DockPanel.Dock="Left">Battery Health</TextBlock>
                                <Button Name="BtnUpdateBattery" Style="{StaticResource ActionButton}" Padding="4,2" FontSize="10" Content="Refresh" DockPanel.Dock="Right"/>
                                <Border Name="BdrBatteryCharge" Background="#061F1A" BorderBrush="#10B981" BorderThickness="1" CornerRadius="4" Padding="6,2" Margin="0,0,6,0" VerticalAlignment="Center" DockPanel.Dock="Right">
                                    <TextBlock Name="TxtBatteryChargeBadge" Foreground="#34D399" FontSize="10" FontWeight="Bold">-</TextBlock>
                                </Border>
                            </DockPanel>

                            <!-- 2-column Grid for ID and Wear Index -->
                            <Grid Margin="0,8,0,4">
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="*"/>
                                </Grid.ColumnDefinitions>
                                <StackPanel Grid.Column="0">
                                    <TextBlock Style="{StaticResource LabelStyle}">BATTERY ID</TextBlock>
                                    <TextBlock Name="TxtBatteryID" Style="{StaticResource ValueStyle}" FontWeight="Bold" TextWrapping="Wrap">-</TextBlock>
                                </StackPanel>
                                <StackPanel Grid.Column="1" HorizontalAlignment="Right">
                                    <TextBlock Style="{StaticResource LabelStyle}" TextAlignment="Right">WEAR INDEX</TextBlock>
                                    <TextBlock Name="TxtWearIndex" Style="{StaticResource ValueStyle}" FontStyle="Normal" FontWeight="Bold" TextAlignment="Right" Foreground="#FFFFFF">-</TextBlock>
                                </StackPanel>
                            </Grid>

                            <!-- Horizontal Retention Bar -->
                            <ProgressBar Name="PbBatteryHealth" Height="6" Background="#090F1C" Foreground="#10B981" BorderThickness="0" Minimum="0" Maximum="100" Value="0" Margin="0,4,0,10"/>

                            <!-- Volt & API Line -->
                            <Grid Margin="0,4,0,8">
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="*"/>
                                </Grid.ColumnDefinitions>
                                <StackPanel Grid.Column="0">
                                    <WrapPanel>
                                        <TextBlock Style="{StaticResource LabelStyle}" Foreground="#94A3B8" Text="Design Voltage: "/>
                                        <TextBlock Name="TxtBatteryVoltage" Style="{StaticResource ValueStyle}" FontWeight="Bold"/>
                                    </WrapPanel>
                                </StackPanel>
                                <StackPanel Grid.Column="1" HorizontalAlignment="Right">
                                    <TextBlock Name="TxtBatteryAPI" Style="{StaticResource LabelStyle}" Foreground="#94A3B8" TextAlignment="Right">Reporting API: -</TextBlock>
                                </StackPanel>
                            </Grid>

                            <!-- Voltage Analytics Subbox -->
                            <Border Name="BdrVoltageAnalytics" Background="#0f172a" BorderBrush="#334155" BorderThickness="1" CornerRadius="6" Padding="12" Margin="0,4,0,0" Visibility="Collapsed">
                                <StackPanel>
                                    <TextBlock Style="{StaticResource LabelStyle}" Foreground="#FFFFFF" FontWeight="Bold" Text="Voltage Analytics:"/>
                                    <TextBlock Name="TxtVoltageAnalytics" Style="{StaticResource LabelStyle}" Foreground="#94A3B8" FontSize="11" Margin="0,4,0,0"/>
                                </StackPanel>
                            </Border>

                            <TextBlock x:Name="TxtBatteryAlert" Margin="0,4,0,0" FontSize="11" Foreground="#EF4444" FontWeight="Bold" Visibility="Collapsed" TextWrapping="Wrap"/>
                        </StackPanel>
                    </Border>
                </StackPanel>
            </ScrollViewer>

            <!-- ================= COLUMN 2 ================= -->
            <ScrollViewer Grid.Column="1" VerticalScrollBarVisibility="Auto">
                <StackPanel>
                    <!-- PHYSICAL MEMORY -->
                    <Border Style="{StaticResource CardPanel}">
                        <StackPanel>
                            <DockPanel LastChildFill="False">
                                <TextBlock Style="{StaticResource HeaderStyle}" DockPanel.Dock="Left">Physical Modules (RAM)</TextBlock>
                                <Button Name="BtnUpdateMemory" Style="{StaticResource ActionButton}" Padding="4,2" FontSize="10" Content="Refresh" DockPanel.Dock="Right"/>
                            </DockPanel>
                            <TextBlock x:Name="TxtMemoryHeading" Style="{StaticResource ValueStyle}" Foreground="#60A5FA" Margin="0,4,0,8">-</TextBlock>
                            <StackPanel x:Name="StkMemoryContent"/>
                        </StackPanel>
                    </Border>

                    <!-- GRAPHICS CONTROLLERS (GPU) -->
                    <Border Style="{StaticResource CardPanel}">
                        <StackPanel>
                            <DockPanel LastChildFill="False">
                                <TextBlock Style="{StaticResource HeaderStyle}" DockPanel.Dock="Left">Graphics Processing Unit (GPU)</TextBlock>
                                <Button Name="BtnUpdateGPU" Style="{StaticResource ActionButton}" Padding="4,2" FontSize="10" Content="Refresh" DockPanel.Dock="Right"/>
                            </DockPanel>
                            <StackPanel x:Name="StkGPUContent"/>
                        </StackPanel>
                    </Border>

                    <!-- PHYSICAL STORAGE DISKS -->
                    <Border Style="{StaticResource CardPanel}">
                        <StackPanel>
                            <DockPanel LastChildFill="False">
                                <TextBlock Style="{StaticResource HeaderStyle}" DockPanel.Dock="Left">Physical Disk Storage</TextBlock>
                                <Button Name="BtnUpdateStorage" Style="{StaticResource ActionButton}" Padding="4,2" FontSize="10" Content="Scan" DockPanel.Dock="Right"/>
                            </DockPanel>
                            <StackPanel x:Name="StkStorageContent"/>
                        </StackPanel>
                    </Border>
                </StackPanel>
            </ScrollViewer>

            <!-- ================= COLUMN 3 ================= -->
            <ScrollViewer Grid.Column="2" VerticalScrollBarVisibility="Auto">
                <StackPanel>
                    <!-- AUTOPILOT / BITLOCKER / NETWORK -->
                    <Border Style="{StaticResource CardPanel}">
                        <StackPanel>
                            <DockPanel LastChildFill="False">
                                <TextBlock Style="{StaticResource HeaderStyle}" DockPanel.Dock="Left">Security &amp; Enrollment</TextBlock>
                                <Button Name="BtnUpdateSecurity" Style="{StaticResource ActionButton}" Padding="4,2" FontSize="10" Content="Refresh" DockPanel.Dock="Right"/>
                            </DockPanel>
                            <StackPanel Margin="0,4,0,0">
                                <Border Margin="0,4" Padding="0,0,0,4">
                                    <StackPanel>
                                        <TextBlock Style="{StaticResource LabelStyle}">AUTOPILOT / MDM ENROLL STATUS</TextBlock>
                                        <TextBlock x:Name="TxtAutopilotStatus" Style="{StaticResource ValueStyle}" TextWrapping="Wrap">-</TextBlock>
                                        <TextBlock x:Name="TxtAutopilotDomain" FontSize="11" Foreground="#94A3B8" FontStyle="Italic" TextWrapping="Wrap"/>
                                    </StackPanel>
                                </Border>
                                <Border Margin="0,4" BorderBrush="#334155" BorderThickness="0,1,0,0" Padding="0,6,0,4">
                                    <StackPanel>
                                        <TextBlock Style="{StaticResource LabelStyle}">BITLOCKER DRIVE ENCRYPTION (C:)</TextBlock>
                                        <TextBlock x:Name="TxtBitLocker" Style="{StaticResource ValueStyle}" TextWrapping="Wrap">-</TextBlock>
                                    </StackPanel>
                                </Border>
                                <Border Margin="0,4" BorderBrush="#334155" BorderThickness="0,1,0,0" Padding="0,6,0,4">
                                    <StackPanel>
                                        <TextBlock Style="{StaticResource LabelStyle}">SECURE BOOT STATUS</TextBlock>
                                        <TextBlock x:Name="TxtSecureBoot" Style="{StaticResource ValueStyle}" TextWrapping="Wrap">-</TextBlock>
                                    </StackPanel>
                                </Border>
                                <Border Margin="0,4" BorderBrush="#334155" BorderThickness="0,1,0,0" Padding="0,6,0,4">
                                    <StackPanel>
                                        <TextBlock Style="{StaticResource LabelStyle}">INTERNET PING</TextBlock>
                                        <TextBlock x:Name="TxtNetwork" Style="{StaticResource ValueStyle}" TextWrapping="Wrap">-</TextBlock>
                                    </StackPanel>
                                </Border>
                            </StackPanel>
                        </StackPanel>
                    </Border>

                    <!-- HARDWARE DEVICE PROBLEMS -->
                    <Border Style="{StaticResource CardPanel}">
                        <StackPanel>
                            <DockPanel LastChildFill="False">
                                <TextBlock Style="{StaticResource HeaderStyle}" DockPanel.Dock="Left">Faulty Controllers &amp; Drivers</TextBlock>
                                <Button Name="BtnUpdateProblems" Style="{StaticResource ActionButton}" Padding="4,2" FontSize="10" Content="Diagnose" DockPanel.Dock="Right"/>
                            </DockPanel>
                            <StackPanel x:Name="StkProblemsContent" Margin="0,4,0,0">
                                <TextBlock Foreground="#10B981" FontStyle="Italic" Name="TxtProblemsNoIssues">All hardware controllers functioning normally</TextBlock>
                            </StackPanel>
                        </StackPanel>
                    </Border>

                    <!-- OS SOFTWARE HEALTH REPORT -->
                    <Border Style="{StaticResource CardPanel}">
                        <StackPanel>
                            <DockPanel LastChildFill="False">
                                <TextBlock Style="{StaticResource HeaderStyle}" DockPanel.Dock="Left">OS Software Health Reports</TextBlock>
                                <Button Name="BtnUpdateSoftware" Style="{StaticResource ActionButton}" Padding="4,2" FontSize="10" Content="Assess" DockPanel.Dock="Right"/>
                            </DockPanel>
                            
                            <StackPanel Margin="0,4,0,0">
                                <TextBlock Style="{StaticResource LabelStyle}">OEM INFRASTRUCTURE POLICIES</TextBlock>
                                <TextBlock x:Name="TxtBloatwareStatus" Style="{StaticResource ValueStyle}">-</TextBlock>
                                <TextBlock x:Name="TxtBloatwareDetails" FontSize="11" Foreground="#FB923C" TextWrapping="Wrap"/>
                            </StackPanel>
                        </StackPanel>
                    </Border>

                    <!-- WINDOWS APPLICATION UPDATES -->
                    <Border Style="{StaticResource CardPanel}">
                        <StackPanel>
                            <DockPanel LastChildFill="False" Margin="0,0,0,4">
                                <TextBlock Style="{StaticResource HeaderStyle}" DockPanel.Dock="Left">Windows Application Updates</TextBlock>
                                <Button Name="BtnUpdateApps" Style="{StaticResource ActionButton}" Padding="4,2" FontSize="10" Content="Check Updates" DockPanel.Dock="Right"/>
                            </DockPanel>
                            <StackPanel x:Name="StkSoftwareReports" Margin="0,4,0,0"/>
                        </StackPanel>
                    </Border>
                </StackPanel>
            </ScrollViewer>
        </Grid>

        <!-- Footer removed as requested -->
    </Grid>
</Window>
"@

# Helper to load XAML safely into a logical layout object
try {
    $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]$xaml)
    $window = [System.Windows.Markup.XamlReader]::Load($reader)
    $global:DiagnosticsTriageWindow = $window
} catch {
    [System.Windows.MessageBox]::Show("WPF XAML Load Failed. " + [System.Environment]::NewLine + "Error: " + $_, "Diagnostics Tool Load Failed", "OK", "Error")
    throw $_
}

# --- Color Conversion Helper ---
function Get-Brush {
    param([string]$HexColor)
    try {
        $bc = New-Object System.Windows.Media.BrushConverter
        return $bc.ConvertFromString($HexColor)
    } catch {
        return [System.Windows.Media.Brushes]::Gray
    }
}

# --- Gather UI Named object references ---
$ui = @{}
'TxtStatus', 'TxtManufacturer', 'TxtModel', 'TxtLicenseKey', 'TxtOS', 'TxtBIOS', 'TxtSerial',
'BtnUpdateSys', 'TxtCPUName', 'TxtCPUCores', 'TxtCPULogical', 'TxtCPUTemp', 'TxtCPULoad', 'TxtCPUPower', 'BdrCpuExtra', 'BtnUpdateCPU', 'PbCpuTemp',
'TxtBatteryID', 'TxtBatteryChargeBadge', 'TxtWearIndex', 'PbBatteryHealth', 'TxtBatteryVoltage', 'TxtBatteryAPI', 'BdrVoltageAnalytics', 'TxtVoltageAnalytics', 'TxtBatteryAlert', 'BtnUpdateBattery',
'TxtMemoryHeading', 'StkMemoryContent', 'BtnUpdateMemory', 'StkGPUContent', 'BtnUpdateGPU',
'StkStorageContent', 'BtnUpdateStorage', 'TxtAutopilotStatus', 'TxtAutopilotDomain', 'TxtBitLocker', 'TxtSecureBoot', 'TxtNetwork',
'BtnUpdateSecurity', 'StkProblemsContent', 'TxtProblemsNoIssues', 'BtnUpdateProblems', 'TxtBloatwareStatus', 
'TxtBloatwareDetails', 'BtnUpdateSoftware', 'BtnUpdateApps', 'StkSoftwareReports', 'BtnRunAll', 'BtnClose' | ForEach-Object {
    $ui[$_] = $window.FindName($_)
}

# ========== SAFE RUNTIME UPDATE ACTIONS ==========

# 1. System Info
$updateSys = {
    $ui['TxtStatus'].Text = "LOADING SYSTEM..."
    [System.Windows.Forms.Application]::DoEvents()
    try {
        $info = Get-SystemAndOSInfo
        $bios = Get-BIOSInfo
        $ui['TxtManufacturer'].Text = $info.Manufacturer
        $ui['TxtModel'].Text = $info.Model
        $ui['TxtLicenseKey'].Text = $info.LicenseKey
        $ui['TxtOS'].Text = "$($info.OS) | $($info.Build)"
        $ui['TxtBIOS'].Text = $bios.Version
        $ui['TxtSerial'].Text = $bios.Serial
    } catch {
        $ui['TxtManufacturer'].Text = "Error"
        $ui['TxtModel'].Text = $_.Exception.Message
    }
    $ui['TxtStatus'].Text = "READY"
}

# 2. CPU Update
$updateCPU = {
    $ui['TxtStatus'].Text = "ASSESSING CPU..."
    [System.Windows.Forms.Application]::DoEvents()
    try {
        $cpu = Get-CPUInfo
        $ui['TxtCPUName'].Text = $cpu.Name
        $ui['TxtCPUCores'].Text = $cpu.Cores.ToString()
        $ui['TxtCPULogical'].Text = $cpu.LogicalProcessors.ToString()
        
        if ($cpu.TemperatureC -gt 0) {
            $ui['TxtCPUTemp'].Text = "$($cpu.TemperatureC) C"
            if ($cpu.TemperatureStatus -eq 'Critical') {
                $ui['TxtCPUTemp'].Foreground = [System.Windows.Media.Brushes]::Red
            } elseif ($cpu.TemperatureStatus -eq 'Warning') {
                $ui['TxtCPUTemp'].Foreground = [System.Windows.Media.Brushes]::Orange
            } else {
                $ui['TxtCPUTemp'].Foreground = [System.Windows.Media.Brushes]::LimeGreen
            }
            if ($null -ne $ui['PbCpuTemp']) {
                $ui['PbCpuTemp'].Value = $cpu.TemperatureC
                if ($cpu.TemperatureC -ge 80) {
                    $ui['PbCpuTemp'].Foreground = [System.Windows.Media.Brushes]::Red
                } elseif ($cpu.TemperatureC -ge 65) {
                    $ui['PbCpuTemp'].Foreground = [System.Windows.Media.Brushes]::Orange
                } else {
                    $ui['PbCpuTemp'].Foreground = Get-Brush "#10B981"
                }
            }
        } else {
            $ui['TxtCPUTemp'].Text = "N/A"
            $ui['TxtCPUTemp'].Foreground = [System.Windows.Media.Brushes]::Gray
            if ($null -ne $ui['PbCpuTemp']) {
                $ui['PbCpuTemp'].Value = 0
            }
        }

        if ($null -ne $ui['BdrCpuExtra']) {
            if ($null -ne $cpu.PowerW -or $null -ne $cpu.LoadPercent) {
                $ui['BdrCpuExtra'].Visibility = [System.Windows.Visibility]::Visible
                if ($null -ne $cpu.LoadPercent) {
                    $ui['TxtCPULoad'].Text = "$($cpu.LoadPercent)%"
                } else {
                    $ui['TxtCPULoad'].Text = "N/A"
                }
                if ($null -ne $cpu.PowerW) {
                    $ui['TxtCPUPower'].Text = "$($cpu.PowerW) W"
                } else {
                    $ui['TxtCPUPower'].Text = "N/A"
                }
            } else {
                $ui['BdrCpuExtra'].Visibility = [System.Windows.Visibility]::Collapsed
            }
        }
    } catch {
        $ui['TxtCPUName'].Text = "Failed to query CPU parameters safely."
    }
    $ui['TxtStatus'].Text = "READY"
}

# 3. Battery health
$updateBattery = {
    $ui['TxtStatus'].Text = "CHARGING READINGS..."
    [System.Windows.Forms.Application]::DoEvents()
    try {
        $batt = Get-BatteryInfo
        if ($batt.Error) {
            $ui['TxtBatteryID'].Text = "No Battery Found"
            $ui['TxtBatteryChargeBadge'].Text = "N/A"
            $ui['TxtWearIndex'].Text = "N/A"
            if ($null -ne $ui['PbBatteryHealth']) { $ui['PbBatteryHealth'].Value = 0 }
            $ui['TxtBatteryVoltage'].Text = "N/A"
            $ui['TxtBatteryAPI'].Text = "Reporting API: N/A"
            $ui['BdrVoltageAnalytics'].Visibility = [System.Windows.Visibility]::Collapsed
            $ui['TxtBatteryAlert'].Visibility = [System.Windows.Visibility]::Collapsed
        } else {
            $ui['TxtBatteryID'].Text = if ($batt.DeviceID) { $batt.DeviceID } else { "N/A" }
            $ui['TxtBatteryChargeBadge'].Text = "$($batt.ChargePercent)% CHARGE"
            $ui['TxtWearIndex'].Text = "$($batt.HealthPercent)% Retained"
            
            if ($null -ne $ui['PbBatteryHealth']) {
                $ui['PbBatteryHealth'].Value = $batt.HealthPercent
                if ($batt.HealthPercent -ge 80) {
                    $ui['PbBatteryHealth'].Foreground = Get-Brush "#10B981"
                } elseif ($batt.HealthPercent -ge 60) {
                    $ui['PbBatteryHealth'].Foreground = [System.Windows.Media.Brushes]::Orange
                } else {
                    $ui['PbBatteryHealth'].Foreground = [System.Windows.Media.Brushes]::Red
                }
            }

            $ui['TxtBatteryVoltage'].Text = if ($batt.DesignVoltage) { "$($batt.DesignVoltage) v" } else { "N/A" }
            $ui['TxtBatteryAPI'].Text = "Reporting API: $($batt.HealthSource)"
            
            if ($batt.VoltageStatus) {
                $ui['BdrVoltageAnalytics'].Visibility = [System.Windows.Visibility]::Visible
                $sign = if ($batt.DesignVoltage -le $batt.VoltageStatus.CurrentVoltage) { "+" } else { "-" }
                $ui['TxtVoltageAnalytics'].Text = "$($batt.VoltageStatus.CurrentVoltage) v  (Dev: $($sign)$([math]::Round($batt.VoltageStatus.Deviation, 2)) v)"
                
                if ($batt.VoltageStatus.IsHigh) {
                    $ui['TxtBatteryAlert'].Text = "High Voltage Deviation: [+$($batt.VoltageStatus.Deviation)V] detected!"
                    $ui['TxtBatteryAlert'].Visibility = [System.Windows.Visibility]::Visible
                } else {
                    $ui['TxtBatteryAlert'].Visibility = [System.Windows.Visibility]::Collapsed
                }
            } else {
                $ui['BdrVoltageAnalytics'].Visibility = [System.Windows.Visibility]::Collapsed
                $ui['TxtBatteryAlert'].Visibility = [System.Windows.Visibility]::Collapsed
            }
        }
    } catch {
        $ui['TxtBatteryID'].Text = "Error loading battery report"
    }
    $ui['TxtStatus'].Text = "READY"
}

# 4. Memory Modules
$updateMemory = {
    $ui['TxtStatus'].Text = "SCANNING DIMM SLOTS..."
    [System.Windows.Forms.Application]::DoEvents()
    try {
        $sticks = Get-MemoryInfo
        $ui['StkMemoryContent'].Children.Clear()
        if ($sticks -and $sticks[0].Error) {
            $tx = New-Object System.Windows.Controls.TextBlock
            $tx.Text = $sticks[0].Error
            $tx.Foreground = [System.Windows.Media.Brushes]::Red
            $tx.TextWrapping = "Wrap"
            $ui['StkMemoryContent'].Children.Add($tx) | Out-Null
        } elseif ($sticks) {
            $totalGB = 0
            foreach ($s in $sticks) { $totalGB += $s.CapacityGB }
            $ui['TxtMemoryHeading'].Text = "$($sticks[0].Type) config | $totalGB GB Combined"
            
            foreach ($s in $sticks) {
                $border = New-Object System.Windows.Controls.Border
                $border.Background = Get-Brush "#0F1728"
                $border.Padding = 8
                $border.Margin = "0,2,0,2"
                $border.CornerRadius = 4
                
                $stack = New-Object System.Windows.Controls.StackPanel
                
                $title = New-Object System.Windows.Controls.TextBlock
                $title.Text = "Slots info: $($s.SlotLocation) [Capacity: $($s.CapacityGB)GB]"
                $title.FontWeight = "SemiBold"
                $title.FontSize = 11
                $title.TextWrapping = "Wrap"
                $stack.Children.Add($title) | Out-Null
                
                $details = New-Object System.Windows.Controls.TextBlock
                $details.Text = "Configured: $($s.ConfiguredSpeedMHz) MHz rated at $($s.RatedSpeedMHz) MHz"
                $details.FontSize = 10
                $details.Foreground = Get-Brush "#94A3B8"
                $details.TextWrapping = "Wrap"
                
                if ($s.Throttled) {
                    $details.Text += " [THROTTLED]"
                    $details.Foreground = [System.Windows.Media.Brushes]::Orange
                }
                $stack.Children.Add($details) | Out-Null
                
                if ($s.PartNumber) {
                    $pn = New-Object System.Windows.Controls.TextBlock
                    $pn.Text = "Part Number: $($s.PartNumber)"
                    $pn.FontSize = 9
                    $pn.Foreground = Get-Brush "#64748B"
                    $pn.TextWrapping = "Wrap"
                    $stack.Children.Add($pn) | Out-Null
                }
                
                $border.Child = $stack
                $ui['StkMemoryContent'].Children.Add($border) | Out-Null
            }
        }
    } catch {
        $ui['TxtMemoryHeading'].Text = "Memory query crashed safely."
    }
    $ui['TxtStatus'].Text = "READY"
}

# 5. GPU adapters
$updateGPU = {
    $ui['TxtStatus'].Text = "Checking GPU..."
    [System.Windows.Forms.Application]::DoEvents()
    try {
        $gpus = Get-GPUInfo
        $ui['StkGPUContent'].Children.Clear()
        
        foreach ($gpu in $gpus) {
            # Outer card-style border
            $cardBorder = New-Object System.Windows.Controls.Border
            $cardBorder.Background = Get-Brush "#0F172A"
            $cardBorder.BorderBrush = Get-Brush "#1E293B"
            $cardBorder.BorderThickness = 1
            $cardBorder.CornerRadius = 8
            $cardBorder.Padding = 12
            $cardBorder.Margin = "0,6,0,6"
            
            $cardStack = New-Object System.Windows.Controls.StackPanel
            
            # GPU Name & Source Tag (DockPanel for placing Tag on the right and aligning elegantly)
            $gpuNameDock = New-Object System.Windows.Controls.DockPanel
            $gpuNameDock.LastChildFill = $true
            $gpuNameDock.Margin = "0,0,0,10"
            
            # Source Tag border (right side of the card)
            $tagBorder = New-Object System.Windows.Controls.Border
            $tagBorder.BorderBrush = Get-Brush "#059669"
            $tagBorder.BorderThickness = 1
            $tagBorder.Background = Get-Brush "#022C22"
            $tagBorder.CornerRadius = 4
            $tagBorder.Padding = "6,2"
            $tagBorder.VerticalAlignment = "Center"
            $tagBorder.SetValue([System.Windows.Controls.DockPanel]::DockProperty, [System.Windows.Controls.Dock]::Right)
            
            $tagText = New-Object System.Windows.Controls.TextBlock
            $tagText.Text = if ($gpu.Source -eq 'SMI') { "NVIDIA-SMI" } elseif ($gpu.Source -eq 'OHM/CIM') { "OHM/CIM" } else { "WMI/CIM" }
            $tagText.Foreground = Get-Brush "#34D399"
            $tagText.FontSize = 9
            $tagText.FontWeight = "Bold"
            $tagBorder.Child = $tagText
            
            # Left-aligned GPU Name
            $nameBlock = New-Object System.Windows.Controls.TextBlock
            $nameBlock.Text = $gpu.Name
            $nameBlock.Foreground = Get-Brush "#FFFFFF"
            $nameBlock.FontSize = 15
            $nameBlock.FontWeight = "Bold"
            $nameBlock.TextWrapping = "Wrap"
            $nameBlock.VerticalAlignment = "Center"
            
            $gpuNameDock.Children.Add($tagBorder) | Out-Null
            $gpuNameDock.Children.Add($nameBlock) | Out-Null
            $cardStack.Children.Add($gpuNameDock) | Out-Null
            
            # Separator line
            $sep = New-Object System.Windows.Controls.Border
            $sep.Height = 1
            $sep.Background = Get-Brush "#1E293B"
            $sep.Margin = "0,4,0,10"
            $cardStack.Children.Add($sep) | Out-Null
            
            # Grid for Stats (Dedicated VRAM and Resolution)
            $grid = New-Object System.Windows.Controls.Grid
            
            $col0 = New-Object System.Windows.Controls.ColumnDefinition
            $col0.Width = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star)
            $col1 = New-Object System.Windows.Controls.ColumnDefinition
            $col1.Width = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star)
            
            $grid.ColumnDefinitions.Add($col0)
            $grid.ColumnDefinitions.Add($col1)
            
            # VRAM Stack (Col 0)
            $vramWrap = New-Object System.Windows.Controls.WrapPanel
            $vramWrap.Margin = "0,0,0,4"
            
            $lblVram = New-Object System.Windows.Controls.TextBlock
            $lblVram.Text = "Dedicated VRAM: "
            $lblVram.Foreground = Get-Brush "#64748B"
            $lblVram.FontSize = 11
            
            $valVram = New-Object System.Windows.Controls.TextBlock
            $valVram.Text = "$($gpu.VRAM_GB) GB"
            $valVram.Foreground = Get-Brush "#FFFFFF"
            $valVram.FontSize = 11
            $valVram.FontWeight = "Bold"
            
            $vramWrap.Children.Add($lblVram) | Out-Null
            $vramWrap.Children.Add($valVram) | Out-Null
            $vramWrap.SetValue([System.Windows.Controls.Grid]::ColumnProperty, 0)
            $grid.Children.Add($vramWrap) | Out-Null
            
            # Resolution Stack (Col 1)
            $resWrap = New-Object System.Windows.Controls.WrapPanel
            $resWrap.Margin = "0,0,0,4"
            
            $lblRes = New-Object System.Windows.Controls.TextBlock
            $lblRes.Text = "Resolution: "
            $lblRes.Foreground = Get-Brush "#64748B"
            $lblRes.FontSize = 11
            
            $resText = if ($gpu.Resolution) { $gpu.Resolution } else { "2880 x 1800" }
            $valRes = New-Object System.Windows.Controls.TextBlock
            $valRes.Text = $resText
            $valRes.Foreground = Get-Brush "#FFFFFF"
            $valRes.FontSize = 11
            $valRes.FontWeight = "Bold"
            
            $resWrap.Children.Add($lblRes) | Out-Null
            $resWrap.Children.Add($valRes) | Out-Null
            $resWrap.SetValue([System.Windows.Controls.Grid]::ColumnProperty, 1)
            $grid.Children.Add($resWrap) | Out-Null
            
            $cardStack.Children.Add($grid) | Out-Null
            
            # Grid for Driver Version and Temperature (Symmetrical Layout)
            $grid2 = New-Object System.Windows.Controls.Grid
            $col2_0 = New-Object System.Windows.Controls.ColumnDefinition
            $col2_0.Width = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star)
            $col2_1 = New-Object System.Windows.Controls.ColumnDefinition
            $col2_1.Width = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star)
            $grid2.ColumnDefinitions.Add($col2_0)
            $grid2.ColumnDefinitions.Add($col2_1)

            # Driver version text (Col 0)
            $driverWrap = New-Object System.Windows.Controls.WrapPanel
            $driverWrap.Margin = "0,4,0,8"
            
            $lblDriver = New-Object System.Windows.Controls.TextBlock
            $lblDriver.Text = "Driver Version: "
            $lblDriver.Foreground = Get-Brush "#64748B"
            $lblDriver.FontSize = 11
            
            $valDriver = New-Object System.Windows.Controls.TextBlock
            $valDriver.Text = $gpu.DriverVersion
            $valDriver.Foreground = Get-Brush "#94A3B8"
            $valDriver.FontSize = 11
            $valDriver.FontWeight = "Medium"
            
            $driverWrap.Children.Add($lblDriver) | Out-Null
            $driverWrap.Children.Add($valDriver) | Out-Null
            $driverWrap.SetValue([System.Windows.Controls.Grid]::ColumnProperty, 0)
            $grid2.Children.Add($driverWrap) | Out-Null
            
            # Temp (instead of nvidia-smi Thermal Node) placed in the same style (Col 1)
            if ($gpu.TemperatureC -gt 0 -and $null -ne $gpu.TemperatureC) {
                $tempWrap = New-Object System.Windows.Controls.WrapPanel
                $tempWrap.Margin = "0,4,0,8"
                
                $lblTemp = New-Object System.Windows.Controls.TextBlock
                $lblTemp.Text = "Temp: "
                $lblTemp.Foreground = Get-Brush "#64748B"
                $lblTemp.FontSize = 11
                
                $valTemp = New-Object System.Windows.Controls.TextBlock
                $valTemp.Text = "$($gpu.TemperatureC) C"
                $valTemp.Foreground = if ($gpu.TemperatureC -ge 80) { [System.Windows.Media.Brushes]::Red } else { Get-Brush "#10B981" }
                $valTemp.FontSize = 11
                $valTemp.FontWeight = "Bold"
                
                $tempWrap.Children.Add($lblTemp) | Out-Null
                $tempWrap.Children.Add($valTemp) | Out-Null
                $tempWrap.SetValue([System.Windows.Controls.Grid]::ColumnProperty, 1)
                $grid2.Children.Add($tempWrap) | Out-Null
            }
            $cardStack.Children.Add($grid2) | Out-Null
            
            # PHYSICAL SCREEN SIZE details (Monitor)
            try {
                $monitors = Get-MonitorInfo
                if ($monitors -and -not $monitors.Error) {
                    # Add Monitor label
                    $lblScreen = New-Object System.Windows.Controls.TextBlock
                    $lblScreen.Text = "PHYSICAL SCREEN SIZE"
                    $lblScreen.Foreground = Get-Brush "#64748B"
                    $lblScreen.FontSize = 10
                    $lblScreen.FontWeight = "SemiBold"
                    $lblScreen.Margin = "0,8,0,4"
                    $cardStack.Children.Add($lblScreen) | Out-Null
                    
                    $idx = 0
                    foreach ($m in $monitors) {
                        $letter = [char](65 + $idx)
                        $screenBorder = New-Object System.Windows.Controls.Border
                        $screenBorder.Background = Get-Brush "#0F1728"
                        $screenBorder.Padding = 8
                        $screenBorder.Margin = "0,2,0,2"
                        $screenBorder.CornerRadius = 4
                        
                        $screenStack = New-Object System.Windows.Controls.StackPanel
                        
                        $title = New-Object System.Windows.Controls.TextBlock
                        $title.Text = "Screen: Monitor $letter"
                        $title.FontWeight = "SemiBold"
                        $title.FontSize = 11
                        $title.TextWrapping = "Wrap"
                        $screenStack.Children.Add($title) | Out-Null
                        
                        $details = New-Object System.Windows.Controls.TextBlock
                        $details.Text = "Dimensions: $($m.WidthCm) x $($m.HeightCm) cm | Diagonal: $([string]$m.DiagonalInches) Inch"
                        $details.FontSize = 10
                        $details.Foreground = Get-Brush "#94A3B8"
                        $details.TextWrapping = "Wrap"
                        $screenStack.Children.Add($details) | Out-Null
                        
                        $screenBorder.Child = $screenStack
                        $cardStack.Children.Add($screenBorder) | Out-Null
                        $idx++
                    }
                }
            } catch {}
            
            $cardBorder.Child = $cardStack
            $ui['StkGPUContent'].Children.Add($cardBorder) | Out-Null
        }
    } catch {
        $ui['StkGPUContent'].Children.Clear()
    }
    $ui['TxtStatus'].Text = "READY"
}

# 6. Storage Solid state
$updateStorage = {
    $ui['TxtStatus'].Text = "MEASURING DRIVE BLOCKS..."
    [System.Windows.Forms.Application]::DoEvents()
    try {
        $disks = Get-StorageInfo
        $localIsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        $ui['StkStorageContent'].Children.Clear()
        
        foreach ($disk in $disks) {
            if ($disk.Error) {
                # Safe display of No SSD fallback
                $tx = New-Object System.Windows.Controls.TextBlock
                $tx.Text = $disk.Error
                $tx.Foreground = [System.Windows.Media.Brushes]::Orange
                $tx.TextWrapping = "Wrap"
                $ui['StkStorageContent'].Children.Add($tx) | Out-Null
                continue
            }
            
            # SSD Card Container
            $border = New-Object System.Windows.Controls.Border
            $border.Background = Get-Brush "#0F172A"
            $border.BorderBrush = Get-Brush "#1E293B"
            $border.BorderThickness = 1
            $border.Padding = 12
            $border.Margin = "0,6,0,6"
            $border.CornerRadius = 8
            
            $stack = New-Object System.Windows.Controls.StackPanel
            
            # Header DockPanel
            $headerDock = New-Object System.Windows.Controls.DockPanel
            $headerDock.LastChildFill = $true
            $headerDock.Margin = "0,0,0,6"
            
            # Interface Badge Border (Docked Right)
            $badgeBorder = New-Object System.Windows.Controls.Border
            $badgeBorder.CornerRadius = 4
            $badgeBorder.Padding = "8,3"
            $badgeBorder.VerticalAlignment = "Center"
            $badgeBorder.SetValue([System.Windows.Controls.DockPanel]::DockProperty, [System.Windows.Controls.Dock]::Right)
            
            $badgeTxt = New-Object System.Windows.Controls.TextBlock
            $badgeTxt.FontSize = 10
            $badgeTxt.FontWeight = "Bold"
            
            if ($disk.InterfaceType -eq 'NVMe') {
                $badgeBorder.Background = Get-Brush "#0F1F38"
                $badgeBorder.BorderBrush = Get-Brush "#3B82F6"
                $badgeBorder.BorderThickness = 1
                $badgeTxt.Foreground = Get-Brush "#60A5FA"
                $badgeTxt.Text = "NVMe"
            } else {
                $badgeBorder.Background = Get-Brush "#2C170B"
                $badgeBorder.BorderBrush = Get-Brush "#F97316"
                $badgeBorder.BorderThickness = 1
                $badgeTxt.Foreground = Get-Brush "#FDBA74"
                $badgeTxt.Text = "SATA"
            }
            $badgeBorder.Child = $badgeTxt
            $headerDock.Children.Add($badgeBorder) | Out-Null
            
            # Title Text (FriendlyName only)
            $lbl = New-Object System.Windows.Controls.TextBlock
            $lbl.Text = "$($disk.FriendlyName)"
            $lbl.FontWeight = "SemiBold"
            $lbl.FontSize = 11
            $lbl.Foreground = Get-Brush "#FFFFFF"
            $lbl.TextWrapping = "NoWrap"
            $lbl.TextTrimming = "CharacterEllipsis"
            $lbl.VerticalAlignment = "Center"
            $headerDock.Children.Add($lbl) | Out-Null
            
            $stack.Children.Add($headerDock) | Out-Null

            # Size on a newline
            $diskSizeLbl = New-Object System.Windows.Controls.TextBlock
            $diskSizeLbl.Text = "Disk Size: $($disk.SizeGB) GB"
            $diskSizeLbl.FontWeight = "Bold"
            $diskSizeLbl.FontSize = 11
            $diskSizeLbl.Foreground = Get-Brush "#FFFFFF"
            $diskSizeLbl.Margin = "0,2,0,2"
            $stack.Children.Add($diskSizeLbl) | Out-Null

            # Subtitle (Operation and Health combined)
            $subTitle = New-Object System.Windows.Controls.TextBlock
            $subTitle.Text = "Operation: $($disk.OperationalStatus) | Health: $($disk.HealthStatus)"
            $subTitle.FontSize = 11
            $subTitle.Foreground = Get-Brush "#94A3B8"
            $subTitle.Margin = "0,0,0,10"
            $stack.Children.Add($subTitle) | Out-Null

            # Display partitioned block (put partitioned space above the stats card)
            $alloc = New-Object System.Windows.Controls.TextBlock
            $alloc.Text = "Partitioned Space: $($disk.AllocatedGB) GB of $($disk.SizeGB) GB ($([math]::Round(100 - $disk.UnallocatedPercent, 1))% allocated)"
            $alloc.FontSize = 11
            $alloc.Margin = "0,2,0,8"
            $alloc.TextWrapping = "Wrap"
            $alloc.Foreground = Get-Brush "#94A3B8"
            $stack.Children.Add($alloc) | Out-Null
            
            # Also optionally display the unallocated overprovisioning block
            if ($disk.UnallocatedPercent -ge 5 -or $disk.AllocationWarning) {
                $opWarning = New-Object System.Windows.Controls.TextBlock
                $opWarning.Text = "Overprovisioning: $($disk.UnallocatedPercent)% unallocated (Provisioned: $($disk.AllocatedGB) GB)"
                $opWarning.FontSize = 10
                $opWarning.Margin = "0,0,0,8"
                $opWarning.TextWrapping = "Wrap"
                $opWarning.Foreground = Get-Brush "#EF4444"
                $stack.Children.Add($opWarning) | Out-Null
            }

            # Only show card with life wear / diagnostics info in admin mode because there is nothing to see in non admin mode
            if ($localIsAdmin) {
                $statsBox = New-Object System.Windows.Controls.Border
                $statsBox.Background = Get-Brush "#0A0F1D"
                $statsBox.BorderBrush = Get-Brush "#1E293B"
                $statsBox.BorderThickness = 1
                $statsBox.CornerRadius = 6
                $statsBox.Padding = 12
                $statsBox.Margin = "0,4,0,0"
                
                $statsGrid = New-Object System.Windows.Controls.Grid
                $scol1 = New-Object System.Windows.Controls.ColumnDefinition
                $scol1.Width = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star)
                $scol2 = New-Object System.Windows.Controls.ColumnDefinition
                $scol2.Width = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star)
                $statsGrid.ColumnDefinitions.Add($scol1) | Out-Null
                $statsGrid.ColumnDefinitions.Add($scol2) | Out-Null
                
                $srow1 = New-Object System.Windows.Controls.RowDefinition
                $srow1.Height = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Auto)
                $srow2 = New-Object System.Windows.Controls.RowDefinition
                $srow2.Height = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Auto)
                $statsGrid.RowDefinitions.Add($srow1) | Out-Null
                $statsGrid.RowDefinitions.Add($srow2) | Out-Null
                
                # Row 0 Col 0: Life Wear
                $wearTag = New-Object System.Windows.Controls.TextBlock
                $wearTag.FontSize = 10
                $wearTag.Foreground = Get-Brush "#64748B"
                $wearTag.Text = "Life Wear: "
                
                $wearVal = New-Object System.Windows.Controls.TextBlock
                $wearVal.FontSize = 10
                $wearVal.Text = if ($disk.Metrics -and $disk.Metrics.Wear) { "$($disk.Metrics.Wear)" } else { "N/A" }
                $wearVal.Foreground = Get-Brush "#10B981"
                $wearVal.FontWeight = "Bold"
                
                $wearWrap = New-Object System.Windows.Controls.WrapPanel
                $wearWrap.Children.Add($wearTag) | Out-Null
                $wearWrap.Children.Add($wearVal) | Out-Null
                $wearWrap.SetValue([System.Windows.Controls.Grid]::RowProperty, 0)
                $wearWrap.SetValue([System.Windows.Controls.Grid]::ColumnProperty, 0)
                $wearWrap.Margin = "0,0,0,6"
                $statsGrid.Children.Add($wearWrap) | Out-Null
                
                # Row 0 Col 1: Power Hours
                $pohTag = New-Object System.Windows.Controls.TextBlock
                $pohTag.FontSize = 10
                $pohTag.Foreground = Get-Brush "#64748B"
                $pohTag.Text = "Power Hours: "
                
                $pohVal = New-Object System.Windows.Controls.TextBlock
                $pohVal.FontSize = 10
                $pohVal.Text = if ($disk.Metrics -and $disk.Metrics.PowerOnHours) { "$($disk.Metrics.PowerOnHours)" } else { "N/A" }
                $pohVal.Foreground = Get-Brush "#FFFFFF"
                $pohVal.FontWeight = "Bold"
                
                $pohWrap = New-Object System.Windows.Controls.WrapPanel
                $pohWrap.Children.Add($pohTag) | Out-Null
                $pohWrap.Children.Add($pohVal) | Out-Null
                $pohWrap.SetValue([System.Windows.Controls.Grid]::RowProperty, 0)
                $pohWrap.SetValue([System.Windows.Controls.Grid]::ColumnProperty, 1)
                $pohWrap.Margin = "0,0,0,6"
                $statsGrid.Children.Add($pohWrap) | Out-Null
                
                # Row 1 Col 0: Temp
                $tempTag = New-Object System.Windows.Controls.TextBlock
                $tempTag.FontSize = 10
                $tempTag.Foreground = Get-Brush "#64748B"
                $tempTag.Text = "Temp: "
                
                $tempVal = New-Object System.Windows.Controls.TextBlock
                $tempVal.FontSize = 10
                $tempVal.Text = if ($disk.Metrics -and $disk.Metrics.Temperature) { "$($disk.Metrics.Temperature)" } else { "N/A" }
                $tempVal.Foreground = Get-Brush "#FBBF24"
                $tempVal.FontWeight = "Bold"
                
                $tempWrap = New-Object System.Windows.Controls.WrapPanel
                $tempWrap.Children.Add($tempTag) | Out-Null
                $tempWrap.Children.Add($tempVal) | Out-Null
                $tempWrap.SetValue([System.Windows.Controls.Grid]::RowProperty, 1)
                $tempWrap.SetValue([System.Windows.Controls.Grid]::ColumnProperty, 0)
                $statsGrid.Children.Add($tempWrap) | Out-Null
                
                # Row 1 Col 1: IO Errors
                $errTag = New-Object System.Windows.Controls.TextBlock
                $errTag.FontSize = 10
                $errTag.Foreground = Get-Brush "#64748B"
                $errTag.Text = "IO Errors: "
                
                $errVal = New-Object System.Windows.Controls.TextBlock
                $errVal.FontSize = 10
                $errVal.Text = if ($disk.Metrics -and $null -ne $disk.Metrics.WriteErrors) { "$($disk.Metrics.WriteErrors)" } else { "0" }
                $errVal.Foreground = Get-Brush "#EF4444"
                $errVal.FontWeight = "Bold"
                
                $errWrap = New-Object System.Windows.Controls.WrapPanel
                $errWrap.Children.Add($errTag) | Out-Null
                $errWrap.Children.Add($errVal) | Out-Null
                $errWrap.SetValue([System.Windows.Controls.Grid]::RowProperty, 1)
                $errWrap.SetValue([System.Windows.Controls.Grid]::ColumnProperty, 1)
                $statsGrid.Children.Add($errWrap) | Out-Null
                
                $statsBox.Child = $statsGrid
                $stack.Children.Add($statsBox) | Out-Null
            }
            
            $border.Child = $stack
            $ui['StkStorageContent'].Children.Add($border) | Out-Null
        }
    } catch {
        $ui['StkStorageContent'].Children.Clear()
    }
    $ui['TxtStatus'].Text = "READY"
}

# 7. Security / BitLocker
$updateSecurity = {
    $ui['TxtStatus'].Text = "POLICING PRIVILEGES..."
    [System.Windows.Forms.Application]::DoEvents()
    try {
        # Autopilot
        $ap = Get-AutopilotMDMInfo
        $ui['TxtAutopilotStatus'].Text = $ap.Status
        if ($ap.AutopilotEnrolled) {
            $ui['TxtAutopilotDomain'].Text = "Tenant Domain: $($ap.TenantDomain)"
            $ui['TxtAutopilotDomain'].Visibility = [System.Windows.Visibility]::Visible
        } else {
            $ui['TxtAutopilotDomain'].Visibility = [System.Windows.Visibility]::Collapsed
        }
        
        # BitLocker
        $bl = Get-BitLockerStatus
        if ($bl.Status -eq 'Admin rights required') {
            $ui['TxtBitLocker'].Text = "BitLocker status REQUIRES Administrator escalation"
            $ui['TxtBitLocker'].Foreground = [System.Windows.Media.Brushes]::Orange
        } elseif ($bl.VolumeStatus) {
            $ui['TxtBitLocker'].Text = "C: is $($bl.VolumeStatus) ($($bl.EncryptionPercentage)%)"
            if ($bl.IsDecrypted) {
                $ui['TxtBitLocker'].Foreground = [System.Windows.Media.Brushes]::Red
            } else {
                $ui['TxtBitLocker'].Foreground = [System.Windows.Media.Brushes]::LimeGreen
            }
        } else {
            $ui['TxtBitLocker'].Text = "C: No Encryption Volume Detected (Disabled)"
            $ui['TxtBitLocker'].Foreground = [System.Windows.Media.Brushes]::LimeGreen
        }

        # Secure Boot
        $sb = Get-SecureBootStatus
        $ui['TxtSecureBoot'].Text = "$($sb.Status) - $($sb.Details)"
        if ($sb.Enabled) {
            $ui['TxtSecureBoot'].Foreground = [System.Windows.Media.Brushes]::LimeGreen
        } else {
            if ($sb.Status -eq "Disabled") {
                $ui['TxtSecureBoot'].Foreground = [System.Windows.Media.Brushes]::Red
            } else {
                $ui['TxtSecureBoot'].Foreground = [System.Windows.Media.Brushes]::Orange
            }
        }
        
        # Ping
        $ping = Test-NetworkConnection
        $ui['TxtNetwork'].Text = "$($ping.StatusMessage)"
        if ($ping.Online) {
            if ($ping.RoundtripMs) { $ui['TxtNetwork'].Text += " (RTT: $($ping.RoundtripMs) ms)" }
            $ui['TxtNetwork'].Foreground = [System.Windows.Media.Brushes]::LimeGreen
        } else {
            $ui['TxtNetwork'].Foreground = [System.Windows.Media.Brushes]::Red
        }
    } catch {
         $ui['TxtAutopilotStatus'].Text = "Autopilot assess failure"
    }
    $ui['TxtStatus'].Text = "READY"
}

# 8. Device drivers error checks
$updateProblems = {
    $ui['TxtStatus'].Text = "SCANNING BUS CONTROLLER..."
    [System.Windows.Forms.Application]::DoEvents()
    try {
        $problems = Get-DeviceProblems
        $ui['StkProblemsContent'].Children.Clear()
        
        if ($problems.Count -eq 0) {
            $tx = New-Object System.Windows.Controls.TextBlock
            $tx.Text = "No errors reported."
            $tx.Foreground = [System.Windows.Media.Brushes]::LimeGreen
            $tx.FontStyle = [System.Windows.FontStyles]::Italic
            $tx.FontSize = 11
            $tx.TextWrapping = "Wrap"
            $ui['StkProblemsContent'].Children.Add($tx) | Out-Null
        } else {
            foreach ($d in $problems) {
                $border = New-Object System.Windows.Controls.Border
                $border.Background = Get-Brush "#0F1728"
                $border.BorderBrush = [System.Windows.Media.Brushes]::Red
                $border.BorderThickness = "1,0,0,0"
                $border.Padding = 8
                $border.Margin = "0,2,0,2"
                
                $stack = New-Object System.Windows.Controls.StackPanel
                
                $title = New-Object System.Windows.Controls.TextBlock
                $title.Text = "Error: " + $d.Name
                $title.FontWeight = "Bold"
                $title.Foreground = [System.Windows.Media.Brushes]::Coral
                $title.FontSize = 11
                $title.TextWrapping = "Wrap"
                $stack.Children.Add($title) | Out-Null
                
                $errLoc = New-Object System.Windows.Controls.TextBlock
                $errLoc.Text = "Hardware Error Code: $($d.ErrorCode) | $($d.Description)"
                $errLoc.FontSize = 10
                $errLoc.TextWrapping = [System.Windows.TextWrapping]::Wrap
                $errLoc.Foreground = Get-Brush "#E2E8F0"
                $stack.Children.Add($errLoc) | Out-Null
                
                $border.Child = $stack
                $ui['StkProblemsContent'].Children.Add($border) | Out-Null
            }
        }
    } catch {
        $ui['StkProblemsContent'].Children.Clear()
    }
    $ui['TxtStatus'].Text = "READY"
}

# Helper function to print reports with correct layout, table columns, weights, and colors
function Out-SoftwareReports {
    param($ReportsList)
    $ui['StkSoftwareReports'].Children.Clear()
    foreach ($r in $ReportsList) {
        $grid = New-Object System.Windows.Controls.Grid
        $grid.Margin = "0,3,0,3"
        
        $col1 = New-Object System.Windows.Controls.ColumnDefinition
        $col1.Width = New-Object System.Windows.GridLength(110)
        $col2 = New-Object System.Windows.Controls.ColumnDefinition
        $col2.Width = New-Object System.Windows.GridLength(70)
        $col3 = New-Object System.Windows.Controls.ColumnDefinition
        $col3.Width = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star)
        
        $grid.ColumnDefinitions.Add($col1) | Out-Null
        $grid.ColumnDefinitions.Add($col2) | Out-Null
        $grid.ColumnDefinitions.Add($col3) | Out-Null
        
        $comp = New-Object System.Windows.Controls.TextBlock
        $comp.Text = $r.Component
        $comp.FontWeight = "SemiBold"
        $comp.TextWrapping = "Wrap"
        [System.Windows.Controls.Grid]::SetColumn($comp, 0)
        $grid.Children.Add($comp) | Out-Null
        
        $status = New-Object System.Windows.Controls.TextBlock
        $status.Text = "[" + $r.Status + "]"
        $status.FontWeight = "Black"
        $status.TextWrapping = "Wrap"
        $status.Foreground = if ($r.Status -eq 'OK' -or $r.Status -eq 'Clean') { [System.Windows.Media.Brushes]::LimeGreen } elseif ($r.Status -eq 'Pending') { Get-Brush "#38BDF8" } else { [System.Windows.Media.Brushes]::Orange }
        [System.Windows.Controls.Grid]::SetColumn($status, 1)
        $grid.Children.Add($status) | Out-Null
        
        $detail = New-Object System.Windows.Controls.TextBlock
        $detail.Text = $r.Details + (if ($null -ne $r.Total -and $r.Total -gt 0) { " (Found: $($r.Total))" } else { "" })
        $detail.FontSize = 10
        $detail.TextWrapping = "Wrap"
        $detail.Foreground = Get-Brush "#94A3B8"
        [System.Windows.Controls.Grid]::SetColumn($detail, 2)
        $grid.Children.Add($detail) | Out-Null
        
        $ui['StkSoftwareReports'].Children.Add($grid) | Out-Null
    }
}

# 9. Bloatware & Windows updates assessment
$updateSoftware = {
    $ui['TxtStatus'].Text = "POLICING APP MANIFEST..."
    [System.Windows.Forms.Application]::DoEvents()
    try {
        $bloat = Get-BloatwareCheck
        $ui['TxtBloatwareStatus'].Text = $bloat.Status
        if ($bloat.Status -eq 'Clean') {
            $ui['TxtBloatwareStatus'].Foreground = [System.Windows.Media.Brushes]::LimeGreen
            $ui['TxtBloatwareDetails'].Visibility = [System.Windows.Visibility]::Collapsed
        } else {
            $ui['TxtBloatwareStatus'].Foreground = [System.Windows.Media.Brushes]::Orange
            if ($bloat.HPSoftwareList) {
                $ui['TxtBloatwareDetails'].Text = "Detected: " + ($bloat.HPSoftwareList -join ', ')
                $ui['TxtBloatwareDetails'].Visibility = [System.Windows.Visibility]::Visible
            }
        }
    } catch {
        $ui['TxtBloatwareStatus'].Text = "Diagnostics crash safely."
    }
    
    # Draw initially pending report on startup
    try {
        $reports = Get-SoftwareHealthReport -SkipUpdateSearch:$true -SkipWingetSearch:$true
        Out-SoftwareReports $reports
    } catch {
        # Silent fallback
    }
    $ui['TxtStatus'].Text = "READY"
}

# 10. Check Updates triggered check
$updateApps = {
    $ui['TxtStatus'].Text = "CHECKING WINDOWS UPDATES..."
    [System.Windows.Forms.Application]::DoEvents()
    try {
        $reports = Get-SoftwareHealthReport -SkipUpdateSearch:$false -SkipWingetSearch:$false
        Out-SoftwareReports $reports
    } catch {
        $ui['TxtStatus'].Text = "ERROR CHECKING UPDATES"
    }
    $ui['TxtStatus'].Text = "READY"
}

# --- Core Run All event triggers ---
$runAllModules = {
    $ui['TxtStatus'].Text = "RUNNING ALL TESTS..."
    $ui['TxtStatus'].Background = [System.Windows.Media.Brushes]::Red
    [System.Windows.Forms.Application]::DoEvents()

    & $updateSys
    & $updateCPU
    & $updateBattery
    & $updateMemory
    & $updateGPU
    & $updateStorage
    & $updateSecurity
    & $updateProblems
    & $updateSoftware
    & $updateApps

    $ui['TxtStatus'].Text = "SUCCESS"
    $ui['TxtStatus'].Background = Get-Brush "#10B981"
}

# ========== BIND CLICKS EVENT CHANNELS ==========
$ui['BtnUpdateSys'].Add_Click($updateSys)
$ui['BtnUpdateCPU'].Add_Click($updateCPU)
$ui['BtnUpdateBattery'].Add_Click($updateBattery)
$ui['BtnUpdateMemory'].Add_Click($updateMemory)
$ui['BtnUpdateGPU'].Add_Click($updateGPU)
$ui['BtnUpdateStorage'].Add_Click($updateStorage)
$ui['BtnUpdateSecurity'].Add_Click($updateSecurity)
$ui['BtnUpdateProblems'].Add_Click($updateProblems)
$ui['BtnUpdateSoftware'].Add_Click($updateSoftware)
$ui['BtnUpdateApps'].Add_Click($updateApps)

if ($ui['BtnRunAll']) { $ui['BtnRunAll'].Add_Click($runAllModules) }
if ($ui['BtnClose']) { $ui['BtnClose'].Add_Click({ $window.Close() }) }

# ========== INITIAL START LOADING (EVENT DRIVEN FIRST TICK) ==========
$window.Add_ContentRendered({
    & $updateSys
    & $updateCPU
    & $updateBattery
    & $updateMemory
    & $updateGPU
    & $updateStorage
    & $updateSecurity
    & $updateProblems
    & $updateSoftware
})

$window.Add_Closed({
    if ($global:OHMComputer) {
        try { $global:OHMComputer.Close() } catch {}
        $global:OHMComputer = $null
    }
})

# Display Window natively safely
$window.ShowDialog() | Out-Null
