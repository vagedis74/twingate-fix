<#
.SYNOPSIS
    Quick-fix repair for a broken Twingate connection (no reboot required).

.DESCRIPTION
    Non-interactive script that force-restarts the Twingate service and client
    when the VPN connection is broken. Handles the common failure mode where
    the service is "Running" but internally stuck (SDWAN Offline, gRPC
    DeadlineExceeded) and enters StopPending when a normal restart is attempted.

    The script force-kills the service process via WMI PID lookup, cleans up
    ghost adapters and stale network profiles, then restarts everything.

    Logs all actions to C:\twingate_logs\Repair-TwingateConnection_<timestamp>.log.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File Repair-TwingateConnection.ps1
#>

# ==============================================================================
# Step 1: Self-elevate if not admin
# ==============================================================================
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

# ==============================================================================
# Step 2: Setup logging
# ==============================================================================
$logDir = "C:\twingate_logs"
if (-not (Test-Path $logDir)) { New-Item -Path $logDir -ItemType Directory -Force | Out-Null }
$logFile = Join-Path $logDir ("Repair-TwingateConnection_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))

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

Write-Log "=== Twingate Connection Repair ===" -Color Cyan
Write-Log "Log file: $logFile"

# ==============================================================================
# Step 3: Verify Twingate service exists
# ==============================================================================
$svc = Get-Service -Name "Twingate.Service" -ErrorAction SilentlyContinue
if (-not $svc) {
    Write-Log "Twingate service is not installed on this computer." -Color Red
    exit 1
}
Write-Log "Twingate service found." -Color Green

# ==============================================================================
# Step 4: Check internet connectivity
# ==============================================================================
Write-Log "Checking internet connectivity..." -Color Cyan
$internetOk = $false
try {
    $response = Invoke-WebRequest -Uri 'http://www.msftconnecttest.com/connecttest.txt' -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
    if ($response.StatusCode -eq 200 -and $response.Content.Trim() -eq 'Microsoft Connect Test') {
        $internetOk = $true
        Write-Log "Internet connectivity verified." -Color Green
    } else {
        Write-Log "Internet test returned an unexpected response." -Color Yellow
    }
} catch {
    Write-Log "Internet test failed: $($_.Exception.Message)" -Color Yellow
}
if (-not $internetOk) {
    Write-Log "WARNING: No internet connection detected. Twingate may not connect after repair." -Color Yellow
}

# ==============================================================================
# Step 5: Diagnose current state (read-only)
# ==============================================================================
Write-Log "" -Color White
Write-Log "--- Diagnostics ---" -Color Cyan

# Service status
$svc = Get-Service -Name "Twingate.Service" -ErrorAction SilentlyContinue
Write-Log "Service status: $($svc.Status)" -Color $(if ($svc.Status -eq 'Running') { 'Green' } else { 'Yellow' })

# Client process
$clientProc = Get-Process -Name "Twingate" -ErrorAction SilentlyContinue
if ($clientProc) {
    Write-Log "Client process: running (PID $($clientProc.Id))" -Color Green
} else {
    Write-Log "Client process: not running" -Color Yellow
}

# Twingate adapter
$adapter = Get-PnpDevice -Class Net -ErrorAction SilentlyContinue |
    Where-Object { $_.FriendlyName -like "*Twingate*" -and $_.Status -eq "OK" } |
    Select-Object -First 1
if ($adapter) {
    Write-Log "Network adapter: $($adapter.FriendlyName) [OK]" -Color Green
} else {
    Write-Log "Network adapter: no healthy Twingate adapter found" -Color Yellow
}

# Connection profile
$connectionProfile = @(Get-NetConnectionProfile -ErrorAction SilentlyContinue |
    Where-Object { $_.InterfaceAlias -like "*Twingate*" }) | Select-Object -First 1
$activeGUID = $null
if ($connectionProfile) {
    $activeGUID = $connectionProfile.InstanceID
    Write-Log "Connection profile: '$($connectionProfile.Name)' (GUID $activeGUID)" -Color Green
} else {
    Write-Log "Connection profile: none" -Color Yellow
}

# Ghost adapters
$ghostAdapters = @(Get-PnpDevice -Class Net -ErrorAction SilentlyContinue |
    Where-Object { $_.FriendlyName -like "*Twingate*" -and $_.Status -ne "OK" })
Write-Log "Ghost adapters: $($ghostAdapters.Count)" -Color $(if ($ghostAdapters.Count -eq 0) { 'Green' } else { 'Yellow' })

# Stale profiles
$profilesPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\NetworkList\Profiles"
$staleProfiles = @()
Get-ChildItem $profilesPath -ErrorAction SilentlyContinue | ForEach-Object {
    $props = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
    if ($props.ProfileName -like "Twingate*") {
        $guid = $_.PSChildName
        if (-not $activeGUID -or $guid -ne $activeGUID) {
            $staleProfiles += [PSCustomObject]@{
                Name   = $props.ProfileName
                GUID   = $guid
                PSPath = $_.PSPath
            }
        }
    }
}
Write-Log "Stale profiles: $($staleProfiles.Count)" -Color $(if ($staleProfiles.Count -eq 0) { 'Green' } else { 'Yellow' })

Write-Log "" -Color White

# ==============================================================================
# Step 6: Remove ghost adapters
# ==============================================================================
if ($ghostAdapters.Count -gt 0) {
    Write-Log "Removing $($ghostAdapters.Count) ghost adapter(s)..." -Color Cyan
    foreach ($ghost in $ghostAdapters) {
        Write-Log "  Removing $($ghost.FriendlyName) [$($ghost.Status)] ($($ghost.InstanceId))..." -Color Yellow
        try {
            $output = & pnputil /remove-device "$($ghost.InstanceId)" 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Log "  Removed." -Color Green
            } else {
                Write-Log "  Failed (exit code $LASTEXITCODE): $output" -Color Red
            }
        } catch {
            Write-Log "  Failed: $($_.Exception.Message)" -Color Red
        }
    }
} else {
    Write-Log "No ghost adapters to remove." -Color Green
}

# ==============================================================================
# Step 7: Remove stale profiles (GUID-based, preserve active)
# ==============================================================================
if ($staleProfiles.Count -gt 0) {
    Write-Log "Removing $($staleProfiles.Count) stale profile(s)..." -Color Cyan
    foreach ($profile in $staleProfiles) {
        Write-Log "  Deleting '$($profile.Name)' ($($profile.GUID))..." -Color Yellow
        try {
            Remove-Item $profile.PSPath -Recurse -Force -ErrorAction Stop
            Write-Log "  Deleted." -Color Green
        } catch {
            Write-Log "  Failed: $($_.Exception.Message)" -Color Red
        }
    }
} else {
    Write-Log "No stale profiles to remove." -Color Green
}

# ==============================================================================
# Step 8: Force-stop Twingate service and processes
# ==============================================================================
Write-Log "Force-stopping Twingate..." -Color Cyan

# Kill service via WMI PID (handles StopPending)
$svc = Get-Service -Name "Twingate.Service" -ErrorAction SilentlyContinue
if ($svc.Status -ne 'Stopped') {
    $svcWmi = Get-WmiObject Win32_Service -Filter "Name='Twingate.Service'" -ErrorAction SilentlyContinue
    if ($svcWmi -and $svcWmi.ProcessId -gt 0) {
        Write-Log "  Killing service process (PID $($svcWmi.ProcessId))..." -Color Yellow
        try {
            Stop-Process -Id $svcWmi.ProcessId -Force -ErrorAction Stop
            Write-Log "  Service process killed." -Color Green
        } catch {
            Write-Log "  Failed to kill service process: $($_.Exception.Message)" -Color Red
        }
    } else {
        Write-Log "  Could not find service process to kill." -Color Yellow
    }
} else {
    Write-Log "  Service is already stopped." -Color Green
}

# Kill remaining Twingate processes
$twingateProcs = Get-Process -Name "Twingate*" -ErrorAction SilentlyContinue
if ($twingateProcs) {
    foreach ($proc in $twingateProcs) {
        Write-Log "  Killing process: $($proc.Name) (PID $($proc.Id))..." -Color Yellow
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    }
    Write-Log "  All Twingate processes killed." -Color Green
} else {
    Write-Log "  No Twingate processes running." -Color Green
}

# ==============================================================================
# Step 9: Wait for clean shutdown
# ==============================================================================
Write-Log "Waiting for service to reach Stopped state..." -Color Cyan
Start-Sleep -Seconds 3

$svc = Get-Service -Name "Twingate.Service" -ErrorAction SilentlyContinue
if ($svc.Status -ne 'Stopped') {
    Write-Log "  Service still $($svc.Status) after 3s, waiting 5s more..." -Color Yellow
    Start-Sleep -Seconds 5
    $svc = Get-Service -Name "Twingate.Service" -ErrorAction SilentlyContinue
    if ($svc.Status -ne 'Stopped') {
        Write-Log "  WARNING: Service is still $($svc.Status). Proceeding anyway." -Color Yellow
    } else {
        Write-Log "  Service stopped." -Color Green
    }
} else {
    Write-Log "  Service stopped." -Color Green
}

# ==============================================================================
# Step 10: Start service
# ==============================================================================
Write-Log "Starting Twingate service..." -Color Cyan
try {
    Start-Service -Name "Twingate.Service" -ErrorAction Stop
    Write-Log "Twingate service started." -Color Green
} catch {
    Write-Log "ERROR: Failed to start Twingate service: $($_.Exception.Message)" -Color Red
    exit 1
}

# ==============================================================================
# Step 11: Start Twingate client
# ==============================================================================
Write-Log "Starting Twingate client..." -Color Cyan

$twingateExe = $null

# Try registry path first
$regPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\Twingate.exe"
$regValue = Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue
if ($regValue -and $regValue.'(default)' -and (Test-Path $regValue.'(default)')) {
    $twingateExe = $regValue.'(default)'
}

# Fallback to Program Files
if (-not $twingateExe) {
    $fallback = "${env:ProgramFiles}\Twingate\Twingate.exe"
    if (Test-Path $fallback) {
        $twingateExe = $fallback
    }
}

if ($twingateExe) {
    Write-Log "  Launching: $twingateExe" -Color Yellow
    Start-Process -FilePath $twingateExe -ErrorAction SilentlyContinue
    Write-Log "  Client launched." -Color Green
} else {
    Write-Log "  WARNING: Twingate.exe not found. Start the client manually." -Color Yellow
}

# ==============================================================================
# Step 12: Poll for recovery (30s, every 5s)
# ==============================================================================
Write-Log "Waiting for Twingate to connect..." -Color Cyan

$maxAttempts = 6   # 6 x 5s = 30 seconds
$connected = $false

for ($i = 1; $i -le $maxAttempts; $i++) {
    Start-Sleep -Seconds 5

    $svc = Get-Service -Name "Twingate.Service" -ErrorAction SilentlyContinue
    $svcRunning = $svc -and $svc.Status -eq 'Running'

    $adapterUp = $false
    $adapterDevice = Get-PnpDevice -Class Net -ErrorAction SilentlyContinue |
        Where-Object { $_.FriendlyName -like "*Twingate*" -and $_.Status -eq "OK" } |
        Select-Object -First 1
    if ($adapterDevice) { $adapterUp = $true }

    $profileExists = $false
    $connProfile = @(Get-NetConnectionProfile -ErrorAction SilentlyContinue |
        Where-Object { $_.InterfaceAlias -like "*Twingate*" }) | Select-Object -First 1
    if ($connProfile) { $profileExists = $true }

    $statusParts = @()
    $statusParts += "service=$(if ($svcRunning) { 'Running' } else { $svc.Status })"
    $statusParts += "adapter=$(if ($adapterUp) { 'Up' } else { 'Down' })"
    $statusParts += "profile=$(if ($profileExists) { 'Yes' } else { 'No' })"

    Write-Log "  Poll $i/${maxAttempts}: $($statusParts -join ', ')" -Color DarkGray

    if ($svcRunning -and $adapterUp -and $profileExists) {
        $connected = $true
        break
    }
}

# ==============================================================================
# Step 13: Summary
# ==============================================================================
Write-Log "" -Color White
Write-Log "--- Result ---" -Color Cyan

if ($connected) {
    Write-Log "Twingate connection restored." -Color Green
} else {
    Write-Log "WARNING: Twingate did not fully reconnect within 30 seconds." -Color Yellow
    Write-Log "The service is running but the tunnel may still be initializing." -Color Yellow
    Write-Log "If the connection does not come up, try Reinstall-Twingate.ps1." -Color Yellow
}

Write-Log "Log file: $logFile" -Color Cyan
