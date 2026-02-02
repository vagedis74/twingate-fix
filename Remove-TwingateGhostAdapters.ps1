<#
.SYNOPSIS
    Detects and removes ghost Twingate network adapters.
.DESCRIPTION
    Lists Twingate network adapters that are no longer present (ghost/phantom devices)
    and offers to remove them. Auto-elevates to admin when removal is needed.
#>

param(
    [string[]]$RemoveInstanceIds
)

# If called with instance IDs, we're in the elevated subprocess — just remove and exit
if ($RemoveInstanceIds) {
    $failed = 0
    foreach ($id in $RemoveInstanceIds) {
        Write-Host "Removing: $id" -ForegroundColor Yellow
        try {
            pnputil /remove-device "$id" | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-Host "  Removed successfully." -ForegroundColor Green
            } else {
                Write-Host "  pnputil returned exit code $LASTEXITCODE." -ForegroundColor Red
                $failed++
            }
        } catch {
            Write-Host "  Failed: $_" -ForegroundColor Red
            $failed++
        }
    }
    Write-Host ""
    if ($failed -gt 0) {
        Write-Host "$failed adapter(s) could not be removed." -ForegroundColor Red
        Read-Host "`nPress Enter to close"
        exit $failed
    }

    Write-Host "All ghost Twingate adapters removed successfully.`n" -ForegroundColor Green

    # Restart Twingate and connect
    Write-Host "Restarting Twingate client..." -ForegroundColor Cyan
    Start-Process "C:\Program Files\Twingate\Twingate.exe"
    Start-Sleep -Seconds 3

    for ($i = 1; $i -le 5; $i++) {
        Write-Host "Connection attempt $i of 5..." -ForegroundColor Cyan
        Start-Process "twingate://connect?network=inlumi.twingate.com"
        Start-Sleep -Seconds 15

        $adapter = Get-PnpDevice -Class Net -ErrorAction SilentlyContinue |
            Where-Object { $_.FriendlyName -like "*Twingate*" -and $_.Status -eq "OK" }
        if ($adapter) {
            Write-Host "`nYour Twingate is fixed!!!`n" -ForegroundColor Green
            Read-Host "Press Enter to close"
            exit 0
        }
    }

    Write-Host "`nCould not verify connection after 5 attempts." -ForegroundColor Red
    Read-Host "`nPress Enter to close"
    exit 1
}

# --- Main flow (no admin required for scanning) ---

# Step 1: Check if Twingate client is installed
Write-Host "`nChecking if Twingate client is installed..." -ForegroundColor Cyan

$twingate = Get-ItemProperty -Path @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
) -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like "*Twingate*" }

if ($twingate) {
    $twingate | ForEach-Object {
        Write-Host "  Name    : $($_.DisplayName)" -ForegroundColor Green
        if ($_.DisplayVersion) {
            Write-Host "  Version : $($_.DisplayVersion)" -ForegroundColor Green
        }
        Write-Host ""
    }
} else {
    Write-Host "  Twingate client is NOT installed.`n" -ForegroundColor Red
}

try {
    Write-Host "Press Space to continue..." -ForegroundColor DarkGray
    do {
        $key = [System.Console]::ReadKey($true)
    } while ($key.Key -ne 'Spacebar')
} catch {
    Read-Host "Press Enter to continue"
}

# Step 2: Scan for ghost adapters
Write-Host "`nScanning for Twingate network adapters..." -ForegroundColor Cyan

# Find all Twingate network adapters
$allAdapters = Get-PnpDevice -Class Net -ErrorAction SilentlyContinue |
    Where-Object { $_.FriendlyName -like "*Twingate*" }

if (-not $allAdapters -or $allAdapters.Count -eq 0) {
    Write-Host "`nNo Twingate network adapters found." -ForegroundColor Yellow
    exit 0
}

# Split into healthy and ghost adapters
$okAdapters    = $allAdapters | Where-Object { $_.Status -eq "OK" }
$ghostAdapters = $allAdapters | Where-Object { $_.Status -ne "OK" }

# Show healthy adapters for informational purposes
if ($okAdapters) {
    Write-Host "`nActive Twingate adapter(s) (OK):" -ForegroundColor Green
    $okAdapters | ForEach-Object {
        Write-Host "  Name       : $($_.FriendlyName)" -ForegroundColor White
        Write-Host "  Status     : $($_.Status)" -ForegroundColor Green
        Write-Host "  InstanceId : $($_.InstanceId)" -ForegroundColor DarkGray
        Write-Host ""
    }
}

if (-not $ghostAdapters -or $ghostAdapters.Count -eq 0) {
    Write-Host "No ghost Twingate network adapters found.`n" -ForegroundColor Green

    # Step 3: Stop the Twingate client and re-scan
    $twingateProc = Get-Process -Name "Twingate" -ErrorAction SilentlyContinue
    if ($twingateProc) {
        Write-Host "Stopping Twingate client..." -ForegroundColor Yellow
        $twingateProc | Stop-Process -Force
        $twingateProc | Wait-Process -ErrorAction SilentlyContinue
        Write-Host "Twingate client stopped.`n" -ForegroundColor Green
    } else {
        Write-Host "Twingate client is not running.`n" -ForegroundColor DarkGray
    }

    Write-Host "Re-scanning for Twingate network adapters..." -ForegroundColor Cyan

    $allAdapters2 = Get-PnpDevice -Class Net -ErrorAction SilentlyContinue |
        Where-Object { $_.FriendlyName -like "*Twingate*" }

    if (-not $allAdapters2 -or $allAdapters2.Count -eq 0) {
        Write-Host "`nNo Twingate network adapters found." -ForegroundColor Yellow
        exit 0
    }

    $okAdapters2    = $allAdapters2 | Where-Object { $_.Status -eq "OK" }
    $ghostAdapters2 = $allAdapters2 | Where-Object { $_.Status -ne "OK" }

    if ($okAdapters2) {
        Write-Host "`nActive Twingate adapter(s) (OK):" -ForegroundColor Green
        $okAdapters2 | ForEach-Object {
            Write-Host "  Name       : $($_.FriendlyName)" -ForegroundColor White
            Write-Host "  Status     : $($_.Status)" -ForegroundColor Green
            Write-Host "  InstanceId : $($_.InstanceId)" -ForegroundColor DarkGray
            Write-Host ""
        }
    }

    if (-not $ghostAdapters2 -or $ghostAdapters2.Count -eq 0) {
        Write-Host "No ghost Twingate network adapters found after stopping the client.`n" -ForegroundColor Green

        # Step 4: Restart Twingate and connect to inlumi.twingate.com
        Write-Host "Restarting Twingate client..." -ForegroundColor Cyan
        Start-Process "C:\Program Files\Twingate\Twingate.exe"
        Start-Sleep -Seconds 3

        for ($i = 1; $i -le 5; $i++) {
            Write-Host "Connection attempt $i of 5..." -ForegroundColor Cyan
            Start-Process "twingate://connect?network=inlumi.twingate.com"
            Start-Sleep -Seconds 15

            $adapter = Get-PnpDevice -Class Net -ErrorAction SilentlyContinue |
                Where-Object { $_.FriendlyName -like "*Twingate*" -and $_.Status -eq "OK" }
            if ($adapter) {
                Write-Host "`nYour Twingate is fixed!!!`n" -ForegroundColor Green
                exit 0
            }
        }

        Write-Host "`nCould not verify connection after 5 attempts." -ForegroundColor Red
        exit 1
    }

    # Ghost adapters found after stopping — continue to removal prompt
    $ghostAdapters = $ghostAdapters2
}

Write-Host "`nFound $($ghostAdapters.Count) ghost Twingate network adapter(s):`n" -ForegroundColor Yellow

$ghostAdapters | ForEach-Object {
    Write-Host "  Name       : $($_.FriendlyName)" -ForegroundColor White
    Write-Host "  Status     : $($_.Status)" -ForegroundColor DarkGray
    Write-Host "  InstanceId : $($_.InstanceId)" -ForegroundColor DarkGray
    Write-Host ""
}

try {
    Write-Host "Press Space to remove ghost adapters..." -ForegroundColor DarkGray
    do {
        $key = [System.Console]::ReadKey($true)
    } while ($key.Key -ne 'Spacebar')
} catch {
    Read-Host "Press Enter to remove ghost adapters"
}

# Build the instance ID list and re-launch elevated
$ids = $ghostAdapters | ForEach-Object { $_.InstanceId }
$quotedIds = ($ids | ForEach-Object { "'$_'" }) -join ','

Write-Host "`nRequesting administrator privileges to remove devices..." -ForegroundColor Cyan

$scriptPath = $MyInvocation.MyCommand.Path
Start-Process powershell -Verb RunAs -ArgumentList @(
    "-ExecutionPolicy", "Bypass",
    "-File", "`"$scriptPath`"",
    "-RemoveInstanceIds", $quotedIds
)
