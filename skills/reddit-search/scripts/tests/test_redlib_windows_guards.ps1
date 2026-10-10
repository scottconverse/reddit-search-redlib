[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$CommonScript)

$ErrorActionPreference = 'Stop'
. $CommonScript

function Assert-Throws {
    param([string]$Name, [scriptblock]$Action)
    try { & $Action } catch { return }
    throw "Expected guard to reject $Name."
}

$null = Assert-RedlibListenerOwnership -ExpectedExecutable 'C:\Redlib\redlib.exe' -ObservedExecutable 'C:\Redlib\redlib.exe' -ListenerPid 1234 -RecordedPid 1234 -LocalAddress '127.0.0.1'
Assert-Throws -Name 'a different process image' -Action { Assert-RedlibListenerOwnership -ExpectedExecutable 'C:\Redlib\redlib.exe' -ObservedExecutable 'C:\Other\other.exe' -ListenerPid 1234 -RecordedPid 1234 -LocalAddress '127.0.0.1' }
Assert-Throws -Name 'a different recorded PID' -Action { Assert-RedlibListenerOwnership -ExpectedExecutable 'C:\Redlib\redlib.exe' -ObservedExecutable 'C:\Redlib\redlib.exe' -ListenerPid 1234 -RecordedPid 9876 -LocalAddress '127.0.0.1' }
Assert-Throws -Name 'a non-loopback bind' -Action { Assert-RedlibListenerOwnership -ExpectedExecutable 'C:\Redlib\redlib.exe' -ObservedExecutable 'C:\Redlib\redlib.exe' -ListenerPid 1234 -RecordedPid 1234 -LocalAddress '0.0.0.0' }
if (Convert-VswhereOutputToPath -Output @() -ExitCode 0) { throw 'Empty vswhere output must trigger the normal missing-workload bootstrap path.' }
if ((Convert-VswhereOutputToPath -Output @('C:\VS Build Tools') -ExitCode 0) -ne 'C:\VS Build Tools') { throw 'Expected a valid vswhere path to be retained.' }

$scratchConfig = Join-Path $env:TEMP ('reddit-search-config-' + [guid]::NewGuid().ToString('n') + '.json')
try {
    $scratchReceipt = [ordered]@{
        schemaVersion = 1; mode = 'redlib'; expectedCommit = $script:RedlibPinnedCommit
        port = 18123; baseUrl = 'http://127.0.0.1:18123'; redlibInstallRoot = 'C:\Configured\Redlib'
        installed = $true; running = $true; usable = $true
    }
    [IO.File]::WriteAllText($scratchConfig, ($scratchReceipt | ConvertTo-Json))
    $resolved = Resolve-RedlibInstallRoot -RequestedRoot $null -ConfigPath $scratchConfig
    if ($resolved -ne 'C:\Configured\Redlib') { throw "Saved custom Redlib root did not resolve: $resolved" }
    $scratchReceipt.mode = 'rss-only'
    [IO.File]::WriteAllText($scratchConfig, ($scratchReceipt | ConvertTo-Json))
    Assert-Throws -Name 'RSS-only config selecting Redlib implicitly' -Action { Resolve-RedlibInstallRoot -RequestedRoot $null -ConfigPath $scratchConfig }
} finally {
    if (Test-Path -LiteralPath $scratchConfig) { [IO.File]::Delete($scratchConfig) }
}

$wrongPin = [pscustomobject]@{
    schemaVersion = 2; versionId = 'a4d36e9'; commit = '0000000000000000000000000000000000000000'
    repository = 'https://github.com/redlib-org/redlib.git'; port = 18080; baseUrl = 'http://127.0.0.1:18080'
    executable = 'C:\Redlib\versions\a4d36e9\bin\redlib.exe'; source = 'C:\Redlib\buildsrc\a4d36e9'
}
Assert-Throws -Name 'an unapproved pin' -Action { Assert-RedlibInstallRecord -Record $wrongPin -Port 18080 -InstallRoot 'C:\Redlib' }
Write-Output 'ownership, PID, loopback, pin, config discovery, and vswhere guards passed'
