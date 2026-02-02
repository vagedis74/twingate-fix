<#
.SYNOPSIS
    Automated Twingate client fix — performs all manual repair steps in sequence.
.DESCRIPTION
    Step 1: Quit the Twingate client
    Step 2: Uninstall Twingate
    Step 3: Execute Remove-Twingate-Cleanup.ps1 as administrator
    Step 4: Reboot (script resumes automatically after logon)
    Step 5: Download and install Twingate silently, configure to join inlumi.twingate.com
    Step 6: Reboot computer
    Step 7: Trigger Intune sync so the device becomes trusted
.NOTES
    Must be run as administrator. The script self-elevates if needed.
    After the reboot in step 4, a scheduled task re-launches this script to continue at step 5.
    After the reboot in step 6, a scheduled task re-launches this script to continue at step 7.
#>

param(
    [switch]$PostReboot,
    [switch]$PostInstallReboot
)

# ── Self-elevate if not running as admin ──────────────────────────────────────
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)

if (-not $isAdmin) {
    Write-Host "`nRequesting administrator privileges..." -ForegroundColor Cyan
    $argList = @("-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`"")
    if ($PostReboot) { $argList += "-PostReboot" }
    if ($PostInstallReboot) { $argList += "-PostInstallReboot" }
    Start-Process powershell -Verb RunAs -ArgumentList $argList
    exit
}

# ── Helper: section header ────────────────────────────────────────────────────
function Write-Step {
    param([int]$Number, [string]$Title)
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "  Step $Number - $Title" -ForegroundColor Cyan
    Write-Host "========================================`n" -ForegroundColor Cyan
}

# ── Helper: pause before next step ───────────────────────────────────────────
function Wait-Continue {
    Write-Host "`nContinuing in 5 seconds..." -ForegroundColor DarkGray
    Start-Sleep -Seconds 5
}

# ═══════════════════════════════════════════════════════════════════════════════
# POST-INSTALL-REBOOT PATH (Step 7)
# ═══════════════════════════════════════════════════════════════════════════════
if ($PostInstallReboot) {
    Write-Host "`n  Resuming Twingate fix after install reboot...`n" -ForegroundColor Green

    # Clean up the scheduled task
    Unregister-ScheduledTask -TaskName "FixTwingatePostInstall" -Confirm:$false -ErrorAction SilentlyContinue

    # ── Step 7: Trigger Intune sync ────────────────────────────────────────
    Write-Step -Number 7 -Title "Trigger Intune sync"

    Write-Host "Triggering Intune device sync to establish device trust..." -ForegroundColor Yellow

    # Restart the Intune Management Extension service to trigger a sync
    $imeSvc = Get-Service -Name IntuneManagementExtension -ErrorAction SilentlyContinue
    if ($imeSvc) {
        Restart-Service -Name IntuneManagementExtension -Force -ErrorAction SilentlyContinue
        Write-Host "Intune Management Extension service restarted." -ForegroundColor Green
    } else {
        Write-Host "Intune Management Extension service not found." -ForegroundColor DarkGray
    }

    # Trigger all MDM EnterpriseMgmt scheduled tasks (policy sync)
    $mdmTasks = Get-ScheduledTask -TaskPath "\Microsoft\Windows\EnterpriseMgmt\*" -ErrorAction SilentlyContinue
    if ($mdmTasks) {
        foreach ($task in $mdmTasks) {
            Start-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -ErrorAction SilentlyContinue
        }
        Write-Host "MDM policy sync tasks triggered ($($mdmTasks.Count) task(s))." -ForegroundColor Green
    } else {
        Write-Host "No MDM scheduled tasks found." -ForegroundColor DarkGray
    }

    Write-Host "`nIntune sync initiated. The device should become trusted shortly." -ForegroundColor Green
    Write-Host "You can verify in Company Portal or Intune portal.`n" -ForegroundColor Yellow

    Write-Host "Twingate fix complete!" -ForegroundColor Green
    Write-Host "`nExiting in 10 seconds..." -ForegroundColor DarkGray
    Start-Sleep -Seconds 10
    exit 0
}

# ═══════════════════════════════════════════════════════════════════════════════
# POST-REBOOT PATH (Steps 5-6)
# ═══════════════════════════════════════════════════════════════════════════════
if ($PostReboot) {
    Write-Host "`n  Resuming Twingate fix after reboot...`n" -ForegroundColor Green

    # Clean up the scheduled task
    Unregister-ScheduledTask -TaskName "FixTwingateContinue" -Confirm:$false -ErrorAction SilentlyContinue

    # ── Step 5: Download, install and configure Twingate ──────────────────
    Write-Step -Number 5 -Title "Download and install Twingate silently"

    $installerUrl  = "https://api.twingate.com/download/windows"
    $installerPath = "$env:USERPROFILE\Downloads\TwingateWindowsInstaller.exe"

    Write-Host "Downloading Twingate installer..." -ForegroundColor Yellow
    & curl.exe -L -o $installerPath $installerUrl
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Download failed (exit code $LASTEXITCODE)." -ForegroundColor Red
        Write-Host "Please download manually from: $installerUrl" -ForegroundColor Yellow
        Start-Sleep -Seconds 5
        exit 1
    }
    Write-Host "Download complete: $installerPath" -ForegroundColor Green

    Write-Host "Installing Twingate silently (network: inlumi.twingate.com)..." -ForegroundColor Yellow
    Start-Process -FilePath $installerPath -ArgumentList "/qn network=inlumi.twingate.com auto_update=true" -Wait
    Write-Host "Twingate installation complete." -ForegroundColor Green

    # Clean up installer
    Remove-Item $installerPath -Force -ErrorAction SilentlyContinue

    # ── Step 6: Reboot ────────────────────────────────────────────────────
    Write-Step -Number 6 -Title "Reboot computer"

    Write-Host "Registering a scheduled task to resume at Step 7 after reboot..." -ForegroundColor Yellow

    $action   = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -File `"$PSCommandPath`" -PostInstallReboot"
    $trigger  = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -RunLevel Highest -LogonType Interactive

    Register-ScheduledTask -TaskName "FixTwingatePostInstall" `
        -Action $action -Trigger $trigger -Settings $settings -Principal $principal `
        -Description "Triggers Intune sync after Twingate install reboot (auto-deletes)" `
        -Force | Out-Null

    Write-Host "Scheduled task registered." -ForegroundColor Green
    Write-Host "`nRebooting to complete the installation..." -ForegroundColor Yellow
    Write-Host "After you log back in, the script will trigger an Intune sync (Step 7).`n" -ForegroundColor Yellow

    Start-Sleep -Seconds 15
    Restart-Computer -Force
}

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN PATH (Steps 1-4)
# ═══════════════════════════════════════════════════════════════════════════════

Write-Host "`n  Twingate Client Fix — Automated Script`n" -ForegroundColor Green

# ── Step 1: Quit Twingate ─────────────────────────────────────────────────────
Write-Step -Number 1 -Title "Quit Twingate"

$twingateProcs = Get-Process -Name "Twingate*" -ErrorAction SilentlyContinue
if ($twingateProcs) {
    foreach ($proc in $twingateProcs) {
        Write-Host "Stopping process: $($proc.Name) (PID $($proc.Id))..." -ForegroundColor Yellow
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 2
    Write-Host "Twingate processes stopped." -ForegroundColor Green
} else {
    Write-Host "Twingate is not running." -ForegroundColor Green
}

Wait-Continue

# ── Step 2: Uninstall Twingate ────────────────────────────────────────────────
Write-Step -Number 2 -Title "Uninstall Twingate"

# Search for Twingate in both 64-bit and 32-bit uninstall locations
$uninstallPaths = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
    "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
)

$twingateApps = $uninstallPaths | ForEach-Object {
    Get-ItemProperty $_ -ErrorAction SilentlyContinue
} | Where-Object { $_.DisplayName -like "*Twingate*" }

if ($twingateApps) {
    foreach ($twingateApp in $twingateApps) {
        Write-Host "Found: $($twingateApp.DisplayName) ($($twingateApp.DisplayVersion))" -ForegroundColor Yellow

        $uninstallString = $twingateApp.UninstallString
        if ($uninstallString) {
            Write-Host "Running uninstaller for $($twingateApp.DisplayName)..." -ForegroundColor Yellow

            # Handle msiexec-based uninstalls
            if ($uninstallString -match "msiexec") {
                $productCode = $twingateApp.PSChildName
                Start-Process msiexec.exe -ArgumentList "/x $productCode /qn" -Wait
            } else {
                # Try running the uninstall string with silent flags
                Start-Process cmd.exe -ArgumentList "/c `"$uninstallString`" /qn" -Wait
            }

            # Wait for any msiexec child processes to finish
            Write-Host "Waiting for uninstaller to finish..." -ForegroundColor DarkGray
            $timeout = 120  # seconds
            $elapsed = 0
            while ($elapsed -lt $timeout) {
                $msiProcs = Get-Process -Name "msiexec" -ErrorAction SilentlyContinue |
                    Where-Object { $_.Id -ne [System.Diagnostics.Process]::GetCurrentProcess().Id }
                if (-not $msiProcs) { break }
                Start-Sleep -Seconds 2
                $elapsed += 2
            }
            if ($elapsed -ge $timeout) {
                Write-Host "Warning: msiexec still running after ${timeout}s, proceeding anyway." -ForegroundColor Red
            }

            Write-Host "Uninstalled: $($twingateApp.DisplayName)" -ForegroundColor Green
        } else {
            Write-Host "No uninstall command found for $($twingateApp.DisplayName). Please uninstall manually from Settings > Apps." -ForegroundColor Red
        }
    }

    # Verify Twingate is actually removed from the registry
    Write-Host "Verifying uninstall completed..." -ForegroundColor DarkGray
    $remaining = $uninstallPaths | ForEach-Object {
        Get-ItemProperty $_ -ErrorAction SilentlyContinue
    } | Where-Object { $_.DisplayName -like "*Twingate*" }

    if ($remaining) {
        Write-Host "Warning: Twingate still appears in installed programs. The uninstall may not have completed fully." -ForegroundColor Red
        foreach ($app in $remaining) {
            Write-Host "  Still listed: $($app.DisplayName)" -ForegroundColor Red
        }
    } else {
        Write-Host "Verified: Twingate is no longer listed in installed programs." -ForegroundColor Green
    }
} else {
    Write-Host "Twingate is not installed (or already uninstalled)." -ForegroundColor Green
}

Wait-Continue

# ── Step 3: Execute cleanup script ────────────────────────────────────────────
Write-Step -Number 3 -Title "Execute Remove-Twingate-Cleanup.ps1"

$cleanupScript = Join-Path $PSScriptRoot "Remove-Twingate-Cleanup.ps1"

if (Test-Path $cleanupScript) {
    Write-Host "Launching Remove-Twingate-Cleanup.ps1 as Administrator..." -ForegroundColor Yellow
    $proc = Start-Process powershell -Verb RunAs -ArgumentList @(
        "-ExecutionPolicy", "Bypass", "-File", "`"$cleanupScript`""
    ) -PassThru -Wait
    Write-Host "Cleanup script finished (exit code $($proc.ExitCode))." -ForegroundColor Green
} else {
    Write-Host "ERROR: Could not find '$cleanupScript'" -ForegroundColor Red
    Write-Host "Make sure Remove-Twingate-Cleanup.ps1 is in the same folder as this script." -ForegroundColor Yellow
    Start-Sleep -Seconds 5
    exit 1
}

Wait-Continue

# ── Step 4: Reboot ────────────────────────────────────────────────────────────
Write-Step -Number 4 -Title "Reboot computer"

Write-Host "Registering a scheduled task to resume at Step 5 after reboot..." -ForegroundColor Yellow

# Create a scheduled task that runs this script with -PostReboot at next logon
$action  = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -File `"$PSCommandPath`" -PostReboot"
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -RunLevel Highest -LogonType Interactive

Register-ScheduledTask -TaskName "FixTwingateContinue" `
    -Action $action -Trigger $trigger -Settings $settings -Principal $principal `
    -Description "Continues the Twingate fix script after reboot (auto-deletes)" `
    -Force | Out-Null

Write-Host "Scheduled task registered." -ForegroundColor Green
Write-Host "`nThe computer will reboot now. After you log back in," -ForegroundColor Yellow
Write-Host "the script will automatically continue with Step 5.`n" -ForegroundColor Yellow

Write-Host "Rebooting in 5 seconds..." -ForegroundColor DarkGray
Start-Sleep -Seconds 5

Restart-Computer -Force
