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

Note: when running this from bash/git-bash on Windows, `$` signs are stripped. Write a temporary `.ps1` file and run it with `powershell -NoProfile -ExecutionPolicy Bypass -File validate.ps1` instead.

## Architecture

### fix_twingate.ps1 — Orchestrator (multi-reboot workflow)

The main script performs a 9-step repair that spans **two reboots**, using scheduled tasks to resume execution across them. It dispatches to different code paths via switch parameters:

| Invocation | Execution path | Steps |
|---|---|---|
| No switches | FIRST RUN | 1-4: Kill Twingate, uninstall, cleanup via Remove-TwingateGhosts.ps1, reboot |
| `-PostReboot` | AFTER FIRST REBOOT | 5-7: Install .NET 8 runtime, delete profiles + download & install Twingate, reboot |
| `-PostInstallReboot` | AFTER SECOND REBOOT | 8-9: Verify connection, Intune sync |

The reboot-resume mechanism works as follows:
- Step 4 registers scheduled task `FixTwingateContinue` (AtLogOn, `-PostReboot`)
- Step 7 registers scheduled task `FixTwingatePostInstall` (AtLogOn, `-PostInstallReboot`)
- Each path unregisters its own scheduled task on entry before proceeding

The blocks are ordered chronologically in the file (Steps 1-4, then 5-7, then 8-9). The main path is guarded by `if (-not $PostReboot -and -not $PostInstallReboot)`, so only one block executes per invocation.

### Remove-TwingateGhosts.ps1 — Cleanup script

Called by `fix_twingate.ps1` in step 3, and can also be run standalone. Warns if not admin but does not self-elevate. Uses `Clean-TwingateProfiles` helper function. Exports Twingate profiles to `TwingateProfile.reg` before deletion, then deletes stale `Twingate*` profiles while preserving/renaming the active one.

### Profile cleanup behavior differences

- **fix_twingate.ps1 Step 6**: Exports the active "Twingate" profile to `.reg`, then deletes ALL `Twingate*` profiles (including the active one) before fresh install — ensures clean slate.
- **Remove-TwingateGhosts.ps1**: Exports profiles to `.reg`, preserves the active Twingate profile (renames it to "Twingate" if needed), only deletes stale ones (`Twingate*` where name != "Twingate").

## Error Handling Patterns

Every step that can fail uses one of two patterns:

- **External process**: check exit code, print error, `exit 1`. E.g. `msiexec`, `curl.exe`, `pnputil`, installer.
- **PowerShell cmdlet**: `try { ... -ErrorAction Stop } catch { Write-Host error; exit 1 }`. E.g. `Register-ScheduledTask`, `Restart-Computer`, `Remove-Item`, `Set-ItemProperty`.

Steps that are best-effort by design (Intune sync in Step 8, connectivity verification in Step 9) intentionally use `-ErrorAction SilentlyContinue` and do not exit on failure.

## Key Implementation Details

- Self-elevation pattern: checks `WindowsPrincipal.IsInRole(Administrator)`, re-launches with `-Verb RunAs` if not admin
- Twingate installer (MSI) is downloaded via `curl.exe` (Windows built-in) from `https://api.twingate.com/download/windows?installer=msi` and installed via `msiexec.exe`
- Install flags: `msiexec /i <msi> /q /l*v <log> NETWORK=inlumi.twingate.com auto_update=true no_optional_updates=true`
- MSI uninstall retries up to 3 times on exit code 1618 (installer busy / another MSI operation in progress)
- .NET 8 Desktop Runtime installer: exit code 3010 is treated as success (means reboot needed, which Step 7 handles)
- Intune sync is triggered by restarting the `IntuneManagementExtension` service and running MDM `EnterpriseMgmt` scheduled tasks
- Ghost adapters are detected via `Get-PnpDevice -Class Net` where Status != "OK", removed via `pnputil /remove-device`
- Network profiles live in `HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\NetworkList\Profiles`
- Post-download validation checks both file existence and non-zero size before attempting install
