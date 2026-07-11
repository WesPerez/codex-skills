[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string[]]$Url,
    [string]$Proxy = "http://127.0.0.1:10808"
)

$ErrorActionPreference = "Stop"

function Test-SensitiveUrl {
    param([string]$Value)

    $variants = [System.Collections.Generic.List[string]]::new()
    $current = $Value
    for ($i = 0; $i -lt 3; $i++) {
        if (-not $variants.Contains($current)) { $variants.Add($current) }
        try {
            $decoded = [System.Uri]::UnescapeDataString($current)
        }
        catch {
            return $true
        }
        if ($decoded -eq $current) { break }
        $current = $decoded
    }

    foreach ($candidate in $variants) {
        if ($candidate -match '(?i)(vmess|vless|trojan|hysteria2|hy2|ss)://') { return $true }
        if ($candidate -match '(?i)(?:[?&#;]|^)(token|auth|key|secret|password|passwd|uuid|access_token|api_key)=') { return $true }
        if ($candidate -match '(?i)/(?:[0-9a-f]{24,}|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})(?:/|$|[?.#])') { return $true }
        if ($candidate -match '/[A-Za-z0-9_-]{40,}(?:/|$|[?.#])') { return $true }

        $parsed = $null
        if ([System.Uri]::TryCreate($candidate, [System.UriKind]::Absolute, [ref]$parsed)) {
            if (-not [string]::IsNullOrEmpty($parsed.UserInfo)) { return $true }
        }
    }
    return $false
}

function Get-CurlClassification {
    param(
        [int]$ExitCode,
        [string]$Status
    )

    if ($ExitCode -eq 0) { return "http-response" }
    if ($ExitCode -eq 28) { return "timeout" }
    if ($ExitCode -in @(5, 7) -and $Proxy) { return "proxy-failure" }
    if ($ExitCode -in @(35, 51, 60)) { return "tls-failure" }
    if ($ExitCode -eq 6) { return "dns-failure" }
    if ($Status -eq "SKIPPED_SENSITIVE") { return "sensitive" }
    return "curl-error"
}

for ($index = 0; $index -lt $Url.Count; $index++) {
    $item = $Url[$index]
    if (Test-SensitiveUrl -Value $item) {
        [pscustomobject]@{
            InputIndex = $index
            Url = "[REDACTED_SENSITIVE_URL]"
            Status = "SKIPPED_SENSITIVE"
            FinalUrl = $null
            CurlExitCode = $null
            Classification = "sensitive"
            ContentType = $null
            ContentLength = $null
            LastModified = $null
            CheckedAt = (Get-Date).ToString('s')
        }
        continue
    }

    $curlArgs = @('-sSIL', '--max-time', '20', '--write-out', "`n__PROBE_META__%{http_code}`t%{url_effective}`n")
    if ($Proxy) { $curlArgs = @('-x', $Proxy) + $curlArgs }
    $rawOutput = & curl.exe @curlArgs $item 2>&1
    $curlExitCode = $LASTEXITCODE
    $headers = @($rawOutput | Where-Object { $_ -notmatch '^__PROBE_META__' })
    $meta = $rawOutput | Select-String '^__PROBE_META__(?<status>\d{3})\t(?<final>.*)$' | Select-Object -Last 1
    $statusMatch = $headers | Select-String '^HTTP/\S+\s+(\d+)' | Select-Object -Last 1
    $contentTypeMatch = $headers | Select-String '^(?i)Content-Type:\s*(.+)$' | Select-Object -Last 1
    $contentLengthMatch = $headers | Select-String '^(?i)Content-Length:\s*(.+)$' | Select-Object -Last 1
    $lastModifiedMatch = $headers | Select-String '^(?i)Last-Modified:\s*(.+)$' | Select-Object -Last 1

    $status = if ($meta) { $meta.Matches[0].Groups['status'].Value } elseif ($statusMatch) { $statusMatch.Matches[0].Groups[1].Value } else { "UNKNOWN" }
    [pscustomobject]@{
        InputIndex = $index
        Url = $item
        Status = $status
        FinalUrl = if ($meta) { $meta.Matches[0].Groups['final'].Value } else { $null }
        CurlExitCode = $curlExitCode
        Classification = Get-CurlClassification -ExitCode $curlExitCode -Status $status
        ContentType = if ($contentTypeMatch) { $contentTypeMatch.Matches[0].Groups[1].Value.Trim() } else { $null }
        ContentLength = if ($contentLengthMatch) { $contentLengthMatch.Matches[0].Groups[1].Value.Trim() } else { $null }
        LastModified = if ($lastModifiedMatch) { $lastModifiedMatch.Matches[0].Groups[1].Value.Trim() } else { $null }
        CheckedAt = (Get-Date).ToString('s')
    }
}
