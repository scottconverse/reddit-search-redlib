[CmdletBinding()]
param(
    [string]$SourceRoot,
    [string]$SkillDirectory = (Join-Path $env:USERPROFILE '.agents\skills\reddit-search'),
    [Alias('InstallRoot')][string]$RedlibInstallRoot,
    [string]$ConfigPath = (Join-Path $env:LOCALAPPDATA 'RedditSearch\config.json'),
    [ValidateRange(1024, 65535)][int]$Port = 18080,
    [switch]$RssOnly,
    [switch]$SkipSkillInstall
)

$portWasSpecified = $PSBoundParameters.ContainsKey('Port')

# This entrypoint intentionally parses and runs in Windows PowerShell 5.1.
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { throw 'This installer supports native Windows only.' }
if (-not $env:LOCALAPPDATA) { throw 'LOCALAPPDATA is unavailable.' }
if (-not $SourceRoot) { $SourceRoot = Split-Path -Parent $PSScriptRoot }
. (Join-Path $PSScriptRoot 'redlib_windows_common.ps1')
$script:SkillCoreFiles = @(
    'SKILL.md',
    'scripts\reddit_extract.py',
    'scripts\install_windows.ps1',
    'scripts\get_redlib_config.ps1',
    'scripts\redlib_windows_common.ps1',
    'scripts\setup_redlib_windows.ps1',
    'scripts\start_redlib_windows.ps1',
    'scripts\start_redlib_daemon_windows.ps1',
    'scripts\test_redlib_windows.ps1',
    'scripts\stop_redlib_windows.ps1',
    'references\access-and-schema.md',
    'references\windows-redlib.md'
)

function Find-CommandPath {
    param([string]$Name, [string[]]$Candidates = @())
    foreach ($candidate in $Candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) { return $candidate }
    }
    $command = Get-Command $Name -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return $command.Source }
    return $null
}

function Invoke-WingetInstall {
    param([string]$PackageId, [string]$Override)
    $winget = Find-CommandPath -Name 'winget.exe' -Candidates @((Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'))
    if (-not $winget) { throw "winget is unavailable; cannot install required package $PackageId automatically." }
    $args = @('install', '--id', $PackageId, '--exact', '--source', 'winget', '--disable-interactivity', '--accept-package-agreements', '--accept-source-agreements', '--silent')
    if ($Override) { $args += @('--override', $Override) }
    & $winget @args
    $code = $LASTEXITCODE
    if ($code -eq 3010 -or $code -eq 1641) { throw "Installing $PackageId requires a Windows restart before setup can continue." }
    if ($code -ne 0) { throw "winget could not install $PackageId (exit code $code). This can indicate canceled elevation or installer failure." }
}

function Find-PowerShell7 {
    return Find-CommandPath -Name 'pwsh.exe' -Candidates @('C:\Program Files\PowerShell\7\pwsh.exe', (Join-Path $env:LOCALAPPDATA 'Programs\PowerShell\7\pwsh.exe'), (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\pwsh.exe'))
}

function Relaunch-InPowerShell7 {
    $pwsh = Find-PowerShell7
    if (-not $pwsh) {
        Invoke-WingetInstall -PackageId 'Microsoft.PowerShell'
        $pwsh = Find-PowerShell7
    }
    if (-not $pwsh) { throw 'PowerShell 7 installation completed but pwsh.exe was not found. Open a new PowerShell window and rerun this command.' }
    $majorText = & $pwsh -NoLogo -NoProfile -Command '$PSVersionTable.PSVersion.Major' 2>$null | Select-Object -Last 1
    if ($LASTEXITCODE -ne 0 -or [int]$majorText -lt 7) { throw "The discovered pwsh.exe is not PowerShell 7 or newer: $pwsh" }
    $args = @('-NoLogo', '-NoProfile', '-File', $PSCommandPath, '-SourceRoot', $SourceRoot, '-SkillDirectory', $SkillDirectory, '-ConfigPath', $ConfigPath, '-Port', [string]$Port)
    if ($RedlibInstallRoot) { $args += @('-RedlibInstallRoot', $RedlibInstallRoot) }
    if ($RssOnly) { $args += '-RssOnly' }
    if ($SkipSkillInstall) { $args += '-SkipSkillInstall' }
    & $pwsh @args
    exit $LASTEXITCODE
}

function Get-PythonRuntime {
    $candidates = @()
    $py = Find-CommandPath -Name 'py.exe'
    $python = Find-CommandPath -Name 'python.exe'
    if ($py) { $candidates += [pscustomobject]@{ path = $py; launcher = $true } }
    if ($python) { $candidates += [pscustomobject]@{ path = $python; launcher = $false } }
    $localPythonRoot = Join-Path $env:LOCALAPPDATA 'Programs\Python'
    if (Test-Path -LiteralPath $localPythonRoot) {
        foreach ($directory in (Get-ChildItem -LiteralPath $localPythonRoot -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending)) {
            $candidatePath = Join-Path $directory.FullName 'python.exe'
            if (Test-Path -LiteralPath $candidatePath -PathType Leaf) { $candidates += [pscustomobject]@{ path = $candidatePath; launcher = $false } }
        }
    }
    foreach ($candidate in $candidates) {
        try {
            if ($candidate.launcher) { $version = (& $candidate.path -3 -c 'import sys;print("%d.%d" % sys.version_info[:2])' 2>$null | Select-Object -Last 1) }
            else { $version = (& $candidate.path -c 'import sys;print("%d.%d" % sys.version_info[:2])' 2>$null | Select-Object -Last 1) }
            if ($LASTEXITCODE -eq 0 -and $version -match '^(\d+)\.(\d+)$' -and ([int]$Matches[1] -gt 3 -or ([int]$Matches[1] -eq 3 -and [int]$Matches[2] -ge 10))) {
                return [pscustomobject]@{ path = $candidate.path; launcher = [bool]$candidate.launcher; version = $version }
            }
        } catch {}
    }
    return $null
}

function Ensure-Python {
    $runtime = Get-PythonRuntime
    if (-not $runtime) {
        Invoke-WingetInstall -PackageId 'Python.Python.3.12'
        $runtime = Get-PythonRuntime
    }
    if (-not $runtime) { throw 'Python 3.10 or newer is required; installation completed but no usable interpreter was found.' }
    return $runtime
}

function Ensure-Git {
    $git = Find-CommandPath -Name 'git.exe' -Candidates @('C:\Program Files\Git\cmd\git.exe', 'C:\Program Files\Git\bin\git.exe')
    if (-not $git) {
        Invoke-WingetInstall -PackageId 'Git.Git'
        $git = Find-CommandPath -Name 'git.exe' -Candidates @('C:\Program Files\Git\cmd\git.exe', 'C:\Program Files\Git\bin\git.exe')
        if ($git) { $env:PATH = (Split-Path -Parent $git) + ';' + $env:PATH }
    }
    if (-not $git) { throw 'Git for Windows is required; winget did not expose git.exe. Open a new PowerShell window and rerun.' }
    return $git
}

function Test-VisualCppBuildTools {
    $vswhere = 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path -LiteralPath $vswhere -PathType Leaf)) { return $null }
    $output = @(& $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath)
    $code = $LASTEXITCODE
    return Convert-VswhereOutputToPath -Output $output -ExitCode $code
}

function Ensure-BuildTools {
    $vsRoot = Test-VisualCppBuildTools
    if ($vsRoot) { return $vsRoot }
    $vswhere = 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe'
    $anyRoot = $null
    if (Test-Path -LiteralPath $vswhere -PathType Leaf) {
        $output = @(& $vswhere -latest -products '*' -property installationPath)
        $code = $LASTEXITCODE
        $anyRoot = Convert-VswhereOutputToPath -Output $output -ExitCode $code
    }
    $vsInstaller = 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vs_installer.exe'
    if ($anyRoot -and (Test-Path -LiteralPath $vsInstaller -PathType Leaf)) {
        & $vsInstaller modify --installPath $anyRoot --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended --quiet --wait --norestart
        $code = $LASTEXITCODE
        if ($code -eq 3010 -or $code -eq 1641) { throw 'Adding the Visual C++ workload requires a Windows restart.' }
        if ($code -ne 0) { throw "Visual Studio Installer could not add the C++ workload (exit code $code); elevation may have been canceled." }
    } else {
        $override = '--quiet --wait --norestart --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended'
        Invoke-WingetInstall -PackageId 'Microsoft.VisualStudio.2022.BuildTools' -Override $override
    }
    $vsRoot = Test-VisualCppBuildTools
    if (-not $vsRoot) { throw 'Visual C++ Build Tools installation did not expose the x64 C++ toolchain. Check Visual Studio Installer and rerun.' }
    return $vsRoot
}

function Ensure-RustMsvc {
    $cargo = Find-CommandPath -Name 'cargo.exe' -Candidates @((Join-Path $env:USERPROFILE '.cargo\bin\cargo.exe'))
    $rustc = Find-CommandPath -Name 'rustc.exe' -Candidates @((Join-Path $env:USERPROFILE '.cargo\bin\rustc.exe'))
    if (-not $cargo -or -not $rustc) {
        Invoke-WingetInstall -PackageId 'Rustlang.Rustup'
        $cargo = Find-CommandPath -Name 'cargo.exe' -Candidates @((Join-Path $env:USERPROFILE '.cargo\bin\cargo.exe'))
        $rustc = Find-CommandPath -Name 'rustc.exe' -Candidates @((Join-Path $env:USERPROFILE '.cargo\bin\rustc.exe'))
    }
    if (-not $cargo -or -not $rustc) { throw 'Rustup installation completed but cargo.exe or rustc.exe was not found. Open a new PowerShell window and rerun.' }
    $cargoBin = Join-Path $env:USERPROFILE '.cargo\bin'
    if ($env:PATH -notlike "*$cargoBin*") { $env:PATH = $cargoBin + ';' + $env:PATH }
    $rustup = Find-CommandPath -Name 'rustup.exe' -Candidates @((Join-Path $cargoBin 'rustup.exe'))
    $hostLine = (& $rustc -Vv | Select-String '^host:' | ForEach-Object { ($_ -split ':', 2)[1].Trim() })
    if ($LASTEXITCODE -ne 0 -or $hostLine -ne 'x86_64-pc-windows-msvc') {
        if (-not $rustup) { throw "Rust host must be x86_64-pc-windows-msvc; found '$hostLine', and rustup.exe cannot install the required toolchain." }
        & $rustup toolchain install stable-x86_64-pc-windows-msvc
        if ($LASTEXITCODE -ne 0) { throw 'Rustup could not install stable-x86_64-pc-windows-msvc.' }
        $env:RUSTUP_TOOLCHAIN = 'stable-x86_64-pc-windows-msvc'
    }
}

function Install-SkillFolder {
    param([string]$From, [string]$To)
    $source = [IO.Path]::GetFullPath($From).TrimEnd('\')
    $target = [IO.Path]::GetFullPath($To).TrimEnd('\')
    foreach ($required in $script:SkillCoreFiles) {
        if (-not (Test-Path -LiteralPath (Join-Path $source $required) -PathType Leaf)) { throw "Skill source is incomplete; missing $required under $source" }
    }
    if ([string]::Equals($source, $target, [StringComparison]::OrdinalIgnoreCase)) { return $target }
    $parent = Split-Path -Parent $target
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    $stage = $target + '.staging-' + [guid]::NewGuid().ToString('n')
    New-Item -ItemType Directory -Path $stage | Out-Null
    Get-ChildItem -LiteralPath $source -Force | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $stage -Recurse -Force }
    foreach ($required in $script:SkillCoreFiles) {
        if (-not (Test-Path -LiteralPath (Join-Path $stage $required) -PathType Leaf)) { throw "Staged skill failed integrity check: $required" }
    }

    $backup = $null
    if (Test-Path -LiteralPath $target) {
        $backupRoot = Join-Path $env:LOCALAPPDATA 'RedditSearch\backups'
        New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null
        $backup = Join-Path $backupRoot ('reddit-search-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '-' + [guid]::NewGuid().ToString('n'))
        Move-Item -LiteralPath $target -Destination $backup
    }
    try {
        Move-Item -LiteralPath $stage -Destination $target
    } catch {
        if ($backup -and -not (Test-Path -LiteralPath $target)) { Move-Item -LiteralPath $backup -Destination $target }
        throw
    }
    return $target
}

function Assert-InstalledSkillFolder {
    param([string]$Path)
    foreach ($required in $script:SkillCoreFiles) {
        if (-not (Test-Path -LiteralPath (Join-Path $Path $required) -PathType Leaf)) { throw "SkillDirectory is incomplete; missing $required under $Path" }
    }
    $null = Get-SkillVersion -ManifestPath (Join-Path $Path 'SKILL.md')
}

function Get-SkillVersion {
    param([string]$ManifestPath)
    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) { throw "Skill manifest is missing: $ManifestPath" }
    $manifest = Get-Content -Raw -LiteralPath $ManifestPath
    $match = [regex]::Match($manifest, '(?m)^metadata:\s*\r?\n\s+version:\s*["'']?(\d+\.\d+\.\d+)["'']?\s*$')
    if (-not $match.Success) { throw "Skill manifest has no semantic metadata.version field: $ManifestPath" }
    return $match.Groups[1].Value
}

function Test-ParserRuntime {
    $parser = Join-Path $SkillDirectory 'scripts\reddit_extract.py'
    if ($python.launcher) { $parserArgs = @('-3', $parser, 'url', 'rss-search', '--query', 'reddit-search-install-check') }
    else { $parserArgs = @($parser, 'url', 'rss-search', '--query', 'reddit-search-install-check') }
    $output = (& $python.path @parserArgs | Select-Object -Last 1)
    if ($LASTEXITCODE -ne 0 -or $output -notmatch '^https://www\.reddit\.com/search\.rss\?q=reddit-search-install-check') {
        throw "Python was found, but the installed reddit-search parser did not pass its local URL-build check ($($python.version))."
    }
}

function Read-SavedConfig {
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { return $null }
    $saved = Get-Content -Raw -LiteralPath $ConfigPath | ConvertFrom-Json
    if ([int]$saved.schemaVersion -ne 1 -or [string]$saved.mode -notin @('redlib', 'rss-only')) { throw "Saved reddit-search configuration is invalid: $ConfigPath" }
    return $saved
}

function Save-Receipt {
    param([object]$Receipt)
    $parent = Split-Path -Parent ([IO.Path]::GetFullPath($ConfigPath))
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    $temp = $ConfigPath + '.' + [guid]::NewGuid().ToString('n') + '.tmp'
    $backup = $null
    if (Test-Path -LiteralPath $ConfigPath -PathType Leaf) {
        $backup = $ConfigPath + '.backup-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '-' + [guid]::NewGuid().ToString('n')
        Copy-Item -LiteralPath $ConfigPath -Destination $backup
    }
    $Receipt['previousConfigBackup'] = $backup
    try {
        $Receipt | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $temp -Encoding utf8
        Move-Item -LiteralPath $temp -Destination $ConfigPath -Force
    } catch {
        if (Test-Path -LiteralPath $temp -PathType Leaf) { [System.IO.File]::Delete($temp) }
        throw
    }
}

$ConfigPath = [IO.Path]::GetFullPath($ConfigPath)
$SourceRoot = [IO.Path]::GetFullPath($SourceRoot)
$SkillDirectory = [IO.Path]::GetFullPath($SkillDirectory)
$savedConfig = Read-SavedConfig

if ($RedlibInstallRoot) {
    $installRoot = [IO.Path]::GetFullPath($RedlibInstallRoot)
} elseif ($savedConfig -and $savedConfig.mode -eq 'redlib' -and $savedConfig.redlibInstallRoot) {
    $installRoot = [IO.Path]::GetFullPath([string]$savedConfig.redlibInstallRoot)
} else {
    $legacyRoot = Join-Path $env:USERPROFILE 'TownReporterTools\Redlib'
    $defaultRoot = Join-Path $env:LOCALAPPDATA 'RedditSearch\Redlib'
    if (Test-Path -LiteralPath (Join-Path $legacyRoot 'install.json') -PathType Leaf) { $installRoot = $legacyRoot }
    else { $installRoot = $defaultRoot }
}

if (-not $RssOnly) {
    $installRoot = [IO.Path]::GetFullPath($installRoot)
    $hasInstallRecord = Test-Path -LiteralPath (Join-Path $installRoot 'install.json') -PathType Leaf
    if (-not $hasInstallRecord) {
        $localAppData = [IO.Path]::GetFullPath($env:LOCALAPPDATA).TrimEnd('\')
        $installPrefix = $localAppData + '\'
        if (-not $installRoot.StartsWith($installPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "A new Redlib build must be under LOCALAPPDATA: $installRoot"
        }
    }
}

# A recorded endpoint is authoritative on reuse unless the caller explicitly chose another port.
if (-not $RssOnly -and -not $portWasSpecified) {
    $recordPath = Join-Path $installRoot 'install.json'
    if (Test-Path -LiteralPath $recordPath -PathType Leaf) {
        $record = Get-Content -Raw -LiteralPath $recordPath | ConvertFrom-Json
        $recordPort = [int]$record.port
        if ($recordPort -lt 1024 -or $recordPort -gt 65535 -or [string]$record.baseUrl -ne "http://127.0.0.1:$recordPort") {
            throw "Recorded Redlib endpoint is invalid; expected a loopback port from 1024 through 65535: $recordPath"
        }
        $Port = $recordPort
    }
}

if ($PSVersionTable.PSVersion.Major -lt 7) { Relaunch-InPowerShell7 }
$python = Ensure-Python
if (-not $SkipSkillInstall) { $SkillDirectory = Install-SkillFolder -From $SourceRoot -To $SkillDirectory }
else { Assert-InstalledSkillFolder -Path $SkillDirectory }
Test-ParserRuntime
$skillVersion = Get-SkillVersion -ManifestPath (Join-Path $SkillDirectory 'SKILL.md')

if ($RssOnly) {
    $receipt = [ordered]@{
        schemaVersion = 1
        mode = 'rss-only'
        skillVersion = $skillVersion
        skillDirectory = $SkillDirectory
        skillInstalled = $true
        installed = $true
        redlibInstalled = $false
        running = $false
        usable = $false
        rssVerified = $false
        redlibInstallRoot = $null
        baseUrl = $null
        port = $null
        expectedCommit = $null
        verifiedAt = [DateTimeOffset]::UtcNow.ToString('o')
        failureCategory = $null
        python = $python.path
        pythonVersion = $python.version
        parserVerified = $true
        details = 'The skill is installed for RSS use. Redlib was explicitly omitted, and RSS network access was not live-tested by this installer.'
    }
    Save-Receipt -Receipt $receipt
    $receipt | ConvertTo-Json -Depth 8
    exit 0
}

$hasInstallRecord = Test-Path -LiteralPath (Join-Path $installRoot 'install.json') -PathType Leaf
if (-not $hasInstallRecord) {
    $null = Ensure-BuildTools
    Ensure-RustMsvc
}
$gitExe = Ensure-Git

$setupScript = Join-Path $PSScriptRoot 'setup_redlib_windows.ps1'
$setupOutput = & $setupScript -InstallRoot $installRoot -Port $Port
if ($LASTEXITCODE -ne 0) { throw 'Redlib provisioning failed; no success receipt was written.' }

$startedByThisCall = $false
try {
    $startOutput = & (Join-Path $PSScriptRoot 'start_redlib_windows.ps1') -InstallRoot $installRoot
    if ($LASTEXITCODE -ne 0) { throw 'Redlib start or ownership check failed; no success receipt was written.' }
    $startResult = (($startOutput | Out-String).Trim() | ConvertFrom-Json)
    $startedByThisCall = [bool]$startResult.startedByThisCall

    $testOutput = & (Join-Path $PSScriptRoot 'test_redlib_windows.ps1') -InstallRoot $installRoot
    $testExit = $LASTEXITCODE
    $testResult = (($testOutput | Out-String).Trim() | ConvertFrom-Json)
    if ($testExit -ne 0 -or -not [bool]$testResult.usable) {
        $category = if ($testResult.failureCategory) { [string]$testResult.failureCategory } else { 'upstream_failure' }
        $details = if ($testResult.detail) { [string]$testResult.detail } else { 'The Reddit-backed response did not pass validation.' }
        throw "Redlib usability gate failed ($category): $details. No success receipt was written."
    }
} catch {
    if ($startedByThisCall) {
        try { & (Join-Path $PSScriptRoot 'stop_redlib_windows.ps1') -InstallRoot $installRoot | Out-Null } catch {}
    }
    throw
}

$receipt = [ordered]@{
    schemaVersion = 1
    mode = 'redlib'
    skillVersion = $skillVersion
    skillDirectory = $SkillDirectory
    skillInstalled = $true
    installed = $true
    redlibInstalled = $true
    running = $true
    usable = $true
    rssVerified = $null
    redlibInstallRoot = $installRoot
    baseUrl = "http://127.0.0.1:$Port"
    port = $Port
    expectedCommit = 'a4d36e954cf1bd64f209cd8868c5a29edc81b374'
    observedCommit = [string]$testResult.observedCommit
    processId = [int]$testResult.listenerPid
    python = $python.path
    pythonVersion = $python.version
    parserVerified = $true
    verifiedAt = [DateTimeOffset]::UtcNow.ToString('o')
    failureCategory = $null
    details = "Redlib passed local ownership/config checks and a Reddit-backed content gate (HTTP $($testResult.contentStatus), $($testResult.postMarkers) posts, $($testResult.commentLinks) comment links)."
}
Save-Receipt -Receipt $receipt
$receipt | ConvertTo-Json -Depth 8
