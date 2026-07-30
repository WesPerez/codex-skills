[CmdletBinding()]
param(
    [int]$LimitPerTag = 30,
    [string]$Proxy = "http://127.0.0.1:10808",
    [string[]]$NetworkPaths = @(),
    [ValidateRange(1, 60)]
    [int]$RateLimitWaitSeconds = 30,
    [ValidateRange(0, 60)]
    [int]$RateLimitWaitBudgetSeconds = 60,
    [switch]$AllowInsecureTlsFallback
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)

function Get-RetryAfterSeconds {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    [int]$delta = 0
    if ([int]::TryParse($Value.Trim(), [ref]$delta)) {
        if ($delta -gt 0) { return $delta }
        return $null
    }
    [System.DateTimeOffset]$retryAt = [System.DateTimeOffset]::MinValue
    if (-not [System.DateTimeOffset]::TryParse($Value.Trim(), [ref]$retryAt)) { return $null }
    $seconds = [Math]::Ceiling(($retryAt.ToUniversalTime() - [System.DateTimeOffset]::UtcNow).TotalSeconds)
    if ($seconds -gt 0) { return [int]$seconds }
    return $null
}

function Invoke-ReaderRequest {
    param(
        [string]$Url,
        [string]$NetworkPath,
        [switch]$AllowInsecureFallback
    )

    $bodyPath = [System.IO.Path]::GetTempFileName()
    $headerPath = [System.IO.Path]::GetTempFileName()
    try {
        $curlArgs = @(
            '-sSL', '--max-time', '30', '--output', $bodyPath,
            '--dump-header', $headerPath, '--write-out', '%{http_code}'
        )
        if ($NetworkPath -ne 'direct') { $curlArgs = @('-x', $NetworkPath) + $curlArgs }
        $statusOutput = @(& curl.exe @curlArgs $Url 2>$null)
        $exitCode = $LASTEXITCODE
        if ($exitCode -in @(35, 51, 60) -and $AllowInsecureFallback) {
            $statusOutput = @(& curl.exe '-k' @curlArgs $Url 2>$null)
            $exitCode = $LASTEXITCODE
        }
        $status = (($statusOutput -join '').Trim() -replace '.*?(\d{3})$', '$1')
        if ($status -notmatch '^\d{3}$') { $status = 'UNKNOWN' }
        $headers = if (Test-Path -LiteralPath $headerPath) { @(Get-Content -LiteralPath $headerPath) } else { @() }
        $retryAfterMatch = $headers | Select-String '^(?i)Retry-After:\s*(.+)$' | Select-Object -Last 1
        $content = if (Test-Path -LiteralPath $bodyPath) {
            [System.IO.File]::ReadAllText($bodyPath, [System.Text.Encoding]::UTF8)
        } else { '' }
        [pscustomobject]@{
            Status = $status
            ExitCode = $exitCode
            Content = $content
            RetryAfter = if ($retryAfterMatch) { $retryAfterMatch.Matches[0].Groups[1].Value.Trim() } else { $null }
            RateLimited = ($status -eq '429' -or $content -match '(?im)^Warning:\s*Target URL returned error 429\b|You(?:''|\u2019)ve performed this action too many times, please try again later\.')
        }
    }
    finally {
        Remove-Item -LiteralPath $bodyPath, $headerPath -Force -ErrorAction SilentlyContinue
    }
}

$tags = [ordered]@{
    "free-node" = "https://linux.do/tag/2138-tag/2138"
    "subscription" = "https://linux.do/tag/193-tag/193"
    "airport" = "https://linux.do/tag/558-tag/558"
    "Clash" = "https://linux.do/tag/clash/1043"
    "V2Ray" = "https://linux.do/tag/v2ray/1570"
}

$seen = @{}
$results = [System.Collections.Generic.List[object]]::new()
$paths = [System.Collections.Generic.List[string]]::new()
foreach ($item in $(if ($NetworkPaths.Count -gt 0) { $NetworkPaths } else { @($Proxy, 'direct') })) {
    $value = if ([string]::IsNullOrWhiteSpace($item)) { 'direct' } else { $item.Trim() }
    if ($value -ne 'direct') {
        $parsed = $null
        if (
            -not [System.Uri]::TryCreate($value, [System.UriKind]::Absolute, [ref]$parsed) -or
            $parsed.Scheme -notin @('http', 'socks5h') -or
            -not [string]::IsNullOrEmpty($parsed.UserInfo) -or
            ($parsed.AbsolutePath -notin @('', '/')) -or
            -not [string]::IsNullOrEmpty($parsed.Query) -or
            -not [string]::IsNullOrEmpty($parsed.Fragment)
        ) {
            throw "Network paths must be direct or credential-free HTTP/SOCKS5H proxy URLs."
        }
    }
    if (-not $paths.Contains($value)) { $paths.Add($value) }
}
if ($paths.Count -lt 1 -or $paths.Count -gt 3) {
    throw "Anonymous network path budget must contain one to three unique paths."
}
$activePathIndex = 0
$waitSpent = 0
$stopDiscovery = $false

foreach ($entry in $tags.GetEnumerator()) {
    if ($stopDiscovery) { break }
    $readerUrl = "https://r.jina.ai/http://$($entry.Value.Substring(8))"
    $response = $null
    $loadedPath = $null
    $hardFailure = $false
    $pathOrder = @($activePathIndex) + @(0..($paths.Count - 1) | Where-Object { $_ -ne $activePathIndex })
    foreach ($pathIndex in $pathOrder) {
        $samePathWaits = 0
        while ($true) {
            $response = Invoke-ReaderRequest -Url $readerUrl -NetworkPath $paths[$pathIndex] -AllowInsecureFallback:$AllowInsecureTlsFallback
            if ($response.ExitCode -eq 0 -and $response.Status -match '^2\d\d$' -and -not $response.RateLimited) {
                $loadedPath = $paths[$pathIndex]
                $activePathIndex = $pathIndex
                break
            }
            if (-not $response.RateLimited) {
                Write-Warning "Failed to read tag '$($entry.Key)' on path $pathIndex (curl $($response.ExitCode), HTTP $($response.Status))."
                if ($response.Status -in @('400', '401', '404', '410')) {
                    $hardFailure = $true
                }
                break
            }

            $retryAfter = Get-RetryAfterSeconds -Value $response.RetryAfter
            $hasTrustedRetryAfter = $null -ne $retryAfter
            $waitFor = if ($hasTrustedRetryAfter) { [int]$retryAfter } else { $RateLimitWaitSeconds }
            $remaining = $RateLimitWaitBudgetSeconds - $waitSpent
            if ($hasTrustedRetryAfter -and $waitFor -gt $remaining) {
                Write-Warning "Tag '$($entry.Key)' returned Retry-After $waitFor seconds, beyond the remaining $remaining-second discovery budget; retaining collected candidates for a later run."
                $stopDiscovery = $true
                break
            }
            if ($hasTrustedRetryAfter -and $samePathWaits -ge 2) {
                Write-Warning "Tag '$($entry.Key)' remained rate limited with Retry-After on the same path; retaining collected candidates for a later run."
                $stopDiscovery = $true
                break
            }
            if ($samePathWaits -ge 2 -or $waitFor -gt $remaining) { break }
            Write-Warning "Tag '$($entry.Key)' was rate limited on path $pathIndex; waiting $waitFor seconds on the same path before retrying."
            Start-Sleep -Seconds $waitFor
            $waitSpent += $waitFor
            $samePathWaits++
        }
        if ($loadedPath -or $stopDiscovery -or $hardFailure) { break }
        if ($pathIndex -ne $pathOrder[-1]) {
            Write-Warning "Tag '$($entry.Key)' remained rate limited or unavailable after bounded same-path retries; trying another anonymous path."
        }
    }
    if ($stopDiscovery) { break }
    if ($hardFailure) { continue }
    if (-not $loadedPath) {
        Write-Warning "Failed to read tag '$($entry.Key)' after $($paths.Count) bounded network paths."
        continue
    }
    $content = $response.Content

    $matches = [regex]::Matches($content, '\[(?<title>[^\]\r\n]+)\]\(https?://linux\.do/t/topic/(?<id>\d+)(?:/\d+)?\)')
    $count = 0
    foreach ($match in $matches) {
        if ($count -ge $LimitPerTag) { break }
        $id = $match.Groups['id'].Value
        $title = $match.Groups['title'].Value.Trim()
        if ($title -match '^\d+(?:[hd]|d ago)?$' -or $title.Length -lt 3) { continue }
        if ($seen.ContainsKey($id)) { continue }

        $seen[$id] = $true
        $count++
        $results.Add([pscustomobject]@{
            Tag = $entry.Key
            TopicId = $id
            Title = $title
            Url = "https://linux.do/t/topic/$id"
        })
    }
}

$sorted = $results | Sort-Object {[int]$_.TopicId} -Descending
foreach ($result in $sorted) {
    Write-Output ("[{0}] {1}" -f $result.Tag, $result.Title)
    Write-Output $result.Url
    Write-Output ""
}

Write-Host "Candidates only. Read each original topic before judging availability." -ForegroundColor Yellow
