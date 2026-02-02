<#
.SYNOPSIS
    Automated Twingate client fix - performs all manual repair steps in sequence.
.DESCRIPTION
    Step 1: Quit the Twingate client
    Step 2: Uninstall Twingate
    Step 3: Execute Remove-TwingateGhosts.ps1 to clean up ghost adapters
    Step 4: Reboot (script resumes automatically after logon)
    Step 5: Download and install Twingate silently, configure to join inlumi.twingate.com
    Step 6: Reboot computer
    Step 7: Trigger Intune sync so the device becomes trusted
    Step 8: Execute Remove-TwingateGhosts.ps1 to clean up ghost adapters
.NOTES
    Must be run as administrator. The script self-elevates if needed.
    After the reboot in step 4, a scheduled task re-launches this script to continue at step 5.
    After the reboot in step 6, a scheduled task re-launches this script to continue at step 7.
#>

param(
    [switch]$PostReboot,
    [switch]$PostInstallReboot
)

# -- Self-elevate if not running as admin --------------------------------------
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

# -- Helper: section header ----------------------------------------------------
function Write-Step {
    param([int]$Number, [string]$Title)
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "  Step $Number - $Title" -ForegroundColor Cyan
    Write-Host "========================================`n" -ForegroundColor Cyan
}

# -- Helper: pause before next step -------------------------------------------
function Wait-Continue {
    Write-Host "`nContinuing in 5 seconds..." -ForegroundColor DarkGray
    Start-Sleep -Seconds 5
}

# ===============================================================================
# FIRST RUN (Steps 1-4)
# ===============================================================================
if (-not $PostReboot -and -not $PostInstallReboot) {

Write-Host "`n  Twingate Client Fix - Automated Script`n" -ForegroundColor Green

# -- Step 1: Quit Twingate -----------------------------------------------------
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

# -- Step 2: Uninstall Twingate ------------------------------------------------
Write-Step -Number 2 -Title "Uninstall Twingate"

$twingateApp = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*" -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -like "*Twingate*" }

if ($twingateApp) {
    Write-Host "Found: $($twingateApp.DisplayName) ($($twingateApp.DisplayVersion))" -ForegroundColor Yellow
    Write-Host "Uninstalling Twingate silently..." -ForegroundColor Yellow
    $uninstallProc = Start-Process msiexec -ArgumentList "/x $($twingateApp.PSChildName) /qn" -Wait -PassThru
    if ($uninstallProc.ExitCode -eq 0) {
        Write-Host "Twingate uninstall complete." -ForegroundColor Green
    } else {
        Write-Host "Uninstall returned code $($uninstallProc.ExitCode)." -ForegroundColor Red
    }
} else {
    Write-Host "Twingate is not installed (or already uninstalled)." -ForegroundColor Green
}

Wait-Continue

# -- Step 3: Execute cleanup script --------------------------------------------
Write-Step -Number 3 -Title "Execute Remove-TwingateGhosts.ps1"

$cleanupScript = Join-Path $PSScriptRoot "Remove-TwingateGhosts.ps1"

if (Test-Path $cleanupScript) {
    Write-Host "Launching Remove-TwingateGhosts.ps1..." -ForegroundColor Yellow
    $proc = Start-Process powershell -ArgumentList @(
        "-ExecutionPolicy", "Bypass", "-File", "`"$cleanupScript`""
    ) -PassThru -Wait
    Write-Host "Cleanup script finished (exit code $($proc.ExitCode))." -ForegroundColor Green
} else {
    Write-Host "ERROR: Could not find '$cleanupScript'" -ForegroundColor Red
    Write-Host "Make sure Remove-TwingateGhosts.ps1 is in the same folder as this script." -ForegroundColor Yellow
    Start-Sleep -Seconds 5
    exit 1
}

Wait-Continue

# -- Step 4: Reboot ------------------------------------------------------------
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

}

# ===============================================================================
# AFTER FIRST REBOOT (Steps 5-6)
# ===============================================================================
if ($PostReboot) {
    Write-Host "`n  Resuming Twingate fix after reboot...`n" -ForegroundColor Green

    # Clean up the scheduled task
    Unregister-ScheduledTask -TaskName "FixTwingateContinue" -Confirm:$false -ErrorAction SilentlyContinue

    # -- Step 5: Download, install and configure Twingate ------------------
    Write-Step -Number 5 -Title "Download and install Twingate silently"

    # Delete all remaining Twingate network profiles before fresh install
    Write-Host "Removing all Twingate network profiles..." -ForegroundColor Yellow
    $profilesPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\NetworkList\Profiles"
    $deleted = 0
    Get-ChildItem $profilesPath -ErrorAction SilentlyContinue | ForEach-Object {
        $props = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
        if ($props.ProfileName -like "Twingate*") {
            Remove-Item $_.PSPath -Recurse -Force
            Write-Host "  Deleted profile '$($props.ProfileName)'" -ForegroundColor DarkGray
            $deleted++
        }
    }
    if ($deleted -eq 0) {
        Write-Host "  No Twingate profiles found." -ForegroundColor Green
    } else {
        Write-Host "  Deleted $deleted Twingate profile(s)." -ForegroundColor Green
    }

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
    if (-not (Test-Path $installerPath) -or (Get-Item $installerPath).Length -eq 0) {
        Write-Host "Downloaded file is missing or empty." -ForegroundColor Red
        Start-Sleep -Seconds 5
        exit 1
    }
    Write-Host "Download complete: $installerPath" -ForegroundColor Green

    Write-Host "Installing Twingate silently (network: inlumi.twingate.com)..." -ForegroundColor Yellow
    $installProc = Start-Process -FilePath $installerPath -ArgumentList "preq_share=true /qn network=inlumi.twingate.com auto_update=true" -Wait -PassThru
    if ($installProc.ExitCode -ne 0) {
        Write-Host "Installation failed (exit code $($installProc.ExitCode))." -ForegroundColor Red
        Start-Sleep -Seconds 10
        exit 1
    }

    # Verify Twingate is actually installed
    $twingateExe = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*" -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like "*Twingate*" }
    if (-not $twingateExe) {
        Write-Host "Installation reported success but Twingate was not found. Install may have failed." -ForegroundColor Red
        Start-Sleep -Seconds 10
        exit 1
    }
    Write-Host "Twingate installation verified." -ForegroundColor Green

    # Clean up installer
    Remove-Item $installerPath -Force -ErrorAction SilentlyContinue

    # -- Step 6: Reboot ----------------------------------------------------
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

# ===============================================================================
# AFTER SECOND REBOOT (Steps 7-8)
# ===============================================================================
if ($PostInstallReboot) {
    Write-Host "`n  Resuming Twingate fix after install reboot...`n" -ForegroundColor Green

    # Clean up the scheduled task
    Unregister-ScheduledTask -TaskName "FixTwingatePostInstall" -Confirm:$false -ErrorAction SilentlyContinue

    # -- Step 7: Trigger Intune sync ----------------------------------------
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

    Wait-Continue

    # -- Step 8: Execute cleanup script ---------------------------------------
    Write-Step -Number 8 -Title "Execute Remove-TwingateGhosts.ps1"

    $cleanupScript = Join-Path $PSScriptRoot "Remove-TwingateGhosts.ps1"

    if (Test-Path $cleanupScript) {
        Write-Host "Launching Remove-TwingateGhosts.ps1..." -ForegroundColor Yellow
        $proc = Start-Process powershell -ArgumentList @(
            "-ExecutionPolicy", "Bypass", "-File", "`"$cleanupScript`""
        ) -PassThru -Wait
        Write-Host "Cleanup script finished (exit code $($proc.ExitCode))." -ForegroundColor Green
    } else {
        Write-Host "ERROR: Could not find '$cleanupScript'" -ForegroundColor Red
        Write-Host "Make sure Remove-TwingateGhosts.ps1 is in the same folder as this script." -ForegroundColor Yellow
    }

    Write-Host "`nTwingate fix complete!" -ForegroundColor Green
    Write-Host "`nExiting in 10 seconds..." -ForegroundColor DarkGray
    Start-Sleep -Seconds 10
    exit 0
}
