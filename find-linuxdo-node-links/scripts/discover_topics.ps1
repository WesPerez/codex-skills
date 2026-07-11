[CmdletBinding()]
param(
    [int]$LimitPerTag = 30,
    [string]$Proxy = "http://127.0.0.1:10808",
    [switch]$AllowInsecureTlsFallback
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)

$tags = [ordered]@{
    "free-node" = "https://linux.do/tag/2138-tag/2138"
    "subscription" = "https://linux.do/tag/193-tag/193"
    "airport" = "https://linux.do/tag/558-tag/558"
    "Clash" = "https://linux.do/tag/clash/1043"
    "V2Ray" = "https://linux.do/tag/v2ray/1570"
}

$seen = @{}
$results = [System.Collections.Generic.List[object]]::new()

foreach ($entry in $tags.GetEnumerator()) {
    $readerUrl = "https://r.jina.ai/http://$($entry.Value.Substring(8))"
    $curlArgs = @('-sSL', '--retry', '2', '--retry-all-errors', '--max-time', '30', $readerUrl)
    if ($Proxy) { $curlArgs = @('-x', $Proxy) + $curlArgs }
    $content = & curl.exe @curlArgs
    $exitCode = $LASTEXITCODE
    if ($exitCode -in @(35, 51, 60) -and $AllowInsecureTlsFallback) {
        Write-Warning "TLS verification failed for tag '$($entry.Key)'; retrying this tag only with explicit insecure fallback."
        $fallbackArgs = @('-k') + $curlArgs
        $content = & curl.exe @fallbackArgs
        $exitCode = $LASTEXITCODE
    }
    if ($exitCode -ne 0) {
        Write-Warning "Failed to read tag '$($entry.Key)' (curl exit $exitCode)."
        continue
    }

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
