#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Deletes all Twingate network profiles except the one named exactly "Twingate".

.DESCRIPTION
    Enumerates registry profiles under NetworkList\Profiles and removes any whose
    ProfileName matches "Twingate*" but is not exactly "Twingate".

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File Remove-TwingateStaleProfiles.ps1
#>

$profilesPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\NetworkList\Profiles"

Write-Host "`n=== Remove stale Twingate network profiles ===" -ForegroundColor Cyan

# --- Enumerate Twingate profiles ---
$activeProfile = $false
$staleProfiles = @()
Get-ChildItem $profilesPath -ErrorAction SilentlyContinue | ForEach-Object {
    $props = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
    if ($props.ProfileName -eq "Twingate") {
        $activeProfile = $true
    } elseif ($props.ProfileName -like "Twingate*") {
        $staleProfiles += [PSCustomObject]@{
            Name   = $props.ProfileName
            PSPath = $_.PSPath
        }
    }
}

if ($activeProfile) {
    Write-Host "Active profile found:" -ForegroundColor Green
    Write-Host "  - Twingate (kept)" -ForegroundColor Green
}

if ($staleProfiles.Count -eq 0) {
    Write-Host "No stale Twingate profiles found." -ForegroundColor Green
    exit 0
}

Write-Host "Found $($staleProfiles.Count) stale profile(s):" -ForegroundColor Yellow
foreach ($profile in $staleProfiles) {
    Write-Host "  - $($profile.Name)" -ForegroundColor DarkGray
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
