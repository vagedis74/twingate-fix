<#
.SYNOPSIS
    Automated Twingate client fix - performs all manual repair steps in sequence.
.DESCRIPTION
    Step 1: Quit the Twingate client
    Step 2: Uninstall Twingate
    Step 3: Execute Remove-TwingateGhosts.ps1 to clean up ghost adapters
    Step 4: Reboot (script resumes automatically after logon)
    Step 5: Install .NET 8 Desktop Runtime (prerequisite for Twingate MSI)
    Step 6: Download and install Twingate silently, configure to join inlumi.twingate.com
    Step 7: Reboot computer
    Step 8: Trigger Intune sync so the device becomes trusted
    Step 9: Verify Twingate connection
    Step 10: Execute Remove-TwingateGhosts.ps1 to clean up ghost adapters
.NOTES
    Must be run as administrator. The script self-elevates if needed.
    After the reboot in step 4, a scheduled task re-launches this script to continue at step 5.
    After the reboot in step 7, a scheduled task re-launches this script to continue at step 8.
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
    try {
        Start-Process powershell -Verb RunAs -ArgumentList $argList -ErrorAction Stop
    } catch {
        Write-Host "ERROR: Failed to obtain administrator privileges: $_" -ForegroundColor Red
        Start-Sleep -Seconds 5
        exit 1
    }
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

# Stop the Twingate service first to prevent it from respawning processes
$twingateSvc = Get-Service -Name "TwingateService" -ErrorAction SilentlyContinue
if ($twingateSvc -and $twingateSvc.Status -eq "Running") {
    Write-Host "Stopping Twingate service..." -ForegroundColor Yellow
    Stop-Service -Name "TwingateService" -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
}

$twingateProcs = Get-Process -Name "Twingate*" -ErrorAction SilentlyContinue
if ($twingateProcs) {
    foreach ($proc in $twingateProcs) {
        Write-Host "Stopping process: $($proc.Name) (PID $($proc.Id))..." -ForegroundColor Yellow
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 2

    # Verify all Twingate processes actually stopped
    $remaining = Get-Process -Name "Twingate*" -ErrorAction SilentlyContinue
    if ($remaining) {
        Write-Host "ERROR: The following Twingate processes are still running:" -ForegroundColor Red
        foreach ($p in $remaining) {
            Write-Host "  $($p.Name) (PID $($p.Id))" -ForegroundColor Red
        }
        Write-Host "Cannot proceed while Twingate is running. Please close it manually." -ForegroundColor Red
        Start-Sleep -Seconds 10
        exit 1
    }
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
    if ($uninstallProc.ExitCode -ne 0) {
        Write-Host "Uninstall failed (exit code $($uninstallProc.ExitCode))." -ForegroundColor Red
        Start-Sleep -Seconds 10
        exit 1
    }

    # Verify Twingate is actually gone from the registry
    $stillInstalled = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*" -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like "*Twingate*" }
    if ($stillInstalled) {
        Write-Host "Uninstall reported success but Twingate is still present in the registry." -ForegroundColor Red
        Start-Sleep -Seconds 10
        exit 1
    }
    Write-Host "Twingate uninstall complete and verified." -ForegroundColor Green
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
    if ($proc.ExitCode -ne 0) {
        Write-Host "Cleanup script failed (exit code $($proc.ExitCode))." -ForegroundColor Red
        Start-Sleep -Seconds 5
        exit 1
    }
    Write-Host "Cleanup script finished successfully." -ForegroundColor Green
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
try {
    $action  = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -File `"$PSCommandPath`" -PostReboot" -ErrorAction Stop
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME -ErrorAction Stop
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ErrorAction Stop
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -RunLevel Highest -LogonType Interactive -ErrorAction Stop

    Register-ScheduledTask -TaskName "FixTwingateContinue" `
        -Action $action -Trigger $trigger -Settings $settings -Principal $principal `
        -Description "Continues the Twingate fix script after reboot (auto-deletes)" `
        -Force -ErrorAction Stop | Out-Null
} catch {
    Write-Host "ERROR: Failed to register scheduled task: $_" -ForegroundColor Red
    Write-Host "Cannot safely reboot without a resume task. Aborting." -ForegroundColor Red
    Start-Sleep -Seconds 10
    exit 1
}

Write-Host "Scheduled task registered." -ForegroundColor Green
Write-Host "`nThe computer will reboot now. After you log back in," -ForegroundColor Yellow
Write-Host "the script will automatically continue with Step 5.`n" -ForegroundColor Yellow

Write-Host "Rebooting in 5 seconds..." -ForegroundColor DarkGray
Start-Sleep -Seconds 5

try {
    Restart-Computer -Force -ErrorAction Stop
} catch {
    Write-Host "ERROR: Failed to reboot: $_" -ForegroundColor Red
    Write-Host "Please reboot manually. The scheduled task will resume the script at Step 5." -ForegroundColor Yellow
    Start-Sleep -Seconds 10
    exit 1
}

}

# ===============================================================================
# AFTER FIRST REBOOT (Steps 5-7)
# ===============================================================================
if ($PostReboot) {
    Write-Host "`n  Resuming Twingate fix after reboot...`n" -ForegroundColor Green

    # Clean up the scheduled task
    Unregister-ScheduledTask -TaskName "FixTwingateContinue" -Confirm:$false -ErrorAction SilentlyContinue

    # -- Step 5: Install .NET 8 Desktop Runtime ----------------------------
    Write-Step -Number 5 -Title "Install .NET 8 Desktop Runtime"

    # Check if .NET 8 Desktop Runtime is already installed
    $dotnet8Installed = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*" -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like "*Windows Desktop Runtime*8.0*" }

    if ($dotnet8Installed) {
        Write-Host ".NET 8 Desktop Runtime is already installed — skipping." -ForegroundColor Green
    } else {
        $dotnetUrl  = "https://builds.dotnet.microsoft.com/dotnet/WindowsDesktop/8.0.23/windowsdesktop-runtime-8.0.23-win-x64.exe"
        $dotnetPath = "$env:USERPROFILE\Downloads\windowsdesktop-runtime-8.0.23-win-x64.exe"

        Write-Host "Downloading .NET 8 Desktop Runtime..." -ForegroundColor Yellow
        & curl.exe -L -o $dotnetPath $dotnetUrl
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Download failed (exit code $LASTEXITCODE)." -ForegroundColor Red
            Write-Host "Please download manually from: $dotnetUrl" -ForegroundColor Yellow
            Start-Sleep -Seconds 5
            exit 1
        }
        if (-not (Test-Path $dotnetPath) -or (Get-Item $dotnetPath).Length -eq 0) {
            Write-Host "Downloaded file is missing or empty." -ForegroundColor Red
            Start-Sleep -Seconds 5
            exit 1
        }
        Write-Host "Download complete: $dotnetPath" -ForegroundColor Green

        Write-Host "Installing .NET 8 Desktop Runtime silently..." -ForegroundColor Yellow
        $dotnetProc = Start-Process -FilePath $dotnetPath -ArgumentList "/install /quiet /norestart" -Wait -PassThru
        # Exit code 3010 means success but reboot required — we reboot in Step 7
        if ($dotnetProc.ExitCode -ne 0 -and $dotnetProc.ExitCode -ne 3010) {
            Write-Host "Installation failed (exit code $($dotnetProc.ExitCode))." -ForegroundColor Red
            Remove-Item $dotnetPath -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 10
            exit 1
        }

        # Clean up installer
        Remove-Item $dotnetPath -Force -ErrorAction SilentlyContinue

        # Verify .NET 8 Desktop Runtime is actually installed
        $dotnet8Verify = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*" -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like "*Windows Desktop Runtime*8.0*" }
        if (-not $dotnet8Verify) {
            Write-Host "Installation reported success but .NET 8 Desktop Runtime was not found. Install may have failed." -ForegroundColor Red
            Start-Sleep -Seconds 10
            exit 1
        }
        Write-Host ".NET 8 Desktop Runtime installed successfully." -ForegroundColor Green
    }

    Wait-Continue

    # -- Step 6: Download, install and configure Twingate ------------------
    Write-Step -Number 6 -Title "Download and install Twingate silently"

    # Delete all remaining Twingate network profiles before fresh install
    Write-Host "Removing all Twingate network profiles..." -ForegroundColor Yellow
    $profilesPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\NetworkList\Profiles"
    $deleted = 0
    Get-ChildItem $profilesPath -ErrorAction SilentlyContinue | ForEach-Object {
        $props = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
        if ($props.ProfileName -like "Twingate*") {
            try {
                Remove-Item $_.PSPath -Recurse -Force -ErrorAction Stop
                Write-Host "  Deleted profile '$($props.ProfileName)'" -ForegroundColor DarkGray
                $deleted++
            } catch {
                Write-Host "  Failed to delete profile '$($props.ProfileName)': $_" -ForegroundColor Red
            }
        }
    }
    if ($deleted -eq 0) {
        Write-Host "  No Twingate profiles found." -ForegroundColor Green
    } else {
        Write-Host "  Deleted $deleted Twingate profile(s)." -ForegroundColor Green
    }

    $installerUrl  = "https://api.twingate.com/download/windows?installer=msi"
    $installerPath = "$env:USERPROFILE\Downloads\TwingateWindowsInstaller.msi"

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
    $installProc = Start-Process -FilePath "msiexec.exe" -ArgumentList "/i `"$installerPath`" /qn network=inlumi.twingate.com auto_update=true no_optional_updates=true" -Wait -PassThru
    if ($installProc.ExitCode -ne 0) {
        Write-Host "Installation failed (exit code $($installProc.ExitCode))." -ForegroundColor Red
        Remove-Item $installerPath -Force -ErrorAction SilentlyContinue
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

    # -- Step 7: Reboot ----------------------------------------------------
    Write-Step -Number 7 -Title "Reboot computer"

    Write-Host "Registering a scheduled task to resume at Step 8 after reboot..." -ForegroundColor Yellow

    try {
        $action   = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -File `"$PSCommandPath`" -PostInstallReboot" -ErrorAction Stop
        $trigger  = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME -ErrorAction Stop
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ErrorAction Stop
        $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -RunLevel Highest -LogonType Interactive -ErrorAction Stop

        Register-ScheduledTask -TaskName "FixTwingatePostInstall" `
            -Action $action -Trigger $trigger -Settings $settings -Principal $principal `
            -Description "Triggers Intune sync after Twingate install reboot (auto-deletes)" `
            -Force -ErrorAction Stop | Out-Null
    } catch {
        Write-Host "ERROR: Failed to register scheduled task: $_" -ForegroundColor Red
        Write-Host "Cannot safely reboot without a resume task. Aborting." -ForegroundColor Red
        Start-Sleep -Seconds 10
        exit 1
    }

    Write-Host "Scheduled task registered." -ForegroundColor Green
    Write-Host "`nRebooting to complete the installation..." -ForegroundColor Yellow
    Write-Host "After you log back in, the script will trigger an Intune sync (Step 8).`n" -ForegroundColor Yellow

    Start-Sleep -Seconds 15

    try {
        Restart-Computer -Force -ErrorAction Stop
    } catch {
        Write-Host "ERROR: Failed to reboot: $_" -ForegroundColor Red
        Write-Host "Please reboot manually. The scheduled task will resume the script at Step 8." -ForegroundColor Yellow
        Start-Sleep -Seconds 10
        exit 1
    }
}

# ===============================================================================
# AFTER SECOND REBOOT (Steps 8-10)
# ===============================================================================
if ($PostInstallReboot) {
    Write-Host "`n  Resuming Twingate fix after install reboot...`n" -ForegroundColor Green

    # Clean up the scheduled task
    Unregister-ScheduledTask -TaskName "FixTwingatePostInstall" -Confirm:$false -ErrorAction SilentlyContinue

    # -- Step 8: Trigger Intune sync ----------------------------------------
    Write-Step -Number 8 -Title "Trigger Intune sync"

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
    $mdmTasks = @(Get-ScheduledTask -TaskPath "\Microsoft\Windows\EnterpriseMgmt\*" -ErrorAction SilentlyContinue)
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

    # -- Step 9: Verify Twingate connection ------------------------------------
    Write-Step -Number 9 -Title "Verify Twingate connection"

    # Find Twingate executable path from registry or known location
    $twingateExePath = $null
    $twingateReg = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*" -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like "*Twingate*" }
    if ($twingateReg -and $twingateReg.InstallLocation) {
        $candidate = Join-Path $twingateReg.InstallLocation "Twingate.exe"
        if (Test-Path $candidate) { $twingateExePath = $candidate }
    }
    if (-not $twingateExePath) {
        $candidate = "$env:ProgramFiles\Twingate\Twingate.exe"
        if (Test-Path $candidate) { $twingateExePath = $candidate }
    }

    # Start Twingate if not running
    $twingateRunning = Get-Process -Name "Twingate" -ErrorAction SilentlyContinue
    if (-not $twingateRunning) {
        if ($twingateExePath) {
            Write-Host "Starting Twingate..." -ForegroundColor Yellow
            Start-Process -FilePath $twingateExePath -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 3
            $twingateRunning = Get-Process -Name "Twingate" -ErrorAction SilentlyContinue
            if ($twingateRunning) {
                Write-Host "Twingate process started." -ForegroundColor Green
            } else {
                Write-Host "WARNING: Could not start Twingate. Please launch it manually." -ForegroundColor Red
            }
        } else {
            Write-Host "WARNING: Could not find Twingate executable. Please launch it manually." -ForegroundColor Red
        }
    } else {
        Write-Host "Twingate is already running." -ForegroundColor Green
    }

    Write-Host "`nPlease sign in to Twingate when the login window appears." -ForegroundColor Yellow
    Write-Host "Waiting for Twingate adapter to come up (up to 90 seconds)..." -ForegroundColor Yellow

    # Poll for Twingate adapter
    $adapterUp = $false
    $elapsed = 0
    $timeout = 90
    while ($elapsed -lt $timeout) {
        $adapter = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*Twingate*" -and $_.Status -eq "Up" }
        if ($adapter) {
            $adapterUp = $true
            Write-Host "Twingate adapter is up: $($adapter.Name)" -ForegroundColor Green
            break
        }
        Start-Sleep -Seconds 5
        $elapsed += 5
        Write-Host "  Waiting... ($elapsed/$timeout seconds)" -ForegroundColor DarkGray
    }

    if ($adapterUp) {
        Write-Host "Testing connectivity to 10.129.255.1..." -ForegroundColor Yellow
        $pingResult = Test-Connection -ComputerName 10.129.255.1 -Count 3 -Quiet -ErrorAction SilentlyContinue
        if ($pingResult) {
            Write-Host "Twingate is connected and internal network is reachable." -ForegroundColor Green
        } else {
            Write-Host "Ping failed. Attempting to re-authenticate Twingate..." -ForegroundColor Yellow

            # Stop and restart Twingate to force re-authentication
            Get-Process -Name "Twingate*" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 3
            if ($twingateExePath) {
                Start-Process -FilePath $twingateExePath -ErrorAction SilentlyContinue
            }

            Write-Host "Please sign in to Twingate again when the login window appears." -ForegroundColor Yellow
            Write-Host "Waiting for Twingate adapter to come up (up to 90 seconds)..." -ForegroundColor Yellow

            # Poll for adapter again after re-auth
            $retryAdapterUp = $false
            $retryElapsed = 0
            while ($retryElapsed -lt $timeout) {
                $retryAdapter = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*Twingate*" -and $_.Status -eq "Up" }
                if ($retryAdapter) {
                    $retryAdapterUp = $true
                    Write-Host "Twingate adapter is up: $($retryAdapter.Name)" -ForegroundColor Green
                    break
                }
                Start-Sleep -Seconds 5
                $retryElapsed += 5
                Write-Host "  Waiting... ($retryElapsed/$timeout seconds)" -ForegroundColor DarkGray
            }

            if ($retryAdapterUp) {
                Write-Host "Retrying ping to 10.129.255.1..." -ForegroundColor Yellow
                $retryPing = Test-Connection -ComputerName 10.129.255.1 -Count 3 -Quiet -ErrorAction SilentlyContinue
                if ($retryPing) {
                    Write-Host "Twingate is connected and internal network is reachable." -ForegroundColor Green
                } else {
                    Write-Host "WARNING: Twingate adapter is up but could not reach 10.129.255.1." -ForegroundColor Red
                    Write-Host "Check Twingate resources and network configuration." -ForegroundColor Yellow
                }
            } else {
                Write-Host "WARNING: Twingate adapter did not come up after re-authentication." -ForegroundColor Red
                Write-Host "Please verify Twingate connectivity manually." -ForegroundColor Yellow
            }
        }
    } else {
        Write-Host "WARNING: Twingate adapter did not come up within $timeout seconds." -ForegroundColor Red
        Write-Host "Please verify Twingate connectivity manually." -ForegroundColor Yellow
    }

    Wait-Continue

    # -- Step 10: Execute cleanup script ---------------------------------------
    Write-Step -Number 10 -Title "Execute Remove-TwingateGhosts.ps1"

    $cleanupScript = Join-Path $PSScriptRoot "Remove-TwingateGhosts.ps1"

    if (Test-Path $cleanupScript) {
        Write-Host "Launching Remove-TwingateGhosts.ps1..." -ForegroundColor Yellow
        $proc = Start-Process powershell -ArgumentList @(
            "-ExecutionPolicy", "Bypass", "-File", "`"$cleanupScript`""
        ) -PassThru -Wait
        if ($proc.ExitCode -ne 0) {
            Write-Host "Cleanup script failed (exit code $($proc.ExitCode))." -ForegroundColor Red
        } else {
            Write-Host "Cleanup script finished successfully." -ForegroundColor Green
        }
    } else {
        Write-Host "ERROR: Could not find '$cleanupScript'" -ForegroundColor Red
        Write-Host "Make sure Remove-TwingateGhosts.ps1 is in the same folder as this script." -ForegroundColor Yellow
    }

    Write-Host "`nTwingate fix complete!" -ForegroundColor Green
    Write-Host "`nExiting in 10 seconds..." -ForegroundColor DarkGray
    Start-Sleep -Seconds 10
    exit 0
}
