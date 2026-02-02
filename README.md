# Twingate Client Repair Toolkit

PowerShell scripts for automated Twingate VPN client repair on Windows. Handles ghost adapter removal, stale network profile cleanup, and full uninstall/reinstall with Intune sync.

Ghost adapters and numbered network profiles (e.g. "Twingate 4") can accumulate after Twingate client updates or reinstalls and may cause network connectivity issues.

## Scripts

### fix_twingate.ps1 — Full automated repair

Performs a complete uninstall/reinstall cycle across three reboots, resuming automatically via scheduled tasks. Self-elevates to admin.

```powershell
powershell -ExecutionPolicy Bypass -File fix_twingate.ps1
```

### Remove-TwingateGhosts.ps1 — Standalone cleanup

Removes ghost adapters and stale network profiles without reinstalling. Requires admin (warns if not elevated).

```powershell
powershell -ExecutionPolicy Bypass -File Remove-TwingateGhosts.ps1
```

## Requirements

- Windows 10 / Windows 11 / Windows Server 2016+
- PowerShell 5.1 or later
- Administrator privileges
