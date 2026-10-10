[CmdletBinding()]
param(
    [string]$InstallRoot,
    [string]$ConfigPath = (Join-Path $env:LOCALAPPDATA 'RedditSearch\config.json')
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'redlib_windows_common.ps1')
$InstallRoot = Resolve-RedlibInstallRoot -RequestedRoot $InstallRoot -ConfigPath $ConfigPath
$configPath = Join-Path $InstallRoot 'install.json'
$pidPath = Join-Path $InstallRoot 'redlib.pid'
if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { throw "Redlib installation record is missing: $configPath" }
$config = Get-Content -Raw -LiteralPath $configPath | ConvertFrom-Json
$expected = Assert-RedlibInstallRecord -Record $config -Port ([int]$config.port) -InstallRoot $InstallRoot
if (-not (Test-Path -LiteralPath $pidPath -PathType Leaf)) { '{"running":false,"stopped":false}'; exit 0 }
$pidText = (Get-Content -Raw -LiteralPath $pidPath).Trim()
if ($pidText -notmatch '^\d+$') { throw 'Redlib PID file is malformed; refusing to stop any process.' }
$pidValue = [int]$pidText
$process = Get-Process -Id $pidValue -ErrorAction SilentlyContinue
if (-not $process) {
    [System.IO.File]::Delete($pidPath)
    '{"running":false,"stopped":false}'
    exit 0
}
$actual = Get-RedlibProcessImage -Id $pidValue
if (-not [string]::Equals($actual, $expected, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to stop PID $pidValue because it runs '$actual', not '$expected'."
}
$listeners = @(Get-NetTCPConnection -LocalPort ([int]$config.port) -State Listen -ErrorAction SilentlyContinue)
if ($listeners.Count -gt 0) {
    if ($listeners.Count -ne 1) { throw 'Refusing to stop Redlib because its listener ownership is ambiguous.' }
    $listener = $listeners[0]
    $null = Assert-RedlibListenerOwnership -ExpectedExecutable $expected -ListenerPid ([int]$listener.OwningProcess) -RecordedPid $pidValue -LocalAddress ([string]$listener.LocalAddress) -ObservedExecutable (Get-RedlibProcessImage -Id ([int]$listener.OwningProcess))
}
Stop-Process -Id $pidValue
Wait-Process -Id $pidValue -Timeout 10 -ErrorAction SilentlyContinue
if (Get-Process -Id $pidValue -ErrorAction SilentlyContinue) { throw "Redlib PID $pidValue did not stop." }
[System.IO.File]::Delete($pidPath)
[ordered]@{ running = $false; stopped = $true; pid = $pidValue } | ConvertTo-Json
exit 0
