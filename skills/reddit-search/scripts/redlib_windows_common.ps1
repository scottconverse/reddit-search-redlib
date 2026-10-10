$script:RedlibVersionId = 'a4d36e9'
$script:RedlibPinnedCommit = 'a4d36e954cf1bd64f209cd8868c5a29edc81b374'
$script:RedlibRepository = 'https://github.com/redlib-org/redlib.git'

function Convert-VswhereOutputToPath {
    param([object[]]$Output, [int]$ExitCode)
    if ($ExitCode -ne 0 -or -not $Output -or $Output.Count -eq 0) { return $null }
    $path = ($Output | Out-String).Trim()
    if (-not $path) { return $null }
    return $path
}

function Resolve-RedlibInstallRoot {
    param([string]$RequestedRoot, [string]$ConfigPath)
    if ($RequestedRoot) { return [IO.Path]::GetFullPath($RequestedRoot) }
    if (-not $ConfigPath) {
        if (-not $env:LOCALAPPDATA) { throw 'LOCALAPPDATA is unavailable and no Redlib install root was supplied.' }
        $ConfigPath = Join-Path $env:LOCALAPPDATA 'RedditSearch\config.json'
    }
    if (Test-Path -LiteralPath $ConfigPath -PathType Leaf) {
        try { $config = Get-Content -Raw -LiteralPath $ConfigPath | ConvertFrom-Json }
        catch { throw "Saved reddit-search configuration is unreadable: $ConfigPath" }
        if ([int]$config.schemaVersion -ne 1 -or [string]$config.mode -notin @('redlib', 'rss-only')) {
            throw "Saved reddit-search configuration has an unsupported schema or mode: $ConfigPath"
        }
        if ([string]$config.mode -eq 'rss-only') { throw 'The saved configuration is RSS-only and does not select a Redlib installation.' }
        $port = [int]$config.port
        if ([string]$config.expectedCommit -ne $script:RedlibPinnedCommit -or
            $port -lt 1024 -or $port -gt 65535 -or
            [string]$config.baseUrl -ne "http://127.0.0.1:$port" -or
            -not $config.redlibInstallRoot -or
            -not [bool]$config.installed -or -not [bool]$config.running -or -not [bool]$config.usable) {
            throw "Saved Redlib configuration does not contain a valid successful loopback receipt: $ConfigPath"
        }
        return [IO.Path]::GetFullPath([string]$config.redlibInstallRoot)
    }
    if (-not $env:LOCALAPPDATA) { throw 'LOCALAPPDATA is unavailable and no Redlib install root was supplied.' }
    return [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'RedditSearch\Redlib'))
}

function Assert-RedlibInstallRecord {
    param(
        [Parameter(Mandatory = $true)]$Record,
        [Parameter(Mandatory = $true)][int]$Port,
        [Parameter(Mandatory = $true)][string]$InstallRoot
    )

    if ($Port -lt 1024 -or $Port -gt 65535) { throw 'Redlib installation record port is outside the supported range.' }
    if ([int]$Record.schemaVersion -ne 2) { throw 'Unsupported Redlib installation record schema.' }
    if ([string]$Record.versionId -ne $script:RedlibVersionId) { throw 'Redlib installation version does not match the approved pin.' }
    if ([string]$Record.commit -ne $script:RedlibPinnedCommit) { throw 'Redlib installation record has the wrong pinned commit.' }
    if ([string]$Record.repository -ne $script:RedlibRepository) { throw 'Redlib installation record has an unexpected source repository.' }
    if ([int]$Record.port -ne $Port) { throw 'Redlib installation record port does not match the requested port.' }
    $expectedUrl = "http://127.0.0.1:$Port"
    if ([string]$Record.baseUrl -ne $expectedUrl) { throw 'Redlib installation record must use its IPv4 loopback endpoint.' }
    if (-not $Record.executable -or -not $Record.source) { throw 'Redlib installation record is missing executable or source provenance.' }

    $expectedExe = [IO.Path]::GetFullPath([string]$Record.executable)
    if (-not (Test-Path -LiteralPath $expectedExe -PathType Leaf)) { throw "Recorded Redlib executable is missing: $expectedExe" }
    $root = [IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
    $expectedRootExe = [IO.Path]::GetFullPath((Join-Path $root "versions\$($script:RedlibVersionId)\bin\redlib.exe"))
    $expectedSource = [IO.Path]::GetFullPath((Join-Path $root "buildsrc\$($script:RedlibVersionId)"))
    if (-not [string]::Equals($expectedExe, $expectedRootExe, [StringComparison]::OrdinalIgnoreCase)) { throw 'Recorded executable path does not belong to the supplied Redlib install root.' }
    $recordSource = [IO.Path]::GetFullPath([string]$Record.source)
    if (-not [string]::Equals($recordSource, $expectedSource, [StringComparison]::OrdinalIgnoreCase)) { throw 'Recorded source path does not belong to the supplied Redlib install root.' }
    if (-not (Test-Path -LiteralPath $recordSource -PathType Container)) { throw "Recorded Redlib source directory is missing: $recordSource" }
    return $expectedExe
}

function Assert-RedlibListenerOwnership {
    param(
        [Parameter(Mandatory = $true)][string]$ExpectedExecutable,
        [Parameter(Mandatory = $true)][int]$ListenerPid,
        [Parameter(Mandatory = $true)][string]$LocalAddress,
        [Parameter(Mandatory = $true)][string]$ObservedExecutable,
        [int]$RecordedPid = 0
    )

    if ($LocalAddress -ne '127.0.0.1') { throw "Redlib listener is not bound to 127.0.0.1: $LocalAddress" }
    if ($RecordedPid -and $RecordedPid -ne $ListenerPid) { throw 'Listener PID differs from the recorded Redlib PID.' }
    $expected = [IO.Path]::GetFullPath($ExpectedExecutable)
    $observed = [IO.Path]::GetFullPath($ObservedExecutable)
    if (-not [string]::Equals($expected, $observed, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Listener process is not the recorded Redlib executable: $observed"
    }
    return $true
}

function Get-RedlibProcessImage {
    param([Parameter(Mandatory = $true)][int]$Id)
    $process = Get-Process -Id $Id -ErrorAction Stop
    try { return [IO.Path]::GetFullPath($process.MainModule.FileName) }
    catch { throw "Cannot verify executable ownership for PID ${Id}: $($_.Exception.Message)" }
}

function Get-RedlibRecord {
    param([Parameter(Mandatory = $true)][string]$InstallRoot, [Parameter(Mandatory = $true)][int]$Port)
    $configPath = Join-Path $InstallRoot 'install.json'
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { throw "Redlib is not installed: $configPath" }
    $record = Get-Content -Raw -LiteralPath $configPath | ConvertFrom-Json
    $null = Assert-RedlibInstallRecord -Record $record -Port $Port -InstallRoot $InstallRoot
    return $record
}
