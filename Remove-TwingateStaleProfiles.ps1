#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Deletes stale Twingate network profiles, preserving only the active connection.

.DESCRIPTION
    Enumerates registry profiles under NetworkList\Profiles and removes any whose
    ProfileName matches "Twingate*" but whose GUID does not match the active
    Twingate connection's InstanceID.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File Remove-TwingateStaleProfiles.ps1
#>

$profilesPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\NetworkList\Profiles"

Write-Host "`n=== Remove stale Twingate network profiles ===" -ForegroundColor Cyan

# --- Check Twingate service state ---
$svc = Get-Service -Name "Twingate.Service" -ErrorAction SilentlyContinue
if (-not $svc) {
    Write-Host "Service 'Twingate.Service' not found." -ForegroundColor Yellow
} elseif ($svc.Status -eq 'Running') {
    Write-Host "Service 'Twingate.Service' is running." -ForegroundColor Green
} else {
    Write-Host "Service 'Twingate.Service' is in state: $($svc.Status)" -ForegroundColor Yellow
    $kill = Read-Host "Do you want to kill the 'Twingate.Service.exe' process? (Y/N)"
    if ($kill -in @('Y', 'y')) {
        try {
            Stop-Process -Name "Twingate.Service" -Force -ErrorAction Stop
            Write-Host "Process 'Twingate.Service.exe' killed." -ForegroundColor Green
        } catch {
            Write-Host "Failed to kill process: $_" -ForegroundColor Red
        }
    }

}

# --- Detect active Twingate connection profile (by GUID) ---
$connectionProfile = @(Get-NetConnectionProfile -ErrorAction SilentlyContinue |
    Where-Object { $_.InterfaceAlias -like "*Twingate*" }) | Select-Object -First 1

$activeGUID = $null
if ($connectionProfile) {
    $activeGUID = $connectionProfile.InstanceID
    Write-Host "Active Twingate connection: '$($connectionProfile.Name)'" -ForegroundColor Cyan
    Write-Host "  InstanceID: $activeGUID" -ForegroundColor DarkGray

    # --- Export active connection profile registry key (if it exists in registry) ---
    $exportPath = "$env:USERPROFILE\Downloads\activeprofile.reg"
    $activeRegKey = Get-Item "$profilesPath\$activeGUID" -ErrorAction SilentlyContinue
    if ($activeRegKey) {
        & reg.exe export $activeRegKey.Name $exportPath /y 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  Exported to $exportPath" -ForegroundColor Green
        } else {
            Write-Host "  Failed to export profile." -ForegroundColor Red
        }
    }
} else {
    Write-Host "No active Twingate connection detected." -ForegroundColor Yellow
}

# --- Enumerate Twingate profiles (stale = GUID does not match active connection) ---
$staleProfiles = @()
Get-ChildItem $profilesPath -ErrorAction SilentlyContinue | ForEach-Object {
    $props = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
    if ($props.ProfileName -like "Twingate*") {
        $guid = $_.PSChildName
        if ($activeGUID -and $guid -eq $activeGUID) {
            Write-Host "Active profile kept:" -ForegroundColor Green
            Write-Host "  - $($props.ProfileName) ($guid)" -ForegroundColor Green
        } else {
            $staleProfiles += [PSCustomObject]@{
                Name   = $props.ProfileName
                GUID   = $guid
                PSPath = $_.PSPath
            }
        }
    }
}

if ($staleProfiles.Count -eq 0) {
    Write-Host "No stale Twingate profiles found." -ForegroundColor Green
    exit 0
}

Write-Host "Found $($staleProfiles.Count) stale profile(s):" -ForegroundColor Yellow
foreach ($profile in $staleProfiles) {
    Write-Host "  - $($profile.Name) ($($profile.GUID))" -ForegroundColor DarkGray
}

# --- Confirm before deleting ---
$answer = Read-Host "`nDo you want to delete these profile(s)? (Y/N)"
if ($answer -notin @('Y', 'y')) {
    Write-Host "Cancelled." -ForegroundColor Yellow
    exit 0
}

# --- Delete stale profiles ---
$deleted = 0
foreach ($profile in $staleProfiles) {
    Write-Host "Deleting '$($profile.Name)'..." -ForegroundColor Yellow -NoNewline
    try {
        Remove-Item $profile.PSPath -Recurse -Force -ErrorAction Stop
        Write-Host " done." -ForegroundColor Green
        $deleted++
    } catch {
        Write-Host " failed: $_" -ForegroundColor Red
    }
}

Write-Host "`nDeleted $deleted of $($staleProfiles.Count) stale profile(s).`n" -ForegroundColor Cyan
