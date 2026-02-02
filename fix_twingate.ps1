<#
.SYNOPSIS
    Automated Twingate client fix — performs all manual repair steps in sequence.
.DESCRIPTION
    Step 1: Quit the Twingate client
    Step 2: Uninstall Twingate
    Step 3: Execute Remove-Twingate-Cleanup.ps1 as administrator
    Step 4: Reboot (script resumes automatically after logon)
    Step 5: Download and install Twingate silently, configure to join inlumi.twingate.com
    Step 6: Reboot when the Twingate installer asks for it
.NOTES
    Must be run as administrator. The script self-elevates if needed.
    After the reboot in step 4, a scheduled task re-launches this script to continue at step 5.
#>

param(
    [switch]$PostReboot
)

# ── Self-elevate if not running as admin ──────────────────────────────────────
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)

if (-not $isAdmin) {
    Write-Host "`nRequesting administrator privileges..." -ForegroundColor Cyan
    $argList = @("-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`"")
    if ($PostReboot) { $argList += "-PostReboot" }
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

# ── Helper: wait for user confirmation ────────────────────────────────────────
function Wait-Continue {
    Write-Host "`nPress Enter to continue to the next step..." -ForegroundColor DarkGray
    Read-Host | Out-Null
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
    $installerPath = "$env:TEMP\TwingateInstaller.exe"

    Write-Host "Downloading Twingate installer..." -ForegroundColor Yellow
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $installerUrl -OutFile $installerPath -UseBasicParsing
        Write-Host "Download complete: $installerPath" -ForegroundColor Green
    } catch {
        Write-Host "Download failed: $_" -ForegroundColor Red
        Write-Host "Please download manually from: $installerUrl" -ForegroundColor Yellow
        Read-Host "Press Enter to exit"
        exit 1
    }

    # Configure Twingate to join the network before installing
    Write-Host "Configuring Twingate to join: inlumi.twingate.com..." -ForegroundColor Yellow
    $twingateRegPath = "HKLM:\SOFTWARE\Twingate"
    if (-not (Test-Path $twingateRegPath)) {
        New-Item -Path $twingateRegPath -Force | Out-Null
    }
    Set-ItemProperty -Path $twingateRegPath -Name "Network" -Value "inlumi.twingate.com"
    Write-Host "Twingate client configured." -ForegroundColor Green

    Write-Host "`nInstalling Twingate silently..." -ForegroundColor Yellow
    Start-Process -FilePath $installerPath -ArgumentList "/S" -Wait
    Write-Host "Twingate installation complete." -ForegroundColor Green

    # Clean up installer
    Remove-Item $installerPath -Force -ErrorAction SilentlyContinue

    # ── Step 6: Reboot when the installer asks for it ────────────────────
    Write-Step -Number 6 -Title "Reboot computer"

    Write-Host "The Twingate installer requires a reboot to complete." -ForegroundColor Yellow
    Write-Host "Please click 'Restart' when the Twingate installer prompts you." -ForegroundColor Yellow
    Write-Host "`nIf no prompt appeared, press Enter to reboot now..." -ForegroundColor DarkGray
    Read-Host | Out-Null
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

$twingateApp = $uninstallPaths | ForEach-Object {
    Get-ItemProperty $_ -ErrorAction SilentlyContinue
} | Where-Object { $_.DisplayName -like "*Twingate*" } | Select-Object -First 1

if ($twingateApp) {
    Write-Host "Found: $($twingateApp.DisplayName) ($($twingateApp.DisplayVersion))" -ForegroundColor Yellow

    $uninstallString = $twingateApp.UninstallString
    if ($uninstallString) {
        Write-Host "Running uninstaller..." -ForegroundColor Yellow

        # Handle msiexec-based uninstalls
        if ($uninstallString -match "msiexec") {
            $productCode = $twingateApp.PSChildName
            Start-Process msiexec.exe -ArgumentList "/x $productCode /qn /norestart" -Wait
        } else {
            # Try running the uninstall string with silent flags
            Start-Process cmd.exe -ArgumentList "/c `"$uninstallString`" /S" -Wait
        }

        Start-Sleep -Seconds 3
        Write-Host "Uninstall complete." -ForegroundColor Green
    } else {
        Write-Host "No uninstall command found. Please uninstall Twingate manually from Settings > Apps." -ForegroundColor Red
        Wait-Continue
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
    Read-Host "Press Enter to exit"
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

Write-Host "Press Enter to reboot..." -ForegroundColor DarkGray
Read-Host | Out-Null

Restart-Computer -Force
