# Native Windows Redlib

Read this when the user explicitly asks to install, start, stop, verify, or diagnose local Redlib on Windows. The scripts use native Windows tools only; they do not use WSL or containers. Unpacking the ZIP never starts setup.

## Complete Windows install

Run the bundled entrypoint after extracting the archive. From the extracted folder:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\reddit-search\scripts\install_windows.ps1
```

If the skill folder is already open in a terminal, use `scripts\install_windows.ps1`. Windows PowerShell 5.1 is accepted; the entrypoint installs/reuses PowerShell 7 and relaunches itself there. It also installs/reuses Python 3.10 or newer and runs a local parser URL-build check before it reports that the skill is installed.

The default command installs or updates the skill, then provisions or reuses local Redlib. It reports success only after process ownership/configuration checks and a Reddit-backed content response pass. `-RssOnly` explicitly installs the skill without Redlib; its receipt says RSS network access was not live-tested. A Redlib error never silently changes the saved mode.

For a fresh Redlib build, the installer uses winget package IDs `Git.Git`, `Rustlang.Rustup`, `Microsoft.VisualStudio.2022.BuildTools` with the Visual C++ workload, `Kitware.CMake`, and `LLVM.LLVM`. It downloads the official portable NASM archive and verifies its SHA-256. PowerShell 7 and Python use `Microsoft.PowerShell` and `Python.Python.3.12`. These installations can need network access and Windows elevation. A canceled installer, blocked network request, or restart requirement is reported as a failure; rerun after resolving it.

When reusing a complete pinned Redlib installation, setup verifies its recorded source pin and executable without checking for Cargo, Rust, MSVC, CMake, NASM, or LLVM. Git is needed for the local source provenance check. The running server still has to pass the live content gate.

## Discovery and saved configuration

Unless `-RedlibInstallRoot` is supplied, the entrypoint checks the saved user configuration, then the legacy `%USERPROFILE%\TownReporterTools\Redlib` location, then `%LOCALAPPDATA%\RedditSearch\Redlib`. A valid explicit or saved root takes priority. Fresh source builds must stay beneath `%LOCALAPPDATA%` to keep the Windows build path short and predictable.

The selection and last successful receipt are stored at `%LOCALAPPDATA%\RedditSearch\config.json`. Override that location with `-ConfigPath` for another user or an isolated setup. Read the saved setting as JSON with:

```powershell
powershell.exe -NoProfile -File .\reddit-search\scripts\get_redlib_config.ps1
```

The helper reports the configured endpoint and the last successful receipt; it does not probe current health. Before using Redlib in a new research task, run `test_redlib_windows.ps1` and use the adapter only when its fresh `usable` field is true.

## Verified machine path

On the machine tested 2026-09-14:

- Redlib commit `a4d36e954cf1bd64f209cd8868c5a29edc81b374` from `main` returned HTTP 200 for `/r/foss`, with 25 post records and real `/r/foss/comments/...` links.
- The build uses native Rust/MSVC. Current Redlib also requires CMake, NASM, and LLVM/Clang for its networking stack.
- The build target stays under the short `%LOCALAPPDATA%\RedditSearch\Redlib` tree. A deeply nested target can make MSBuild FileTracker fail even when Windows long paths are enabled.

The displayed Redlib version may lag the source revision. Verify `git_commit`, not just the displayed version. The installer retains the pinned source checkout and AGPL license; it does not bundle Redlib binaries.

## Lifecycle scripts

```powershell
pwsh -NoProfile -File "$HOME\.agents\skills\reddit-search\scripts\start_redlib_windows.ps1"
pwsh -NoProfile -File "$HOME\.agents\skills\reddit-search\scripts\test_redlib_windows.ps1"
pwsh -NoProfile -File "$HOME\.agents\skills\reddit-search\scripts\stop_redlib_windows.ps1"
```

With no explicit `-InstallRoot`, lifecycle scripts resolve the saved root from `%LOCALAPPDATA%\RedditSearch\config.json`; if no saved configuration exists, they use `%LOCALAPPDATA%\RedditSearch\Redlib`. A saved RSS-only configuration does not imply a Redlib path. The recorded installation supplies its port, including custom ports. The start script binds only to `127.0.0.1`, enables RSS, and refuses an occupied or ambiguously owned port. It records whether it started the process or reused the verified listener. The verifier checks the pinned record, listener address, owning PID and executable, Redlib's reported commit/configuration, then requests `/r/foss` and validates post and comment links.

If the Reddit-backed gate fails, the installer does not write a success receipt or replace the existing configuration. It stops a process only when that installer invocation started it; a preexisting server remains untouched for diagnosis. A prior configuration is copied to a timestamped sibling backup only after a new receipt has passed validation.

No logon task or Windows service is installed. Redlib runs on demand and must be started again after reboot.

## Safety and interpretation

- Never launch with `--ipv4-only`; it can bind beyond loopback. Use `--address 127.0.0.1`.
- Redlib's environment variables are prefixed, including `REDLIB_ENABLE_RSS`, `REDLIB_FULL_URL`, and `REDLIB_ROBOTS_DISABLE_INDEXING`.
- `/info.json` proves process health, not Reddit access. The separate content request is the usability gate.
- Do not move the source pin to a newer `main` commit automatically. A new pin needs a fresh build and live usability review before packaging.
- On upstream blocks, keep the failure category and report partial coverage. Do not cycle through public instances to evade a block.
