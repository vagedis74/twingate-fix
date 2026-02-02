<#
.SYNOPSIS
    Deletes all Twingate network profiles from the registry.
.DESCRIPTION
    Finds and removes all network profiles with a name matching "Twingate*"
    from the Windows network profile registry. Requires admin privileges.
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

# Delete all Twingate network profiles
Write-Host "`nScanning for Twingate network profiles..." -ForegroundColor Cyan

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
