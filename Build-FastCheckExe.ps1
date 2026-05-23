#Requires -Version 5.1
<#
.SYNOPSIS
    Builds Fastcheck.exe from FastCheck.ps1 using ps2exe (STA, no console).
    Copies FastCheck.Core.ps1 and FastCheck.UI.ps1 beside the exe for runspace loading.
#>
$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $PSScriptRoot

$entryPath  = Join-Path $PSScriptRoot 'FastCheck.ps1'
$corePath   = Join-Path $PSScriptRoot 'FastCheck.Core.ps1'
$uiPath     = Join-Path $PSScriptRoot 'FastCheck.UI.ps1'
$iconPath   = Join-Path $PSScriptRoot 'laptop.ico'
$outExe     = Join-Path $PSScriptRoot 'Fastcheck.exe'

foreach ($path in @($entryPath, $corePath, $uiPath, $iconPath)) {
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Required file not found: $path"
    }
}

if (-not (Get-Module -ListAvailable -Name ps2exe)) {
    Install-Module -Name ps2exe -Scope CurrentUser -Repository PSGallery -Force -AllowClobber
}

Import-Module -Name ps2exe

$ps2exeParams = @{
    inputFile  = $entryPath
    outputFile = $outExe
    iconFile   = $iconPath
    title      = 'Fastcheck by Yordi'
    version    = '1.0'
    STA        = $true
    noConsole  = $true
}

Invoke-PS2EXE @ps2exeParams

Write-Host "Built: $outExe"
Write-Host "Ship Fastcheck.exe together with FastCheck.Core.ps1 and FastCheck.UI.ps1 from this folder."
