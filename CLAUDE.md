# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Automated Twingate VPN client repair toolkit for Windows. All scripts are PowerShell 5.1+ and require administrator privileges. The target Twingate network is `inlumi.twingate.com`. The environment is Intune-managed (MDM).

## Running Scripts

All scripts must be run as administrator with execution policy bypass:

```powershell
powershell -ExecutionPolicy Bypass -File fix_twingate.ps1
```

There is no build step, no test suite, and no linter. Validate syntax with:

```powershell
$tokens = $null; $errors = $null
[System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path 'script.ps1').Path, [ref]$tokens, [ref]$errors)
$errors  # empty = valid
```

## Architecture

### fix_twingate.ps1 — Orchestrator (multi-reboot workflow)

The main script performs an 8-step repair that spans **three reboots**, using scheduled tasks to resume execution across them. It dispatches to different code paths via switch parameters:

| Invocation | Execution path | Steps |
|---|---|---|
| No switches | FIRST RUN | 1-4: Kill Twingate, uninstall, cleanup, reboot |
| `-PostReboot` | AFTER FIRST REBOOT | 5-6: Download & install Twingate, reboot |
| `-PostInstallReboot` | AFTER SECOND REBOOT | 7-8: Intune sync, cleanup, done |

The reboot-resume mechanism works as follows:
- Step 4 registers scheduled task `FixTwingateContinue` (AtLogOn, `-PostReboot`)
- Step 6 registers scheduled task `FixTwingatePostInstall` (AtLogOn, `-PostInstallReboot`)
- Each path unregisters its own scheduled task on entry before proceeding

The blocks are ordered chronologically in the file (Steps 1-4, then 5-6, then 7-8). The main path is guarded by `if (-not $PostReboot -and -not $PostInstallReboot)`, so only one block executes per invocation.

### Standalone cleanup scripts

Three variants exist with overlapping functionality (ghost adapter removal + network profile cleanup):

- **Remove-Twingate-Cleanup.ps1** — Called by `fix_twingate.ps1` in steps 3 and 8. Does NOT self-elevate (expects caller to provide admin context).
- **Remove-TwingateGhostAdapters.ps1** — Standalone version that self-elevates. Deletes ALL `Twingate*` profiles.
- **Remove-TwingateGhosts.ps1** — Standalone version without self-elevation. Only deletes numbered stale profiles (`Twingate \d+`), preserves/renames the active one.

## Key Implementation Details

- Self-elevation pattern: checks `WindowsPrincipal.IsInRole(Administrator)`, re-launches with `-Verb RunAs` if not admin
- Twingate installer is downloaded via `curl.exe` (Windows built-in) from `https://api.twingate.com/download/windows`
- Install flags: `/qn network='inlumi.twingate.com' auto_update=true`
- Intune sync is triggered by restarting the `IntuneManagementExtension` service and running MDM `EnterpriseMgmt` scheduled tasks
- Ghost adapters are detected via `Get-PnpDevice -Class Net` where Status != "OK", removed via `pnputil /remove-device`
- Network profiles live in `HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\NetworkList\Profiles`
