<#
.SYNOPSIS
    Detects and removes ghost Twingate network adapters.
.NOTES
    Requires administrator privileges. Does not self-elevate.
#>

# Warn if not running as admin
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)
if (-not $isAdmin) {
    Write-Host "`nWARNING: This script requires administrator privileges." -ForegroundColor Red
    Write-Host "Registry and device operations will fail without elevation.`n" -ForegroundColor Red
}

# -- Helper: clean up stale Twingate network profiles -------------------------
function Clean-TwingateProfiles {
    param([string]$Label = "Checking")
    Write-Host "$Label Twingate network profiles..." -ForegroundColor Cyan
    $profilesPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\NetworkList\Profiles"
    $activeProfile = @(Get-NetConnectionProfile -ErrorAction SilentlyContinue |
        Where-Object { $_.InterfaceAlias -like "*Twingate*" }) | Select-Object -First 1

    if ($activeProfile -and $activeProfile.Name -ne "Twingate") {
        Get-ChildItem $profilesPath -ErrorAction SilentlyContinue | ForEach-Object {
            $props = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
            if ($props.ProfileName -eq $activeProfile.Name) {
                try {
                    Set-ItemProperty $_.PSPath -Name "ProfileName" -Value "Twingate" -ErrorAction Stop
                    Write-Host "  Renamed '$($activeProfile.Name)' -> 'Twingate'" -ForegroundColor Green
                } catch {
                    Write-Host "  Failed to rename profile '$($activeProfile.Name)': $_" -ForegroundColor Red
                }
            }
        }
    }

    $deleted = 0
    Get-ChildItem $profilesPath -ErrorAction SilentlyContinue | ForEach-Object {
        $props = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
        if ($props.ProfileName -like "Twingate*" -and $props.ProfileName -ne "Twingate") {
            try {
                Remove-Item $_.PSPath -Recurse -Force -ErrorAction Stop
                Write-Host "  Deleted stale profile '$($props.ProfileName)'" -ForegroundColor DarkGray
                $deleted++
            } catch {
                Write-Host "  Failed to delete profile '$($props.ProfileName)': $_" -ForegroundColor Red
            }
        }
    }

    if ($deleted -eq 0 -and (-not $activeProfile -or $activeProfile.Name -eq "Twingate")) {
        Write-Host "  No stale profiles found." -ForegroundColor Green
    } else {
        Write-Host "  Profile cleanup complete.`n" -ForegroundColor Green
    }
}

# Scan for ghost Twingate adapters
Write-Host "`nScanning for ghost Twingate network adapters..." -ForegroundColor Cyan

$ghostAdapters = @(Get-PnpDevice -Class Net -ErrorAction SilentlyContinue |
    Where-Object { $_.FriendlyName -like "*Twingate*" -and $_.Status -ne "OK" })

if ($ghostAdapters.Count -eq 0) {
    Write-Host "No ghost Twingate adapters found.`n" -ForegroundColor Green
    Clean-TwingateProfiles -Label "Checking"
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
        $output = & pnputil /remove-device "$($adapter.InstanceId)" 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host " done." -ForegroundColor Green
        } else {
            Write-Host " failed (exit code $LASTEXITCODE): $output" -ForegroundColor Red
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

Clean-TwingateProfiles -Label "Cleaning up"

Write-Host "Exiting in 5 seconds..." -ForegroundColor DarkGray
Start-Sleep -Seconds 5
exit 0
