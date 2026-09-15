[CmdletBinding()]
param(
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'RedditSearch\Redlib'),
    [ValidateRange(1024, 65535)][int]$Port = 18080,
    [switch]$SkipPrerequisiteInstall,
    [switch]$Start
)

$ErrorActionPreference = 'Stop'
$VersionId = 'a4d36e9'
$PinnedRef = 'main'
$PinnedCommit = 'a4d36e954cf1bd64f209cd8868c5a29edc81b374'
$Repository = 'https://github.com/redlib-org/redlib.git'
$NasmUrl = 'https://www.nasm.us/pub/nasm/releasebuilds/3.02/win64/nasm-3.02-win64.zip'
$NasmSha256 = '161D0BFAFF53C2F9E9F3E69FD0672323EBABAFD1268976A5CEC11BE92A19AEE7'

if (-not $IsWindows) { throw 'This installer supports native Windows only.' }
if (-not $env:LOCALAPPDATA) { throw 'LOCALAPPDATA is unavailable.' }

$resolvedParent = [IO.Path]::GetFullPath((Split-Path -Parent $InstallRoot))
$localAppData = [IO.Path]::GetFullPath($env:LOCALAPPDATA)
if (-not $resolvedParent.StartsWith($localAppData, [StringComparison]::OrdinalIgnoreCase)) {
    throw "InstallRoot must be under LOCALAPPDATA unless the script is deliberately adapted: $InstallRoot"
}

$git = Get-Command git.exe -ErrorAction SilentlyContinue | Select-Object -First 1
$cargo = Get-Command cargo.exe -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $git) { throw 'Git for Windows is required.' }
if (-not $cargo) { throw 'Rust/Cargo with the MSVC target is required.' }

$activeTarget = (& rustc.exe -Vv | Select-String '^host:' | ForEach-Object { ($_ -split ':', 2)[1].Trim() })
if ($activeTarget -ne 'x86_64-pc-windows-msvc') {
    throw "Expected Rust host x86_64-pc-windows-msvc; found '$activeTarget'."
}

$vswhere = 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path -LiteralPath $vswhere)) { throw 'Visual Studio vswhere.exe was not found.' }
$vsRoot = (& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath).Trim()
if (-not $vsRoot) { throw 'Visual C++ x64 build tools were not found.' }
$devCmd = Join-Path $vsRoot 'Common7\Tools\VsDevCmd.bat'
if (-not (Test-Path -LiteralPath $devCmd)) {
    $devCmd = Join-Path $vsRoot 'Common7\Tools\LaunchDevCmd.bat'
}
if (-not (Test-Path -LiteralPath $devCmd)) { throw "Developer command script was not found under $vsRoot." }

$prebuiltExe = Join-Path $InstallRoot "target\$VersionId\release\redlib.exe"
$buildRequired = -not (Test-Path -LiteralPath $prebuiltExe)

function Find-BuildTool {
    param([string]$Command, [string[]]$Candidates)
    foreach ($candidate in $Candidates) {
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    $found = Get-Command $Command -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) { return $found.Source }
    return $null
}

$cmakeCandidates = @(
    (Join-Path $vsRoot 'Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe'),
    'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe',
    'C:\Program Files\CMake\bin\cmake.exe'
)
$nasmCandidates = @(
    (Join-Path $InstallRoot 'tools\nasm-3.02\nasm.exe'),
    'C:\Program Files\NASM\nasm.exe'
)
$clangCandidates = @('C:\Program Files\LLVM\bin\clang.exe')

$cmake = Find-BuildTool -Command 'cmake.exe' -Candidates $cmakeCandidates
$nasm = Find-BuildTool -Command 'nasm.exe' -Candidates $nasmCandidates
$clang = Find-BuildTool -Command 'clang.exe' -Candidates $clangCandidates

if ($buildRequired -and (-not $cmake -or -not $nasm -or -not $clang) -and -not $SkipPrerequisiteInstall) {
    if (-not $nasm) {
        $downloadRoot = Join-Path $InstallRoot 'downloads'
        $nasmArchive = Join-Path $downloadRoot 'nasm-3.02-win64.zip'
        New-Item -ItemType Directory -Force -Path $downloadRoot, (Join-Path $InstallRoot 'tools') | Out-Null
        if (-not (Test-Path -LiteralPath $nasmArchive)) {
            Invoke-WebRequest -Uri $NasmUrl -OutFile $nasmArchive -TimeoutSec 60
        }
        $observedNasmHash = (Get-FileHash -LiteralPath $nasmArchive -Algorithm SHA256).Hash
        if ($observedNasmHash -ne $NasmSha256) {
            throw "NASM archive hash mismatch. Expected $NasmSha256; found $observedNasmHash."
        }
        Expand-Archive -LiteralPath $nasmArchive -DestinationPath (Join-Path $InstallRoot 'tools') -Force
        $nasm = Find-BuildTool -Command 'nasm.exe' -Candidates $nasmCandidates
    }

    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ((-not $cmake -or -not $clang) -and -not $winget) {
        throw 'CMake or LLVM/Clang is missing and winget is unavailable. Install the missing Redlib build prerequisites manually.'
    }
    $packages = @()
    if (-not $cmake) { $packages += 'Kitware.CMake' }
    if (-not $clang) { $packages += 'LLVM.LLVM' }
    foreach ($package in $packages) {
        & $winget.Source install --id $package --exact --accept-package-agreements --accept-source-agreements --silent
        if ($LASTEXITCODE -ne 0) { throw "Failed to install prerequisite package $package." }
    }
    $cmake = Find-BuildTool -Command 'cmake.exe' -Candidates $cmakeCandidates
    $nasm = Find-BuildTool -Command 'nasm.exe' -Candidates $nasmCandidates
    $clang = Find-BuildTool -Command 'clang.exe' -Candidates $clangCandidates
}

if ($buildRequired -and -not $cmake) { throw 'CMake is required to build current Redlib.' }
if ($buildRequired -and -not $nasm) { throw 'NASM is required to build current Redlib.' }
if ($buildRequired -and -not $clang) { throw 'LLVM/Clang is required to build current Redlib.' }

$versionRoot = Join-Path $InstallRoot "versions\$VersionId"
$sourceRoot = Join-Path $InstallRoot "buildsrc\$VersionId"
$targetRoot = Join-Path $InstallRoot "target\$VersionId"
$binaryRoot = Join-Path $versionRoot 'bin'
$installedExe = Join-Path $binaryRoot 'redlib.exe'
$configPath = Join-Path $InstallRoot 'install.json'

New-Item -ItemType Directory -Force -Path $versionRoot, $binaryRoot, (Split-Path -Parent $sourceRoot), $targetRoot | Out-Null
if (-not (Test-Path -LiteralPath (Join-Path $sourceRoot '.git'))) {
    if (Test-Path -LiteralPath $sourceRoot) {
        throw "Source path exists but is not the expected Git checkout: $sourceRoot"
    }
    & $git.Source clone --no-checkout $Repository $sourceRoot
    if ($LASTEXITCODE -ne 0) { throw 'Redlib source checkout failed.' }
}

& $git.Source -C $sourceRoot fetch origin $PinnedCommit --depth 1
if ($LASTEXITCODE -ne 0) { throw 'Pinned Redlib commit fetch failed.' }
& $git.Source -C $sourceRoot checkout --detach $PinnedCommit
if ($LASTEXITCODE -ne 0) { throw 'Pinned Redlib commit checkout failed.' }

$origin = (& $git.Source -C $sourceRoot remote get-url origin).Trim()
$commit = (& $git.Source -C $sourceRoot rev-parse HEAD).Trim()
if ($origin -ne $Repository) { throw "Unexpected Redlib source origin: $origin" }
if ($commit -ne $PinnedCommit) { throw "Pinned commit mismatch. Expected $PinnedCommit; found $commit." }

$builtExe = Join-Path $targetRoot 'release\redlib.exe'
if (-not (Test-Path -LiteralPath $builtExe)) {
    $quotedDevCmd = '"' + $devCmd + '"'
    $quotedSource = '"' + $sourceRoot + '"'
    $toolPaths = @(
        (Split-Path -Parent $cmake),
        (Split-Path -Parent $nasm),
        (Split-Path -Parent $clang)
    ) -join ';'
    $buildCommand = "call $quotedDevCmd -arch=x64 -host_arch=x64 >nul && set `"PATH=$toolPaths;%PATH%`" && set `"CMAKE_GENERATOR=Visual Studio 17 2022`" && set `"CARGO_TARGET_DIR=$targetRoot`" && cd /d $quotedSource && cargo build --release --locked"
    & cmd.exe /d /s /c $buildCommand
    if ($LASTEXITCODE -ne 0) { throw "Native Redlib build failed with exit code $LASTEXITCODE." }
}
if (-not (Test-Path -LiteralPath $builtExe)) { throw 'Build completed without producing redlib.exe.' }

Copy-Item -LiteralPath $builtExe -Destination $installedExe -Force
$licenseSource = Join-Path $sourceRoot 'LICENSE'
if (Test-Path -LiteralPath $licenseSource) {
    Copy-Item -LiteralPath $licenseSource -Destination (Join-Path $versionRoot 'LICENSE') -Force
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

if ($Start) {
    & (Join-Path $PSScriptRoot 'start_redlib_windows.ps1') -InstallRoot $InstallRoot
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    & (Join-Path $PSScriptRoot 'test_redlib_windows.ps1') -InstallRoot $InstallRoot
    if ($LASTEXITCODE -ne 0) {
        & (Join-Path $PSScriptRoot 'stop_redlib_windows.ps1') -InstallRoot $InstallRoot
        throw 'Redlib started locally but failed the Reddit-backed usability gate.'
    }
}

$record | ConvertTo-Json
