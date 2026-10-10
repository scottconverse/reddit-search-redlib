[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$InstallRoot,
    [Parameter(Mandatory = $true)][string]$ResultPath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'redlib_windows_common.ps1')

$result = [ordered]@{ success = $false; detail = $null; launcherPid = [int]$PID }
$process = $null
$pidPath = $null
$resultPathFull = [IO.Path]::GetFullPath($ResultPath)
try {
    $InstallRoot = [IO.Path]::GetFullPath($InstallRoot)
    $expectedLogRoot = [IO.Path]::GetFullPath((Join-Path $InstallRoot 'logs'))
    $logPrefix = $expectedLogRoot.TrimEnd('\') + '\'
    if (-not $resultPathFull.StartsWith($logPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Startup result path must be inside the owned Redlib logs directory.'
    }

    $recordPath = Join-Path $InstallRoot 'install.json'
    if (-not (Test-Path -LiteralPath $recordPath -PathType Leaf)) { throw "Redlib is not installed: $recordPath" }
    $config = Get-Content -Raw -LiteralPath $recordPath | ConvertFrom-Json
    $port = [int]$config.port
    $exe = Assert-RedlibInstallRecord -Record $config -Port $port -InstallRoot $InstallRoot
    $baseUrl = [string]$config.baseUrl
    $pidPath = Join-Path $InstallRoot 'redlib.pid'

    $listeners = @(Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue)
    if ($listeners.Count -gt 0) {
        throw "Port $port gained a listener before the detached Redlib launch; refusing to start a second process."
    }
    if (Test-Path -LiteralPath $pidPath -PathType Leaf) {
        $pidText = (Get-Content -Raw -LiteralPath $pidPath).Trim()
        if ($pidText -notmatch '^\d+$') { throw "Redlib PID file is malformed: $pidPath" }
        $staleProcess = Get-Process -Id ([int]$pidText) -ErrorAction SilentlyContinue
        if ($staleProcess) {
            $staleImage = Get-RedlibProcessImage -Id ([int]$pidText)
            if ([string]::Equals($staleImage, $exe, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Recorded Redlib PID $pidText became active before detached launch; preserving it."
            }
            throw "PID file points to a different executable: $staleImage"
        }
    }

    $null = New-Item -ItemType Directory -Force -Path $expectedLogRoot
    $logId = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '-' + [guid]::NewGuid().ToString('n')
    $stdinLog = Join-Path $expectedLogRoot "redlib-$logId.stdin.txt"
    $stdoutLog = Join-Path $expectedLogRoot "redlib-$logId.stdout.log"
    $stderrLog = Join-Path $expectedLogRoot "redlib-$logId.stderr.log"
    [IO.File]::WriteAllBytes($stdinLog, [byte[]]@())

    $serverEnvironment = [ordered]@{
        PORT = [string]$port
        REDLIB_ROBOTS_DISABLE_INDEXING = 'on'
        REDLIB_ENABLE_RSS = 'on'
        REDLIB_FULL_URL = $baseUrl
    }
    $savedEnvironment = @{}
    foreach ($name in $serverEnvironment.Keys) {
        $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
    }
    try {
        foreach ($name in $serverEnvironment.Keys) {
            [Environment]::SetEnvironmentVariable($name, [string]$serverEnvironment[$name], 'Process')
        }
        $process = Start-Process -FilePath $exe -ArgumentList '--address 127.0.0.1' -WorkingDirectory (Split-Path -Parent $exe) `
            -WindowStyle Hidden -PassThru -RedirectStandardInput $stdinLog -RedirectStandardOutput $stdoutLog -RedirectStandardError $stderrLog
    } finally {
        foreach ($name in $serverEnvironment.Keys) {
            [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name], 'Process')
        }
    }

    $process.Id | Set-Content -LiteralPath $pidPath -Encoding ascii
    $ready = $false
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        Start-Sleep -Milliseconds 500
        if ($process.HasExited) { break }
        $listeners = @(Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue)
        if ($listeners.Count -gt 0) {
            if ($listeners.Count -ne 1) { throw 'Redlib did not create exactly one listener.' }
            $listener = $listeners[0]
            $image = Get-RedlibProcessImage -Id ([int]$listener.OwningProcess)
            $null = Assert-RedlibListenerOwnership -ExpectedExecutable $exe -ListenerPid ([int]$listener.OwningProcess) `
                -RecordedPid ([int]$process.Id) -LocalAddress ([string]$listener.LocalAddress) -ObservedExecutable $image

            $info = $null
            try { $info = Invoke-RestMethod -Uri "$baseUrl/info.json" -TimeoutSec 2 } catch { }
            if ($info) {
                if (([string]$info.git_commit).Trim() -ne [string]$config.commit) { throw 'Running Redlib commit differs from the installation record.' }
                if ($info.config.REDLIB_ENABLE_RSS -ne 'on' -or $info.config.REDLIB_FULL_URL -ne $baseUrl) { throw 'Running Redlib configuration differs from the installation record.' }
                $ready = $true
                break
            }
        }
    }
    if (-not $ready) { throw 'Redlib started but did not become healthy on its verified loopback listener.' }

    $result = [ordered]@{
        success = $true
        launcherPid = [int]$PID
        running = $true
        reused = $false
        startedByThisCall = $true
        pid = [int]$process.Id
        baseUrl = $baseUrl
        info = $info
        stdoutLog = $stdoutLog
        stderrLog = $stderrLog
    }
} catch {
    $details = "$($_.Exception.Message) (at $($_.InvocationInfo.ScriptName):$($_.InvocationInfo.ScriptLineNumber); $($_.ScriptStackTrace))"
    if ($process -and -not $process.HasExited) {
        try {
            $image = Get-RedlibProcessImage -Id ([int]$process.Id)
            if ($image -and [string]::Equals($image, $exe, [StringComparison]::OrdinalIgnoreCase)) {
                $process.Kill()
                $process.WaitForExit(5000) | Out-Null
            }
        } catch { $details += " Cleanup detail: $($_.Exception.Message)" }
    }
    if ($pidPath -and (Test-Path -LiteralPath $pidPath) -and $process -and (Get-Content -Raw -LiteralPath $pidPath).Trim() -eq [string]$process.Id) {
        [IO.File]::Delete($pidPath)
    }
    $result = [ordered]@{ success = $false; detail = $details; launcherPid = [int]$PID }
}

$temporaryResult = $resultPathFull + '.' + [guid]::NewGuid().ToString('n') + '.tmp'
try {
    [IO.File]::WriteAllText($temporaryResult, ($result | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
    [IO.File]::Move($temporaryResult, $resultPathFull)
} catch {
    if (Test-Path -LiteralPath $temporaryResult) { [IO.File]::Delete($temporaryResult) }
    throw
}
if (-not [bool]$result.success) { exit 1 }
exit 0
