[CmdletBinding()]
param(
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'RedditSearch\Redlib'),
    [ValidateRange(1024, 65535)][int]$Port = 18080,
    [switch]$SkipPrerequisiteInstall,
    [switch]$Start
)

$ErrorActionPreference = 'Stop'
$portWasSpecified = $PSBoundParameters.ContainsKey('Port')
. (Join-Path $PSScriptRoot 'redlib_windows_common.ps1')
$VersionId = 'a4d36e9'
$PinnedRef = 'main'
$PinnedCommit = 'a4d36e954cf1bd64f209cd8868c5a29edc81b374'
$Repository = 'https://github.com/redlib-org/redlib.git'
$NasmUrl = 'https://www.nasm.us/pub/nasm/releasebuilds/3.02/win64/nasm-3.02-win64.zip'
$NasmSha256 = '161D0BFAFF53C2F9E9F3E69FD0672323EBABAFD1268976A5CEC11BE92A19AEE7'

if ($env:OS -ne 'Windows_NT') { throw 'This installer supports native Windows only.' }
if (-not $env:LOCALAPPDATA) { throw 'LOCALAPPDATA is unavailable.' }
$InstallRoot = [IO.Path]::GetFullPath($InstallRoot)
$versionRoot = Join-Path $InstallRoot "versions\$VersionId"
$sourceRoot = Join-Path $InstallRoot "buildsrc\$VersionId"
$targetRoot = Join-Path $InstallRoot "target\$VersionId"
$installedExe = Join-Path $versionRoot 'bin\redlib.exe'
$configPath = Join-Path $InstallRoot 'install.json'

function Find-Tool {
    param([string]$Name, [string[]]$Candidates = @())
    foreach ($candidate in $Candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) { return $candidate }
    }
    $found = Get-Command $Name -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) { return $found.Source }
    return $null
}

function Assert-ExistingSourcePin {
    param([object]$Record, [string]$GitExe)
    $recordSource = [IO.Path]::GetFullPath([string]$Record.source)
    if (-not (Test-Path -LiteralPath (Join-Path $recordSource '.git'))) { throw "Recorded Redlib source checkout is missing: $recordSource" }
    $origin = (& $GitExe -C $recordSource remote get-url origin).Trim()
    if ($LASTEXITCODE -ne 0 -or $origin -ne $Repository) { throw "Unexpected Redlib source origin: $origin" }
    $commit = (& $GitExe -C $recordSource rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or $commit -ne $PinnedCommit) { throw "Recorded Redlib source is not pinned to $PinnedCommit; found '$commit'." }
}

function Start-And-Verify {
    $startedByThisCall = $false
    try {
        $startOutput = & (Join-Path $PSScriptRoot 'start_redlib_windows.ps1') -InstallRoot $InstallRoot
        if ($LASTEXITCODE -ne 0) { throw 'Redlib start failed.' }
        $startResult = (($startOutput | Out-String).Trim() | ConvertFrom-Json)
        $startedByThisCall = [bool]$startResult.startedByThisCall
        $testOutput = & (Join-Path $PSScriptRoot 'test_redlib_windows.ps1') -InstallRoot $InstallRoot
        if ($LASTEXITCODE -ne 0) {
            if ($startedByThisCall) { & (Join-Path $PSScriptRoot 'stop_redlib_windows.ps1') -InstallRoot $InstallRoot | Out-Null }
            throw 'Redlib did not pass the Reddit-backed usability gate.'
        }
    } catch {
        if ($startedByThisCall) {
            try { & (Join-Path $PSScriptRoot 'stop_redlib_windows.ps1') -InstallRoot $InstallRoot | Out-Null } catch {}
        }
        throw
    }
}

# Reuse a complete pinned installation before inspecting compiler prerequisites.
if (Test-Path -LiteralPath $configPath -PathType Leaf) {
    $existing = Get-Content -Raw -LiteralPath $configPath | ConvertFrom-Json
    if (-not $portWasSpecified) {
        $recordPort = [int]$existing.port
        if ($recordPort -lt 1024 -or $recordPort -gt 65535 -or [string]$existing.baseUrl -ne "http://127.0.0.1:$recordPort") {
            throw "Recorded Redlib endpoint is invalid; expected a loopback port from 1024 through 65535: $configPath"
        }
        $Port = $recordPort
    }
    $existingExe = Assert-RedlibInstallRecord -Record $existing -Port $Port -InstallRoot $InstallRoot
    if (-not [string]::Equals($existingExe, [IO.Path]::GetFullPath($installedExe), [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Installation record executable path does not belong to this Redlib installation root.'
    }
    $gitExe = Find-Tool -Name 'git.exe' -Candidates @('C:\Program Files\Git\cmd\git.exe', 'C:\Program Files\Git\bin\git.exe')
    if (-not $gitExe) { throw 'A complete Redlib install was found, but Git is needed to verify its recorded source pin.' }
    Assert-ExistingSourcePin -Record $existing -GitExe $gitExe
    if ($Start) { Start-And-Verify }
    $existing | ConvertTo-Json -Depth 8
    exit 0
}
if (Test-Path -LiteralPath $installedExe -PathType Leaf) {
    throw "Unrecorded Redlib executable already exists; preserving it and refusing to replace it: $installedExe"
}

# A new source build stays under LOCALAPPDATA and uses a separator boundary.
$localAppData = [IO.Path]::GetFullPath($env:LOCALAPPDATA).TrimEnd('\')
$installPrefix = $localAppData + '\'
if (-not $InstallRoot.StartsWith($installPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "A new Redlib build must be under LOCALAPPDATA: $InstallRoot"
}

$git = Find-Tool -Name 'git.exe' -Candidates @('C:\Program Files\Git\cmd\git.exe', 'C:\Program Files\Git\bin\git.exe')
$cargo = Find-Tool -Name 'cargo.exe' -Candidates @((Join-Path $env:USERPROFILE '.cargo\bin\cargo.exe'))
$rustc = Find-Tool -Name 'rustc.exe' -Candidates @((Join-Path $env:USERPROFILE '.cargo\bin\rustc.exe'))
if (-not $git) { throw 'Git for Windows is required to build Redlib.' }
if (-not $cargo -or -not $rustc) { throw 'Rust/Cargo with the MSVC target is required to build Redlib.' }
$activeTarget = (& $rustc -Vv | Select-String '^host:' | ForEach-Object { ($_ -split ':', 2)[1].Trim() })
if ($LASTEXITCODE -ne 0 -or $activeTarget -ne 'x86_64-pc-windows-msvc') {
    throw "Expected Rust host x86_64-pc-windows-msvc; found '$activeTarget'."
}

$vswhere = 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path -LiteralPath $vswhere)) { throw 'Visual Studio vswhere.exe was not found. Install Visual C++ Build Tools with the C++ workload.' }
$vswhereOutput = @(& $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath)
$vswhereExit = $LASTEXITCODE
$vsRoot = Convert-VswhereOutputToPath -Output $vswhereOutput -ExitCode $vswhereExit
if (-not $vsRoot) { throw 'Visual C++ x64 build tools were not found. Install the Build Tools C++ workload.' }
$devCmd = Join-Path $vsRoot 'Common7\Tools\VsDevCmd.bat'
if (-not (Test-Path -LiteralPath $devCmd)) { $devCmd = Join-Path $vsRoot 'Common7\Tools\LaunchDevCmd.bat' }
if (-not (Test-Path -LiteralPath $devCmd)) { throw "Developer command script was not found under $vsRoot." }

function Find-BuildTool {
    param([string]$Command, [string[]]$Candidates)
    foreach ($candidate in $Candidates) { if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate } }
    $found = Get-Command $Command -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) { return $found.Source }
    return $null
}

$cmakeCandidates = @(
    (Join-Path $vsRoot 'Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe'),
    'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe',
    'C:\Program Files\CMake\bin\cmake.exe'
)
$nasmCandidates = @((Join-Path $InstallRoot 'tools\nasm-3.02\nasm.exe'), 'C:\Program Files\NASM\nasm.exe')
$clangCandidates = @('C:\Program Files\LLVM\bin\clang.exe')
$cmake = Find-BuildTool -Command 'cmake.exe' -Candidates $cmakeCandidates
$nasm = Find-BuildTool -Command 'nasm.exe' -Candidates $nasmCandidates
$clang = Find-BuildTool -Command 'clang.exe' -Candidates $clangCandidates

if ((-not $cmake -or -not $nasm -or -not $clang) -and -not $SkipPrerequisiteInstall) {
    if (-not $nasm) {
        $downloadRoot = Join-Path $InstallRoot 'downloads'
        $nasmArchive = Join-Path $downloadRoot 'nasm-3.02-win64.zip'
        New-Item -ItemType Directory -Force -Path $downloadRoot, (Join-Path $InstallRoot 'tools') | Out-Null
        if (-not (Test-Path -LiteralPath $nasmArchive)) { Invoke-WebRequest -Uri $NasmUrl -OutFile $nasmArchive -TimeoutSec 60 }
        $observedNasmHash = (Get-FileHash -LiteralPath $nasmArchive -Algorithm SHA256).Hash
        if ($observedNasmHash -ne $NasmSha256) { throw "NASM archive hash mismatch. Expected $NasmSha256; found $observedNasmHash." }
        Expand-Archive -LiteralPath $nasmArchive -DestinationPath (Join-Path $InstallRoot 'tools') -Force
        $nasm = Find-BuildTool -Command 'nasm.exe' -Candidates $nasmCandidates
    }

    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ((-not $cmake -or -not $clang) -and -not $winget) { throw 'CMake or LLVM/Clang is missing and winget is unavailable.' }
    $packages = @()
    if (-not $cmake) { $packages += 'Kitware.CMake' }
    if (-not $clang) { $packages += 'LLVM.LLVM' }
    foreach ($package in $packages) {
        & $winget.Source install --id $package --exact --accept-package-agreements --accept-source-agreements --silent
        $code = $LASTEXITCODE
        if ($code -eq 3010 -or $code -eq 1641) { throw "Installing $package requires a Windows restart before Redlib can be built." }
        if ($code -ne 0) { throw "Failed to install $package (winget exit code $code)." }
    }
    $cmake = Find-BuildTool -Command 'cmake.exe' -Candidates $cmakeCandidates
    $nasm = Find-BuildTool -Command 'nasm.exe' -Candidates $nasmCandidates
    $clang = Find-BuildTool -Command 'clang.exe' -Candidates $clangCandidates
}

if (-not $cmake) { throw 'CMake is required to build current Redlib.' }
if (-not $nasm) { throw 'NASM is required to build current Redlib.' }
if (-not $clang) { throw 'LLVM/Clang is required to build current Redlib.' }

$sourceRoot = Join-Path $InstallRoot "buildsrc\$VersionId"
$targetRoot = Join-Path $InstallRoot "target\$VersionId"
$binaryRoot = Join-Path $InstallRoot "versions\$VersionId\bin"
$installedExe = Join-Path $binaryRoot 'redlib.exe'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $sourceRoot), $targetRoot, $binaryRoot | Out-Null
if (-not (Test-Path -LiteralPath (Join-Path $sourceRoot '.git'))) {
    if (Test-Path -LiteralPath $sourceRoot) { throw "Source path exists but is not the expected Git checkout: $sourceRoot" }
    & $git clone --no-checkout $Repository $sourceRoot
    if ($LASTEXITCODE -ne 0) { throw 'Redlib source checkout failed.' }
}

& $git -C $sourceRoot fetch origin $PinnedCommit --depth 1
if ($LASTEXITCODE -ne 0) { throw 'Pinned Redlib commit fetch failed.' }
& $git -C $sourceRoot checkout --detach $PinnedCommit
if ($LASTEXITCODE -ne 0) { throw 'Pinned Redlib commit checkout failed.' }
$origin = (& $git -C $sourceRoot remote get-url origin).Trim()
$commit = (& $git -C $sourceRoot rev-parse HEAD).Trim()
if ($origin -ne $Repository) { throw "Unexpected Redlib source origin: $origin" }
if ($commit -ne $PinnedCommit) { throw "Pinned commit mismatch. Expected $PinnedCommit; found $commit." }

$builtExe = Join-Path $targetRoot 'release\redlib.exe'
if (-not (Test-Path -LiteralPath $builtExe)) {
    $quotedDevCmd = '"' + $devCmd + '"'
    $quotedSource = '"' + $sourceRoot + '"'
    $toolPaths = @((Split-Path -Parent $cmake), (Split-Path -Parent $nasm), (Split-Path -Parent $clang)) -join ';'
    $buildCommand = "call $quotedDevCmd -arch=x64 -host_arch=x64 >nul && set `"PATH=$toolPaths;%PATH%`" && set `"CMAKE_GENERATOR=Visual Studio 17 2022`" && set `"CARGO_TARGET_DIR=$targetRoot`" && cd /d $quotedSource && cargo build --release --locked"
    & cmd.exe /d /s /c $buildCommand
    if ($LASTEXITCODE -ne 0) { throw "Native Redlib build failed with exit code $LASTEXITCODE." }
}
if (-not (Test-Path -LiteralPath $builtExe -PathType Leaf)) { throw 'Build completed without producing redlib.exe.' }
Copy-Item -LiteralPath $builtExe -Destination $installedExe -Force
if (Test-Path -LiteralPath (Join-Path $sourceRoot 'LICENSE')) {
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'LICENSE') -Destination (Join-Path (Split-Path -Parent $binaryRoot) 'LICENSE') -Force
}

$record = [ordered]@{
    schemaVersion = 2
    versionId = $VersionId
    ref = $PinnedRef
    commit = $PinnedCommit
    repository = $Repository
    executable = $installedExe
    source = $sourceRoot
    port = $Port
    baseUrl = "http://127.0.0.1:$Port"
    installedAt = [DateTimeOffset]::UtcNow.ToString('o')
}
$record | ConvertTo-Json | Set-Content -LiteralPath $configPath -Encoding utf8
if ($Start) { Start-And-Verify }
$record | ConvertTo-Json -Depth 8
