#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Lists all Twingate network profiles and highlights which is the original.

.DESCRIPTION
    Enumerates registry profiles under NetworkList\Profiles, identifies which
    Twingate profile is actively connected, and marks stale duplicates.
    This is a read-only diagnostic script. It does not modify or delete anything.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File Get-TwingateProfiles.ps1
#>

$profilesPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\NetworkList\Profiles"

Write-Host "`n=== Twingate Network Profile Report ===" -ForegroundColor Cyan

# --- Check Twingate service state ---
$svc = Get-Service -Name "Twingate.Service" -ErrorAction SilentlyContinue
if (-not $svc) {
    Write-Host "Service 'Twingate.Service' not found.`n" -ForegroundColor Yellow
} elseif ($svc.Status -eq 'Running') {
    Write-Host "Service 'Twingate.Service' is running.`n" -ForegroundColor Green
} else {
    Write-Host "Service 'Twingate.Service' is in state: $($svc.Status)`n" -ForegroundColor Yellow
}

# --- Detect active Twingate connection profile (by GUID) ---
$connectionProfile = @(Get-NetConnectionProfile -ErrorAction SilentlyContinue |
    Where-Object { $_.InterfaceAlias -like "*Twingate*" }) | Select-Object -First 1

$activeGUID = $null
if ($connectionProfile) {
    $activeGUID = $connectionProfile.InstanceID
    Write-Host "Active Twingate connection: '$($connectionProfile.Name)' on interface '$($connectionProfile.InterfaceAlias)'" -ForegroundColor Green
    Write-Host "  InstanceID: $activeGUID" -ForegroundColor DarkGray
} else {
    Write-Host "No active Twingate connection detected." -ForegroundColor Yellow
}

# --- Enumerate all Twingate profiles from registry ---
$allProfiles = @()
Get-ChildItem $profilesPath -ErrorAction SilentlyContinue | ForEach-Object {
    $props = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
    if ($props.ProfileName -like "Twingate*") {
        $guid = $_.PSChildName

        # Match active connection by GUID, not name
        $isActiveConnection = $activeGUID -and $guid -eq $activeGUID

        $allProfiles += [PSCustomObject]@{
            Name               = $props.ProfileName
            GUID               = $guid
            PSPath             = $_.PSPath
            IsActiveConnection = $isActiveConnection
        }
    }
}

if ($allProfiles.Count -eq 0) {
    Write-Host "`nNo Twingate network profiles found in registry." -ForegroundColor Yellow
    exit 0
}

# --- Check if active connection profile exists in registry ---
$activeInRegistry = $false
if ($activeGUID) {
    $activeInRegistry = ($allProfiles | Where-Object { $_.IsActiveConnection }).Count -gt 0
    if (-not $activeInRegistry) {
        Write-Host "`nNote: Active connection profile ($activeGUID) is not in the registry." -ForegroundColor Yellow
        Write-Host "  This is normal -- Twingate manages it outside NetworkList\Profiles." -ForegroundColor DarkGray
    }
}

Write-Host "`n--- Registry Profiles ($($allProfiles.Count) total) ---`n"

$staleCount = 0
foreach ($profile in $allProfiles) {
    $tags = @()
    if ($profile.IsActiveConnection) {
        $tags += "ACTIVE CONNECTION"
    } else {
        $tags += "STALE"
        $staleCount++
    }

    $tagString = " [$($tags -join ', ')]"

    if ($profile.IsActiveConnection) {
        Write-Host "  * $($profile.Name)$tagString" -ForegroundColor Green
    } else {
        Write-Host "    $($profile.Name)$tagString" -ForegroundColor DarkGray
    }
    Write-Host "      GUID: $($profile.GUID)" -ForegroundColor DarkGray
}

# --- Summary ---
Write-Host ""
$activeCount = ($allProfiles | Where-Object { $_.IsActiveConnection }).Count
Write-Host "Summary: $activeCount active, $staleCount stale" -ForegroundColor Cyan

if ($staleCount -gt 0) {
    Write-Host "Tip: Run Remove-TwingateStaleProfiles.ps1 to clean up stale profiles." -ForegroundColor Yellow
}

Write-Host ""
