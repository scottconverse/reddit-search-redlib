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

$null = New-Item -ItemType Directory -Force -Path $logRoot
$launchId = [guid]::NewGuid().ToString('n')
$resultPath = Join-Path $logRoot "redlib-launch-$launchId.json"
$daemonScript = Join-Path $PSScriptRoot 'start_redlib_daemon_windows.ps1'
$pwsh = Join-Path $PSHOME 'pwsh.exe'
if (-not (Test-Path -LiteralPath $daemonScript -PathType Leaf)) { throw "Detached Redlib launch helper is missing: $daemonScript" }
if (-not (Test-Path -LiteralPath $pwsh -PathType Leaf)) { throw "PowerShell 7 executable is missing: $pwsh" }
$installRootFull = [IO.Path]::GetFullPath($InstallRoot)
$installRootArgument = $installRootFull.TrimEnd([char[]]@('\', '/'))
$installRootVolume = [IO.Path]::GetPathRoot($installRootFull).TrimEnd([char[]]@('\', '/'))
if ([string]::Equals($installRootArgument, $installRootVolume, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'A drive root cannot be used as the Redlib installation root.'
}

$helperArguments = @(
    '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $daemonScript + '"'),
    '-InstallRoot', ('"' + $installRootArgument + '"'), '-ResultPath', ('"' + $resultPath + '"')
)
$helper = Start-Process -FilePath $pwsh -ArgumentList $helperArguments -WorkingDirectory $InstallRoot -WindowStyle Hidden -Verb Open -PassThru
if (-not $helper.WaitForExit(60000)) {
    throw "Detached Redlib launch helper exceeded 60 seconds (PID $($helper.Id)); it was left running to finish its bounded health check and cleanup safely."
}
if (-not (Test-Path -LiteralPath $resultPath -PathType Leaf)) {
    throw "Detached Redlib launch helper exited with code $($helper.ExitCode) without writing a result. See logs under $logRoot."
}
$launchResult = Get-Content -Raw -LiteralPath $resultPath | ConvertFrom-Json
if (-not [bool]$launchResult.success) { throw [string]$launchResult.detail }
if ($helper.ExitCode -ne 0) { throw "Detached Redlib launch helper exited unexpectedly with code $($helper.ExitCode)." }
$stillRunningHelper = Get-Process -Id ([int]$launchResult.launcherPid) -ErrorAction SilentlyContinue
if ($stillRunningHelper) { throw "Detached Redlib launch helper PID $($launchResult.launcherPid) is still running after its result was written." }
[System.IO.File]::Delete($resultPath)

[ordered]@{
    running = [bool]$launchResult.running
    reused = [bool]$launchResult.reused
    startedByThisCall = [bool]$launchResult.startedByThisCall
    daemonExited = $true
    pid = [int]$launchResult.pid
    baseUrl = [string]$launchResult.baseUrl
    info = $launchResult.info
    stdoutLog = [string]$launchResult.stdoutLog
    stderrLog = [string]$launchResult.stderrLog
} | ConvertTo-Json -Depth 10
exit 0
