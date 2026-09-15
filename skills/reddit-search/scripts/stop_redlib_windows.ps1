[CmdletBinding()]
param([string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'RedditSearch\Redlib'))

$ErrorActionPreference = 'Stop'
$configPath = Join-Path $InstallRoot 'install.json'
$pidPath = Join-Path $InstallRoot 'redlib.pid'
if (-not (Test-Path -LiteralPath $configPath)) { throw "Redlib installation record is missing: $configPath" }
if (-not (Test-Path -LiteralPath $pidPath)) { '{"running":false,"stopped":false}'; exit 0 }

$config = Get-Content -Raw -LiteralPath $configPath | ConvertFrom-Json
$expected = [IO.Path]::GetFullPath([string]$config.executable)
$pidValue = [int](Get-Content -Raw -LiteralPath $pidPath)
$process = Get-Process -Id $pidValue -ErrorAction SilentlyContinue
if (-not $process) {
    Remove-Item -LiteralPath $pidPath -Force
    '{"running":false,"stopped":false}'
    exit 0
}
$actual = [IO.Path]::GetFullPath($process.MainModule.FileName)
if ($actual -ne $expected) { throw "Refusing to stop PID $pidValue because it runs '$actual', not '$expected'." }

Stop-Process -Id $pidValue
Wait-Process -Id $pidValue -Timeout 10 -ErrorAction SilentlyContinue
if (Get-Process -Id $pidValue -ErrorAction SilentlyContinue) { throw "Redlib PID $pidValue did not stop." }
Remove-Item -LiteralPath $pidPath -Force
[ordered]@{ running = $false; stopped = $true; pid = $pidValue } | ConvertTo-Json
exit 0
