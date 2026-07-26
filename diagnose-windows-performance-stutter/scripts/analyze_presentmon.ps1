#requires -Version 5.1
<#
.SYNOPSIS
    Read-only PresentMon CSV analyzer for a single capture.

.DESCRIPTION
    Computes frame-time statistics from a PresentMon CSV without modifying the
    source file or the system. One CSV capture is treated as a single
    experimental unit; per-frame samples are summarized but not treated as
    independent significance tests.

    Compatible with PowerShell 5.1+. Missing optional columns produce warnings
    instead of hard failures.

    Interval metrics (MsBetweenPresents / MsBetweenDisplayChange) only include
    finite values that are strictly greater than zero. Zero, negative, and
    unparseable samples are counted separately so first-frame zeros do not
    pollute percentiles or swapchain heuristics.

.PARAMETER CsvPath
    Path to a PresentMon CSV capture. Required.

.PARAMETER ProcessId
    Optional integer process id filter.

.PARAMETER ProcessName
    Optional process executable leaf-name filter (case-insensitive). A short name,
    name with .exe, or full path is normalized to the same executable stem before
    matching ProcessName or Application values.

.PARAMETER SwapChainAddress
    Optional swapchain address filter. When omitted, selection prefers the
    swapchain with the most valid (finite, >0) MsBetweenDisplayChange samples
    when any such samples exist; otherwise falls back to valid MsBetweenPresents.

.PARAMETER TargetFps
    Optional target FPS used to derive the frame budget (1000 / TargetFps).
    Defaults to 60 when neither TargetFps nor LongFrameThresholdMs is set.

.PARAMETER LongFrameThresholdMs
    Optional absolute long-frame threshold in milliseconds.

.PARAMETER OutputPath
    Optional path for JSON output. Defaults to stdout. Refuses to overwrite
    an existing file.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$CsvPath,

    [Parameter(Mandatory = $false)]
    [Nullable[int]]$ProcessId,

    [Parameter(Mandatory = $false)]
    [string]$ProcessName,

    [Parameter(Mandatory = $false)]
    [string]$SwapChainAddress,

    [Parameter(Mandatory = $false)]
    [Nullable[double]]$TargetFps,

    [Parameter(Mandatory = $false)]
    [Nullable[double]]$LongFrameThresholdMs,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-ErrAndExit {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [int]$ExitCode = 1
    )
    [Console]::Error.WriteLine($Message)
    exit $ExitCode
}

function Convert-ToNullableDouble {
    param([object]$Value)
    if ($null -eq $Value) { return $null }
    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    $parsed = 0.0
    if ([double]::TryParse($text, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) {
        return $parsed
    }
    if ([double]::TryParse($text, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::CurrentCulture, [ref]$parsed)) {
        return $parsed
    }
    return $null
}

function New-IntervalQuality {
    $q = New-Object System.Collections.Specialized.OrderedDictionary
    $q['positive_count'] = 0
    $q['zero_count'] = 0
    $q['negative_count'] = 0
    $q['unparseable_count'] = 0
    return $q
}

function Add-IntervalObservation {
    param(
        [Parameter(Mandatory = $true)]$Quality,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[double]]$PositiveValues,
        [Parameter(Mandatory = $false)]$RawValue
    )

    $text = if ($null -eq $RawValue) { '' } else { [string]$RawValue }
    if ([string]::IsNullOrWhiteSpace($text)) {
        $Quality['unparseable_count'] = [int]$Quality['unparseable_count'] + 1
        return
    }

    $parsed = Convert-ToNullableDouble -Value $text
    if ($null -eq $parsed -or [double]::IsNaN([double]$parsed) -or [double]::IsInfinity([double]$parsed)) {
        $Quality['unparseable_count'] = [int]$Quality['unparseable_count'] + 1
        return
    }

    $num = [double]$parsed
    if ($num -gt 0) {
        $Quality['positive_count'] = [int]$Quality['positive_count'] + 1
        [void]$PositiveValues.Add($num)
    } elseif ($num -eq 0) {
        $Quality['zero_count'] = [int]$Quality['zero_count'] + 1
    } else {
        $Quality['negative_count'] = [int]$Quality['negative_count'] + 1
    }
}

function Get-Percentile {
    param(
        [Parameter(Mandatory = $true)][double[]]$SortedValues,
        [Parameter(Mandatory = $true)][double]$Percentile
    )
    if ($null -eq $SortedValues -or $SortedValues.Length -eq 0) {
        return $null
    }
    if ($SortedValues.Length -eq 1) {
        return [double]$SortedValues[0]
    }
    $rank = ($Percentile / 100.0) * ($SortedValues.Length - 1)
    $low = [int][Math]::Floor($rank)
    $high = [int][Math]::Ceiling($rank)
    if ($low -eq $high) {
        return [double]$SortedValues[$low]
    }
    $weight = $rank - $low
    return ([double]$SortedValues[$low] * (1.0 - $weight)) + ([double]$SortedValues[$high] * $weight)
}

function Get-MetricStats {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][double[]]$Values,
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        $FrameBudgetMs = $null,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        $LongThresholdMs = $null,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        $Quality = $null
    )

    $result = New-Object System.Collections.Specialized.OrderedDictionary
    $result['available'] = $false
    $result['count'] = 0
    $result['mean'] = $null
    $result['p50'] = $null
    $result['p95'] = $null
    $result['p99'] = $null
    $result['max'] = $null
    $result['pct_gt_1_5x_frame_budget'] = $null
    $result['pct_gt_2x_frame_budget'] = $null
    $result['pct_gt_long_frame_threshold'] = $null
    $result['gt_1_5x_frame_budget_count'] = $null
    $result['gt_2x_frame_budget_count'] = $null
    $result['gt_long_frame_threshold_count'] = $null
    $result['zero_count'] = 0
    $result['negative_count'] = 0
    $result['unparseable_count'] = 0

    if ($null -ne $Quality) {
        $result['zero_count'] = [int]$Quality['zero_count']
        $result['negative_count'] = [int]$Quality['negative_count']
        $result['unparseable_count'] = [int]$Quality['unparseable_count']
    }

    if ($null -eq $Values -or $Values.Length -eq 0) {
        return $result
    }

    $sorted = @($Values | Sort-Object)
    $count = $sorted.Count
    $sum = 0.0
    foreach ($v in $sorted) { $sum += [double]$v }

    $result['available'] = $true
    $result['count'] = $count
    $result['mean'] = [Math]::Round($sum / $count, 6)
    $result['p50'] = [Math]::Round((Get-Percentile -SortedValues $sorted -Percentile 50), 6)
    $result['p95'] = [Math]::Round((Get-Percentile -SortedValues $sorted -Percentile 95), 6)
    $result['p99'] = [Math]::Round((Get-Percentile -SortedValues $sorted -Percentile 99), 6)
    $result['max'] = [Math]::Round([double]$sorted[$count - 1], 6)

    if ($null -ne $FrameBudgetMs -and $FrameBudgetMs -gt 0) {
        $t15 = 1.5 * [double]$FrameBudgetMs
        $t20 = 2.0 * [double]$FrameBudgetMs
        $c15 = 0
        $c20 = 0
        foreach ($v in $sorted) {
            if ([double]$v -gt $t15) { $c15++ }
            if ([double]$v -gt $t20) { $c20++ }
        }
        $result['gt_1_5x_frame_budget_count'] = $c15
        $result['gt_2x_frame_budget_count'] = $c20
        $result['pct_gt_1_5x_frame_budget'] = [Math]::Round(100.0 * $c15 / $count, 4)
        $result['pct_gt_2x_frame_budget'] = [Math]::Round(100.0 * $c20 / $count, 4)
    }

    if ($null -ne $LongThresholdMs -and $LongThresholdMs -gt 0) {
        $cLong = 0
        foreach ($v in $sorted) {
            if ([double]$v -gt [double]$LongThresholdMs) { $cLong++ }
        }
        $result['gt_long_frame_threshold_count'] = $cLong
        $result['pct_gt_long_frame_threshold'] = [Math]::Round(100.0 * $cLong / $count, 4)
    }

    return $result
}

function Convert-DroppedFlag {
    param([object]$RawValue)
    # Returns: $true (dropped), $false (displayed), $null (unparseable/empty)
    if ($null -eq $RawValue) { return $null }
    $raw = [string]$RawValue
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }

    $asInt = 0
    if ([int]::TryParse($raw, [ref]$asInt)) {
        return ($asInt -ne 0)
    }

    $asDouble = Convert-ToNullableDouble -Value $raw
    if ($null -ne $asDouble -and -not [double]::IsNaN([double]$asDouble) -and -not [double]::IsInfinity([double]$asDouble)) {
        return ([double]$asDouble -ne 0.0)
    }

    $asBool = $false
    if ([bool]::TryParse($raw, [ref]$asBool)) {
        return $asBool
    }

    if ($raw.Equals('yes', [System.StringComparison]::OrdinalIgnoreCase) -or
        $raw.Equals('y', [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    if ($raw.Equals('no', [System.StringComparison]::OrdinalIgnoreCase) -or
        $raw.Equals('n', [System.StringComparison]::OrdinalIgnoreCase)) {
        return $false
    }

    return $null
}

function Get-RowProcessName {
    param(
        [Parameter(Mandatory = $true)]$Row,
        [Parameter(Mandatory = $true)][hashtable]$ColumnMap
    )
    if ($ColumnMap.ContainsKey('ProcessName')) {
        $v = [string]$Row.($ColumnMap['ProcessName'])
        if (-not [string]::IsNullOrWhiteSpace($v)) { return $v.Trim() }
    }
    if ($ColumnMap.ContainsKey('Application')) {
        $v = [string]$Row.($ColumnMap['Application'])
        if (-not [string]::IsNullOrWhiteSpace($v)) { return $v.Trim() }
    }
    return $null
}

function Convert-ToProcessNameKey {
    param([AllowNull()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $text = $Value.Trim()
    try {
        $leaf = [System.IO.Path]::GetFileName($text)
    } catch {
        $leaf = $text
    }
    if ([string]::IsNullOrWhiteSpace($leaf)) { $leaf = $text }
    if ($leaf.EndsWith('.exe', [System.StringComparison]::OrdinalIgnoreCase)) {
        return $leaf.Substring(0, $leaf.Length - 4)
    }
    return $leaf
}

function Resolve-ColumnMap {
    param([Parameter(Mandatory = $true)][string[]]$PropertyNames)

    $lookup = @{}
    foreach ($name in $PropertyNames) {
        if (-not [string]::IsNullOrWhiteSpace($name)) {
            $lookup[$name.ToLowerInvariant()] = $name
        }
    }

    $wanted = @(
        'Application',
        'ProcessName',
        'ProcessID',
        'ProcessId',
        'SwapChainAddress',
        'PresentMode',
        'MsBetweenPresents',
        'MsBetweenDisplayChange'
    )

    $map = @{}
    foreach ($key in $wanted) {
        $lk = $key.ToLowerInvariant()
        if ($lookup.ContainsKey($lk)) {
            $map[$key] = $lookup[$lk]
        }
    }

    if (-not $map.ContainsKey('ProcessID') -and $map.ContainsKey('ProcessId')) {
        $map['ProcessID'] = $map['ProcessId']
    }

    # Dropped column aliases: prefer exact "Dropped", then "Dropped Frames", then "DroppedFrames".
    $droppedAliases = @('Dropped', 'Dropped Frames', 'DroppedFrames')
    foreach ($alias in $droppedAliases) {
        $lk = $alias.ToLowerInvariant()
        if ($lookup.ContainsKey($lk)) {
            $map['Dropped'] = $lookup[$lk]
            $map['DroppedActualColumn'] = $lookup[$lk]
            break
        }
    }

    return $map
}

function New-SwapchainBucket {
    param([Parameter(Mandatory = $true)][string]$Address)

    $item = New-Object System.Collections.Specialized.OrderedDictionary
    $item['swap_chain_address'] = $Address
    $item['row_count'] = 0
    $item['valid_ms_between_presents'] = 0
    $item['valid_ms_between_display_change'] = 0
    $item['parseable_dropped_count'] = 0
    $item['parseable_displayed_count'] = 0
    $item['dropped_unparseable_count'] = 0
    return $item
}

$warnings = New-Object System.Collections.Generic.List[string]

if ([string]::IsNullOrWhiteSpace($CsvPath)) {
    Write-ErrAndExit -Message 'CsvPath is required.'
}

$resolvedCsv = $null
try {
    $resolvedCsv = (Resolve-Path -LiteralPath $CsvPath).Path
} catch {
    Write-ErrAndExit -Message ("CsvPath not found: {0}" -f $CsvPath)
}

if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    if (Test-Path -LiteralPath $OutputPath) {
        Write-ErrAndExit -Message ("OutputPath already exists and will not be overwritten: {0}" -f $OutputPath)
    }
}

if ($PSBoundParameters.ContainsKey('TargetFps') -and $null -ne $TargetFps) {
    if ($TargetFps -le 0) {
        Write-ErrAndExit -Message 'TargetFps must be > 0 when specified.'
    }
}

if ($PSBoundParameters.ContainsKey('LongFrameThresholdMs') -and $null -ne $LongFrameThresholdMs) {
    if ($LongFrameThresholdMs -le 0) {
        Write-ErrAndExit -Message 'LongFrameThresholdMs must be > 0 when specified.'
    }
}

if (-not [string]::IsNullOrWhiteSpace($ProcessName)) {
    $ProcessName = $ProcessName.Trim()
}
$processNameMatchKey = Convert-ToProcessNameKey -Value $ProcessName

if (-not [string]::IsNullOrWhiteSpace($SwapChainAddress)) {
    $SwapChainAddress = $SwapChainAddress.Trim()
}

$effectiveTargetFps = $null
$frameBudgetMs = $null
$budgetSource = $null

if ($PSBoundParameters.ContainsKey('TargetFps') -and $null -ne $TargetFps) {
    $effectiveTargetFps = [double]$TargetFps
    $frameBudgetMs = 1000.0 / $effectiveTargetFps
    $budgetSource = 'TargetFps'
} elseif ($PSBoundParameters.ContainsKey('LongFrameThresholdMs') -and $null -ne $LongFrameThresholdMs) {
    $frameBudgetMs = $null
    $budgetSource = 'none_custom_threshold_only'
    $warnings.Add('TargetFps not set; >1.5x/>2x frame-budget ratios are omitted. LongFrameThresholdMs is used only as an absolute threshold.')
} else {
    $effectiveTargetFps = 60.0
    $frameBudgetMs = 1000.0 / $effectiveTargetFps
    $budgetSource = 'default_60fps'
    $warnings.Add('Neither TargetFps nor LongFrameThresholdMs was specified; using default TargetFps=60 for frame-budget ratios.')
}

$longThreshold = $null
if ($PSBoundParameters.ContainsKey('LongFrameThresholdMs') -and $null -ne $LongFrameThresholdMs) {
    $longThreshold = [double]$LongFrameThresholdMs
}

$rows = @(Import-Csv -LiteralPath $resolvedCsv)
if ($rows.Count -eq 0) {
    Write-ErrAndExit -Message ("CSV contains no data rows: {0}" -f $resolvedCsv)
}

$propertyNames = @($rows[0].PSObject.Properties.Name)
$columnMap = Resolve-ColumnMap -PropertyNames $propertyNames

if (-not $columnMap.ContainsKey('ProcessID')) {
    Write-ErrAndExit -Message 'Required column ProcessID/ProcessId is missing from CSV.'
}
if (-not $columnMap.ContainsKey('SwapChainAddress')) {
    Write-ErrAndExit -Message 'Required column SwapChainAddress is missing from CSV.'
}
if (-not $columnMap.ContainsKey('MsBetweenPresents')) {
    $warnings.Add('Column MsBetweenPresents is missing; present-interval metrics will be empty.')
}
if (-not $columnMap.ContainsKey('MsBetweenDisplayChange')) {
    $warnings.Add('Column MsBetweenDisplayChange is missing; display-change metrics will be empty.')
}
if (-not $columnMap.ContainsKey('PresentMode')) {
    $warnings.Add('Column PresentMode is missing; present-mode distribution will be empty.')
}

$droppedActualColumn = $null
if ($columnMap.ContainsKey('DroppedActualColumn')) {
    $droppedActualColumn = [string]$columnMap['DroppedActualColumn']
}
$droppedAvailable = -not [string]::IsNullOrWhiteSpace($droppedActualColumn)
if (-not $droppedAvailable) {
    $warnings.Add('No Dropped / Dropped Frames / DroppedFrames column found; dropped-frame statistics are unavailable.')
}

if (-not $columnMap.ContainsKey('ProcessName') -and -not $columnMap.ContainsKey('Application')) {
    if (-not [string]::IsNullOrWhiteSpace($ProcessName)) {
        Write-ErrAndExit -Message 'ProcessName filter was provided, but CSV has neither ProcessName nor Application column.'
    }
    $warnings.Add('Neither ProcessName nor Application column is present; process name metadata is unavailable.')
}

$processKeyCol = $columnMap['ProcessID']
$processGroups = @{}

foreach ($row in $rows) {
    $pidText = [string]$row.$processKeyCol
    $pidVal = 0
    if (-not [int]::TryParse($pidText, [ref]$pidVal)) {
        continue
    }
    $name = Get-RowProcessName -Row $row -ColumnMap $columnMap
    if (-not $processGroups.ContainsKey($pidVal)) {
        $bucket = New-Object System.Collections.Specialized.OrderedDictionary
        $bucket['process_id'] = $pidVal
        $bucket['process_name'] = $name
        $bucket['row_count'] = 0
        $processGroups[$pidVal] = $bucket
    }
    $processGroups[$pidVal]['row_count'] = [int]$processGroups[$pidVal]['row_count'] + 1
    if ([string]::IsNullOrWhiteSpace([string]$processGroups[$pidVal]['process_name']) -and -not [string]::IsNullOrWhiteSpace($name)) {
        $processGroups[$pidVal]['process_name'] = $name
    }
}

if ($processGroups.Count -eq 0) {
    Write-ErrAndExit -Message 'No rows with a parseable ProcessID were found.'
}

$selectedProcessId = $null
$selectedProcessName = $null
$hasProcessIdFilter = $PSBoundParameters.ContainsKey('ProcessId') -and $null -ne $ProcessId
$hasProcessNameFilter = -not [string]::IsNullOrWhiteSpace($ProcessName)

if ($hasProcessIdFilter -and $hasProcessNameFilter) {
    if (-not $processGroups.ContainsKey([int]$ProcessId)) {
        Write-ErrAndExit -Message ("ProcessId {0} not found in CSV." -f $ProcessId)
    }
    $candidateName = [string]$processGroups[[int]$ProcessId]['process_name']
    $candidateNameKey = Convert-ToProcessNameKey -Value $candidateName
    if ([string]::IsNullOrWhiteSpace($candidateNameKey) -or -not $candidateNameKey.Equals($processNameMatchKey, [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-ErrAndExit -Message ("ProcessId {0} does not match ProcessName filter '{1}' (observed '{2}')." -f $ProcessId, $ProcessName, $candidateName)
    }
    $selectedProcessId = [int]$ProcessId
    $selectedProcessName = $candidateName
} elseif ($hasProcessIdFilter) {
    if (-not $processGroups.ContainsKey([int]$ProcessId)) {
        Write-ErrAndExit -Message ("ProcessId {0} not found in CSV." -f $ProcessId)
    }
    $selectedProcessId = [int]$ProcessId
    $selectedProcessName = $processGroups[$selectedProcessId]['process_name']
} elseif ($hasProcessNameFilter) {
    $matches = @($processGroups.GetEnumerator() | Where-Object {
            $n = [string]$_.Value['process_name']
            $nKey = Convert-ToProcessNameKey -Value $n
            -not [string]::IsNullOrWhiteSpace($nKey) -and $nKey.Equals($processNameMatchKey, [System.StringComparison]::OrdinalIgnoreCase)
        })
    if ($matches.Count -eq 0) {
        Write-ErrAndExit -Message ("ProcessName '{0}' not found in CSV after executable leaf-name normalization." -f $ProcessName)
    }
    if ($matches.Count -gt 1) {
        $pidList = ($matches | ForEach-Object { $_.Key }) -join ', '
        Write-ErrAndExit -Message ("ProcessName '{0}' is ambiguous across ProcessId values: {1}. Specify -ProcessId." -f $ProcessName, $pidList)
    }
    $selectedProcessId = [int]$matches[0].Key
    $selectedProcessName = $matches[0].Value['process_name']
} else {
    if ($processGroups.Count -gt 1) {
        $pidList = ($processGroups.Keys | Sort-Object) -join ', '
        Write-ErrAndExit -Message ("CSV contains multiple processes (ProcessId: {0}). Specify -ProcessId or an executable -ProcessName." -f $pidList)
    }
    $only = @($processGroups.GetEnumerator())[0]
    $selectedProcessId = [int]$only.Key
    $selectedProcessName = $only.Value['process_name']
}

$processRows = @($rows | Where-Object {
        $pidVal = 0
        if ([int]::TryParse([string]$_.$processKeyCol, [ref]$pidVal)) {
            $pidVal -eq $selectedProcessId
        } else {
            $false
        }
    })

if ($processRows.Count -eq 0) {
    Write-ErrAndExit -Message ("No rows remain after filtering ProcessId {0}." -f $selectedProcessId)
}

$scCol = $columnMap['SwapChainAddress']
$mbpCol = $null
if ($columnMap.ContainsKey('MsBetweenPresents')) { $mbpCol = $columnMap['MsBetweenPresents'] }
$mbdCol = $null
if ($columnMap.ContainsKey('MsBetweenDisplayChange')) { $mbdCol = $columnMap['MsBetweenDisplayChange'] }
$droppedCol = $null
if ($droppedAvailable) { $droppedCol = $droppedActualColumn }

$swapchainStats = @{}
foreach ($row in $processRows) {
    $sc = [string]$row.$scCol
    if ([string]::IsNullOrWhiteSpace($sc)) { $sc = '(empty)' }
    if (-not $swapchainStats.ContainsKey($sc)) {
        $swapchainStats[$sc] = New-SwapchainBucket -Address $sc
    }
    $bucket = $swapchainStats[$sc]
    $bucket['row_count'] = [int]$bucket['row_count'] + 1

    if ($null -ne $mbpCol) {
        $tmpPos = New-Object System.Collections.Generic.List[double]
        $tmpQ = New-IntervalQuality
        Add-IntervalObservation -Quality $tmpQ -PositiveValues $tmpPos -RawValue $row.$mbpCol
        if ([int]$tmpQ['positive_count'] -gt 0) {
            $bucket['valid_ms_between_presents'] = [int]$bucket['valid_ms_between_presents'] + 1
        }
    }

    if ($null -ne $mbdCol) {
        $tmpPos = New-Object System.Collections.Generic.List[double]
        $tmpQ = New-IntervalQuality
        Add-IntervalObservation -Quality $tmpQ -PositiveValues $tmpPos -RawValue $row.$mbdCol
        if ([int]$tmpQ['positive_count'] -gt 0) {
            $bucket['valid_ms_between_display_change'] = [int]$bucket['valid_ms_between_display_change'] + 1
        }
    }

    if ($null -ne $droppedCol) {
        $flag = Convert-DroppedFlag -RawValue $row.$droppedCol
        if ($null -eq $flag) {
            $bucket['dropped_unparseable_count'] = [int]$bucket['dropped_unparseable_count'] + 1
        } elseif ($flag) {
            $bucket['parseable_dropped_count'] = [int]$bucket['parseable_dropped_count'] + 1
        } else {
            $bucket['parseable_displayed_count'] = [int]$bucket['parseable_displayed_count'] + 1
        }
    }
}

$scList = New-Object System.Collections.Generic.List[object]
foreach ($entry in $swapchainStats.GetEnumerator()) {
    [void]$scList.Add($entry.Value)
}

$hasAnyValidDisplay = $false
if ($null -ne $mbdCol) {
    foreach ($scItem in $scList) {
        if ([int]$scItem['valid_ms_between_display_change'] -gt 0) {
            $hasAnyValidDisplay = $true
            break
        }
    }
}

if ($hasAnyValidDisplay) {
    $allSwapChains = @($scList | Sort-Object -Property `
            @{ Expression = { [int]$_['valid_ms_between_display_change'] }; Descending = $true }, `
            @{ Expression = { [int]$_['valid_ms_between_presents'] }; Descending = $true }, `
            @{ Expression = { [int]$_['row_count'] }; Descending = $true }, `
            @{ Expression = { [string]$_['swap_chain_address'] }; Descending = $false })
} else {
    $allSwapChains = @($scList | Sort-Object -Property `
            @{ Expression = { [int]$_['valid_ms_between_presents'] }; Descending = $true }, `
            @{ Expression = { [int]$_['row_count'] }; Descending = $true }, `
            @{ Expression = { [string]$_['swap_chain_address'] }; Descending = $false })
}

$swapChainSelection = $null
$selectedSwapChain = $null
$swapChainSelectionNote = $null

if (-not [string]::IsNullOrWhiteSpace($SwapChainAddress)) {
    $exact = @($allSwapChains | Where-Object { [string]$_['swap_chain_address'].Equals($SwapChainAddress, [System.StringComparison]::OrdinalIgnoreCase) })
    if ($exact.Count -eq 0) {
        $known = ($allSwapChains | ForEach-Object { $_['swap_chain_address'] }) -join ', '
        Write-ErrAndExit -Message ("SwapChainAddress '{0}' not found for selected process. Known: {1}" -f $SwapChainAddress, $known)
    }
    $selectedSwapChain = [string]$exact[0]['swap_chain_address']
    $swapChainSelection = 'user_specified'
    $swapChainSelectionNote = 'User-specified SwapChainAddress.'
} else {
    if ($allSwapChains.Count -eq 0) {
        Write-ErrAndExit -Message 'No swapchain rows available after process filtering.'
    }
    $selectedSwapChain = [string]$allSwapChains[0]['swap_chain_address']
    if ($hasAnyValidDisplay) {
        $swapChainSelection = 'heuristic_most_valid_display_change_frames'
        $swapChainSelectionNote = 'Heuristic: MsBetweenDisplayChange present and at least one swapchain has finite >0 display-change intervals; selected the chain with the most valid display-change samples (tie-break: valid MsBetweenPresents, row_count, address). Not a guarantee of the primary displayed chain.'
        if ($allSwapChains.Count -gt 1) {
            $warnings.Add(('SwapChainAddress not specified; selected {0} by display-change heuristic. All swapchains are listed in selection.swap_chains.' -f $selectedSwapChain))
        } else {
            $warnings.Add(('SwapChainAddress not specified; only one swapchain present ({0}).' -f $selectedSwapChain))
        }
    } else {
        $swapChainSelection = 'heuristic_most_valid_present_frames'
        $swapChainSelectionNote = 'Heuristic: no valid (finite >0) MsBetweenDisplayChange samples across swapchains; fell back to most valid MsBetweenPresents samples (tie-break: row_count, address). Not a guarantee of the primary displayed chain.'
        if ($allSwapChains.Count -gt 1) {
            $warnings.Add(('SwapChainAddress not specified; selected {0} by presents heuristic (no valid display-change samples). All swapchains are listed in selection.swap_chains.' -f $selectedSwapChain))
        } else {
            $warnings.Add(('SwapChainAddress not specified; only one swapchain present ({0}).' -f $selectedSwapChain))
        }
    }
}

$selectedRows = @($processRows | Where-Object {
        $sc = [string]$_.$scCol
        if ([string]::IsNullOrWhiteSpace($sc)) { $sc = '(empty)' }
        $sc.Equals($selectedSwapChain, [System.StringComparison]::OrdinalIgnoreCase)
    })

if ($selectedRows.Count -eq 0) {
    Write-ErrAndExit -Message ("No rows remain after filtering SwapChainAddress '{0}'." -f $selectedSwapChain)
}

$mbpValues = New-Object System.Collections.Generic.List[double]
$mbdValues = New-Object System.Collections.Generic.List[double]
$mbpQuality = New-IntervalQuality
$mbdQuality = New-IntervalQuality
$presentModeCounts = @{}
$droppedCount = 0
$displayedCount = 0
$droppedParsed = 0
$droppedUnparseable = 0

foreach ($row in $selectedRows) {
    if ($null -ne $mbpCol) {
        Add-IntervalObservation -Quality $mbpQuality -PositiveValues $mbpValues -RawValue $row.$mbpCol
    }
    if ($null -ne $mbdCol) {
        Add-IntervalObservation -Quality $mbdQuality -PositiveValues $mbdValues -RawValue $row.$mbdCol
    }

    if ($columnMap.ContainsKey('PresentMode')) {
        $mode = [string]$row.($columnMap['PresentMode'])
        if ([string]::IsNullOrWhiteSpace($mode)) { $mode = '(empty)' }
        if (-not $presentModeCounts.ContainsKey($mode)) {
            $presentModeCounts[$mode] = 0
        }
        $presentModeCounts[$mode]++
    }

    if ($null -ne $droppedCol) {
        $flag = Convert-DroppedFlag -RawValue $row.$droppedCol
        if ($null -eq $flag) {
            $droppedUnparseable++
        } elseif ($flag) {
            $droppedParsed++
            $droppedCount++
        } else {
            $droppedParsed++
            $displayedCount++
        }
    }
}

$mbpStats = Get-MetricStats -Values $mbpValues.ToArray() -FrameBudgetMs $frameBudgetMs -LongThresholdMs $longThreshold -Quality $mbpQuality
$mbdStats = Get-MetricStats -Values $mbdValues.ToArray() -FrameBudgetMs $frameBudgetMs -LongThresholdMs $longThreshold -Quality $mbdQuality

if ($null -ne $mbpCol) {
    if ([int]$mbpQuality['zero_count'] -gt 0 -or [int]$mbpQuality['negative_count'] -gt 0 -or [int]$mbpQuality['unparseable_count'] -gt 0) {
        $warnings.Add(('MsBetweenPresents quality: positive={0}, zero={1}, negative={2}, unparseable={3}. Only finite >0 values are used for stats and swapchain heuristics.' -f `
                $mbpQuality['positive_count'], $mbpQuality['zero_count'], $mbpQuality['negative_count'], $mbpQuality['unparseable_count']))
    }
}
if ($null -ne $mbdCol) {
    if ([int]$mbdQuality['zero_count'] -gt 0 -or [int]$mbdQuality['negative_count'] -gt 0 -or [int]$mbdQuality['unparseable_count'] -gt 0) {
        $warnings.Add(('MsBetweenDisplayChange quality: positive={0}, zero={1}, negative={2}, unparseable={3}. Only finite >0 values are used for stats and swapchain heuristics.' -f `
                $mbdQuality['positive_count'], $mbdQuality['zero_count'], $mbdQuality['negative_count'], $mbdQuality['unparseable_count']))
    }
}

$presentModeDistribution = New-Object System.Collections.Specialized.OrderedDictionary
foreach ($entry in ($presentModeCounts.GetEnumerator() | Sort-Object Name)) {
    $presentModeDistribution[$entry.Key] = $entry.Value
}

$droppedCountOut = $null
$displayedCountOut = $null
$droppedRateOut = $null
$droppedUnparseableOut = $null
if ($droppedAvailable) {
    $droppedCountOut = $droppedCount
    $displayedCountOut = $displayedCount
    $droppedUnparseableOut = $droppedUnparseable
    if ($droppedParsed -gt 0) {
        $droppedRateOut = [Math]::Round(100.0 * $droppedCount / $droppedParsed, 4)
    } else {
        $warnings.Add(('Dropped column "{0}" present but no parseable values in the selected rows.' -f $droppedActualColumn))
    }
}

$processList = New-Object System.Collections.Generic.List[object]
foreach ($entry in ($processGroups.GetEnumerator() | Sort-Object Name)) {
    $procItem = New-Object System.Collections.Specialized.OrderedDictionary
    $procItem['process_id'] = $entry.Value['process_id']
    $procItem['process_name'] = $entry.Value['process_name']
    $procItem['row_count'] = $entry.Value['row_count']
    [void]$processList.Add($procItem)
}

$frameBudgetMsOut = $null
if ($null -ne $frameBudgetMs) {
    $frameBudgetMsOut = [Math]::Round([double]$frameBudgetMs, 6)
}

$inputInfo = New-Object System.Collections.Specialized.OrderedDictionary
$inputInfo['csv_path'] = $resolvedCsv
$inputInfo['row_count_total'] = $rows.Count
$inputInfo['row_count_process'] = $processRows.Count
$inputInfo['row_count_selected'] = $selectedRows.Count
$inputInfo['columns_present'] = @($propertyNames)

$selectionInfo = New-Object System.Collections.Specialized.OrderedDictionary
$selectionInfo['process_id'] = $selectedProcessId
$selectionInfo['process_name'] = $selectedProcessName
$selectionInfo['swap_chain_address'] = $selectedSwapChain
$selectionInfo['swap_chain_selection'] = $swapChainSelection
$selectionInfo['swap_chain_selection_note'] = $swapChainSelectionNote
$selectionInfo['swap_chains'] = @($allSwapChains)
if ($processList.Count -gt 0) {
    $selectionInfo['processes_in_capture'] = $processList.ToArray()
} else {
    $selectionInfo['processes_in_capture'] = @()
}

$frameBudgetInfo = New-Object System.Collections.Specialized.OrderedDictionary
$frameBudgetInfo['target_fps'] = $effectiveTargetFps
$frameBudgetInfo['frame_budget_ms'] = $frameBudgetMsOut
$frameBudgetInfo['long_frame_threshold_ms'] = $longThreshold
$frameBudgetInfo['source'] = $budgetSource

$metricsInfo = New-Object System.Collections.Specialized.OrderedDictionary
$metricsInfo['MsBetweenPresents'] = $mbpStats
$metricsInfo['MsBetweenDisplayChange'] = $mbdStats

$presentModeInfo = New-Object System.Collections.Specialized.OrderedDictionary
$presentModeInfo['distribution'] = $presentModeDistribution
$presentModeInfo['total_rows'] = $selectedRows.Count

$droppedInfo = New-Object System.Collections.Specialized.OrderedDictionary
$droppedInfo['available'] = [bool]$droppedAvailable
$droppedInfo['column_name'] = $droppedActualColumn
$droppedInfo['parsed_count'] = if ($droppedAvailable) { $droppedParsed } else { $null }
$droppedInfo['dropped_count'] = $droppedCountOut
$droppedInfo['displayed_count'] = $displayedCountOut
$droppedInfo['unparseable_count'] = $droppedUnparseableOut
$droppedInfo['dropped_rate_pct'] = $droppedRateOut

$result = New-Object System.Collections.Specialized.OrderedDictionary
$result['schema_version'] = '1.1.0'
$result['analysis_unit'] = 'single_capture'
$result['statistical_note'] = 'This report summarizes one PresentMon capture as a single experimental unit. Frame-level samples are descriptive only and are not treated as independent observations for statistical significance testing. Interval stats use only finite values strictly greater than zero.'
$result['input'] = $inputInfo
$result['selection'] = $selectionInfo
$result['frame_budget'] = $frameBudgetInfo
$result['metrics'] = $metricsInfo
$result['present_mode'] = $presentModeInfo
$result['dropped'] = $droppedInfo
$result['warnings'] = @($warnings.ToArray())

$json = $result | ConvertTo-Json -Depth 8

if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    $outParent = Split-Path -Parent $OutputPath
    if (-not [string]::IsNullOrWhiteSpace($outParent) -and -not (Test-Path -LiteralPath $outParent)) {
        New-Item -ItemType Directory -Path $outParent -Force | Out-Null
    }
    if (Test-Path -LiteralPath $OutputPath) {
        Write-ErrAndExit -Message ("OutputPath already exists and will not be overwritten: {0}" -f $OutputPath)
    }
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($OutputPath, $json, $utf8NoBom)
} else {
    Write-Output $json
}
