<#
.SYNOPSIS
    Detects and removes ghost Twingate network adapters.
#>

# Scan for ghost Twingate adapters
Write-Host "`nScanning for ghost Twingate network adapters..." -ForegroundColor Cyan

$ghostAdapters = Get-PnpDevice -Class Net -ErrorAction SilentlyContinue |
    Where-Object { $_.FriendlyName -like "*Twingate*" -and $_.Status -ne "OK" }

if (-not $ghostAdapters) {
    Write-Host "No ghost Twingate adapters found.`n" -ForegroundColor Green

    # Clean up stale Twingate network profiles
    Write-Host "Checking Twingate network profiles..." -ForegroundColor Cyan
    $profilesPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\NetworkList\Profiles"
    $activeProfile = Get-NetConnectionProfile -ErrorAction SilentlyContinue |
        Where-Object { $_.InterfaceAlias -like "*Twingate*" }

    if ($activeProfile -and $activeProfile.Name -ne "Twingate") {
        Get-ChildItem $profilesPath | ForEach-Object {
            $props = Get-ItemProperty $_.PSPath
            if ($props.ProfileName -eq $activeProfile.Name) {
                Set-ItemProperty $_.PSPath -Name "ProfileName" -Value "Twingate"
                Write-Host "  Renamed '$($activeProfile.Name)' -> 'Twingate'" -ForegroundColor Green
            }
        }
    }

    $deleted = 0
    Get-ChildItem $profilesPath | ForEach-Object {
        $props = Get-ItemProperty $_.PSPath
        if ($props.ProfileName -match '^Twingate \d+$') {
            Remove-Item $_.PSPath -Recurse -Force
            Write-Host "  Deleted stale profile '$($props.ProfileName)'" -ForegroundColor DarkGray
            $deleted++
        }
    }

    if ($deleted -eq 0 -and (-not $activeProfile -or $activeProfile.Name -eq "Twingate")) {
        Write-Host "  No stale profiles found." -ForegroundColor Green
    } else {
        Write-Host "  Profile cleanup complete.`n" -ForegroundColor Green
    }

    Write-Host "`nExiting in 5 seconds..." -ForegroundColor DarkGray
    Start-Sleep -Seconds 5
    exit 0
}

Write-Host "Found $($ghostAdapters.Count) ghost adapter(s):`n" -ForegroundColor Yellow
$ghostAdapters | ForEach-Object {
    Write-Host "  $($_.FriendlyName) [$($_.Status)] - $($_.InstanceId)" -ForegroundColor DarkGray
}

# Remove each ghost adapter (requires admin)
Write-Host ""
$failed = 0
foreach ($adapter in $ghostAdapters) {
    Write-Host "Removing $($adapter.InstanceId)..." -ForegroundColor Yellow -NoNewline
    try {
        pnputil /remove-device "$($adapter.InstanceId)" 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Host " done." -ForegroundColor Green
        } else {
            Write-Host " failed (exit code $LASTEXITCODE)." -ForegroundColor Red
            $failed++
        }
    } catch {
        Write-Host " failed: $_" -ForegroundColor Red
        $failed++
    }
}

Write-Host ""
if ($failed -gt 0) {
    Write-Host "$failed adapter(s) could not be removed. Run as administrator." -ForegroundColor Red
    Write-Host "Exiting in 5 seconds..." -ForegroundColor DarkGray
    Start-Sleep -Seconds 5
    exit 1
}
Write-Host "All ghost Twingate adapters removed.`n" -ForegroundColor Green

# Clean up stale Twingate network profiles
Write-Host "Cleaning up Twingate network profiles..." -ForegroundColor Cyan
$profilesPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\NetworkList\Profiles"
$activeProfile = Get-NetConnectionProfile -ErrorAction SilentlyContinue |
    Where-Object { $_.InterfaceAlias -like "*Twingate*" }

if ($activeProfile -and $activeProfile.Name -ne "Twingate") {
    Get-ChildItem $profilesPath | ForEach-Object {
        $props = Get-ItemProperty $_.PSPath
        if ($props.ProfileName -eq $activeProfile.Name) {
            Set-ItemProperty $_.PSPath -Name "ProfileName" -Value "Twingate"
            Write-Host "  Renamed '$($activeProfile.Name)' -> 'Twingate'" -ForegroundColor Green
        }
    }
}

$deleted = 0
Get-ChildItem $profilesPath | ForEach-Object {
    $props = Get-ItemProperty $_.PSPath
    if ($props.ProfileName -match '^Twingate \d+$') {
        Remove-Item $_.PSPath -Recurse -Force
        Write-Host "  Deleted stale profile '$($props.ProfileName)'" -ForegroundColor DarkGray
        $deleted++
    }
}

if ($deleted -eq 0 -and (-not $activeProfile -or $activeProfile.Name -eq "Twingate")) {
    Write-Host "  No stale profiles found." -ForegroundColor Green
} else {
    Write-Host "  Profile cleanup complete.`n" -ForegroundColor Green
}

Write-Host "Exiting in 5 seconds..." -ForegroundColor DarkGray
Start-Sleep -Seconds 5
