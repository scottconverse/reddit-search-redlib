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
$logRoot = Join-Path $InstallRoot 'logs'
if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { throw "Redlib is not installed: $configPath" }
$config = Get-Content -Raw -LiteralPath $configPath | ConvertFrom-Json
$port = [int]$config.port
$exe = Assert-RedlibInstallRecord -Record $config -Port $port -InstallRoot $InstallRoot
$baseUrl = [string]$config.baseUrl
$recordedPid = 0
if (Test-Path -LiteralPath $pidPath -PathType Leaf) {
    $pidText = (Get-Content -Raw -LiteralPath $pidPath).Trim()
    if ($pidText -notmatch '^\d+$') { throw "Redlib PID file is malformed: $pidPath" }
    $recordedPid = [int]$pidText
}

$listeners = @(Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue)
if ($listeners.Count -gt 0) {
    if ($listeners.Count -ne 1) { throw "Port $port has multiple listeners; refusing to reuse an ambiguous process." }
    $listener = $listeners[0]
    $image = Get-RedlibProcessImage -Id ([int]$listener.OwningProcess)
    $null = Assert-RedlibListenerOwnership -ExpectedExecutable $exe -ListenerPid ([int]$listener.OwningProcess) -RecordedPid $recordedPid -LocalAddress ([string]$listener.LocalAddress) -ObservedExecutable $image
    $info = Invoke-RestMethod -Uri "$baseUrl/info.json" -TimeoutSec 5
    if (([string]$info.git_commit).Trim() -ne [string]$config.commit) { throw 'Running Redlib commit differs from the installation record.' }
    if ($info.config.REDLIB_ENABLE_RSS -ne 'on' -or $info.config.REDLIB_FULL_URL -ne $baseUrl) { throw 'Running Redlib configuration differs from the installation record.' }
    if (-not $recordedPid) { [string]$listener.OwningProcess | Set-Content -LiteralPath $pidPath -Encoding ascii }
    [ordered]@{ running = $true; reused = $true; startedByThisCall = $false; pid = [int]$listener.OwningProcess; baseUrl = $baseUrl; info = $info } | ConvertTo-Json -Depth 10
    exit 0
}

if ($recordedPid) {
    $recordedProcess = Get-Process -Id $recordedPid -ErrorAction SilentlyContinue
    if ($recordedProcess) {
        $recordedImage = Get-RedlibProcessImage -Id $recordedPid
        if ([string]::Equals($recordedImage, $exe, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Recorded Redlib PID $recordedPid is still running but has no listener on port $port; preserving it."
        }
        throw "PID file points to a different executable: $recordedImage"
    }
}

New-Item -ItemType Directory -Force -Path $logRoot | Out-Null
$startInfo = [Diagnostics.ProcessStartInfo]::new()
$startInfo.FileName = $exe
$startInfo.Arguments = '--address 127.0.0.1'
$startInfo.WorkingDirectory = Split-Path -Parent $exe
$startInfo.UseShellExecute = $false
$startInfo.CreateNoWindow = $true
$startInfo.Environment['PORT'] = [string]$port
$startInfo.Environment['REDLIB_ROBOTS_DISABLE_INDEXING'] = 'on'
$startInfo.Environment['REDLIB_ENABLE_RSS'] = 'on'
$startInfo.Environment['REDLIB_FULL_URL'] = $baseUrl
$process = [Diagnostics.Process]::Start($startInfo)
$process.Id | Set-Content -LiteralPath $pidPath -Encoding ascii

$ready = $false
try {
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        Start-Sleep -Milliseconds 500
        if ($process.HasExited) { break }
        try {
            $info = Invoke-RestMethod -Uri "$baseUrl/info.json" -TimeoutSec 2
            if (([string]$info.git_commit).Trim() -ne [string]$config.commit) { throw 'Running Redlib commit differs from the installation record.' }
            if ($info.config.REDLIB_ENABLE_RSS -ne 'on' -or $info.config.REDLIB_FULL_URL -ne $baseUrl) { throw 'Running Redlib configuration differs from the installation record.' }
            $listeners = @(Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue)
            if ($listeners.Count -ne 1) { throw 'Redlib did not create exactly one listener.' }
            $listener = $listeners[0]
            $image = Get-RedlibProcessImage -Id ([int]$listener.OwningProcess)
            $null = Assert-RedlibListenerOwnership -ExpectedExecutable $exe -ListenerPid ([int]$listener.OwningProcess) -RecordedPid $process.Id -LocalAddress ([string]$listener.LocalAddress) -ObservedExecutable $image
            $ready = $true
            break
        } catch {
            if ($_.Exception.Message -match 'differs from the installation record|listener|loopback|executable') { throw }
        }
    }
    if (-not $ready) { throw 'Redlib started but did not become healthy on loopback.' }
} catch {
    if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit(5000) | Out-Null }
    if ((Test-Path -LiteralPath $pidPath) -and (Get-Content -Raw -LiteralPath $pidPath).Trim() -eq [string]$process.Id) {
        [System.IO.File]::Delete($pidPath)
    }
    throw
}

[ordered]@{ running = $true; reused = $false; startedByThisCall = $true; pid = $process.Id; baseUrl = $baseUrl; info = $info } | ConvertTo-Json -Depth 10
exit 0
