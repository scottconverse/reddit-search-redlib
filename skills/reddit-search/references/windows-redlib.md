# Native Windows Redlib

Read this only when the user asks to install, start, stop, verify, or diagnose a local Redlib on Windows.

## Verified machine path

On the machine tested 2026-09-14:

- Rust `1.97.1` with the `x86_64-pc-windows-msvc` target is installed.
- Visual C++ Build Tools are installed, although `cl.exe` is not normally on `PATH`.
- Docker and Podman are absent.
- Redlib commit `a4d36e954cf1bd64f209cd8868c5a29edc81b374` from `main` builds successfully with native Rust/MSVC and no WSL.
- Current Redlib also requires CMake, NASM, and LLVM/Clang to build its browser-emulation networking stack. The setup script installs missing CMake and LLVM copies through `winget`. For NASM it downloads the official portable 3.02 archive, verifies the pinned SHA-256, and unpacks it privately under the Redlib installation; the NASM vendor installer was not reliably discoverable after silent installation. Use `-SkipPrerequisiteInstall` to require all tools to be preinstalled instead.
- The build target must stay under the short `%LOCALAPPDATA%\RedditSearch\Redlib` tree. A deeply nested source/target path can make MSBuild FileTracker fail even when Windows long paths are otherwise enabled.
- The resulting executable reports the pinned commit and returned HTTP 200 for `/r/foss`, with 25 post records and real `/r/foss/comments/...` links during verification.

The stable `v0.36.0` release is retained as a rollback version but is not the active recommendation because Reddit returned 403 for its older client. The scripts build the newer pinned source locally and retain its AGPL license and source checkout with the installation.

## Lifecycle

All scripts default to `%LOCALAPPDATA%\RedditSearch\Redlib` and port `18080`. Override `-InstallRoot` or `-Port` when necessary.

1. `setup_redlib_windows.ps1` verifies Git, Rust, MSVC, CMake, NASM, and LLVM/Clang; checks out the exact pinned commit; builds with `--locked` under a short target path; and records provenance. It does not start Redlib unless `-Start` is supplied. With `-Start`, it also runs the Reddit-backed usability test and stops the process if that gate fails.
2. `start_redlib_windows.ps1` starts the recorded executable hidden, binds it to `127.0.0.1`, enables robots exclusion and RSS, and verifies `/info.json`. It refuses to take over an occupied port.
3. `test_redlib_windows.ps1` verifies the listener, executable ownership, provenance, local configuration, and one Reddit-backed content request. Its `usable` field is the gate for choosing local Redlib.
4. `stop_redlib_windows.ps1` stops only the recorded PID after verifying that its executable path matches the installation.

Do not add an automatic logon task or Windows service unless the user separately asks for persistence. On-demand startup avoids maintaining a nonfunctional background server when Reddit blocks the upstream client.

## Safety and interpretation

- Never launch with `--ipv4-only`: it can bind beyond loopback. Use `--address 127.0.0.1`.
- Redlib's environment variables are prefixed, including `REDLIB_ENABLE_RSS`, `REDLIB_FULL_URL`, and `REDLIB_ROBOTS_DISABLE_INDEXING`.
- The crate/version string may lag the source revision; verify `git_commit`, not only the displayed version.
- Do not move the pin to a newer `main` commit automatically. A new commit needs a fresh build and live usability review before packaging.
- If upstream verification fails, stop the local process unless the user is actively diagnosing it, then continue with RSS or a single explicitly acceptable public instance.
