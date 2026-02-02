<#
.SYNOPSIS
    Creates a simulated Twingate ghost network adapter for testing.
.DESCRIPTION
    Uses the SetupDi API to register a root-enumerated network device named
    "Twingate Virtual Adapter" with no matching driver. The device appears in
    Device Manager and Get-PnpDevice with Status != OK, which is exactly how
    Remove-TwingateGhosts.ps1 detects ghost adapters.
.PARAMETER Count
    Number of ghost adapters to create (default 1).
.NOTES
    Requires administrator privileges. Does not self-elevate.
    Remove with: Remove-TwingateGhosts.ps1 or pnputil /remove-device <InstanceId>
#>

param(
    [int]$Count = 1
)

# Warn if not running as admin
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)
if (-not $isAdmin) {
    Write-Host "`nERROR: This script requires administrator privileges." -ForegroundColor Red
    Write-Host "Registry and device operations will fail without elevation.`n" -ForegroundColor Red
    exit 1
}

# SetupDi P/Invoke definitions
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class SetupApi {
    public const int DICD_GENERATE_ID    = 0x01;
    public const int SPDRP_HARDWAREID    = 0x01;
    public const int SPDRP_FRIENDLYNAME  = 0x0C;
    public const int DIF_REGISTERDEVICE  = 0x19;

    [StructLayout(LayoutKind.Sequential)]
    public struct SP_DEVINFO_DATA {
        public int    cbSize;
        public Guid   ClassGuid;
        public int    DevInst;
        public IntPtr Reserved;
    }

    [DllImport("setupapi.dll", SetLastError = true)]
    public static extern IntPtr SetupDiCreateDeviceInfoList(
        ref Guid ClassGuid, IntPtr hwndParent);

    [DllImport("setupapi.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool SetupDiCreateDeviceInfo(
        IntPtr DeviceInfoSet, string DeviceName, ref Guid ClassGuid,
        string DeviceDescription, IntPtr hwndParent, int CreationFlags,
        ref SP_DEVINFO_DATA DeviceInfoData);

    [DllImport("setupapi.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool SetupDiSetDeviceRegistryProperty(
        IntPtr DeviceInfoSet, ref SP_DEVINFO_DATA DeviceInfoData,
        int Property, byte[] PropertyBuffer, int PropertyBufferSize);

    [DllImport("setupapi.dll", SetLastError = true)]
    public static extern bool SetupDiCallClassInstaller(
        int InstallFunction, IntPtr DeviceInfoSet,
        ref SP_DEVINFO_DATA DeviceInfoData);

    [DllImport("setupapi.dll", SetLastError = true)]
    public static extern bool SetupDiDestroyDeviceInfoList(IntPtr DeviceInfoSet);
}
"@ -ErrorAction Stop

# Network adapter class GUID: {4d36e972-e325-11ce-bfc1-08002be10318}
$netClassGuid = [Guid]::new("4d36e972-e325-11ce-bfc1-08002be10318")

$created = 0
for ($i = 1; $i -le $Count; $i++) {

    $deviceInfoSet = [SetupApi]::SetupDiCreateDeviceInfoList([ref]$netClassGuid, [IntPtr]::Zero)
    if ($deviceInfoSet -eq [IntPtr]::new(-1)) {
        $err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        Write-Host "Failed to create device info list. Win32 error $err" -ForegroundColor Red
        continue
    }

    try {
        $devInfo        = New-Object SetupApi+SP_DEVINFO_DATA
        $devInfo.cbSize = [Runtime.InteropServices.Marshal]::SizeOf($devInfo)

        # Create a root-enumerated device entry in the Net class
        $ok = [SetupApi]::SetupDiCreateDeviceInfo(
            $deviceInfoSet,
            "Net",
            [ref]$netClassGuid,
            "Twingate Virtual Adapter",
            [IntPtr]::Zero,
            [SetupApi]::DICD_GENERATE_ID,
            [ref]$devInfo
        )
        if (-not $ok) {
            $err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
            Write-Host "[$i/$Count] SetupDiCreateDeviceInfo failed. Win32 error $err" -ForegroundColor Red
            continue
        }

        # Hardware ID (REG_MULTI_SZ: value + double null terminator)
        $hwId      = "ROOT\TWINGATE_GHOST_TEST`0`0"
        $hwIdBytes = [Text.Encoding]::Unicode.GetBytes($hwId)
        $ok = [SetupApi]::SetupDiSetDeviceRegistryProperty(
            $deviceInfoSet, [ref]$devInfo,
            [SetupApi]::SPDRP_HARDWAREID,
            $hwIdBytes, $hwIdBytes.Length
        )
        if (-not $ok) {
            $err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
            Write-Host "[$i/$Count] Failed to set hardware ID. Win32 error $err" -ForegroundColor Red
            continue
        }

        # Friendly name (what Get-PnpDevice.FriendlyName returns)
        $friendlyName  = "Twingate Virtual Adapter`0"
        $fnBytes       = [Text.Encoding]::Unicode.GetBytes($friendlyName)
        [SetupApi]::SetupDiSetDeviceRegistryProperty(
            $deviceInfoSet, [ref]$devInfo,
            [SetupApi]::SPDRP_FRIENDLYNAME,
            $fnBytes, $fnBytes.Length
        ) | Out-Null

        # Register the device in the PnP manager
        $ok = [SetupApi]::SetupDiCallClassInstaller(
            [SetupApi]::DIF_REGISTERDEVICE,
            $deviceInfoSet,
            [ref]$devInfo
        )
        if (-not $ok) {
            $err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
            Write-Host "[$i/$Count] DIF_REGISTERDEVICE failed. Win32 error $err" -ForegroundColor Red
            continue
        }

        Write-Host "[$i/$Count] Device registered." -ForegroundColor Green
        $created++

    } finally {
        [SetupApi]::SetupDiDestroyDeviceInfoList($deviceInfoSet) | Out-Null
    }
}

# Disable each newly created ghost adapter so its Status becomes != OK
if ($created -gt 0) {
    Write-Host "Disabling ghost adapter(s) to simulate ghost status..." -ForegroundColor Yellow
    $testDevices = @(Get-PnpDevice -Class Net -ErrorAction SilentlyContinue |
        Where-Object { $_.FriendlyName -eq 'Twingate Virtual Adapter' -and $_.Status -eq 'OK' })
    foreach ($dev in $testDevices) {
        & pnputil /disable-device "$($dev.InstanceId)" 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  Disabled $($dev.InstanceId)" -ForegroundColor DarkGray
        } else {
            Disable-PnpDevice -InstanceId $dev.InstanceId -Confirm:$false -ErrorAction SilentlyContinue
        }
    }
}

Write-Host "`nCreated $created ghost adapter(s).`n" -ForegroundColor Cyan

# Verify — show all Twingate ghost adapters now present
$ghosts = @(Get-PnpDevice -Class Net -ErrorAction SilentlyContinue |
    Where-Object { $_.FriendlyName -like "*Twingate*" -and $_.Status -ne "OK" })

if ($ghosts.Count -gt 0) {
    Write-Host "Current Twingate ghost adapters:" -ForegroundColor Cyan
    $ghosts | ForEach-Object {
        Write-Host "  $($_.FriendlyName) [$($_.Status)] - $($_.InstanceId)" -ForegroundColor DarkGray
    }
} else {
    Write-Host "WARNING: No ghost adapters detected by Get-PnpDevice. The device may need a moment to register." -ForegroundColor Yellow
}

Write-Host ""
