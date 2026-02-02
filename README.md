# Twingate Ghost Adapter Fix

PowerShell script that detects and removes ghost (phantom) Twingate network adapters on Windows.

Ghost adapters can accumulate after Twingate client updates or reinstalls and may cause network connectivity issues.

## Usage

```powershell
powershell -ExecutionPolicy Bypass -File Remove-TwingateGhostAdapters.ps1
```

Or right-click the script and select **Run with PowerShell**.

## How it works

1. Checks if the Twingate client is installed and shows the version
2. Scans for all Twingate network adapters (no admin required)
3. Shows active adapters and identifies any ghost devices (status not OK)
4. If ghost adapters are found, prompts for confirmation before removal
5. Automatically requests administrator privileges (UAC prompt) only when removal is needed

## Requirements

- Windows 10 / Windows 11 / Windows Server 2016+
- PowerShell 5.1 or later
