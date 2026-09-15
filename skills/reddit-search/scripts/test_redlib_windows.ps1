[CmdletBinding()]
param(
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'RedditSearch\Redlib'),
    [string]$TestPath = '/r/foss'
)

$ErrorActionPreference = 'Stop'
$configPath = Join-Path $InstallRoot 'install.json'
$pidPath = Join-Path $InstallRoot 'redlib.pid'
if (-not (Test-Path -LiteralPath $configPath)) { throw "Redlib installation record is missing: $configPath" }
$config = Get-Content -Raw -LiteralPath $configPath | ConvertFrom-Json
$result = [ordered]@{
    installed = $true
    running = $false
    usable = $false
    baseUrl = $config.baseUrl
    expectedCommit = $config.commit
    observedCommit = $null
    listener = $null
    contentStatus = $null
    postMarkers = 0
    commentLinks = 0
    failureCategory = $null
    detail = $null
}

try {
    $info = Invoke-RestMethod -Uri "$($config.baseUrl)/info.json" -TimeoutSec 5
    $result.running = $true
    $result.observedCommit = ([string]$info.git_commit).Trim()
    if ($result.observedCommit -ne $result.expectedCommit) { throw 'Running Redlib commit differs from the installation record.' }
    if ($info.config.REDLIB_ENABLE_RSS -ne 'on') { throw 'Running Redlib does not have RSS enabled.' }
    if ($info.config.REDLIB_FULL_URL -ne $config.baseUrl) { throw 'Running Redlib FULL_URL differs from the installation record.' }

    $listener = Get-NetTCPConnection -LocalPort ([int]$config.port) -State Listen | Select-Object -First 1
    $result.listener = $listener.LocalAddress
    if ($listener.LocalAddress -ne '127.0.0.1') { throw "Redlib is not loopback-only: $($listener.LocalAddress)" }
    if (Test-Path -LiteralPath $pidPath) {
        $recordedPid = [int](Get-Content -Raw -LiteralPath $pidPath)
        if ($listener.OwningProcess -ne $recordedPid) { throw 'Listener PID differs from the recorded Redlib PID.' }
    }

    try {
        $page = Invoke-WebRequest -Uri "$($config.baseUrl)$TestPath" -TimeoutSec 20 -SkipHttpErrorCheck -Headers @{'User-Agent'='reddit-search-redlib-verifier/1.0'}
        $result.contentStatus = [int]$page.StatusCode
        $responseBody = [string]$page.Content
        if ($result.contentStatus -eq 200) {
            $result.postMarkers = ([regex]::Matches($responseBody, 'class="post(?: |")')).Count
            $result.commentLinks = ([regex]::Matches($responseBody, 'href="[^"]*/comments/[^"]+"')).Count
            if ($page.Headers.'Content-Type' -notmatch 'text/html' -or $result.postMarkers -lt 1 -or $result.commentLinks -lt 1) {
                $result.failureCategory = 'parse_failure'
                $result.detail = 'Content response did not contain the expected Redlib post and comment-link structure.'
            } else {
                $result.usable = $true
            }
        } elseif ($responseBody -match 'Failed to parse page JSON data|Couldn.t send request to Reddit|Rate limit check failed') {
            $result.failureCategory = 'upstream_failure'
            $result.detail = (($responseBody -replace '<[^>]+>', ' ') -replace '\s+', ' ').Trim()
        } else {
            $result.failureCategory = switch ($result.contentStatus) {
                403 { 'forbidden_or_challenged' }
                429 { 'rate_limited' }
                { $_ -ge 500 } { 'upstream_failure' }
                404 { 'not_found' }
                default { 'transport_failure' }
            }
            $result.detail = "Unexpected HTTP status $($result.contentStatus)."
        }
    } catch {
        $result.failureCategory = 'transport_failure'
        $result.detail = $_.Exception.Message
    }
} catch {
    if (-not $result.failureCategory) { $result.failureCategory = 'local_health_failure' }
    $result.detail = $_.Exception.Message
}

$result | ConvertTo-Json
if (-not $result.usable) { exit 2 }
exit 0
