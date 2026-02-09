#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Configures the Twingate service to start only when network connectivity is available.

.DESCRIPTION
    Adds a network availability trigger and NlaSvc dependency to "Twingate.Service"
    so Windows will not start the service until IP connectivity is established.
    Logs all output to C:\twingate_logs\Set-TwingateServiceTrigger_<timestamp>.log.

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
Write-Log "=== Configure Twingate service network trigger ===" -Color Cyan

$svc = Get-Service -Name "Twingate.Service" -ErrorAction SilentlyContinue
if (-not $svc) {
    Write-Log "Service 'Twingate.Service' not found." -Color Red
    exit 1
}

Write-Log "Service 'Twingate.Service' found (Status: $($svc.Status))." -Color Green

# --- Internet connectivity test ---
Write-Log "Testing internet connectivity..." -Color Cyan
$internetOk = $false
try {
    $response = Invoke-WebRequest -Uri 'http://www.msftconnecttest.com/connecttest.txt' -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
    if ($response.StatusCode -eq 200 -and $response.Content.Trim() -eq 'Microsoft Connect Test') {
        $internetOk = $true
        Write-Log "  Internet access test PASSED (HTTP 200 from msftconnecttest.com)." -Color Green
    } else {
        Write-Log "  Internet access test FAILED (unexpected response: HTTP $($response.StatusCode))." -Color Red
    }
} catch {
    Write-Log "  Internet access test FAILED: $($_.Exception.Message)" -Color Red
}
if (-not $internetOk) {
    Write-Log "  WARNING: No internet connectivity detected. Twingate service may not function correctly." -Color Yellow
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
    # --- Add network availability trigger ---
    Write-Log "Setting start trigger: network availability..." -Color Cyan
    & sc.exe triggerinfo "Twingate.Service" start/networkon 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Log "  Service trigger set: start on network availability." -Color Green
    } else {
        Write-Log "  Failed to set service trigger (exit code $LASTEXITCODE)." -Color Red
    }

    # --- Add NlaSvc dependency ---
    Write-Log "Setting service dependency: NlaSvc (Network Location Awareness)..." -Color Cyan
    & sc.exe config "Twingate.Service" depend= NlaSvc 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Log "  Service dependency set: NlaSvc." -Color Green
    } else {
        Write-Log "  Failed to set service dependency (exit code $LASTEXITCODE)." -Color Red
    }

    # --- Deploy startup internet-check logging script ---
    Write-Log "Deploying internet-check logging script: $helperScript" -Color Cyan
    $helperContent = @'
# Test-TwingateInternet.ps1 — Runs at startup to log internet connectivity before Twingate starts
$logDir  = 'C:\twingate_logs'
if (-not (Test-Path $logDir)) { New-Item -Path $logDir -ItemType Directory -Force | Out-Null }
$logFile = Join-Path $logDir ('TwingateInternetCheck_{0}.log' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))

function Write-CheckLog { param([string]$Msg) Add-Content -Path $logFile -Value ("[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Msg) }

Write-CheckLog "=== Twingate startup internet connectivity check ==="
Write-CheckLog "Computer: $env:COMPUTERNAME  User: $env:USERNAME"

$svc = Get-Service -Name 'Twingate.Service' -ErrorAction SilentlyContinue
if ($svc) { Write-CheckLog "Twingate.Service status: $($svc.Status)" }
else       { Write-CheckLog "Twingate.Service not found" }

$internetOk = $false
try {
    $resp = Invoke-WebRequest -Uri 'http://www.msftconnecttest.com/connecttest.txt' -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop
    if ($resp.StatusCode -eq 200 -and $resp.Content.Trim() -eq 'Microsoft Connect Test') {
        $internetOk = $true
        Write-CheckLog "Internet access test PASSED (HTTP 200 from msftconnecttest.com)"
    } else {
        Write-CheckLog "Internet access test FAILED (unexpected response: HTTP $($resp.StatusCode))"
    }
} catch {
    Write-CheckLog "Internet access test FAILED: $($_.Exception.Message)"
}
if (-not $internetOk) {
    Write-CheckLog "WARNING: No internet connectivity detected before Twingate service start."
}
'@
    Set-Content -Path $helperScript -Value $helperContent -Force
    Write-Log "  Helper script created." -Color Green

    # --- Register scheduled task to run helper at startup ---
    Write-Log "Registering scheduled task '$taskName' (AtStartup)..." -Color Cyan
    try {
        # Remove existing task if present
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        $taskAction  = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$helperScript`""
        $taskTrigger = New-ScheduledTaskTrigger -AtStartup
        $taskPrincipal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest
        Register-ScheduledTask -TaskName $taskName -Action $taskAction -Trigger $taskTrigger -Principal $taskPrincipal -Description 'Logs internet connectivity before Twingate service starts' -ErrorAction Stop | Out-Null
        Write-Log "  Scheduled task '$taskName' registered." -Color Green
    } catch {
        Write-Log "  Failed to register scheduled task: $($_.Exception.Message)" -Color Red
    }

    Write-Log "Done. 'Twingate.Service' will now only start when network is available." -Color Cyan
    Write-Log "Internet connectivity will be logged at every startup in $logDir." -Color Cyan
} else {
    # --- Remove network availability trigger ---
    Write-Log "Removing service triggers..." -Color Cyan
    & sc.exe triggerinfo "Twingate.Service" delete 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Log "  Service triggers removed." -Color Green
    } elseif ($LASTEXITCODE -eq 87) {
        Write-Log "  No triggers found (already removed)." -Color Yellow
    } else {
        Write-Log "  Failed to remove service triggers (exit code $LASTEXITCODE)." -Color Red
    }

    # --- Remove NlaSvc dependency ---
    Write-Log "Removing service dependencies..." -Color Cyan
    & sc.exe config "Twingate.Service" depend= / 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Log "  Service dependencies removed." -Color Green
    } else {
        Write-Log "  Failed to remove service dependencies (exit code $LASTEXITCODE)." -Color Red
    }

    # --- Remove startup internet-check scheduled task ---
    Write-Log "Removing scheduled task '$taskName'..." -Color Cyan
    $existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($existingTask) {
        try {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop
            Write-Log "  Scheduled task '$taskName' removed." -Color Green
        } catch {
            Write-Log "  Failed to remove scheduled task: $($_.Exception.Message)" -Color Red
        }
    } else {
        Write-Log "  Scheduled task '$taskName' not found (already removed)." -Color Yellow
    }

    # --- Remove helper script ---
    if (Test-Path $helperScript) {
        Remove-Item -Path $helperScript -Force
        Write-Log "  Helper script removed: $helperScript" -Color Green
    } else {
        Write-Log "  Helper script not found (already removed)." -Color Yellow
    }

    Write-Log "Done. 'Twingate.Service' reverted to default startup behavior." -Color Cyan
    Write-Log "Startup internet connectivity logging has been removed." -Color Cyan
}
