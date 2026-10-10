[CmdletBinding()]
param(
    [string]$InstallRoot,
    [string]$ConfigPath = (Join-Path $env:LOCALAPPDATA 'RedditSearch\config.json'),
    [string]$TestPath = '/r/foss'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'redlib_windows_common.ps1')
$InstallRoot = Resolve-RedlibInstallRoot -RequestedRoot $InstallRoot -ConfigPath $ConfigPath
if ($TestPath -notmatch '^/r/[A-Za-z0-9_]{1,21}/?$') { throw 'TestPath must be one local absolute subreddit route such as /r/foss.' }
$configPath = Join-Path $InstallRoot 'install.json'
$pidPath = Join-Path $InstallRoot 'redlib.pid'
$result = [ordered]@{
    installed = $false
    running = $false
    usable = $false
    baseUrl = $null
    expectedCommit = $script:RedlibPinnedCommit
    observedCommit = $null
    listener = $null
    listenerPid = $null
    processExecutable = $null
    contentStatus = $null
    postMarkers = 0
    commentLinks = 0
    failureCategory = $null
    detail = $null
}

try {
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { throw "Redlib installation record is missing: $configPath" }
    $config = Get-Content -Raw -LiteralPath $configPath | ConvertFrom-Json
    $port = [int]$config.port
    $exe = Assert-RedlibInstallRecord -Record $config -Port $port -InstallRoot $InstallRoot
    $result.installed = $true
    $result.baseUrl = [string]$config.baseUrl
    $result.expectedCommit = [string]$config.commit

    $listeners = @(Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue)
    if ($listeners.Count -ne 1) { throw "Expected one Redlib listener on port $port; found $($listeners.Count)." }
    $listener = $listeners[0]
    $recordedPid = 0
    if (Test-Path -LiteralPath $pidPath -PathType Leaf) {
        $pidText = (Get-Content -Raw -LiteralPath $pidPath).Trim()
        if ($pidText -notmatch '^\d+$') { throw 'Redlib PID file is malformed.' }
        $recordedPid = [int]$pidText
    }
    $image = Get-RedlibProcessImage -Id ([int]$listener.OwningProcess)
    $null = Assert-RedlibListenerOwnership -ExpectedExecutable $exe -ListenerPid ([int]$listener.OwningProcess) -RecordedPid $recordedPid -LocalAddress ([string]$listener.LocalAddress) -ObservedExecutable $image
    $result.listener = [string]$listener.LocalAddress
    $result.listenerPid = [int]$listener.OwningProcess
    $result.processExecutable = $image

    $info = Invoke-RestMethod -Uri "$($config.baseUrl)/info.json" -TimeoutSec 5
    $result.running = $true
    $result.observedCommit = ([string]$info.git_commit).Trim()
    if ($result.observedCommit -ne $result.expectedCommit) { throw 'Running Redlib commit differs from the installation record.' }
    if ($info.config.REDLIB_ENABLE_RSS -ne 'on') { throw 'Running Redlib does not have RSS enabled.' }
    if ($info.config.REDLIB_FULL_URL -ne $config.baseUrl) { throw 'Running Redlib FULL_URL differs from the installation record.' }

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

$result | ConvertTo-Json -Depth 8
if (-not $result.usable) { exit 2 }
exit 0
