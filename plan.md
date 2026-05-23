FastCheck WPF migration plan

Goals





Compatibility: PowerShell 5.1 + built-in .NET Framework (PresentationFramework, optional System.Windows.Forms for MessageBox / confirm dialogs). No .NET 6+ SDK or runtime required on fresh laptops.



Architecture: Backend returns structured objects; WPF UI on the STA main thread; heavy work in a runspace updating UI via [hashtable]::Synchronized + Dispatcher.Invoke.



Parity: Every check in the current script stays; add Secure Boot when admin; BitLocker still may call Disable-BitLocker, but only after an explicit confirmation dialog.

Current script inventory (465 lines)







Lines



Section



Console-only today



Target function





11–12



Admin flag



inline



Get-FastCheckContext





21–36



Show-Row, Show-Header



yes



Remove





39–68



Get-CimOrWmiInstance



shared infra



Keep in core (unchanged logic)





74–88



System & OS + license



Show-*



Get-SystemOsInfo





90–115



CPU + thermal zones



colors



Get-CpuInfo





116–120



BIOS



Show-*



Get-BiosInfo





122–165



Memory (per-DIMM, throttle warning)



colors



Get-MemoryInfo → MemorySticks[]





167–187



Display adapters (GPU filter)



Show-*



Get-DisplayAdapterInfo





189–203



Screen / monitor WMI



Show-*



Get-ScreenInfo





205–224



Autopilot / MDM



Show-*



Get-ExternalManagementInfo





226–244



BitLocker (+ Disable-BitLocker)



Show-*



Get-BitLockerInfo (+ UI confirm)





246–277



Storage SSDs + reliability (admin)



colors



Get-StorageInfo





279–332



Battery health + voltage check



Show-*



Get-BatteryInfo





334–343



Network ping



Show-*



Test-NetworkConnectivity





345–375



Device Manager problems



Get-ErrorDescription + Show-*



Get-DeviceManagerProblems





377–403



HP bloatware (non-HP)



Show-*



Get-HpBloatwareCheck





406–459



Software health (Appx, winget, WU, dumps)



Write-Progress, Format-Table



Get-SoftwareHealthInfo





—



(missing) Secure Boot



README only



Get-SecureBootInfo (new, admin)





9, 407–408, 451, 461–465



Clear-Host, Write-Progress, pause



yes



Remove; progress → syncHash

Proposed file layout

FastCheck/
  FastCheck.Core.ps1      # All diagnostic functions + Invoke-FastCheckDiagnostics
  FastCheck.UI.ps1        # XAML string, syncHash wiring, runspace, ShowDialog
  FastCheck.ps1           # Entry: dot-source Core + UI, require STA, launch app
  Build-FastCheckExe.ps1  # Update for STA + multi-file ps2exe if needed
  README.md               # Update run instructions + GUI + BitLocker confirm

Entry point stays .\FastCheck.ps1 for familiarity; core/UI split keeps the 465-line monolith maintainable.

Backend design

Shared context

function Get-FastCheckContext {
    [PSCustomObject]@{
        IsAdmin = ...
        RunAt   = Get-Date
    }
}

Pass $Context (or $IsAdmin) into functions that gate admin-only paths (BitLocker, storage reliability counters, Secure Boot).

Severity instead of console colors

Replace $ColorValue / "Red" / "Yellow" with a small enum-like string on each field or row:





OK, Warning, Error, Info, NotAvailable

Example — CPU temperature (same thresholds as today: 70 / 85 °C):

# Get-CpuInfo returns:
[PSCustomObject]@{
    Name = ...
    Cores = ...
    LogicalProcessors = ...
    TemperatureC = $maxTemp   # $null if not reported
    TemperatureSeverity = 'OK' | 'Warning' | 'Error' | 'NotAvailable'
}

Section return shapes (summary)





Scalar sections: single [PSCustomObject] (Get-SystemOsInfo, Get-CpuInfo, Get-BiosInfo, Get-BatteryInfo, Test-NetworkConnectivity, Get-ExternalManagementInfo, Get-HpBloatwareCheck, Get-SecureBootInfo).



Collection sections: @(...) (Get-MemoryInfo, Get-DisplayAdapterInfo, Get-ScreenInfo, Get-StorageInfo, Get-DeviceManagerProblems).



Software health: keep the existing row model (Component, Status, Total, Details) — already GUI-friendly; map [!!]/[OK] to Severity if useful for binding.



Master report from orchestrator:

function Invoke-FastCheckDiagnostics {
    param(
        [Parameter(Mandatory)]
        $Context,
        [scriptblock]$OnProgress,   # optional: section name for UI
        [scriptblock]$OnBitLockerConfirm  # returns $true to allow Disable-BitLocker
    )
    # Returns [PSCustomObject]@{ Context; Sections = ordered hashtable or named properties }
}

Run sections in the same order as today so behavior and dependencies stay predictable ($System used by HP check → orchestrator calls Get-SystemOsInfo first and passes manufacturer into Get-HpBloatwareCheck).

BitLocker (confirmed behavior)

Logic preserved from lines 226–244:





If not admin → return Status = 'AdminRequired', no cmdlet calls.



If admin and volume encrypted (not FullyDecrypted / DecryptionInProgress) → invoke $OnBitLockerConfirm (UI shows System.Windows.MessageBox Yes/No).



Only if user confirms → Disable-BitLocker -MountPoint C: (same as today).



Return structured status: VolumeStatus, EncryptionPercentage, ActionTaken (None | DecryptInitiated | AlreadyDecrypting), Severity.

Secure Boot (new, admin-only)

function Get-SecureBootInfo {
    param([bool]$IsAdmin)
    if (-not $IsAdmin) {
        return [PSCustomObject]@{ Enabled = $null; Status = 'AdminRequired'; Severity = 'Info' }
    }
    try {
        $enabled = Confirm-SecureBootUEFI
        [PSCustomObject]@{ Enabled = $enabled; Status = ...; Severity = ... }
    } catch {
        [PSCustomObject]@{ Enabled = $null; Status = $_.Exception.Message; Severity = 'NotAvailable' }
    }
}

Place after External Management or grouped with BitLocker in UI as “Security” — your choice at implementation time; orchestrator order: suggest after BitLocker in the security group.

Infrastructure to keep verbatim (logic)





[Get-CimOrWmiInstance](c:\Users\Yordi\Documents\GitHub\FastCheck\FastCheck.ps1) (lines 39–68)



License registry fallback (79–83)



Memory type map + throttle detection (127–157)



GPU name filter regex (169–174)



Monitor diagonal math (191–199)



Autopilot/MDM registry keys (207–217)



Storage SSD filter + allocation % (248–277)



Battery powercfg XML fallback + voltage tolerance 0.5 V (291–328)



PnP error codes 1,2,3,10,18,22,28,31 (Get-ErrorDescription)



HP registry scan paths (384–393)



Winget line counting, WU COM searcher, Get-DumpCount paths (410–459)

Remove from backend





Show-Row, Show-Header, color variables, Write-Host, Format-Table, Clear-Host, pause, Write-Progress

Use $OnProgress.Invoke("Memory") (or similar) from the orchestrator so the runspace can update syncHash.TxtStatus / syncHash.Progress.

Frontend design (minimal WPF)

flowchart LR
    subgraph mainThread [STA Main Thread]
        XAML[WPF Window]
        SyncHash[syncHash controls]
        Dispatcher[Dispatcher.Invoke]
    end
    subgraph bg [Background Runspace]
        Orchestrator[Invoke-FastCheckDiagnostics]
        Sections[Get-* functions]
    end
    XAML --> SyncHash
    BtnRun -->|BeginInvoke| Orchestrator
    Orchestrator --> Sections
    Sections -->|OnProgress| Dispatcher
    Orchestrator -->|final report| Dispatcher
    Dispatcher --> SyncHash

Controls (functional, not polished):





BtnRun — starts diagnostics; disabled while running



ProgressBar + TxtStatus — section name from $OnProgress



TreeView or ListView — bind/report sections after completion (e.g. parent nodes: System, CPU, Memory, …; children: key/value rows). Alternative: single ItemsControl with DataTemplate for section headers + nested items — pick simplest that works in PS 5.1 without extra NuGet.

Boilerplate (your pattern):





Add-Type -AssemblyName PresentationFramework



Optional: Add-Type -AssemblyName System.Windows.Forms only if needed beyond WPF MessageBox



[xml]$xaml → XamlReader::Load



$syncHash = [hashtable]::Synchronized(@{}) with Window, BtnRun, TxtStatus, Progress, result panel



BtnRun.Add_Click → create runspace, AddScript block calling Invoke-FastCheckDiagnostics with:





dot-sourced functions loaded in runspace or single bundled script block that dot-sources FastCheck.Core.ps1



$OnBitLockerConfirm implemented via Dispatcher.Invoke showing Yes/No dialog



On completion: Dispatcher.Invoke fills UI, re-enables button

STA requirement: WPF requires apartment state STA. Entry [FastCheck.ps1](c:\Users\Yordi\Documents\GitHub\FastCheck\FastCheck.ps1) should set at top:

if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    powershell -STA -File $PSCommandPath
    exit
}

Update [Build-FastCheckExe.ps1](c:\Users\Yordi\Documents\GitHub\FastCheck\Build-FastCheckExe.ps1) to pass ps2exe STA / merge scripts if the module supports bundling FastCheck.Core.ps1 + FastCheck.UI.ps1 into one exe (verify ps2exe -merge or concatenate dot-source at build time).

Migration steps (implementation order)





Extract FastCheck.Core.ps1: move Get-CimOrWmiInstance, Get-ErrorDescription, Get-DumpCount, then one function per section; add Get-SecureBootInfo and Invoke-FastCheckDiagnostics.



Validate backend in console (temporary): dot-source core, run Invoke-FastCheckDiagnostics, inspect $report | ConvertTo-Json -Depth 6 — no WPF yet.



Build FastCheck.UI.ps1 with XAML + syncHash + runspace; wire progress and BitLocker confirm.



Replace root FastCheck.ps1 with STA launcher that dot-sources Core + UI.



Update README (GUI usage, admin vs normal, BitLocker confirm, Secure Boot).



Adjust Build-FastCheckExe.ps1 for STA and multi-file packaging; smoke-test on non-admin and admin.

Testing checklist







Scenario



Expected





Normal user



All non-admin sections populate; BitLocker/Secure Boot/storage SMART show admin-required, not empty crash





Admin, BitLocker off



Status OK, no decrypt





Admin, BitLocker encrypted



Confirm dialog; Yes → Disable-BitLocker attempted; structured ActionTaken





Admin, BitLocker encrypted



No → report only, no cmdlet





Laptop with battery



Health % + voltage deviation logic unchanged





Desktop / VM



Battery “not detected”; CPU temp “not reported” where applicable





Non-HP machine with HP apps



Bloatware list populated





HP machine



Bloatware skipped message





Double-click Run



Button disabled until complete; UI stays responsive

Risks / notes





winget and Appx may be slow or absent — keep try/catch and existing fallbacks; show section errors in report Errors collection rather than failing whole run.



ps2exe + WPF: STA and embedding XAML string are critical; test exe on a clean VM without PowerShell 7.



README drift: Secure Boot will be implemented; BitLocker docs should mention confirmation dialog instead of silent decrypt.

