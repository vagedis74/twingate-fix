<#
.SYNOPSIS
    Removes ghost Twingate network adapters and deletes all Twingate network profiles.
.DESCRIPTION
    Finds and removes Twingate network adapters that are not in "OK" status (ghost/phantom
    devices) using pnputil, then deletes all Twingate* network profiles from the Windows
    registry. Requires admin privileges.
#>

# Self-elevate if not running as admin
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)

if (-not $isAdmin) {
    Write-Host "`nRequesting administrator privileges..." -ForegroundColor Cyan
    $scriptPath = $MyInvocation.MyCommand.Path
    Start-Process powershell -Verb RunAs -ArgumentList @(
        "-ExecutionPolicy", "Bypass",
        "-File", "`"$scriptPath`""
    )
    exit
}

# Remove ghost Twingate network adapters
Write-Host "`nScanning for ghost Twingate network adapters..." -ForegroundColor Cyan

$ghostAdapters = Get-PnpDevice -Class Net -ErrorAction SilentlyContinue |
    Where-Object { $_.FriendlyName -like "*Twingate*" -and $_.Status -ne "OK" }

$removed = 0
if ($ghostAdapters) {
    foreach ($adapter in $ghostAdapters) {
        Write-Host "  Removing '$($adapter.FriendlyName)' (Status: $($adapter.Status))..." -ForegroundColor Yellow
        try {
            pnputil /remove-device "$($adapter.InstanceId)" | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-Host "    Removed successfully." -ForegroundColor Green
                $removed++
            } else {
                Write-Host "    pnputil returned exit code $LASTEXITCODE." -ForegroundColor Red
            }
        } catch {
            Write-Host "    Failed: $_" -ForegroundColor Red
        }
    }
    Write-Host ""
}

if ($removed -eq 0 -and -not $ghostAdapters) {
    Write-Host "  No ghost Twingate adapters found.`n" -ForegroundColor Green
} else {
    Write-Host "  Removed $removed ghost adapter(s).`n" -ForegroundColor Green
}

# Delete all Twingate network profiles
Write-Host "Scanning for Twingate network profiles..." -ForegroundColor Cyan

$profilesPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\NetworkList\Profiles"
$deleted = 0

Get-ChildItem $profilesPath -ErrorAction SilentlyContinue | ForEach-Object {
    $props = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
    if ($props.ProfileName -like "Twingate*") {
        Remove-Item $_.PSPath -Recurse -Force
        Write-Host "  Deleted profile '$($props.ProfileName)'" -ForegroundColor Yellow
        $deleted++
    }
}

if ($deleted -eq 0) {
    Write-Host "  No Twingate network profiles found.`n" -ForegroundColor Green
} else {
    Write-Host "`n  Deleted $deleted Twingate network profile(s).`n" -ForegroundColor Green
}

Read-Host "Press Enter to close"
