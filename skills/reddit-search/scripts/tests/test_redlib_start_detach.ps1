[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$StartScript,
    [Parameter(Mandatory = $true)][string]$VerifierScript,
    [Parameter(Mandatory = $true)][string]$StopScript,
    [Parameter(Mandatory = $true)][string]$WorkRoot,
    [Parameter(Mandatory = $true)][string]$PwshPath
)

$ErrorActionPreference = 'Stop'

function Find-CSharpCompiler {
    $frameworkCandidates = @(
        (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
        (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
    )
    foreach ($candidate in $frameworkCandidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }

    $vswhere = 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe'
    if (Test-Path -LiteralPath $vswhere -PathType Leaf) {
        $matches = @(& $vswhere -latest -products '*' -find 'MSBuild\Current\Bin\Roslyn\csc.exe' 2>$null)
        if ($LASTEXITCODE -eq 0) {
            foreach ($candidate in $matches) {
                if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
            }
        }
    }
    throw 'The Windows start-detachment regression requires the Visual Studio C# compiler.'
}

function Quote-PowerShellLiteral {
    param([string]$Value)
    return "'" + $Value.Replace("'", "''") + "'"
}

function Invoke-PowerShellFile {
    param([string]$File, [string]$Root)
    $arguments = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $File, '-InstallRoot', $Root)
    $output = & $PwshPath @arguments 2>&1 | Out-String
    $code = $LASTEXITCODE
    return [pscustomobject]@{ exitCode = $code; output = $output }
}

$WorkRoot = [IO.Path]::GetFullPath($WorkRoot)
$installRoot = Join-Path $WorkRoot ('detach-' + [guid]::NewGuid().ToString('n'))
$null = New-Item -ItemType Directory -Force -Path $installRoot
$versionRoot = Join-Path $installRoot 'versions\a4d36e9\bin'
$sourceRoot = Join-Path $installRoot 'buildsrc\a4d36e9'
$logRoot = Join-Path $installRoot 'logs'
$null = New-Item -ItemType Directory -Force -Path $versionRoot, $sourceRoot
$exe = Join-Path $versionRoot 'redlib.exe'
$sourceFile = Join-Path $WorkRoot 'fake_redlib.cs'
$portProbe = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
$portProbe.Start()
$port = ([Net.IPEndPoint]$portProbe.LocalEndpoint).Port
$portProbe.Stop()
$baseUrl = "http://127.0.0.1:$port"

$source = @'
using System;
using System.Globalization;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;

internal static class FakeRedlib
{
    private const string Commit = "a4d36e954cf1bd64f209cd8868c5a29edc81b374";

    private static void Main()
    {
        int port = Int32.Parse(Environment.GetEnvironmentVariable("PORT"), CultureInfo.InvariantCulture);
        string baseUrl = Environment.GetEnvironmentVariable("REDLIB_FULL_URL");
        string input = Console.ReadLine();
        Console.Error.WriteLine("stdin-eof=" + (input == null).ToString().ToLowerInvariant());
        Console.Error.Flush();

        TcpListener listener = new TcpListener(IPAddress.Loopback, port);
        listener.Start();
        Console.Out.WriteLine("fake-redlib-ready");
        Console.Out.Flush();
        while (true)
        {
            using (TcpClient client = listener.AcceptTcpClient())
            using (NetworkStream stream = client.GetStream())
            using (StreamReader reader = new StreamReader(stream, Encoding.ASCII, false, 1024, true))
            {
                string requestLine = reader.ReadLine();
                string header;
                while ((header = reader.ReadLine()) != null && header.Length != 0) { }

                string path = "/";
                if (!String.IsNullOrEmpty(requestLine))
                {
                    string[] pieces = requestLine.Split(' ');
                    if (pieces.Length > 1) path = pieces[1].Split('?')[0];
                }
                Console.Out.WriteLine("request=" + path);
                Console.Error.WriteLine("request=" + path);
                Console.Out.Flush();
                Console.Error.Flush();

                int status = 200;
                string statusText = "OK";
                string contentType = "text/html; charset=utf-8";
                string body;
                if (path == "/info.json")
                {
                    contentType = "application/json; charset=utf-8";
                    body = "{\"git_commit\":\"" + Commit + "\",\"config\":{\"REDLIB_ENABLE_RSS\":\"on\",\"REDLIB_FULL_URL\":\"" + baseUrl + "\"}}";
                }
                else if (path == "/r/foss")
                {
                    body = "<html><div class=\"post\">fixture</div><a href=\"" + baseUrl + "/r/foss/comments/t3_fixture\">thread</a></html>";
                }
                else
                {
                    status = 404;
                    statusText = "Not Found";
                    body = "not found";
                }

                byte[] payload = Encoding.UTF8.GetBytes(body);
                string responseHeader = "HTTP/1.1 " + status.ToString(CultureInfo.InvariantCulture) + " " + statusText + "\r\n" +
                    "Content-Type: " + contentType + "\r\n" +
                    "Content-Length: " + payload.Length.ToString(CultureInfo.InvariantCulture) + "\r\n" +
                    "Connection: close\r\n\r\n";
                byte[] headerBytes = Encoding.ASCII.GetBytes(responseHeader);
                stream.Write(headerBytes, 0, headerBytes.Length);
                stream.Write(payload, 0, payload.Length);
                stream.Flush();
            }
        }
    }
}
'@

try {
    [IO.File]::WriteAllText($sourceFile, $source, [Text.UTF8Encoding]::new($false))
    $compiler = Find-CSharpCompiler
    $compileOutput = & $compiler '/nologo' '/target:exe' "/out:$exe" '/reference:System.dll' $sourceFile 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $exe -PathType Leaf)) {
        throw "Could not build the fake Redlib test server: $compileOutput"
    }

    $record = [ordered]@{
        schemaVersion = 2
        versionId = 'a4d36e9'
        ref = 'main'
        commit = 'a4d36e954cf1bd64f209cd8868c5a29edc81b374'
        repository = 'https://github.com/redlib-org/redlib.git'
        executable = $exe
        source = $sourceRoot
        port = $port
        baseUrl = $baseUrl
        installedAt = [DateTimeOffset]::UtcNow.ToString('o')
    }
    $record | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $installRoot 'install.json') -Encoding utf8

    $wrapper = Join-Path $WorkRoot 'run_start_redlib.ps1'
    $installRootWithTrailingSeparator = $installRoot + '\'
    $wrapperText = '& ' + (Quote-PowerShellLiteral $StartScript) + ' -InstallRoot ' + (Quote-PowerShellLiteral $installRootWithTrailingSeparator) + "`r`n"
    [IO.File]::WriteAllText($wrapper, $wrapperText, [Text.UTF8Encoding]::new($false))

    $callerInfo = [Diagnostics.ProcessStartInfo]::new()
    $callerInfo.FileName = $PwshPath
    foreach ($argument in @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $wrapper)) {
        $callerInfo.ArgumentList.Add($argument)
    }
    $callerInfo.UseShellExecute = $false
    $callerInfo.RedirectStandardInput = $true
    $callerInfo.RedirectStandardOutput = $true
    $callerInfo.RedirectStandardError = $true
    $caller = [Diagnostics.Process]::new()
    $caller.StartInfo = $callerInfo
    if (-not $caller.Start()) { throw 'Could not start the monitored PowerShell caller.' }
    $stdoutTask = $caller.StandardOutput.ReadToEndAsync()
    $stderrTask = $caller.StandardError.ReadToEndAsync()
    $caller.StandardInput.Close()

    if (-not $caller.WaitForExit(15000)) {
        $caller.Kill()
        $null = $caller.WaitForExit(5000)
        throw 'The caller PowerShell process did not exit within 15 seconds after starting Redlib.'
    }
    $streamsClosed = [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($stdoutTask, $stderrTask), 5000)
    if (-not $streamsClosed) {
        throw 'The caller exited but a live Redlib child still held the caller stdout/stderr pipes open.'
    }
    if ($caller.ExitCode -ne 0) {
        throw "The start-script caller exited with code $($caller.ExitCode): $($stdoutTask.Result) $($stderrTask.Result)"
    }
    $startResult = $stdoutTask.Result.Trim() | ConvertFrom-Json
    if (-not [bool]$startResult.startedByThisCall -or [int]$startResult.pid -le 0) {
        throw 'The caller did not report that it started the test server.'
    }
    if (-not [bool]$startResult.daemonExited) {
        throw 'The launching helper did not confirm its own exit before returning.'
    }
    if (-not (Test-Path -LiteralPath $startResult.stdoutLog -PathType Leaf) -or -not (Test-Path -LiteralPath $startResult.stderrLog -PathType Leaf)) {
        throw 'The detached server did not write to its owned stdout/stderr log files.'
    }
    $stdoutLogText = Get-Content -Raw -LiteralPath $startResult.stdoutLog
    $stderrLogText = Get-Content -Raw -LiteralPath $startResult.stderrLog
    if ($stdoutLogText -notmatch 'fake-redlib-ready' -or $stderrLogText -notmatch 'stdin-eof=true') {
        throw 'The detached server did not receive redirected standard input/output/error handles.'
    }
    $stdoutLeaf = [IO.Path]::GetFileName([string]$startResult.stdoutLog)
    $stdinLeaf = $stdoutLeaf.Replace('.stdout.log', '.stdin.txt')
    $stdinLogPath = Join-Path $logRoot $stdinLeaf
    if (-not (Test-Path -LiteralPath $stdinLogPath -PathType Leaf) -or (Get-Item -LiteralPath $stdinLogPath).Length -ne 0) {
        throw 'The server standard-input handle was not redirected to its owned file.'
    }

    $verification = Invoke-PowerShellFile -File $VerifierScript -Root $installRoot
    if ($verification.exitCode -ne 0) { throw "The detached server failed its health/content gate: $($verification.output)" }
    $verified = $verification.output.Trim() | ConvertFrom-Json
    if (-not [bool]$verified.usable -or [int]$verified.listenerPid -ne [int]$startResult.pid -or $verified.listener -ne '127.0.0.1') {
        throw 'The caller exited, but its child did not remain healthy on the expected loopback listener.'
    }
    $stdoutAfterContent = Get-Content -Raw -LiteralPath $startResult.stdoutLog
    $stderrAfterContent = Get-Content -Raw -LiteralPath $startResult.stderrLog
    if ($stdoutAfterContent -notmatch 'request=/r/foss' -or $stderrAfterContent -notmatch 'request=/r/foss') {
        throw 'The detached service did not continue writing stdout and stderr logs after the launch helper exited.'
    }

    [pscustomobject]@{
        callerExited = $true
        callerExitCode = [int]$caller.ExitCode
        stdoutClosed = $true
        stderrClosed = $true
        childAlive = $true
        usable = [bool]$verified.usable
        listener = [string]$verified.listener
        processId = [int]$verified.listenerPid
        stdoutLog = [string]$startResult.stdoutLog
        stderrLog = [string]$startResult.stderrLog
    } | ConvertTo-Json -Depth 4
} finally {
    if (Test-Path -LiteralPath (Join-Path $installRoot 'redlib.pid') -PathType Leaf) {
        $cleanup = Invoke-PowerShellFile -File $StopScript -Root $installRoot
        if ($cleanup.exitCode -ne 0) { Write-Error "Test cleanup could not stop its owned child: $($cleanup.output)" }
    }
    if ($caller) { $caller.Dispose() }
}
