#Requires -Version 5.1
<#
.SYNOPSIS
    Builds Fastcheck.exe from FastCheck.ps1 using the ps2exe module.
#>
$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $PSScriptRoot

# Paths are relative to this repo folder so the script works after any GitHub clone path.
$sourcePs1 = '.\FastCheck.ps1'
$iconPath   = '.\laptop.ico'
$outExe     = '.\Fastcheck.exe'

if (-not (Test-Path -LiteralPath $sourcePs1)) {
    throw "Source script not found: $sourcePs1"
}
if (-not (Test-Path -LiteralPath $iconPath)) {
    throw "Icon not found: $iconPath"
}

if (-not (Get-Module -ListAvailable -Name ps2exe)) {
    Install-Module -Name ps2exe -Scope CurrentUser -Repository PSGallery -Force -AllowClobber
}

Import-Module -Name ps2exe

# ps2exe uses -iconFile (not -icon). Positional args match: input script, output exe.
Invoke-PS2EXE -inputFile $sourcePs1 -outputFile $outExe -iconFile $iconPath -title 'Fastcheck by Yordi' -version '0.8'

Write-Host "Built: $outExe"
