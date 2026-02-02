# Twingate Client Repair Toolkit

PowerShell scripts for automated Twingate VPN client repair on Windows. Handles ghost adapter removal, stale network profile cleanup, and full uninstall/reinstall with Intune sync.

Ghost adapters and numbered network profiles (e.g. "Twingate 4") can accumulate after Twingate client updates or reinstalls and may cause network connectivity issues.

## Scripts

### fix_twingate.ps1 — Full automated repair

Performs a complete uninstall/reinstall cycle across two reboots, resuming automatically via scheduled tasks. Self-elevates to admin.

| Step | Action |
|------|--------|
| 1 | Quit the Twingate client |
| 2 | Uninstall Twingate |
| 3 | Remove ghost adapters and stale network profiles |
| 4 | Reboot (resumes automatically) |
| 5 | Install .NET 8 Desktop Runtime (prerequisite for Twingate MSI) |
| 6 | Download and install Twingate MSI (`inlumi.twingate.com`) |
| 7 | Reboot (resumes automatically) |
| 8 | Verify Twingate connection |
| 9 | Trigger Intune sync |

```powershell
powershell -ExecutionPolicy Bypass -File fix_twingate.ps1
```

### Reinstall-Twingate.ps1 — Quick reinstall

Single-run reinstall using a local `TwingateWindowsInstaller.exe` bundled in the repo. Self-elevates to admin.

| Step | Action |
|------|--------|
| 1 | Stop Twingate service and processes |
| 2 | Uninstall Twingate (`REMOVE=ALL`) |
| 3 | Remove ghost network adapters |
| 4 | Delete all Twingate network profiles |
| 5 | Install Twingate from local installer (`inlumi.twingate.com`) |
| 6 | Reboot |

```powershell
powershell -ExecutionPolicy Bypass -File Reinstall-Twingate.ps1
```

### Remove-TwingateGhosts.ps1 — Standalone cleanup

Removes ghost adapters and stale network profiles without reinstalling. Requires admin (warns if not elevated).

```powershell
powershell -ExecutionPolicy Bypass -File Remove-TwingateGhosts.ps1
```

### New-TwingateGhostAdapter.ps1 — Test utility

Creates simulated ghost Twingate network adapters for testing the removal scripts. Uses the Windows SetupDi API to register a fake adapter that appears with `Status=Error` in Device Manager.

```powershell
# Create one ghost adapter
powershell -ExecutionPolicy Bypass -File New-TwingateGhostAdapter.ps1

# Create multiple ghost adapters
powershell -ExecutionPolicy Bypass -File New-TwingateGhostAdapter.ps1 -Count 3
```

## Requirements

- Windows 10 / Windows 11 / Windows Server 2016+
- PowerShell 5.1 or later
- Administrator privileges
