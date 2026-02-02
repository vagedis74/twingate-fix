<#
.SYNOPSIS
    Reinstalls the Twingate client using the local installer bundled in this repo.
.DESCRIPTION
    Step 1: Stop Twingate service and processes
    Step 2: Uninstall Twingate via PowerShell (REMOVE=ALL)
    Step 3: Remove ghost Twingate network adapters
    Step 4: Delete all Twingate network profiles from registry
    Step 5: Install Twingate from TwingateWindowsInstaller.exe in the script directory
.NOTES
    Must be run as administrator. The script self-elevates if needed.
    The installer TwingateWindowsInstaller.exe must be in the same folder as this script.
#>

# -- Self-elevate if not running as admin --------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)

if (-not $isAdmin) {
    Write-Host "`nRequesting administrator privileges..." -ForegroundColor Cyan
    try {
        Start-Process powershell -Verb RunAs -ArgumentList @(
            "-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`""
        ) -ErrorAction Stop
    } catch {
        Write-Host "ERROR: Failed to obtain administrator privileges: $_" -ForegroundColor Red
        Start-Sleep -Seconds 5
        exit 1
    }
    exit
}

# -- Verify installer exists before starting -----------------------------------
$installerPath = Join-Path $PSScriptRoot "TwingateWindowsInstaller.exe"
if (-not (Test-Path $installerPath)) {
    Write-Host "ERROR: Installer not found at '$installerPath'" -ForegroundColor Red
    Write-Host "Make sure TwingateWindowsInstaller.exe is in the same folder as this script." -ForegroundColor Yellow
    Start-Sleep -Seconds 5
    exit 1
}

# ==============================================================================
# Step 1: Stop Twingate
# ==============================================================================
Write-Host "`nStep 1 - Stopping Twingate..." -ForegroundColor Cyan

$twingateSvc = Get-Service -Name "Twingate.Service" -ErrorAction SilentlyContinue
if ($twingateSvc -and $twingateSvc.Status -eq "Running") {
    Write-Host "Stopping Twingate service..." -ForegroundColor Yellow
    Stop-Service -Name "Twingate.Service" -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
}

$twingateProcs = Get-Process -Name "Twingate*" -ErrorAction SilentlyContinue
if ($twingateProcs) {
    foreach ($proc in $twingateProcs) {
        Write-Host "Stopping process: $($proc.Name) (PID $($proc.Id))..." -ForegroundColor Yellow
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 2

    $remaining = Get-Process -Name "Twingate*" -ErrorAction SilentlyContinue
    if ($remaining) {
        Write-Host "ERROR: The following Twingate processes are still running:" -ForegroundColor Red
        foreach ($p in $remaining) {
            Write-Host "  $($p.Name) (PID $($p.Id))" -ForegroundColor Red
        }
        Write-Host "Cannot proceed while Twingate is running." -ForegroundColor Red
        Start-Sleep -Seconds 10
        exit 1
    }
    Write-Host "Twingate processes stopped." -ForegroundColor Green
} else {
    Write-Host "Twingate is not running." -ForegroundColor Green
}

# ==============================================================================
# Step 2: Uninstall Twingate via PowerShell
# ==============================================================================
Write-Host "`nStep 2 - Uninstalling Twingate..." -ForegroundColor Cyan

try {
    $twingatePackage = Get-Package -Name "Twingate*" -ProviderName msi -ErrorAction Stop
} catch {
    Write-Host "Twingate is not installed (or already uninstalled)." -ForegroundColor Green
}

if ($twingatePackage) {
    Write-Host "Found: $($twingatePackage.Name) ($($twingatePackage.Version))" -ForegroundColor Yellow
    Write-Host "Uninstalling silently..." -ForegroundColor Yellow

    try {
        $twingatePackage | Uninstall-Package -Force -AdditionalArguments @("REMOVE=ALL") -ErrorAction Stop
    } catch {
        Write-Host "Uninstall failed: $_" -ForegroundColor Red
        Start-Sleep -Seconds 10
        exit 1
    }

    Write-Host "Twingate uninstalled successfully." -ForegroundColor Green
}

# ==============================================================================
# Step 3: Remove ghost Twingate network adapters
# ==============================================================================
Write-Host "`nStep 3 - Scanning for ghost Twingate network adapters..." -ForegroundColor Cyan

$ghostAdapters = @(Get-PnpDevice -Class Net -ErrorAction SilentlyContinue |
    Where-Object { $_.FriendlyName -like "*Twingate*" -and $_.Status -ne "OK" })

if ($ghostAdapters.Count -eq 0) {
    Write-Host "No ghost Twingate adapters found." -ForegroundColor Green
} else {
    Write-Host "Found $($ghostAdapters.Count) ghost adapter(s):`n" -ForegroundColor Yellow
    foreach ($adapter in $ghostAdapters) {
        Write-Host "  $($adapter.FriendlyName) [$($adapter.Status)] - $($adapter.InstanceId)" -ForegroundColor DarkGray
    }

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

    if ($failed -gt 0) {
        Write-Host "`n$failed adapter(s) could not be removed." -ForegroundColor Red
    } else {
        Write-Host "`nAll ghost Twingate adapters removed." -ForegroundColor Green
    }
}

# ==============================================================================
# Step 4: Delete Twingate network profiles from registry
# ==============================================================================
Write-Host "`nStep 4 - Scanning for Twingate network profiles in registry..." -ForegroundColor Cyan

$profilesPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\NetworkList\Profiles"
$twingateProfiles = @()

Get-ChildItem $profilesPath -ErrorAction SilentlyContinue | ForEach-Object {
    $props = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
    if ($props.ProfileName -like "Twingate*") {
        $twingateProfiles += [PSCustomObject]@{
            Name   = $props.ProfileName
            PSPath = $_.PSPath
            RegKey = $_.Name
        }
    }
}

if ($twingateProfiles.Count -eq 0) {
    Write-Host "No Twingate network profiles found." -ForegroundColor Green
} else {
    Write-Host "Found $($twingateProfiles.Count) Twingate profile(s):`n" -ForegroundColor Yellow
    foreach ($profile in $twingateProfiles) {
        Write-Host "  $($profile.Name) - $($profile.RegKey)" -ForegroundColor DarkGray
    }

    Write-Host ""
    $deleted = 0
    foreach ($profile in $twingateProfiles) {
        Write-Host "Deleting profile '$($profile.Name)'..." -ForegroundColor Yellow -NoNewline
        try {
            Remove-Item $profile.PSPath -Recurse -Force -ErrorAction Stop
            Write-Host " done." -ForegroundColor Green
            $deleted++
        } catch {
            Write-Host " failed: $_" -ForegroundColor Red
        }
    }

    Write-Host "`nDeleted $deleted of $($twingateProfiles.Count) profile(s)." -ForegroundColor Green
}

# ==============================================================================
# Step 5: Install Twingate from local installer
# ==============================================================================
Write-Host "`nStep 5 - Installing Twingate from local installer..." -ForegroundColor Cyan
Write-Host "Installer: $installerPath" -ForegroundColor Yellow

$installProc = Start-Process -FilePath $installerPath -ArgumentList "/qn NETWORK=inlumi.twingate.com auto_update=true no_optional_updates=true ncsi_global_dns=true" -Wait -PassThru
if ($installProc.ExitCode -ne 0) {
    $ec = $installProc.ExitCode
    Write-Host "Installation failed with exit code $ec." -ForegroundColor Red
    Start-Sleep -Seconds 10
    exit 1
}

Write-Host "Twingate installed successfully." -ForegroundColor Green

Write-Host "`nDone. Please reboot and sign in to Twingate." -ForegroundColor Green
Start-Sleep -Seconds 5
exit 0
