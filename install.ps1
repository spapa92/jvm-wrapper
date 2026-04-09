#Requires -Version 5.1
<#
.SYNOPSIS
    jvmw installer - sets up jvmw globally on Windows
.DESCRIPTION
    Copies jvmw.ps1 to a permanent location and adds it to PATH.
    Run once after downloading jvmw.ps1.
    Does NOT require elevation if installing to user profile only.
#>

param(
    [switch]$Global,   # Install to C:\Program Files\jvmw (needs elevation)
    [switch]$Uninstall
)

$ErrorActionPreference = "Stop"

$installDir = if ($Global) { "C:\Program Files\jvmw" } else { "$env:USERPROFILE\.jvmw\bin" }
$scriptSrc  = Join-Path $PSScriptRoot "jvmw.ps1"
$scriptDst  = Join-Path $installDir "jvmw.ps1"

# Create a small wrapper .cmd so you can call jvmw from cmd.exe too
$wrapperCmd = Join-Path $installDir "jvmw.cmd"
$wrapperContent = @"
@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0jvmw.ps1" %*
"@

if ($Uninstall) {
    Write-Host "  Uninstalling jvmw..." -ForegroundColor Yellow
    if (Test-Path $installDir) { Remove-Item $installDir -Recurse -Force }
    $scope = if ($Global) { "Machine" } else { "User" }
    $p = [System.Environment]::GetEnvironmentVariable("PATH", $scope)
    $p = ($p -split ';' | Where-Object { $_ -ne $installDir }) -join ';'
    [System.Environment]::SetEnvironmentVariable("PATH", $p, $scope)
    Write-Host "  ✓ jvmw uninstalled" -ForegroundColor Green
    exit 0
}

if (-not (Test-Path $scriptSrc)) {
    Write-Host "  ✗ jvmw.ps1 not found at: $scriptSrc" -ForegroundColor Red
    Write-Host "  Place install.ps1 next to jvmw.ps1 and re-run."
    exit 1
}

New-Item -ItemType Directory -Path $installDir -Force | Out-Null
Copy-Item $scriptSrc $scriptDst -Force
Set-Content -Path $wrapperCmd -Value $wrapperContent -Encoding ASCII

# Add to PATH
$scope = if ($Global) { "Machine" } else { "User" }
$currentPath = [System.Environment]::GetEnvironmentVariable("PATH", $scope)
if ($currentPath -notmatch [regex]::Escape($installDir)) {
    [System.Environment]::SetEnvironmentVariable("PATH", "$installDir;$currentPath", $scope)
    Write-Host "  ✓ Added to $scope PATH: $installDir" -ForegroundColor Green
} else {
    Write-Host "  ✓ Already in PATH: $installDir" -ForegroundColor Cyan
}

Write-Host ""
Write-Host "  ✓ jvmw installed to: $installDir" -ForegroundColor Green
Write-Host ""
Write-Host "  Restart your terminal, then run:" -ForegroundColor Gray
Write-Host "    jvmw help" -ForegroundColor White
Write-Host "    jvmw available --lts" -ForegroundColor White
Write-Host "    jvmw install 21" -ForegroundColor White
Write-Host ""
