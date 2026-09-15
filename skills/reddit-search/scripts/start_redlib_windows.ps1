[CmdletBinding()]
param([string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'RedditSearch\Redlib'))

$ErrorActionPreference = 'Stop'
$configPath = Join-Path $InstallRoot 'install.json'
$pidPath = Join-Path $InstallRoot 'redlib.pid'
$logRoot = Join-Path $InstallRoot 'logs'
if (-not (Test-Path -LiteralPath $configPath)) { throw "Redlib is not installed: $configPath" }
$config = Get-Content -Raw -LiteralPath $configPath | ConvertFrom-Json
$exe = [IO.Path]::GetFullPath([string]$config.executable)
if (-not (Test-Path -LiteralPath $exe)) { throw "Recorded executable is missing: $exe" }

if (Test-Path -LiteralPath $pidPath) {
    $oldPid = [int](Get-Content -Raw -LiteralPath $pidPath)
    $oldProcess = Get-Process -Id $oldPid -ErrorAction SilentlyContinue
    if ($oldProcess) {
        $actual = $oldProcess.MainModule.FileName
        if ([IO.Path]::GetFullPath($actual) -eq $exe) {
            Invoke-RestMethod -Uri "$($config.baseUrl)/info.json" -TimeoutSec 5 | ConvertTo-Json -Depth 8
            exit 0
        }
        throw "PID file points to a different executable: $actual"
    }
}

$occupied = Get-NetTCPConnection -LocalPort ([int]$config.port) -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
if ($occupied) { throw "Port $($config.port) is already owned by PID $($occupied.OwningProcess)." }

New-Item -ItemType Directory -Force -Path $logRoot | Out-Null
$startInfo = [Diagnostics.ProcessStartInfo]::new()
$startInfo.FileName = $exe
$startInfo.Arguments = '--address 127.0.0.1'
$startInfo.WorkingDirectory = Split-Path -Parent $exe
$startInfo.UseShellExecute = $false
$startInfo.CreateNoWindow = $true
$startInfo.Environment['PORT'] = [string]$config.port
$startInfo.Environment['REDLIB_ROBOTS_DISABLE_INDEXING'] = 'on'
$startInfo.Environment['REDLIB_ENABLE_RSS'] = 'on'
$startInfo.Environment['REDLIB_FULL_URL'] = [string]$config.baseUrl
$process = [Diagnostics.Process]::Start($startInfo)
$process.Id | Set-Content -LiteralPath $pidPath -Encoding ascii

$ready = $false
for ($attempt = 0; $attempt -lt 20; $attempt++) {
    Start-Sleep -Milliseconds 500
    if ($process.HasExited) { break }
    try {
        $info = Invoke-RestMethod -Uri "$($config.baseUrl)/info.json" -TimeoutSec 2
        $ready = $true
        break
    } catch {}
}
if (-not $ready) {
    if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit(5000) | Out-Null }
    Remove-Item -LiteralPath $pidPath -Force -ErrorAction SilentlyContinue
    throw 'Redlib started but did not become healthy on loopback.'
}

[ordered]@{ running = $true; pid = $process.Id; baseUrl = $config.baseUrl; info = $info } | ConvertTo-Json -Depth 10
exit 0
