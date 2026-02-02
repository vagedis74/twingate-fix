# Twingate Ghost Adapter Fix

PowerShell script that removes ghost (phantom) Twingate network adapters and deletes all Twingate network profiles on Windows.

Ghost adapters and numbered network profiles (e.g. "Twingate 4") can accumulate after Twingate client updates or reinstalls and may cause network connectivity issues.

## Usage

```powershell
powershell -ExecutionPolicy Bypass -File Remove-TwingateGhostAdapters.ps1
```

Or right-click the script and select **Run with PowerShell**.

## How it works

1. Auto-elevates to admin via UAC (required for device removal and registry access)
2. Scans for ghost Twingate network adapters (status not OK) and removes them via `pnputil`
3. Deletes all Twingate network profiles from the registry (`HKLM:\...\NetworkList\Profiles`)

## Requirements

- Windows 10 / Windows 11 / Windows Server 2016+
- PowerShell 5.1 or later
