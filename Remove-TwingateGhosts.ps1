<#
.SYNOPSIS
    Detects and removes ghost Twingate network adapters.
#>

# Scan for ghost Twingate adapters
Write-Host "`nScanning for ghost Twingate network adapters..." -ForegroundColor Cyan

$ghostAdapters = Get-PnpDevice -Class Net -ErrorAction SilentlyContinue |
    Where-Object { $_.FriendlyName -like "*Twingate*" -and $_.Status -ne "OK" }

if (-not $ghostAdapters) {
    Write-Host "No ghost Twingate adapters found.`n" -ForegroundColor Green
    Write-Host "Press space to exit..." -ForegroundColor DarkGray
    while ($host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown").Character -ne ' ') {}
    exit 0
}

Write-Host "Found $($ghostAdapters.Count) ghost adapter(s):`n" -ForegroundColor Yellow
$ghostAdapters | ForEach-Object {
    Write-Host "  $($_.FriendlyName) [$($_.Status)] - $($_.InstanceId)" -ForegroundColor DarkGray
}

# Remove each ghost adapter (requires admin)
Write-Host ""
$failed = 0
foreach ($adapter in $ghostAdapters) {
    Write-Host "Removing $($adapter.InstanceId)..." -ForegroundColor Yellow -NoNewline
    try {
        pnputil /remove-device "$($adapter.InstanceId)" 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Host " done." -ForegroundColor Green
        } else {
            Write-Host " failed (exit code $LASTEXITCODE)." -ForegroundColor Red
            $failed++
        }
    } catch {
        Write-Host " failed: $_" -ForegroundColor Red
        $failed++
    }
}

Write-Host ""
if ($failed -gt 0) {
    Write-Host "$failed adapter(s) could not be removed. Run as administrator." -ForegroundColor Red
    Write-Host "Press space to exit..." -ForegroundColor DarkGray
    while ($host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown").Character -ne ' ') {}
    exit 1
}
Write-Host "All ghost Twingate adapters removed.`n" -ForegroundColor Green
Write-Host "Press space to exit..." -ForegroundColor DarkGray
while ($host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown").Character -ne ' ') {}
