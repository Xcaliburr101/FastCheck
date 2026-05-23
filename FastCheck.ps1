#Requires -Version 5.1
<#
.SYNOPSIS
    FastCheck — hardware and system diagnostics (WPF GUI).
.DESCRIPTION
    PowerShell 5.1 / .NET Framework WPF application. Diagnostic logic lives in FastCheck.Core.ps1.
#>

function Get-WindowsPowerShellExePath {
    $psHomeExe = if ($PSHOME) { Join-Path $PSHOME 'powershell.exe' } else { $null }
    if ($psHomeExe -and (Test-Path -LiteralPath $psHomeExe)) { return $psHomeExe }

    $systemExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path -LiteralPath $systemExe) { return $systemExe }

    return $null
}

# WPF requires Windows PowerShell 5.1 (Desktop) in STA.
# Do not use (Get-Process -Id $PID).Path for relaunch — in VS Code/Cursor that is the editor host (exit code 5 / access denied).
$needsRelaunch = ($PSVersionTable.PSEdition -ne 'Desktop') -or
    ([Threading.Thread]::CurrentThread.GetApartmentState() -ne [Threading.ApartmentState]::STA)

if ($needsRelaunch) {
    $psExe = Get-WindowsPowerShellExePath
    if (-not $psExe) {
        Write-Error 'FastCheck requires Windows PowerShell 5.1 (powershell.exe).'
        exit 1
    }
    $scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
    if (-not $scriptDir) { $scriptDir = (Get-Location).Path }
    $arguments = "-STA -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    try {
        $proc = Start-Process -FilePath $psExe -ArgumentList $arguments -WorkingDirectory $scriptDir -Wait -PassThru
        exit $(if ($null -ne $proc.ExitCode) { $proc.ExitCode } else { 0 })
    } catch {
        Write-Error "Failed to start WPF host: $($_.Exception.Message)"
        exit 1
    }
}

$root = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($root)) { $root = (Get-Location).Path }

. (Join-Path $root 'FastCheck.Core.ps1')
. (Join-Path $root 'FastCheck.UI.ps1')

$coreScript = Join-Path $root 'FastCheck.Core.ps1'
if (-not (Test-Path -LiteralPath $coreScript)) {
    $coreScript = Join-Path (Split-Path -Parent $PSCommandPath) 'FastCheck.Core.ps1'
}
Start-FastCheckGui -CoreScriptPath $coreScript
