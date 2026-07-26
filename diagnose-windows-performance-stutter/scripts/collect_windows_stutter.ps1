#requires -Version 5.1
<#
.SYNOPSIS
  Read-only Windows stutter baseline collector (process family + system counters).

.DESCRIPTION
  Collects timed samples for a target process tree and system contention signals.
  Prefer low-overhead Win32/PDH English counters. Never mutates the target,
  competing processes, or system configuration; never stops processes; and never
  captures command lines, environment variables, or window titles.

  The collector temporarily lowers only its own PowerShell host to BelowNormal
  and restores the original class in finally. Target and competing processes are
  never changed.

  Output is triage evidence only. Summary statistics are descriptive and do not
  encode diagnosis thresholds or conclusions.


.PARAMETER ProcessId
  Preferred parameter for the root process ID to lock (alias of TargetPid).
  Descendants are aggregated as the process family. Use -ProcessId in automation.

.PARAMETER TargetPid
  Compatibility name for ProcessId. Same value; -ProcessId is preferred.

.PARAMETER ProcessName
  Optional exact ProcessName match for the root (without .exe). Rejects mismatch.

.PARAMETER DurationSeconds
  Collection duration in seconds. Default 30. Minimum 5 (needs multi-sample deltas). Hard upper bound 300.

.PARAMETER IntervalSeconds
  Sample interval in seconds. Default 1. Hard upper bound 10.

.PARAMETER SystemCounterIntervalSeconds
  PDH system-counter interval. Default 10 seconds to limit observer overhead.

.PARAMETER TopProcessIntervalSeconds
  System-wide process scan interval. Default 10 seconds to limit observer overhead.
  The first scan primes cumulative CPU values; ranked rows begin with the second scan.

.PARAMETER OutputDirectory
  Destination directory. Must not exist, or must be empty. Auto-created if omitted.

.PARAMETER TopProcessCount
  Number of system-wide CPU hot processes recorded each sample. Default 12. Max 30.

.PARAMETER SkipTopProcesses
  Diagnostic/low-overhead mode. Skip the system-wide per-process scan; target-family
  and PDH system counters are still collected and top-processes.csv remains present.

.PARAMETER SkipSystemCounters
  Diagnostic mode. Skip PDH system counters while retaining target-family sampling.
  system.csv remains present with empty counter fields.

.PARAMETER FamilyRefreshSeconds
  How often to rediscover descendants. Default 5. Min 1, Max 60.


.EXAMPLE
  .\collect_windows_stutter.ps1 -ProcessId 1234

.EXAMPLE
  .\collect_windows_stutter.ps1 -ProcessId 1234 -ProcessName sample-app -DurationSeconds 60 -IntervalSeconds 1

.EXAMPLE
  .\collect_windows_stutter.ps1 -TargetPid 1234
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [Alias('ProcessId')]
    [ValidateRange(1, 2147483647)]
    [int]$TargetPid,

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$ProcessName,

    [Parameter(Mandatory = $false)]
    [ValidateRange(5, 300)]
    [int]$DurationSeconds = 30,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 10)]
    [double]$IntervalSeconds = 1,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 60)]
    [double]$SystemCounterIntervalSeconds = 10,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 60)]
    [double]$TopProcessIntervalSeconds = 10,

    [Parameter(Mandatory = $false)]
    [string]$OutputDirectory,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 30)]
    [int]$TopProcessCount = 12,

    [Parameter(Mandatory = $false)]
    [switch]$SkipTopProcesses,

    [Parameter(Mandatory = $false)]
    [switch]$SkipSystemCounters,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 60)]
    [int]$FamilyRefreshSeconds = 5
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Native interop (read-only)
# ---------------------------------------------------------------------------

function Ensure-NativeTypes {
    if ($script:NativeTypesReady) {
        return
    }

    $typeDef = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class WindowsStutterCollectorNative {
    public const uint PDH_FMT_DOUBLE = 0x00000200;
    public const uint PDH_CSTATUS_VALID_DATA = 0x00000000;
    public const uint PDH_CSTATUS_NEW_DATA = 0x00000001;
    public const int ProcessBasicInformation = 0;
    public const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
    public const uint PROCESS_QUERY_INFORMATION = 0x0400;
    public const uint TH32CS_SNAPPROCESS = 0x00000002;
    public const int ERROR_ACCESS_DENIED = 5;
    public const int ERROR_INVALID_HANDLE = 6;
    public const int ERROR_SUCCESS = 0;
    public const int ERROR_INSUFFICIENT_BUFFER = 122;
    public static readonly IntPtr INVALID_HANDLE_VALUE = new IntPtr(-1);

    [StructLayout(LayoutKind.Sequential)]
    public struct PDH_FMT_COUNTERVALUE {
        public uint CStatus;
        public double doubleValue;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct IO_COUNTERS {
        public ulong ReadOperationCount;
        public ulong WriteOperationCount;
        public ulong OtherOperationCount;
        public ulong ReadTransferCount;
        public ulong WriteTransferCount;
        public ulong OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct PROCESS_BASIC_INFORMATION {
        public IntPtr Reserved1;
        public IntPtr PebBaseAddress;
        public IntPtr Reserved2_0;
        public IntPtr Reserved2_1;
        public IntPtr UniqueProcessId;
        public IntPtr InheritedFromUniqueProcessId;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct FILETIME {
        public uint dwLowDateTime;
        public uint dwHighDateTime;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct PROCESSENTRY32W {
        public uint dwSize;
        public uint cntUsage;
        public uint th32ProcessID;
        public IntPtr th32DefaultHeapID;
        public uint th32ModuleID;
        public uint cntThreads;
        public uint th32ParentProcessID;
        public int pcPriClassBase;
        public uint dwFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)]
        public string szExeFile;
    }

    [DllImport("pdh.dll", CharSet = CharSet.Unicode)]
    // Use IntPtr for szDataSource so live queries can pass NULL reliably from PowerShell.
    public static extern uint PdhOpenQueryW(IntPtr szDataSource, IntPtr dwUserData, out IntPtr phQuery);

    [DllImport("pdh.dll", CharSet = CharSet.Unicode)]
    public static extern uint PdhAddEnglishCounterW(IntPtr hQuery, string szFullCounterPath, IntPtr dwUserData, out IntPtr phCounter);

    [DllImport("pdh.dll")]
    public static extern uint PdhCollectQueryData(IntPtr hQuery);

    [DllImport("pdh.dll", CharSet = CharSet.Unicode)]
    public static extern uint PdhGetFormattedCounterValue(IntPtr hCounter, uint dwFormat, out uint lpdwType, out PDH_FMT_COUNTERVALUE pValue);

    [DllImport("pdh.dll")]
    public static extern uint PdhCloseQuery(IntPtr hQuery);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr OpenProcess(uint dwDesiredAccess, bool bInheritHandle, int dwProcessId);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CloseHandle(IntPtr hObject);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GetProcessIoCounters(IntPtr hProcess, out IO_COUNTERS lpIoCounters);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GetProcessTimes(
        IntPtr hProcess,
        out FILETIME creationTime,
        out FILETIME exitTime,
        out FILETIME kernelTime,
        out FILETIME userTime);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GetProcessHandleCount(IntPtr hProcess, out uint pdwHandleCount);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GetProcessAffinityMask(IntPtr hProcess, out UIntPtr lpProcessAffinityMask, out UIntPtr lpSystemAffinityMask);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GetProcessDefaultCpuSets(
        IntPtr Process,
        [Out] uint[] CpuSetIds,
        uint CpuSetIdCount,
        out uint RequiredIdCount);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr CreateToolhelp32Snapshot(uint dwFlags, uint th32ProcessID);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool Process32FirstW(IntPtr hSnapshot, ref PROCESSENTRY32W lppe);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool Process32NextW(IntPtr hSnapshot, ref PROCESSENTRY32W lppe);

    [DllImport("kernel32.dll")]
    public static extern void SetLastError(uint dwErrCode);

    [DllImport("ntdll.dll")]
    public static extern int NtQueryInformationProcess(
        IntPtr processHandle,
        int processInformationClass,
        ref PROCESS_BASIC_INFORMATION processInformation,
        int processInformationLength,
        out int returnLength);

    public static ulong FileTimeToUInt64(FILETIME ft) {
        return ((ulong)ft.dwHighDateTime << 32) | ft.dwLowDateTime;
    }

    public static double FileTimeToSeconds(FILETIME ft) {
        return FileTimeToUInt64(ft) / 10000000.0;
    }

    public static Dictionary<string, double> CollectPdhValues(
        IntPtr query,
        string[] names,
        IntPtr[] counters,
        out uint collectStatus) {
        collectStatus = PdhCollectQueryData(query);
        var values = new Dictionary<string, double>(StringComparer.OrdinalIgnoreCase);
        if (collectStatus != 0 || names == null || counters == null) {
            return values;
        }
        int count = Math.Min(names.Length, counters.Length);
        for (int i = 0; i < count; i++) {
            if (counters[i] == IntPtr.Zero) {
                continue;
            }
            uint type;
            PDH_FMT_COUNTERVALUE formatted;
            uint status = PdhGetFormattedCounterValue(counters[i], PDH_FMT_DOUBLE, out type, out formatted);
            if (status == 0 &&
                (formatted.CStatus == PDH_CSTATUS_VALID_DATA || formatted.CStatus == PDH_CSTATUS_NEW_DATA)) {
                values[names[i]] = formatted.doubleValue;
            }
        }
        return values;
    }
}
'@

    try {
        Add-Type -TypeDefinition $typeDef -Language CSharp -ErrorAction Stop | Out-Null
    } catch {
        if (-not ($_.Exception.Message -match 'already exists|already been defined|redefinition')) {
            throw
        }
    }

    $script:NativeTypesReady = $true
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Write-CollectorWarning {
    param([string]$Message)
    [void]$script:Warnings.Add($Message)
    Write-Warning $Message
}

function New-IsoTimestamp {
    param([datetime]$Value = (Get-Date))
    return $Value.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
}

function ConvertTo-JsonCompat {
    param(
        [Parameter(Mandatory = $true)]$InputObject,
        [int]$Depth = 8
    )
    try {
        return ($InputObject | ConvertTo-Json -Depth $Depth -Compress:$false)
    } catch {
        throw ("ConvertTo-Json failed: {0}" -f $_.Exception.Message)
    }
}

function ConvertTo-JsonSafeValue {
    param($Value)

    if ($null -eq $Value) {
        return $null
    }
    if ($Value -is [string]) {
        return $Value
    }
    if ($Value -is [bool]) {
        return [bool]$Value
    }
    if ($Value -is [Enum]) {
        return $Value.ToString()
    }
    if ($Value -is [byte] -or $Value -is [int16] -or $Value -is [uint16] -or $Value -is [int] -or $Value -is [uint32] -or $Value -is [int64] -or $Value -is [uint64] -or $Value -is [double] -or $Value -is [decimal] -or $Value -is [single] -or $Value -is [long]) {
        # Normalize numerics to JSON-friendly CLR types for PS 5.1 ConvertTo-Json.
        if ($Value -is [double] -or $Value -is [single] -or $Value -is [decimal]) {
            return [double]$Value
        }
        return [int64]$Value
    }
    if ($Value -is [System.Collections.IDictionary]) {
        $map = @{}
        foreach ($key in @($Value.Keys)) {
            $map[[string]$key] = ConvertTo-JsonSafeValue -Value ($Value[$key])
        }
        return $map
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $list = @()
        foreach ($item in $Value) {
            $list += , (ConvertTo-JsonSafeValue -Value $item)
        }
        return $list
    }
    try {
        return [string]$Value
    } catch {
        return $null
    }
}

function Test-DirectoryIsEmpty {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        return $true
    }
    $item = Get-Item -LiteralPath $Path -Force
    if (-not $item.PSIsContainer) {
        throw "Output path exists and is not a directory: $Path"
    }
    $children = @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop)
    return ($children.Count -eq 0)
}

function Resolve-OutputDirectory {
    param([string]$Requested)

    if ([string]::IsNullOrWhiteSpace($Requested)) {
        $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
        $leaf = "windows-stutter_{0}_pid{1}_{2}" -f $stamp, $TargetPid, $PID
        $base = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath 'windows-stutter-collector'
        if (-not (Test-Path -LiteralPath $base)) {
            New-Item -ItemType Directory -Path $base -Force | Out-Null
        }
        $path = Join-Path -Path $base -ChildPath $leaf
        New-Item -ItemType Directory -Path $path -Force | Out-Null
        return (Resolve-Path -LiteralPath $path).Path
    }

    $full = [System.IO.Path]::GetFullPath($Requested)
    if (Test-Path -LiteralPath $full) {
        if (-not (Test-DirectoryIsEmpty -Path $full)) {
            throw "Refusing to write into non-empty output directory: $full"
        }
    } else {
        New-Item -ItemType Directory -Path $full -Force | Out-Null
    }
    return (Resolve-Path -LiteralPath $full).Path
}

function Open-ProcessQueryHandle {
    param([int]$ProcessId)

    $accessLimited = [WindowsStutterCollectorNative]::PROCESS_QUERY_LIMITED_INFORMATION
    $handle = [WindowsStutterCollectorNative]::OpenProcess($accessLimited, $false, $ProcessId)
    if ($handle -ne [IntPtr]::Zero) {
        return $handle
    }

    $accessClassic = [WindowsStutterCollectorNative]::PROCESS_QUERY_INFORMATION
    $handle = [WindowsStutterCollectorNative]::OpenProcess($accessClassic, $false, $ProcessId)
    if ($handle -eq [IntPtr]::Zero) {
        return [IntPtr]::Zero
    }
    return $handle
}

function Get-ParentProcessId {
    param([int]$ProcessId)

    $handle = Open-ProcessQueryHandle -ProcessId $ProcessId
    if ($handle -eq [IntPtr]::Zero) {
        return $null
    }

    try {
        $info = New-Object WindowsStutterCollectorNative+PROCESS_BASIC_INFORMATION
        $retLen = 0
        $status = [WindowsStutterCollectorNative]::NtQueryInformationProcess(
            $handle,
            [WindowsStutterCollectorNative]::ProcessBasicInformation,
            [ref]$info,
            [System.Runtime.InteropServices.Marshal]::SizeOf($info),
            [ref]$retLen
        )
        if ($status -ne 0) {
            return $null
        }
        try {
            return [int]$info.InheritedFromUniqueProcessId.ToInt64()
        } catch {
            return [int]$info.InheritedFromUniqueProcessId.ToInt32()
        }
    } finally {
        [void][WindowsStutterCollectorNative]::CloseHandle($handle)
    }
}

function Get-ProcessSnapshotMap {
    # Occasional parent-link snapshot only (FamilyRefreshSeconds). Not per-second.
    # Prefer Toolhelp32 batch snapshot; CIM is fallback only.
    $map = @{}
    $source = 'none'

    $snap = [WindowsStutterCollectorNative]::CreateToolhelp32Snapshot(
        [WindowsStutterCollectorNative]::TH32CS_SNAPPROCESS,
        0
    )
    if ($snap -ne [WindowsStutterCollectorNative]::INVALID_HANDLE_VALUE -and $snap -ne [IntPtr]::Zero) {
        try {
            $entry = New-Object WindowsStutterCollectorNative+PROCESSENTRY32W
            $entry.dwSize = [uint32][System.Runtime.InteropServices.Marshal]::SizeOf($entry)
            $ok = [WindowsStutterCollectorNative]::Process32FirstW($snap, [ref]$entry)
            if ($ok) {
                $source = 'toolhelp32'
                do {
                    try {
                        $pidValue = [int]$entry.th32ProcessID
                        $parent = [int]$entry.th32ParentProcessID
                        $name = $null
                        if (-not [string]::IsNullOrWhiteSpace($entry.szExeFile)) {
                            $name = [System.IO.Path]::GetFileNameWithoutExtension($entry.szExeFile)
                        }
                        $map[$pidValue] = [pscustomobject]@{
                            ProcessId       = $pidValue
                            ParentProcessId = $parent
                            ProcessName     = $name
                        }
                    } catch {
                    }
                    $entry.dwSize = [uint32][System.Runtime.InteropServices.Marshal]::SizeOf($entry)
                    $ok = [WindowsStutterCollectorNative]::Process32NextW($snap, [ref]$entry)
                } while ($ok)
            } else {
                $err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
                Write-CollectorWarning ("Toolhelp Process32FirstW failed win32=$err; will try CIM fallback.")
            }
        } finally {
            [void][WindowsStutterCollectorNative]::CloseHandle($snap)
        }
    } else {
        $err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        Write-CollectorWarning ("CreateToolhelp32Snapshot failed win32=$err; will try CIM fallback.")
    }

    if ($map.Count -gt 0) {
        $script:LastFamilySnapshotSource = $source
        return $map
    }

    try {
        Write-CollectorWarning 'Family snapshot falling back to Get-CimInstance Win32_Process (Toolhelp unavailable or empty).'
        $rows = Get-CimInstance -ClassName Win32_Process -Property ProcessId, ParentProcessId, Name -ErrorAction Stop
        foreach ($row in $rows) {
            try {
                $pidValue = [int]$row.ProcessId
                $parent = $null
                if ($null -ne $row.ParentProcessId) {
                    $parent = [int]$row.ParentProcessId
                }
                $name = $null
                if ($null -ne $row.Name) {
                    $name = [System.IO.Path]::GetFileNameWithoutExtension([string]$row.Name)
                }
                $map[$pidValue] = [pscustomobject]@{
                    ProcessId       = $pidValue
                    ParentProcessId = $parent
                    ProcessName     = $name
                }
            } catch {
            }
        }
        if ($map.Count -gt 0) {
            $script:LastFamilySnapshotSource = 'cim_fallback'
            return $map
        }
    } catch {
        Write-CollectorWarning ("CIM family snapshot fallback failed: {0}. Last resort NtQuery parent walk." -f $_.Exception.Message)
    }

    foreach ($p in [System.Diagnostics.Process]::GetProcesses()) {
        try {
            $pidValue = $p.Id
            $name = $null
            try { $name = $p.ProcessName } catch { $name = $null }
            $parent = Get-ParentProcessId -ProcessId $pidValue
            $map[$pidValue] = [pscustomobject]@{
                ProcessId       = $pidValue
                ParentProcessId = $parent
                ProcessName     = $name
            }
        } catch {
        } finally {
            try { $p.Dispose() } catch { }
        }
    }
    $script:LastFamilySnapshotSource = 'ntquery_last_resort'
    return $map
}

function Get-ProcessFamilyIds {
    param(
        [int]$RootPid,
        [hashtable]$SnapshotMap
    )

    $family = New-Object 'System.Collections.Generic.HashSet[int]'
    [void]$family.Add($RootPid)

    $changed = $true
    while ($changed) {
        $changed = $false
        foreach ($key in @($SnapshotMap.Keys)) {
            $row = $SnapshotMap[$key]
            if ($null -eq $row.ParentProcessId) {
                continue
            }
            if ($family.Contains([int]$row.ParentProcessId) -and -not $family.Contains([int]$row.ProcessId)) {
                [void]$family.Add([int]$row.ProcessId)
                $changed = $true
            }
        }
    }

    return @($family | Sort-Object)
}

function Get-ProcessCpuSeconds {
    param([int]$ProcessId)

    $handle = Open-ProcessQueryHandle -ProcessId $ProcessId
    if ($handle -eq [IntPtr]::Zero) {
        return $null
    }

    try {
        $creation = New-Object WindowsStutterCollectorNative+FILETIME
        $exit = New-Object WindowsStutterCollectorNative+FILETIME
        $kernel = New-Object WindowsStutterCollectorNative+FILETIME
        $user = New-Object WindowsStutterCollectorNative+FILETIME
        $ok = [WindowsStutterCollectorNative]::GetProcessTimes($handle, [ref]$creation, [ref]$exit, [ref]$kernel, [ref]$user)
        if (-not $ok) {
            return $null
        }
        return ([WindowsStutterCollectorNative]::FileTimeToSeconds($kernel) + [WindowsStutterCollectorNative]::FileTimeToSeconds($user))
    } finally {
        [void][WindowsStutterCollectorNative]::CloseHandle($handle)
    }
}

function Get-ProcessIoSnapshot {
    param([int]$ProcessId)

    $handle = Open-ProcessQueryHandle -ProcessId $ProcessId
    if ($handle -eq [IntPtr]::Zero) {
        return $null
    }

    try {
        $io = New-Object WindowsStutterCollectorNative+IO_COUNTERS
        $ok = [WindowsStutterCollectorNative]::GetProcessIoCounters($handle, [ref]$io)
        if (-not $ok) {
            return $null
        }
        return [pscustomobject]@{
            ReadOperationCount  = [uint64]$io.ReadOperationCount
            WriteOperationCount = [uint64]$io.WriteOperationCount
            OtherOperationCount = [uint64]$io.OtherOperationCount
            ReadTransferCount   = [uint64]$io.ReadTransferCount
            WriteTransferCount  = [uint64]$io.WriteTransferCount
            OtherTransferCount  = [uint64]$io.OtherTransferCount
        }
    } finally {
        [void][WindowsStutterCollectorNative]::CloseHandle($handle)
    }
}

function Get-ProcessHandleCountSafe {
    param([int]$ProcessId)

    $handle = Open-ProcessQueryHandle -ProcessId $ProcessId
    if ($handle -eq [IntPtr]::Zero) {
        return $null
    }
    try {
        $count = [uint32]0
        $ok = [WindowsStutterCollectorNative]::GetProcessHandleCount($handle, [ref]$count)
        if (-not $ok) {
            return $null
        }
        return [int]$count
    } finally {
        [void][WindowsStutterCollectorNative]::CloseHandle($handle)
    }
}

function Get-RootProcessReadonlyState {
    param([int]$ProcessId)

    $state = [ordered]@{
        pid                     = $ProcessId
        process_name            = $null
        priority_class          = $null
        base_priority           = $null
        processor_affinity      = $null
        system_affinity         = $null
        default_cpu_sets        = $null
        default_cpu_sets_status = 'not_queried'
        query_errors            = @()
    }
    $queryErrors = New-Object System.Collections.ArrayList

    try {
        $proc = [System.Diagnostics.Process]::GetProcessById($ProcessId)
        try {
            $state.process_name = $proc.ProcessName
            try { $state.priority_class = [string]$proc.PriorityClass } catch {
                [void]$queryErrors.Add("priority_class: $($_.Exception.Message)")
            }
            try { $state.base_priority = [int]$proc.BasePriority } catch {
                [void]$queryErrors.Add("base_priority: $($_.Exception.Message)")
            }
        } finally {
            $proc.Dispose()
        }
    } catch {
        [void]$queryErrors.Add("process_lookup: $($_.Exception.Message)")
    }

    $handle = Open-ProcessQueryHandle -ProcessId $ProcessId
    if ($handle -eq [IntPtr]::Zero) {
        [void]$queryErrors.Add('OpenProcess(QUERY_LIMITED/QUERY) failed; affinity and CPU Sets unavailable')
        $state.query_errors = @($queryErrors)
        $state.default_cpu_sets_status = 'permission_or_access_failed'
        return $state
    }

    try {
        $procMask = [UIntPtr]::Zero
        $sysMask = [UIntPtr]::Zero
        $affOk = [WindowsStutterCollectorNative]::GetProcessAffinityMask($handle, [ref]$procMask, [ref]$sysMask)
        if ($affOk) {
            $state.processor_affinity = ('0x{0:X}' -f $procMask.ToUInt64())
            $state.system_affinity = ('0x{0:X}' -f $sysMask.ToUInt64())
        } else {
            $err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
            [void]$queryErrors.Add("GetProcessAffinityMask failed win32=$err")
        }

        try {
            $required = [uint32]0
            # Clear sticky last-error so RequiredIdCount=0 empty sets are not misread as failures.
            [WindowsStutterCollectorNative]::SetLastError(0)
            $probe = [WindowsStutterCollectorNative]::GetProcessDefaultCpuSets($handle, $null, 0, [ref]$required)
            $last = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
            if ($required -gt 0) {
                $ids = New-Object 'System.UInt32[]' ($required)
                [WindowsStutterCollectorNative]::SetLastError(0)
                $ok = [WindowsStutterCollectorNative]::GetProcessDefaultCpuSets($handle, $ids, $required, [ref]$required)
                if ($ok) {
                    # PS 5.1 ConvertTo-Json mishandles UInt32[]; emit JSON-safe ints.
                    $state.default_cpu_sets = @($ids | ForEach-Object { [int64]$_ })
                    $state.default_cpu_sets_status = 'ok'
                } else {
                    $last = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
                    $state.default_cpu_sets_status = "failed_win32_$last"
                    [void]$queryErrors.Add("GetProcessDefaultCpuSets failed win32=$last")
                }
            } else {
                # RequiredIdCount == 0 means no default CPU sets are assigned for this process.
                # Treat as empty success unless a clear access/handle/parameter error is present.
                $hardFail = (
                    $last -eq [WindowsStutterCollectorNative]::ERROR_ACCESS_DENIED -or
                    $last -eq [WindowsStutterCollectorNative]::ERROR_INVALID_HANDLE -or
                    $last -eq 87
                )
                if ($probe -or (-not $hardFail)) {
                    $state.default_cpu_sets = @()
                    $state.default_cpu_sets_status = 'ok_empty'
                } else {
                    $state.default_cpu_sets_status = "failed_win32_$last"
                    [void]$queryErrors.Add("GetProcessDefaultCpuSets probe failed win32=$last")
                }
            }
        } catch {
            $state.default_cpu_sets_status = 'api_unavailable_or_error'
            [void]$queryErrors.Add("default_cpu_sets: $($_.Exception.Message)")
        }
    } finally {
        [void][WindowsStutterCollectorNative]::CloseHandle($handle)
    }

    $state.query_errors = @($queryErrors)
    return $state
}

function New-PdhSession {
    $query = [IntPtr]::Zero
    $status = [WindowsStutterCollectorNative]::PdhOpenQueryW([IntPtr]::Zero, [IntPtr]::Zero, [ref]$query)
    if ($status -ne 0) {
        throw ("PdhOpenQueryW failed: 0x{0:X8}" -f $status)
    }

    $session = [pscustomobject]@{
        Query    = $query
        Counters = @{}
        Missing  = New-Object System.Collections.ArrayList
    }
    return $session
}

function Add-PdhEnglishCounter {
    param(
        $Session,
        [string]$Name,
        [string]$Path
    )

    $counter = [IntPtr]::Zero
    $status = [WindowsStutterCollectorNative]::PdhAddEnglishCounterW($Session.Query, $Path, [IntPtr]::Zero, [ref]$counter)
    if ($status -ne 0) {
        $msg = "{0} ({1}) status=0x{2:X8}" -f $Name, $Path, $status
        [void]$Session.Missing.Add($msg)
        Write-CollectorWarning ("PDH counter unavailable, will degrade: {0}" -f $msg)
        $Session.Counters[$Name] = $null
        return $false
    }
    $Session.Counters[$Name] = $counter
    return $true
}

function Collect-PdhSample {
    param($Session)

    $values = [ordered]@{}
    $names = New-Object System.Collections.Generic.List[string]
    $handles = New-Object System.Collections.Generic.List[System.IntPtr]
    foreach ($key in @($Session.Counters.Keys)) {
        $handle = $Session.Counters[$key]
        $values[$key] = $null
        if ($null -eq $handle -or $handle -eq [IntPtr]::Zero) {
            continue
        }
        $names.Add([string]$key) | Out-Null
        $handles.Add([IntPtr]$handle) | Out-Null
    }

    $status = [uint32]0
    $nativeValues = [WindowsStutterCollectorNative]::CollectPdhValues(
        $Session.Query,
        $names.ToArray(),
        $handles.ToArray(),
        [ref]$status
    )
    if ($status -ne 0) {
        Write-CollectorWarning ("PdhCollectQueryData status=0x{0:X8}" -f $status)
        return $null
    }
    foreach ($entry in $nativeValues.GetEnumerator()) {
        $values[[string]$entry.Key] = [double]$entry.Value
    }
    return $values
}

function Close-PdhSession {
    param($Session)
    if ($null -ne $Session -and $Session.Query -ne [IntPtr]::Zero) {
        [void][WindowsStutterCollectorNative]::PdhCloseQuery($Session.Query)
        $Session.Query = [IntPtr]::Zero
    }
}

function Get-Percentile {
    param(
        [double[]]$Values,
        [double]$Percentile
    )
    if ($null -eq $Values -or $Values.Count -eq 0) {
        return $null
    }
    $sorted = @($Values | Sort-Object)
    if ($sorted.Count -eq 1) {
        return [double]$sorted[0]
    }
    $rank = ($Percentile / 100.0) * ($sorted.Count - 1)
    $low = [int][Math]::Floor($rank)
    $high = [int][Math]::Ceiling($rank)
    if ($low -eq $high) {
        return [double]$sorted[$low]
    }
    $weight = $rank - $low
    return ([double]$sorted[$low] * (1.0 - $weight)) + ([double]$sorted[$high] * $weight)
}

function Get-SeriesStats {
    param([AllowNull()][object[]]$Values)

    $nums = New-Object System.Collections.Generic.List[double]
    foreach ($v in @($Values)) {
        if ($null -eq $v -or $v -eq '') { continue }
        $parsed = 0.0
        $parsedOk = $false
        if ($v -is [string]) {
            $parsedOk = [double]::TryParse(
                [string]$v,
                [System.Globalization.NumberStyles]::Float,
                [System.Globalization.CultureInfo]::InvariantCulture,
                [ref]$parsed
            )
        } else {
            try {
                $parsed = [Convert]::ToDouble($v, [System.Globalization.CultureInfo]::InvariantCulture)
                $parsedOk = $true
            } catch {
                $parsedOk = $false
            }
        }
        if ($parsedOk -and -not [double]::IsNaN($parsed) -and -not [double]::IsInfinity($parsed)) {
            $nums.Add($parsed) | Out-Null
        }
    }
    if ($nums.Count -eq 0) {
        return [ordered]@{
            count = 0
            min = $null
            max = $null
            avg = $null
            p50 = $null
            p95 = $null
            last = $null
        }
    }
    $arr = $nums.ToArray()
    $sum = 0.0
    foreach ($n in $arr) { $sum += $n }
    return [ordered]@{
        count = $arr.Length
        min   = [Math]::Round(($arr | Measure-Object -Minimum).Minimum, 6)
        max   = [Math]::Round(($arr | Measure-Object -Maximum).Maximum, 6)
        avg   = [Math]::Round(($sum / $arr.Length), 6)
        p50   = [Math]::Round((Get-Percentile -Values $arr -Percentile 50), 6)
        p95   = [Math]::Round((Get-Percentile -Values $arr -Percentile 95), 6)
        last  = [Math]::Round($arr[$arr.Length - 1], 6)
    }
}

function ConvertTo-CsvLine {
    param([object[]]$Fields)
    $parts = foreach ($f in $Fields) {
        if ($null -eq $f) {
            '""'
        } else {
            $s = if ($f -is [System.IFormattable] -and -not ($f -is [string])) {
                $f.ToString($null, [System.Globalization.CultureInfo]::InvariantCulture)
            } else {
                [string]$f
            }
            if ($s -match '[,"\r\n]') {
                '"' + ($s.Replace('"', '""')) + '"'
            } else {
                $s
            }
        }
    }
    return ($parts -join ',')
}

function Write-CsvFile {
    param(
        [string]$Path,
        [string[]]$Headers,
        [System.Collections.IEnumerable]$Rows
    )
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine((ConvertTo-CsvLine -Fields $Headers))
    foreach ($row in $Rows) {
        $vals = foreach ($h in $Headers) { $row[$h] }
        [void]$sb.AppendLine((ConvertTo-CsvLine -Fields $vals))
    }
    [System.IO.File]::WriteAllText($Path, $sb.ToString(), [System.Text.UTF8Encoding]::new($false))
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

$script:Warnings = New-Object System.Collections.ArrayList
$script:NativeTypesReady = $false
$script:LastFamilySnapshotSource = 'none'
$logicalProcessors = [Environment]::ProcessorCount
$collectorStartCpu = $null
$collectorEndCpu = $null
$collectorSamplingStartCpu = $null
$collectorSamplingEndCpu = $null
$samplingStartedLocal = $null
$samplingEndedLocal = $null
$collectorOriginalPriority = $null
$collectorPriorityApplied = $false
$collectorPriorityRestored = $false
$pdh = $null
$runStartedLocal = Get-Date

# Start collector CPU accounting before Add-Type / PDH / enum prep (main try body).
$selfProc = $null
try {
    $selfProc = [System.Diagnostics.Process]::GetCurrentProcess()
    $collectorStartCpu = $selfProc.TotalProcessorTime.TotalSeconds
    $collectorOriginalPriority = [string]$selfProc.PriorityClass
    if ($selfProc.PriorityClass -in @(
            [System.Diagnostics.ProcessPriorityClass]::Normal,
            [System.Diagnostics.ProcessPriorityClass]::AboveNormal,
            [System.Diagnostics.ProcessPriorityClass]::High,
            [System.Diagnostics.ProcessPriorityClass]::RealTime
        )) {
        $selfProc.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::BelowNormal
        $collectorPriorityApplied = $true
    }
} catch {
    $collectorStartCpu = $null
    Write-CollectorWarning ("Could not lower collector self-priority: {0}" -f $_.Exception.Message)
}

try {
    Ensure-NativeTypes

    if ($IntervalSeconds -gt $DurationSeconds) {
        throw "IntervalSeconds ($IntervalSeconds) cannot exceed DurationSeconds ($DurationSeconds)."
    }

    try {
        $rootProc = [System.Diagnostics.Process]::GetProcessById($TargetPid)
    } catch {
        throw "ProcessId/TargetPid $TargetPid is not running or is inaccessible."
    }

    $rootName = $null
    try {
        $rootName = $rootProc.ProcessName
    } finally {
        $rootProc.Dispose()
    }

    if (-not [string]::IsNullOrWhiteSpace($ProcessName)) {
        $expected = $ProcessName.Trim()
        if ($expected.EndsWith('.exe', [System.StringComparison]::OrdinalIgnoreCase)) {
            $expected = $expected.Substring(0, $expected.Length - 4)
        }
        if (-not [string]::Equals($rootName, $expected, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "ProcessName mismatch for PID $TargetPid. Expected exact '$expected', actual '$rootName'."
        }
    }

    # Validate target before creating any output directory.
    $rootStateStart = Get-RootProcessReadonlyState -ProcessId $TargetPid
    if ($rootStateStart.query_errors.Count -gt 0) {
        foreach ($err in $rootStateStart.query_errors) {
            Write-CollectorWarning ("Root process read-only query note: {0}" -f $err)
        }
    }

    $outputDir = Resolve-OutputDirectory -Requested $OutputDirectory

    $counterSpecs = [ordered]@{
        'cpu_total_pct'            = '\Processor Information(_Total)\% Processor Time'
        'cpu_user_pct'             = '\Processor Information(_Total)\% User Time'
        'cpu_privileged_pct'       = '\Processor Information(_Total)\% Privileged Time'
        'cpu_interrupt_pct'        = '\Processor Information(_Total)\% Interrupt Time'
        'cpu_dpc_pct'              = '\Processor Information(_Total)\% DPC Time'
        'processor_queue_length'   = '\System\Processor Queue Length'
        'context_switches_per_sec' = '\System\Context Switches/sec'
        'system_calls_per_sec'     = '\System\System Calls/sec'
        'available_mbytes'         = '\Memory\Available MBytes'
        'commit_limit_bytes'       = '\Memory\Commit Limit'
        'committed_bytes'          = '\Memory\Committed Bytes'
        'pages_input_per_sec'      = '\Memory\Pages Input/sec'
        'page_reads_per_sec'       = '\Memory\Page Reads/sec'
        'pages_per_sec'            = '\Memory\Pages/sec'
        'disk_avg_sec_read'        = '\PhysicalDisk(_Total)\Avg. Disk sec/Read'
        'disk_avg_sec_write'       = '\PhysicalDisk(_Total)\Avg. Disk sec/Write'
        'disk_avg_queue_length'    = '\PhysicalDisk(_Total)\Avg. Disk Queue Length'
        'disk_reads_per_sec'       = '\PhysicalDisk(_Total)\Disk Reads/sec'
        'disk_writes_per_sec'      = '\PhysicalDisk(_Total)\Disk Writes/sec'
    }

    $fallbackSpecs = [ordered]@{
        'cpu_total_pct'      = '\Processor(_Total)\% Processor Time'
        'cpu_user_pct'       = '\Processor(_Total)\% User Time'
        'cpu_privileged_pct' = '\Processor(_Total)\% Privileged Time'
        'cpu_interrupt_pct'  = '\Processor(_Total)\% Interrupt Time'
        'cpu_dpc_pct'        = '\Processor(_Total)\% DPC Time'
    }

    if (-not $SkipSystemCounters) {
        $pdh = New-PdhSession
        foreach ($name in @($counterSpecs.Keys)) {
            $ok = Add-PdhEnglishCounter -Session $pdh -Name $name -Path ([string]$counterSpecs[$name])
            if (-not $ok -and $fallbackSpecs.Contains($name)) {
                [void](Add-PdhEnglishCounter -Session $pdh -Name $name -Path ([string]$fallbackSpecs[$name]))
            }
        }

        # Prime PDH (rate counters need a baseline sample)
        [void](Collect-PdhSample -Session $pdh)
        Start-Sleep -Milliseconds 200
        [void](Collect-PdhSample -Session $pdh)
    } else {
        $pdh = [pscustomobject]@{
            Query = [IntPtr]::Zero
            Counters = @{}
            Missing = New-Object System.Collections.ArrayList
        }
    }

    $familyRows = New-Object System.Collections.Generic.List[object]
    $topRows = New-Object System.Collections.Generic.List[object]
    $systemRows = New-Object System.Collections.Generic.List[object]

    $prevFamilyCpu = @{}
    $prevFamilyIo = @{}
    $prevTopCpu = @{}
    $prevTopSampleUtc = $null
    $nextTopProcessSampleDue = $null
    $prevSystemSampleUtc = $null
    $nextSystemCounterSampleDue = $null
    $prevSampleUtc = $null
    $lastFamilyRefresh = [datetime]::MinValue
    $familyIds = @($TargetPid)

    if ($null -eq $selfProc) {
        try { $selfProc = [System.Diagnostics.Process]::GetCurrentProcess() } catch { $selfProc = $null }
    }
    if ($null -eq $collectorStartCpu) {
        try {
            if ($null -ne $selfProc) {
                $collectorStartCpu = $selfProc.TotalProcessorTime.TotalSeconds
            } else {
                $collectorStartCpu = Get-ProcessCpuSeconds -ProcessId $PID
            }
        } catch {
            $collectorStartCpu = Get-ProcessCpuSeconds -ProcessId $PID
        }
    }

    $plannedSamples = [int][Math]::Floor($DurationSeconds / $IntervalSeconds)
    if ($plannedSamples -lt 1) { $plannedSamples = 1 }

    $sampleIndex = 0
    $samplingStartedLocal = Get-Date
    try {
        if ($null -ne $selfProc) {
            $selfProc.Refresh()
            $collectorSamplingStartCpu = $selfProc.TotalProcessorTime.TotalSeconds
        } else {
            $collectorSamplingStartCpu = Get-ProcessCpuSeconds -ProcessId $PID
        }
    } catch {
        $collectorSamplingStartCpu = Get-ProcessCpuSeconds -ProcessId $PID
    }
    $loopStarted = $samplingStartedLocal
    $nextDue = $loopStarted
    $nextSystemCounterSampleDue = $loopStarted
    $nextTopProcessSampleDue = $loopStarted

    Write-Host ("Collecting read-only stutter baseline for PID {0} ({1}) for {2}s every {3}s -> {4}" -f $TargetPid, $rootName, $DurationSeconds, $IntervalSeconds, $outputDir)

    while ($true) {
        $now = Get-Date
        $elapsed = ($now - $loopStarted).TotalSeconds
        if ($sampleIndex -ge $plannedSamples -or $elapsed -ge ($DurationSeconds + 0.25)) {
            break
        }

        if ($now -lt $nextDue) {
            $sleepMs = [int][Math]::Max(1, [Math]::Min(1000, ($nextDue - $now).TotalMilliseconds))
            Start-Sleep -Milliseconds $sleepMs
            continue
        }

        $sampleUtc = (Get-Date).ToUniversalTime()
        $sampleLocal = Get-Date
        $wallDeltaSec = $null
        if ($null -ne $prevSampleUtc) {
            $wallDeltaSec = ($sampleUtc - $prevSampleUtc).TotalSeconds
            if ($wallDeltaSec -le 0) { $wallDeltaSec = $IntervalSeconds }
        }

        if (($sampleLocal - $lastFamilyRefresh).TotalSeconds -ge $FamilyRefreshSeconds -or $sampleIndex -eq 0) {
            $snap = Get-ProcessSnapshotMap
            if (-not $snap.ContainsKey($TargetPid)) {
                Write-CollectorWarning "Root PID $TargetPid disappeared during collection."
                $familyIds = @($TargetPid)
            } else {
                $familyIds = Get-ProcessFamilyIds -RootPid $TargetPid -SnapshotMap $snap
            }
            $lastFamilyRefresh = $sampleLocal
        }

        $famCpuSecondsTotal = 0.0
        $famCpuCores = $null
        $famWs = [int64]0
        $famPrivate = [int64]0
        $famThreads = 0
        $famHandles = 0
        $famCountAlive = 0
        $memberNames = New-Object System.Collections.Generic.List[string]
        $memberPids = New-Object System.Collections.Generic.List[int]

        $currentFamilyCpu = @{}
        $currentFamilyIo = @{}

        foreach ($fp in $familyIds) {
            $memberPids.Add([int]$fp) | Out-Null
            $cpuSec = Get-ProcessCpuSeconds -ProcessId $fp
            if ($null -eq $cpuSec) {
                continue
            }
            $famCountAlive++
            $famCpuSecondsTotal += $cpuSec
            $familyIdentityKey = "${fp}:unknown"

            try {
                $pobj = [System.Diagnostics.Process]::GetProcessById($fp)
                try {
                    $memberNames.Add($pobj.ProcessName) | Out-Null
                    try { $familyIdentityKey = "${fp}:$($pobj.StartTime.ToUniversalTime().Ticks)" } catch { }
                    try { $famWs += [int64]$pobj.WorkingSet64 } catch { }
                    try { $famPrivate += [int64]$pobj.PrivateMemorySize64 } catch { }
                    try { $famThreads += [int]$pobj.Threads.Count } catch { }
                } finally {
                    $pobj.Dispose()
                }
            } catch { }

            $currentFamilyCpu[$familyIdentityKey] = $cpuSec

            $hc = Get-ProcessHandleCountSafe -ProcessId $fp
            if ($null -ne $hc) { $famHandles += $hc }

            $io = Get-ProcessIoSnapshot -ProcessId $fp
            if ($null -ne $io) {
                $currentFamilyIo[$familyIdentityKey] = $io
            }
        }

        $famCpuDeltaSec = $null
        $ioReadOpsPerSec = $null
        $ioWriteOpsPerSec = $null
        $ioOtherOpsPerSec = $null
        $ioReadBytesPerSec = $null
        $ioWriteBytesPerSec = $null
        $ioOtherBytesPerSec = $null

        if ($null -ne $wallDeltaSec -and $wallDeltaSec -gt 0) {
            $deltaCpu = 0.0
            $haveDelta = $false
            foreach ($fp in $currentFamilyCpu.Keys) {
                if ($prevFamilyCpu.ContainsKey($fp)) {
                    $d = [double]$currentFamilyCpu[$fp] - [double]$prevFamilyCpu[$fp]
                    if ($d -ge 0) {
                        $deltaCpu += $d
                        $haveDelta = $true
                    }
                }
            }
            if ($haveDelta) {
                $famCpuDeltaSec = $deltaCpu
                $famCpuCores = $deltaCpu / $wallDeltaSec
            }

            $dReadOps = [double]0
            $dWriteOps = [double]0
            $dOtherOps = [double]0
            $dReadBytes = [double]0
            $dWriteBytes = [double]0
            $dOtherBytes = [double]0
            $haveIo = $false
            foreach ($fp in $currentFamilyIo.Keys) {
                if ($prevFamilyIo.ContainsKey($fp)) {
                    $prev = $prevFamilyIo[$fp]
                    $cur = $currentFamilyIo[$fp]
                    $haveIo = $true
                    $dReadOps += [Math]::Max(0, [double]$cur.ReadOperationCount - [double]$prev.ReadOperationCount)
                    $dWriteOps += [Math]::Max(0, [double]$cur.WriteOperationCount - [double]$prev.WriteOperationCount)
                    $dOtherOps += [Math]::Max(0, [double]$cur.OtherOperationCount - [double]$prev.OtherOperationCount)
                    $dReadBytes += [Math]::Max(0, [double]$cur.ReadTransferCount - [double]$prev.ReadTransferCount)
                    $dWriteBytes += [Math]::Max(0, [double]$cur.WriteTransferCount - [double]$prev.WriteTransferCount)
                    $dOtherBytes += [Math]::Max(0, [double]$cur.OtherTransferCount - [double]$prev.OtherTransferCount)
                }
            }
            if ($haveIo) {
                $ioReadOpsPerSec = $dReadOps / $wallDeltaSec
                $ioWriteOpsPerSec = $dWriteOps / $wallDeltaSec
                $ioOtherOpsPerSec = $dOtherOps / $wallDeltaSec
                $ioReadBytesPerSec = $dReadBytes / $wallDeltaSec
                $ioWriteBytesPerSec = $dWriteBytes / $wallDeltaSec
                $ioOtherBytesPerSec = $dOtherBytes / $wallDeltaSec
            }
        }

        $famCpuPctOfSystem = $null
        if ($null -ne $famCpuCores -and $logicalProcessors -gt 0) {
            $famCpuPctOfSystem = ($famCpuCores / $logicalProcessors) * 100.0
        }

        $wallDeltaOut = ''
        if ($null -ne $wallDeltaSec) { $wallDeltaOut = [Math]::Round($wallDeltaSec, 6) }
        $famCpuDeltaOut = ''
        if ($null -ne $famCpuDeltaSec) { $famCpuDeltaOut = [Math]::Round($famCpuDeltaSec, 6) }
        $famCpuCoresOut = ''
        if ($null -ne $famCpuCores) { $famCpuCoresOut = [Math]::Round($famCpuCores, 6) }
        $famCpuPctOut = ''
        if ($null -ne $famCpuPctOfSystem) { $famCpuPctOut = [Math]::Round($famCpuPctOfSystem, 6) }
        $ioReadOpsOut = ''
        if ($null -ne $ioReadOpsPerSec) { $ioReadOpsOut = [Math]::Round($ioReadOpsPerSec, 6) }
        $ioWriteOpsOut = ''
        if ($null -ne $ioWriteOpsPerSec) { $ioWriteOpsOut = [Math]::Round($ioWriteOpsPerSec, 6) }
        $ioOtherOpsOut = ''
        if ($null -ne $ioOtherOpsPerSec) { $ioOtherOpsOut = [Math]::Round($ioOtherOpsPerSec, 6) }
        $ioReadBytesOut = ''
        if ($null -ne $ioReadBytesPerSec) { $ioReadBytesOut = [Math]::Round($ioReadBytesPerSec, 3) }
        $ioWriteBytesOut = ''
        if ($null -ne $ioWriteBytesPerSec) { $ioWriteBytesOut = [Math]::Round($ioWriteBytesPerSec, 3) }
        $ioOtherBytesOut = ''
        if ($null -ne $ioOtherBytesPerSec) { $ioOtherBytesOut = [Math]::Round($ioOtherBytesPerSec, 3) }

        $familyRow = [ordered]@{
            sample_index              = $sampleIndex
            timestamp_utc             = (New-IsoTimestamp -Value $sampleLocal)
            wall_delta_sec            = $wallDeltaOut
            root_pid                  = $TargetPid
            family_pids               = ($memberPids -join ';')
            family_names              = ((@($memberNames | Select-Object -Unique)) -join ';')
            family_process_count      = $memberPids.Count
            family_cpu_queryable_process_count = $famCountAlive
            family_cpu_delta_sec      = $famCpuDeltaOut
            family_cpu_cores          = $famCpuCoresOut
            family_cpu_pct_of_system  = $famCpuPctOut
            family_working_set_bytes  = $famWs
            family_private_bytes      = $famPrivate
            family_thread_count       = $famThreads
            family_handle_count       = $famHandles
            io_read_ops_per_sec       = $ioReadOpsOut
            io_write_ops_per_sec      = $ioWriteOpsOut
            io_other_ops_per_sec      = $ioOtherOpsOut
            io_read_bytes_per_sec     = $ioReadBytesOut
            io_write_bytes_per_sec    = $ioWriteBytesOut
            io_other_bytes_per_sec    = $ioOtherBytesOut
            logical_processors        = $logicalProcessors
        }
        $familyRows.Add($familyRow) | Out-Null

        $prevFamilyCpu = $currentFamilyCpu
        $prevFamilyIo = $currentFamilyIo

        $systemDue = (-not $SkipSystemCounters) -and ($sampleLocal -ge $nextSystemCounterSampleDue)
        if ($systemDue) {
            $systemWallDeltaSec = $null
            if ($null -ne $prevSystemSampleUtc) {
                $systemWallDeltaSec = ($sampleUtc - $prevSystemSampleUtc).TotalSeconds
            }
            $systemWallDeltaOut = ''
            if ($null -ne $systemWallDeltaSec) { $systemWallDeltaOut = [Math]::Round($systemWallDeltaSec, 6) }
            $pdhValues = Collect-PdhSample -Session $pdh
            $systemRow = [ordered]@{
            sample_index              = $sampleIndex
            timestamp_utc             = (New-IsoTimestamp -Value $sampleLocal)
            wall_delta_sec            = $systemWallDeltaOut
            cpu_total_pct             = ''
            cpu_user_pct              = ''
            cpu_privileged_pct        = ''
            cpu_interrupt_pct         = ''
            cpu_dpc_pct               = ''
            processor_queue_length    = ''
            context_switches_per_sec  = ''
            system_calls_per_sec      = ''
            available_mbytes          = ''
            commit_limit_bytes        = ''
            committed_bytes           = ''
            commit_pct                = ''
            pages_input_per_sec       = ''
            page_reads_per_sec        = ''
            pages_per_sec             = ''
            disk_avg_sec_read         = ''
            disk_avg_sec_write        = ''
            disk_avg_queue_length     = ''
            disk_reads_per_sec        = ''
            disk_writes_per_sec       = ''
            logical_processors        = $logicalProcessors
            }

            if ($null -ne $pdhValues) {
            $sysKeys = @(
                'cpu_total_pct','cpu_user_pct','cpu_privileged_pct','cpu_interrupt_pct','cpu_dpc_pct',
                'processor_queue_length','context_switches_per_sec','system_calls_per_sec',
                'available_mbytes','commit_limit_bytes','committed_bytes',
                'pages_input_per_sec','page_reads_per_sec','pages_per_sec',
                'disk_avg_sec_read','disk_avg_sec_write','disk_avg_queue_length',
                'disk_reads_per_sec','disk_writes_per_sec'
            )
            foreach ($k in $sysKeys) {
                if ($pdhValues.Contains($k) -and $null -ne $pdhValues[$k]) {
                    $systemRow[$k] = [Math]::Round([double]$pdhValues[$k], 6)
                }
            }
            if ($systemRow['commit_limit_bytes'] -ne '' -and $systemRow['committed_bytes'] -ne '') {
                $lim = [double]$systemRow['commit_limit_bytes']
                $com = [double]$systemRow['committed_bytes']
                if ($lim -gt 0) {
                    $systemRow['commit_pct'] = [Math]::Round(($com / $lim) * 100.0, 6)
                }
            }
            }
            $systemRows.Add($systemRow) | Out-Null
            $prevSystemSampleUtc = $sampleUtc
            do {
                $nextSystemCounterSampleDue = $nextSystemCounterSampleDue.AddSeconds($SystemCounterIntervalSeconds)
            } while ($nextSystemCounterSampleDue -le $sampleLocal)
        }

        $topProcessDue = (-not $SkipTopProcesses) -and ($sampleLocal -ge $nextTopProcessSampleDue)
        if ($topProcessDue) {
            $topWallDeltaSec = $null
            if ($null -ne $prevTopSampleUtc) {
                $topWallDeltaSec = ($sampleUtc - $prevTopSampleUtc).TotalSeconds
            }
            $currentTopCpu = @{}
            $topCandidates = New-Object System.Collections.Generic.List[object]

            foreach ($p in [System.Diagnostics.Process]::GetProcesses()) {
                try {
                    $pidValue = $p.Id
                    if ($pidValue -eq 0) { continue }
                    $cpuSec = $null
                    try {
                        $cpuSec = $p.TotalProcessorTime.TotalSeconds
                    } catch {
                        $cpuSec = Get-ProcessCpuSeconds -ProcessId $pidValue
                    }
                    if ($null -eq $cpuSec) { continue }
                    $topIdentityKey = "${pidValue}:unknown"
                    try { $topIdentityKey = "${pidValue}:$($p.StartTime.ToUniversalTime().Ticks)" } catch { }
                    $currentTopCpu[$topIdentityKey] = $cpuSec

                    $name = ''
                    try { $name = $p.ProcessName } catch { $name = '' }
                    $ws = ''
                    try { $ws = [int64]$p.WorkingSet64 } catch { $ws = '' }
                    $threads = ''
                    try { $threads = [int]$p.Threads.Count } catch { $threads = '' }

                    $cores = $null
                    $pct = $null
                    if ($null -ne $topWallDeltaSec -and $topWallDeltaSec -gt 0 -and $prevTopCpu.ContainsKey($topIdentityKey)) {
                        $d = [double]$cpuSec - [double]$prevTopCpu[$topIdentityKey]
                        if ($d -ge 0) {
                            $cores = $d / $topWallDeltaSec
                            if ($logicalProcessors -gt 0) {
                                $pct = ($cores / $logicalProcessors) * 100.0
                            }
                        }
                    }

                    if ($null -ne $cores) {
                        $inFamily = $false
                        if ($familyIds -contains $pidValue) { $inFamily = $true }
                        $topCandidates.Add([pscustomobject]@{
                            pid = $pidValue
                            name = $name
                            cpu_cores = $cores
                            cpu_pct_of_system = $pct
                            working_set_bytes = $ws
                            thread_count = $threads
                            in_target_family = $inFamily
                        }) | Out-Null
                    }
                } catch {
                } finally {
                    try { $p.Dispose() } catch { }
                }
            }

            $rank = 0
            foreach ($c in @($topCandidates | Sort-Object -Property cpu_cores -Descending | Select-Object -First $TopProcessCount)) {
                $rank++
                $pctOut = ''
                if ($null -ne $c.cpu_pct_of_system) { $pctOut = [Math]::Round([double]$c.cpu_pct_of_system, 6) }
                $topRows.Add([ordered]@{
                    sample_index         = $sampleIndex
                    timestamp_utc        = (New-IsoTimestamp -Value $sampleLocal)
                    rank                 = $rank
                    pid                  = $c.pid
                    process_name         = $c.name
                    cpu_cores            = [Math]::Round([double]$c.cpu_cores, 6)
                    cpu_pct_of_system    = $pctOut
                    working_set_bytes    = $c.working_set_bytes
                    thread_count         = $c.thread_count
                    in_target_family     = $c.in_target_family
                }) | Out-Null
            }

            $prevTopCpu = $currentTopCpu
            $prevTopSampleUtc = $sampleUtc
            do {
                $nextTopProcessSampleDue = $nextTopProcessSampleDue.AddSeconds($TopProcessIntervalSeconds)
            } while ($nextTopProcessSampleDue -le $sampleLocal)
        }
        $prevSampleUtc = $sampleUtc
        $sampleIndex++
        $nextDue = $loopStarted.AddSeconds($sampleIndex * $IntervalSeconds)
    }

    $samplingEndedLocal = Get-Date
    try {
        if ($null -ne $selfProc) {
            $selfProc.Refresh()
            $collectorSamplingEndCpu = $selfProc.TotalProcessorTime.TotalSeconds
        } else {
            $collectorSamplingEndCpu = Get-ProcessCpuSeconds -ProcessId $PID
        }
    } catch {
        $collectorSamplingEndCpu = Get-ProcessCpuSeconds -ProcessId $PID
    }

    # Capture root runtime state again at end to detect priority/affinity/CPU Set changes.
    $rootStateEnd = Get-RootProcessReadonlyState -ProcessId $TargetPid
    if ($rootStateEnd.query_errors.Count -gt 0) {
        foreach ($err in $rootStateEnd.query_errors) {
            Write-CollectorWarning ("Root process end-state query note: {0}" -f $err)
        }
    }

    $familyHeaders = @(
        'sample_index','timestamp_utc','wall_delta_sec','root_pid','family_pids','family_names',
        'family_process_count','family_cpu_queryable_process_count',
        'family_cpu_delta_sec','family_cpu_cores','family_cpu_pct_of_system',
        'family_working_set_bytes','family_private_bytes','family_thread_count','family_handle_count',
        'io_read_ops_per_sec','io_write_ops_per_sec','io_other_ops_per_sec',
        'io_read_bytes_per_sec','io_write_bytes_per_sec','io_other_bytes_per_sec','logical_processors'
    )
    $systemHeaders = @(
        'sample_index','timestamp_utc','wall_delta_sec',
        'cpu_total_pct','cpu_user_pct','cpu_privileged_pct','cpu_interrupt_pct','cpu_dpc_pct',
        'processor_queue_length','context_switches_per_sec','system_calls_per_sec',
        'available_mbytes','commit_limit_bytes','committed_bytes','commit_pct',
        'pages_input_per_sec','page_reads_per_sec','pages_per_sec',
        'disk_avg_sec_read','disk_avg_sec_write','disk_avg_queue_length',
        'disk_reads_per_sec','disk_writes_per_sec','logical_processors'
    )
    $topHeaders = @(
        'sample_index','timestamp_utc','rank','pid','process_name',
        'cpu_cores','cpu_pct_of_system','working_set_bytes','thread_count','in_target_family'
    )

    $familyPath = Join-Path $outputDir 'process-family.csv'
    $systemPath = Join-Path $outputDir 'system.csv'
    $topPath = Join-Path $outputDir 'top-processes.csv'
    $manifestPath = Join-Path $outputDir 'manifest.json'
    $summaryPath = Join-Path $outputDir 'summary.json'

    Write-CsvFile -Path $familyPath -Headers $familyHeaders -Rows $familyRows
    Write-CsvFile -Path $systemPath -Headers $systemHeaders -Rows $systemRows
    Write-CsvFile -Path $topPath -Headers $topHeaders -Rows $topRows

    $requiredCounterNames = @(
        'cpu_total_pct','processor_queue_length','context_switches_per_sec',
        'cpu_dpc_pct','cpu_interrupt_pct','available_mbytes','committed_bytes',
        'page_reads_per_sec','disk_avg_sec_read','disk_avg_queue_length'
    )
    $counterAvailability = [ordered]@{}
    foreach ($name in @($counterSpecs.Keys)) {
        $present = $false
        if ($pdh.Counters.ContainsKey($name) -and $null -ne $pdh.Counters[$name] -and $pdh.Counters[$name] -ne [IntPtr]::Zero) {
            $present = $true
        }
        $counterAvailability[$name] = $present
    }

    $missingRequired = @()
    if (-not $SkipSystemCounters) {
        $missingRequired = @($requiredCounterNames | Where-Object { -not $counterAvailability[$_] })
    }

    $counterRequestList = @()
    foreach ($entry in $counterSpecs.GetEnumerator()) {
        $counterRequestList += , (@{
            name = [string]$entry.Key
            path = [string]$entry.Value
            available = [bool]$counterAvailability[$entry.Key]
        })
    }

    $collectorOverhead = [ordered]@{
        cpu_seconds           = $null
        avg_cpu_cores         = $null
        avg_cpu_pct_of_system = $null
        span_seconds          = $null
        initialization_cpu_seconds = $null
        sampling_cpu_seconds = $null
        sampling_duration_seconds = $null
        sampling_avg_cpu_cores = $null
        sampling_avg_cpu_pct_of_system = $null
        post_sampling_cpu_seconds = $null
        includes_initial_output_serialization = $true
        includes_final_overhead_field_rewrite = $false
        covers_from           = 'before_main_try_before_AddType'
        covers_through        = 'after_first_csv_json_serialization_before_overhead_field_rewrite'
        family_snapshot_source = $script:LastFamilySnapshotSource
        note                  = 'Descriptive overhead only. Use sampling_avg_cpu_cores to judge observer effect during the timed window; initialization includes Add-Type and PDH setup. The final rewrite that stores these fields is necessarily excluded.'
    }

    $processNameFilter = $null
    if (-not [string]::IsNullOrWhiteSpace($ProcessName)) { $processNameFilter = $ProcessName }

    $runEndedLocal = Get-Date
    $samplingDuration = ($samplingEndedLocal - $samplingStartedLocal).TotalSeconds

    $requestedSafe = ConvertTo-JsonSafeValue -Value $counterRequestList
    $missingSafe = @()
    if ($null -ne $missingRequired) {
        foreach ($m in $missingRequired) { $missingSafe += [string]$m }
    }
    $degradedSafe = @()
    if ($null -ne $pdh -and $null -ne $pdh.Missing) {
        foreach ($d in $pdh.Missing) { $degradedSafe += [string]$d }
    }
    $warningsSafe = @()
    if ($null -ne $script:Warnings) {
        foreach ($w in $script:Warnings) { $warningsSafe += [string]$w }
    }
    $rootStartSafe = ConvertTo-JsonSafeValue -Value $rootStateStart
    $rootEndSafe = ConvertTo-JsonSafeValue -Value $rootStateEnd
    $overheadSafe = ConvertTo-JsonSafeValue -Value $collectorOverhead
    $rootStateChanges = @{}
    foreach ($field in @(
            'priority_class','base_priority','processor_affinity','system_affinity',
            'default_cpu_sets_status'
        )) {
        $before = $rootStateStart[$field]
        $after = $rootStateEnd[$field]
        if ([string]$before -ne [string]$after) {
            $rootStateChanges[$field] = @{
                before = ConvertTo-JsonSafeValue -Value $before
                after = ConvertTo-JsonSafeValue -Value $after
            }
        }
    }
    $beforeCpuSets = (@($rootStateStart.default_cpu_sets) -join ',')
    $afterCpuSets = (@($rootStateEnd.default_cpu_sets) -join ',')
    if ($beforeCpuSets -ne $afterCpuSets) {
        $rootStateChanges['default_cpu_sets'] = @{
            before = ConvertTo-JsonSafeValue -Value $rootStateStart.default_cpu_sets
            after = ConvertTo-JsonSafeValue -Value $rootStateEnd.default_cpu_sets
        }
    }
    $rootStateChanged = ($rootStateChanges.Count -gt 0)

    $manifest = [ordered]@{
        schema_version          = '1.0.0'
        collector               = 'collect_windows_stutter.ps1'
        purpose                 = 'read_only_windows_stutter_baseline_for_triage'
        not_a_diagnosis         = $true
        host                    = $env:COMPUTERNAME
        os_version              = [string][Environment]::OSVersion.VersionString
        powershell_version      = $PSVersionTable.PSVersion.ToString()
        logical_processors      = $logicalProcessors
        collector_started_at_utc = (New-IsoTimestamp -Value $runStartedLocal)
        started_at_utc          = (New-IsoTimestamp -Value $samplingStartedLocal)
        ended_at_utc            = (New-IsoTimestamp -Value $samplingEndedLocal)
        duration_requested_sec  = $DurationSeconds
        duration_actual_sec     = [Math]::Round($samplingDuration, 3)
        interval_sec            = $IntervalSeconds
        sample_count            = $sampleIndex
        target                  = [ordered]@{
            root_pid              = $TargetPid
            process_name_filter   = $processNameFilter
            observed_process_name = $rootName
            readonly_state_start  = $rootStartSafe
            readonly_state_end    = $rootEndSafe
            readonly_state_changed = $rootStateChanged
            readonly_state_changes = $rootStateChanges
        }
        collection              = [ordered]@{
            family_refresh_sec      = $FamilyRefreshSeconds
            top_process_count       = $TopProcessCount
            top_process_interval_sec = $TopProcessIntervalSeconds
            top_processes_enabled   = (-not [bool]$SkipTopProcesses)
            top_process_first_scan_is_baseline = $true
            system_counter_interval_sec = $SystemCounterIntervalSeconds
            system_counters_enabled = (-not [bool]$SkipSystemCounters)
            pdh_english             = $true
            avoid_per_second_cim    = $true
            family_snapshot_primary = 'toolhelp32'
            family_snapshot_source  = $script:LastFamilySnapshotSource
            captures_command_line   = $false
            captures_environment    = $false
            captures_window_title   = $false
            mutates_system          = $false
            mutates_target_process  = $false
            mutates_collector_process = $collectorPriorityApplied
            collector_original_priority = $collectorOriginalPriority
            collector_sampling_priority = if ($collectorPriorityApplied) { 'BelowNormal' } else { $collectorOriginalPriority }
            stops_processes         = $false
        }
        counters                = [ordered]@{
            skipped = [bool]$SkipSystemCounters
            requested = $requestedSafe
            missing_required_for_baseline = $missingSafe
            degraded = $degradedSafe
        }
        files                   = [ordered]@{
            manifest       = 'manifest.json'
            process_family = 'process-family.csv'
            top_processes  = 'top-processes.csv'
            system         = 'system.csv'
            summary        = 'summary.json'
        }
        output_directory        = $outputDir
        warnings                = $warningsSafe
        collector_overhead      = $overheadSafe
        usage_note              = 'Artifacts are triage evidence. Do not treat summary stats as diagnosis conclusions or fixed health thresholds.'
    }

    $summary = [ordered]@{
        schema_version = '1.0.0'
        not_a_diagnosis = $true
        target_pid = $TargetPid
        observed_process_name = $rootName
        sample_count = $sampleIndex
        duration_actual_sec = [Math]::Round($samplingDuration, 3)
        series = [ordered]@{
            family_cpu_cores             = Get-SeriesStats -Values @($familyRows | ForEach-Object { $_['family_cpu_cores'] })
            family_cpu_pct_of_system     = Get-SeriesStats -Values @($familyRows | ForEach-Object { $_['family_cpu_pct_of_system'] })
            family_working_set_bytes     = Get-SeriesStats -Values @($familyRows | ForEach-Object { $_['family_working_set_bytes'] })
            family_private_bytes         = Get-SeriesStats -Values @($familyRows | ForEach-Object { $_['family_private_bytes'] })
            family_thread_count          = Get-SeriesStats -Values @($familyRows | ForEach-Object { $_['family_thread_count'] })
            family_handle_count          = Get-SeriesStats -Values @($familyRows | ForEach-Object { $_['family_handle_count'] })
            io_read_bytes_per_sec        = Get-SeriesStats -Values @($familyRows | ForEach-Object { $_['io_read_bytes_per_sec'] })
            io_write_bytes_per_sec       = Get-SeriesStats -Values @($familyRows | ForEach-Object { $_['io_write_bytes_per_sec'] })
            system_cpu_total_pct         = Get-SeriesStats -Values @($systemRows | ForEach-Object { $_['cpu_total_pct'] })
            system_processor_queue       = Get-SeriesStats -Values @($systemRows | ForEach-Object { $_['processor_queue_length'] })
            system_context_switches      = Get-SeriesStats -Values @($systemRows | ForEach-Object { $_['context_switches_per_sec'] })
            system_dpc_pct               = Get-SeriesStats -Values @($systemRows | ForEach-Object { $_['cpu_dpc_pct'] })
            system_interrupt_pct         = Get-SeriesStats -Values @($systemRows | ForEach-Object { $_['cpu_interrupt_pct'] })
            system_available_mbytes      = Get-SeriesStats -Values @($systemRows | ForEach-Object { $_['available_mbytes'] })
            system_commit_pct            = Get-SeriesStats -Values @($systemRows | ForEach-Object { $_['commit_pct'] })
            system_page_reads_per_sec    = Get-SeriesStats -Values @($systemRows | ForEach-Object { $_['page_reads_per_sec'] })
            system_disk_avg_sec_read     = Get-SeriesStats -Values @($systemRows | ForEach-Object { $_['disk_avg_sec_read'] })
            system_disk_avg_queue_length = Get-SeriesStats -Values @($systemRows | ForEach-Object { $_['disk_avg_queue_length'] })
        }
        root_readonly_state_start = $rootStartSafe
        root_readonly_state_end = $rootEndSafe
        root_readonly_state_changed = $rootStateChanged
        root_readonly_state_changes = $rootStateChanges
        collector_overhead = $overheadSafe
        warnings = $warningsSafe
        interpretation_guardrail = 'Values are descriptive sample statistics for human triage only. No automatic conclusion, severity label, or fixed threshold is implied.'
    }

    [System.IO.File]::WriteAllText($manifestPath, (ConvertTo-JsonCompat -InputObject $manifest -Depth 10), [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText($summaryPath, (ConvertTo-JsonCompat -InputObject $summary -Depth 10), [System.Text.UTF8Encoding]::new($false))

    # Finalize collector CPU after CSV + JSON serialization so overhead includes that work.
    try {
        if ($null -ne $selfProc) {
            $selfProc.Refresh()
            $collectorEndCpu = $selfProc.TotalProcessorTime.TotalSeconds
        } else {
            $collectorEndCpu = Get-ProcessCpuSeconds -ProcessId $PID
        }
    } catch {
        $collectorEndCpu = Get-ProcessCpuSeconds -ProcessId $PID
    } finally {
        try { if ($null -ne $selfProc) { $selfProc.Dispose() } } catch { }
    }

    $collectorCpuSec = $null
    $collectorCpuCores = $null
    $collectorCpuPctOfSystem = $null
    $collectorSpanSeconds = ((Get-Date) - $runStartedLocal).TotalSeconds
    if ($null -ne $collectorStartCpu -and $null -ne $collectorEndCpu -and $collectorSpanSeconds -gt 0) {
        $collectorCpuSec = [Math]::Max(0, [double]$collectorEndCpu - [double]$collectorStartCpu)
        $collectorCpuCores = $collectorCpuSec / $collectorSpanSeconds
        if ($logicalProcessors -gt 0) {
            $collectorCpuPctOfSystem = ($collectorCpuCores / $logicalProcessors) * 100.0
        }
    }
    $initializationCpuSec = $null
    $samplingCpuSec = $null
    $postSamplingCpuSec = $null
    if ($null -ne $collectorStartCpu -and $null -ne $collectorSamplingStartCpu) {
        $initializationCpuSec = [Math]::Max(0, [double]$collectorSamplingStartCpu - [double]$collectorStartCpu)
    }
    if ($null -ne $collectorSamplingStartCpu -and $null -ne $collectorSamplingEndCpu) {
        $samplingCpuSec = [Math]::Max(0, [double]$collectorSamplingEndCpu - [double]$collectorSamplingStartCpu)
    }
    if ($null -ne $collectorSamplingEndCpu -and $null -ne $collectorEndCpu) {
        $postSamplingCpuSec = [Math]::Max(0, [double]$collectorEndCpu - [double]$collectorSamplingEndCpu)
    }
    if ($null -ne $collectorCpuSec) { $collectorOverhead.cpu_seconds = [Math]::Round($collectorCpuSec, 6) }
    if ($null -ne $collectorCpuCores) { $collectorOverhead.avg_cpu_cores = [Math]::Round($collectorCpuCores, 6) }
    if ($null -ne $collectorCpuPctOfSystem) { $collectorOverhead.avg_cpu_pct_of_system = [Math]::Round($collectorCpuPctOfSystem, 6) }
    $collectorOverhead.span_seconds = [Math]::Round($collectorSpanSeconds, 6)
    if ($null -ne $initializationCpuSec) { $collectorOverhead.initialization_cpu_seconds = [Math]::Round($initializationCpuSec, 6) }
    if ($null -ne $samplingCpuSec) {
        $collectorOverhead.sampling_cpu_seconds = [Math]::Round($samplingCpuSec, 6)
        $collectorOverhead.sampling_duration_seconds = [Math]::Round($samplingDuration, 6)
        if ($samplingDuration -gt 0) {
            $samplingAvgCores = $samplingCpuSec / $samplingDuration
            $collectorOverhead.sampling_avg_cpu_cores = [Math]::Round($samplingAvgCores, 6)
            if ($logicalProcessors -gt 0) {
                $collectorOverhead.sampling_avg_cpu_pct_of_system = [Math]::Round((100.0 * $samplingAvgCores / $logicalProcessors), 6)
            }
        }
    }
    if ($null -ne $postSamplingCpuSec) { $collectorOverhead.post_sampling_cpu_seconds = [Math]::Round($postSamplingCpuSec, 6) }
    $collectorOverhead.family_snapshot_source = $script:LastFamilySnapshotSource
    $overheadSafeFinal = ConvertTo-JsonSafeValue -Value $collectorOverhead
    $manifest['collector_overhead'] = $overheadSafeFinal
    $summary['collector_overhead'] = $overheadSafeFinal
    [System.IO.File]::WriteAllText($manifestPath, (ConvertTo-JsonCompat -InputObject $manifest -Depth 10), [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText($summaryPath, (ConvertTo-JsonCompat -InputObject $summary -Depth 10), [System.Text.UTF8Encoding]::new($false))

    Write-Host ("Done. samples={0} output={1}" -f $sampleIndex, $outputDir)
    Write-Output $outputDir
}
catch {
    try {
        Write-Host ("ERRTYPE=" + $_.Exception.GetType().FullName)
        Write-Host ("ERRMSG=" + $_.Exception.Message)
        if ($null -ne $_.Exception.InnerException) {
            Write-Host ("INNER=" + $_.Exception.InnerException.Message)
        }
        if ($null -ne $_.InvocationInfo) {
            Write-Host ("ERRSCRIPT=" + $_.InvocationInfo.ScriptName + " LINE=" + $_.InvocationInfo.ScriptLineNumber)
            Write-Host ("ERRLINE=" + $_.InvocationInfo.Line)
        }
    } catch { }
    Write-Error $_
    exit 1
}
finally {
    try { Close-PdhSession -Session $pdh } catch { }
    if ($collectorPriorityApplied -and -not [string]::IsNullOrWhiteSpace([string]$collectorOriginalPriority)) {
        try {
            $restoreProc = [System.Diagnostics.Process]::GetCurrentProcess()
            try {
                $restoreProc.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::$collectorOriginalPriority
                $collectorPriorityRestored = $true
            } finally {
                $restoreProc.Dispose()
            }
        } catch {
            Write-Warning ("Could not restore collector self-priority to {0}: {1}" -f $collectorOriginalPriority, $_.Exception.Message)
        }
    }
}
