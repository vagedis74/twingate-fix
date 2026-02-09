#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Configures the Twingate service to start only when network connectivity is available.

.DESCRIPTION
    Interactive script that configures "Twingate.Service" to start only when internet
    connectivity is confirmed. Prompts the user to (I)mplement or (R)evert the
    configuration. Logs all actions to C:\twingate_logs\Set-TwingateServiceTrigger_<timestamp>.log.
    Tests internet connectivity (via msftconnecttest.com) before any changes.

    Implement: Sets startup type to Manual via sc.exe config, adds NlaSvc dependency
    via sc.exe config, deploys C:\twingate_logs\Test-TwingateInternet.ps1 helper script,
    registers TwingateInternetCheck scheduled task (runs as SYSTEM at startup) that polls
    for internet connectivity and starts the Twingate service once confirmed.

    No SCM trigger is used — the scheduled task is the sole boot-time start mechanism.
    This avoids the problem where sc.exe start/networkon fires when any IP address
    appears on any interface, before actual internet connectivity is available.

    Revert: Restores startup type to Automatic, removes any service trigger and NlaSvc
    dependency, unregisters the TwingateInternetCheck scheduled task, deletes the helper
    script.

    The startup helper polls msftconnecttest.com every 10 seconds for up to 5 minutes,
    then starts the service once internet is confirmed. It produces a timestamped
    TwingateInternetCheck_<timestamp>.log in C:\twingate_logs\ at every boot.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File Set-TwingateServiceTrigger.ps1
#>

# --- Logging setup ---
$logDir  = "C:\twingate_logs"
if (-not (Test-Path $logDir)) { New-Item -Path $logDir -ItemType Directory -Force | Out-Null }
$logFile = Join-Path $logDir ("Set-TwingateServiceTrigger_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))

function Write-Log {
    param(
        [string]$Message,
        [string]$Color = 'White'
    )
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $entry = "[$ts] $Message"
    Add-Content -Path $logFile -Value $entry
    Write-Host $Message -ForegroundColor $Color
}

Write-Log "Log file: $logFile"
Write-Log "=== Twingate Service Configuration ===" -Color Cyan

$svc = Get-Service -Name "Twingate.Service" -ErrorAction SilentlyContinue
if (-not $svc) {
    Write-Log "Twingate service is not installed on this computer." -Color Red
    exit 1
}

Write-Log "Twingate service found. Current status: $($svc.Status)." -Color Green

# --- Internet connectivity test ---
Write-Log "Testing internet access now, before making changes to Twingate..." -Color Cyan
$internetOk = $false
try {
    $response = Invoke-WebRequest -Uri 'http://www.msftconnecttest.com/connecttest.txt' -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
    if ($response.StatusCode -eq 200 -and $response.Content.Trim() -eq 'Microsoft Connect Test') {
        $internetOk = $true
        Write-Log "Internet connectivity verified." -Color Green
    } else {
        Write-Log "Internet test returned an unexpected response." -Color Red
    }
} catch {
    Write-Log "Internet test failed: $($_.Exception.Message)" -Color Red
}
if (-not $internetOk) {
    Write-Log "WARNING: No internet connection detected. Twingate may not work correctly after changes." -Color Yellow
}

$action = Read-Host "`nDo you want to (I)mplement or (R)evert the network trigger? (I/R)"
Write-Log "User selected: $action"
if ($action -notin @('I', 'i', 'R', 'r')) {
    Write-Log "Invalid choice. Exiting." -Color Yellow
    exit 0
}

$helperScript = Join-Path $logDir 'Test-TwingateInternet.ps1'
$taskName     = 'TwingateInternetCheck'

if ($action -in @('I', 'i')) {
    # --- Add NlaSvc dependency ---
    Write-Log "Adding a dependency on the Network Location Awareness service..." -Color Cyan
    & sc.exe config "Twingate.Service" depend= NlaSvc 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Log "Twingate will now start after the network awareness service is ready." -Color Green
    } else {
        Write-Log "Failed to add the network awareness dependency." -Color Red
    }

    # --- Stop service if running or stopping ---
    $svc = Get-Service -Name "Twingate.Service" -ErrorAction SilentlyContinue
    if ($svc.Status -in @('Running', 'StopPending')) {
        Write-Log "Twingate service is $($svc.Status). Killing the process before changing startup type..." -Color Yellow
        $svcWmi = Get-WmiObject Win32_Service -Filter "Name='Twingate.Service'" -ErrorAction SilentlyContinue
        if ($svcWmi -and $svcWmi.ProcessId -gt 0) {
            try {
                Stop-Process -Id $svcWmi.ProcessId -Force -ErrorAction Stop
                Write-Log "Twingate service process (PID $($svcWmi.ProcessId)) killed." -Color Green
            } catch {
                Write-Log "Failed to kill Twingate service process: $($_.Exception.Message)" -Color Red
            }
        } else {
            Write-Log "Could not find Twingate service process to kill." -Color Yellow
        }
    } else {
        Write-Log "Twingate service is $($svc.Status). No need to stop it." -Color Green
    }

    # --- Set startup type to Manual ---
    Write-Log "Changing Twingate startup type from Automatic to Manual..." -Color Cyan
    & sc.exe config "Twingate.Service" start= demand 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Log "Twingate startup type set to Manual." -Color Green
    } else {
        Write-Log "Failed to change the startup type." -Color Red
    }

    # --- Deploy startup internet-check logging script ---
    Write-Log "Installing a startup script that logs internet connectivity before Twingate starts..." -Color Cyan
    $helperContent = @'
# Test-TwingateInternet.ps1 — Runs at startup to poll for internet and start Twingate service
$logDir  = 'C:\twingate_logs'
if (-not (Test-Path $logDir)) { New-Item -Path $logDir -ItemType Directory -Force | Out-Null }
$logFile = Join-Path $logDir ('TwingateInternetCheck_{0}.log' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))

function Write-CheckLog { param([string]$Msg) Add-Content -Path $logFile -Value ("[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Msg) }

Write-CheckLog "=== Twingate internet-gated startup ==="
Write-CheckLog "Computer: $env:COMPUTERNAME  User: $env:USERNAME"

$svc = Get-Service -Name 'Twingate.Service' -ErrorAction SilentlyContinue
if (-not $svc) {
    Write-CheckLog "Twingate service is not installed. Exiting."
    exit 0
}
Write-CheckLog "Twingate service status: $($svc.Status)"
if ($svc.Status -eq 'Running') {
    Write-CheckLog "Service is already running. Nothing to do."
    exit 0
}

$maxAttempts = 30   # 30 x 10s = 5 minutes
$intervalSec = 10
$internetOk  = $false

Write-CheckLog "Polling for internet connectivity (every ${intervalSec}s, up to $($maxAttempts * $intervalSec)s)..."

for ($i = 1; $i -le $maxAttempts; $i++) {
    # Re-check service state each iteration
    $svc = Get-Service -Name 'Twingate.Service' -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq 'Running') {
        Write-CheckLog "Service started externally during poll. Nothing to do."
        exit 0
    }

    try {
        $resp = Invoke-WebRequest -Uri 'http://www.msftconnecttest.com/connecttest.txt' -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
        if ($resp.StatusCode -eq 200 -and $resp.Content.Trim() -eq 'Microsoft Connect Test') {
            $internetOk = $true
            Write-CheckLog "Attempt ${i}: Internet connectivity confirmed."
            break
        } else {
            Write-CheckLog "Attempt ${i}: Unexpected response (status $($resp.StatusCode))."
        }
    } catch {
        Write-CheckLog "Attempt ${i}: No internet yet — $($_.Exception.Message)"
    }

    Start-Sleep -Seconds $intervalSec
}

if (-not $internetOk) {
    Write-CheckLog "Timed out after $($maxAttempts * $intervalSec) seconds without internet. Service NOT started."
    exit 1
}

Write-CheckLog "Starting Twingate service..."
try {
    Start-Service -Name 'Twingate.Service' -ErrorAction Stop
    $svc = Get-Service -Name 'Twingate.Service'
    Write-CheckLog "Twingate service is now: $($svc.Status)"
} catch {
    Write-CheckLog "Failed to start Twingate service: $($_.Exception.Message)"
    exit 1
}
'@
    Set-Content -Path $helperScript -Value $helperContent -Force
    Write-Log "Startup script installed." -Color Green

    # --- Register scheduled task to run helper at startup ---
    Write-Log "Scheduling the internet connectivity check to run at every boot..." -Color Cyan
    try {
        # Remove existing task if present
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        $taskAction  = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$helperScript`""
        $taskTrigger = New-ScheduledTaskTrigger -AtStartup
        $taskPrincipal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest
        Register-ScheduledTask -TaskName $taskName -Action $taskAction -Trigger $taskTrigger -Principal $taskPrincipal -Description 'Polls for internet connectivity at boot and starts Twingate service once confirmed' -ErrorAction Stop | Out-Null
        Write-Log "Internet connectivity check scheduled." -Color Green
    } catch {
        Write-Log "Failed to schedule the internet connectivity check: $($_.Exception.Message)" -Color Red
    }

    Write-Log "" -Color Cyan
    Write-Log "All done! Twingate will now only start once internet connectivity is confirmed at boot." -Color Cyan
    Write-Log "The startup task polls for internet and starts the service. Logs are in $logDir." -Color Cyan
} else {
    # --- Remove network availability trigger ---
    Write-Log "Removing the network availability trigger..." -Color Cyan
    & sc.exe triggerinfo "Twingate.Service" delete 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Log "Network trigger removed. Twingate will no longer wait for network." -Color Green
    } elseif ($LASTEXITCODE -eq 87) {
        Write-Log "No network trigger found (already removed)." -Color Yellow
    } else {
        Write-Log "Failed to remove the network trigger." -Color Red
    }

    # --- Restore startup type to Automatic ---
    Write-Log "Changing Twingate startup type back to Automatic..." -Color Cyan
    & sc.exe config "Twingate.Service" start= auto 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Log "Twingate startup type restored to Automatic." -Color Green
    } else {
        Write-Log "Failed to restore the startup type." -Color Red
    }

    # --- Remove NlaSvc dependency ---
    Write-Log "Removing the network awareness dependency..." -Color Cyan
    & sc.exe config "Twingate.Service" depend= / 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Log "Network awareness dependency removed." -Color Green
    } else {
        Write-Log "Failed to remove the network awareness dependency." -Color Red
    }

    # --- Remove startup internet-check scheduled task ---
    Write-Log "Removing the startup internet connectivity check..." -Color Cyan
    $existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($existingTask) {
        try {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop
            Write-Log "Startup internet check removed." -Color Green
        } catch {
            Write-Log "Failed to remove the startup internet check: $($_.Exception.Message)" -Color Red
        }
    } else {
        Write-Log "Startup internet check was already removed." -Color Yellow
    }

    # --- Remove helper script ---
    if (Test-Path $helperScript) {
        Remove-Item -Path $helperScript -Force
        Write-Log "Startup script removed." -Color Green
    } else {
        Write-Log "Startup script was already removed." -Color Yellow
    }

    Write-Log "" -Color Cyan
    Write-Log "All done! Twingate has been reverted to its default startup behavior." -Color Cyan
    Write-Log "The startup internet connectivity logging has been removed." -Color Cyan
}
