[CmdletBinding()]
param([string]$ConfigPath = (Join-Path $env:LOCALAPPDATA 'RedditSearch\config.json'))

$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { throw "reddit-search has no saved Windows configuration: $ConfigPath" }
$config = Get-Content -Raw -LiteralPath $ConfigPath | ConvertFrom-Json
if ([int]$config.schemaVersion -ne 1) { throw 'Unsupported reddit-search Windows configuration schema.' }
if ([string]$config.mode -notin @('redlib', 'rss-only')) { throw 'Saved mode must be redlib or rss-only.' }
if (-not $config.skillDirectory) { throw 'Saved configuration has no skillDirectory.' }

if ($config.mode -eq 'redlib') {
    if (-not $config.redlibInstallRoot -or -not $config.baseUrl) { throw 'Redlib configuration is missing its install root or endpoint.' }
    if ([string]$config.expectedCommit -ne 'a4d36e954cf1bd64f209cd8868c5a29edc81b374') { throw 'Saved Redlib configuration has an unexpected commit pin.' }
    $port = [int]$config.port
    if ($port -lt 1024 -or $port -gt 65535) { throw 'Saved Redlib port is outside the supported range.' }
    if ([string]$config.baseUrl -ne "http://127.0.0.1:$port") { throw 'Saved Redlib endpoint must use IPv4 loopback.' }
    if (-not [bool]$config.installed -or -not [bool]$config.running -or -not [bool]$config.usable) { throw 'Saved Redlib mode lacks a successful install, run, and content-verification receipt.' }
} else {
    if ($config.redlibInstallRoot -or $config.baseUrl) { throw 'RSS-only configuration must not claim a Redlib endpoint.' }
    if ([bool]$config.redlibInstalled -or [bool]$config.running -or [bool]$config.usable) { throw 'RSS-only configuration must not claim Redlib is installed, running, or usable.' }
}

$config | Add-Member -NotePropertyName configPath -NotePropertyValue ([IO.Path]::GetFullPath($ConfigPath)) -Force
$config | ConvertTo-Json -Depth 8
