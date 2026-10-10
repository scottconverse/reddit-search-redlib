# Changelog

Project versions follow the root `VERSION` file. Redlib's upstream revision is tracked separately in `skills/reddit-search/scripts/redlib_windows_common.ps1` and the Windows reference.

## 0.1.2 — 2026-10-10

- Detach newly started Redlib from the setup/lifecycle caller by redirecting standard input, output, and error to per-launch files under the owned installation root. The caller can return while Redlib continues serving requests.
- Add a native Windows regression that captures the launching PowerShell process's output pipes, proves it exits with both streams closed, and verifies the owned loopback service remains usable.
- Fresh-build testing on native Windows 11 Pro used two runs. The first, elevated bootstrap installed VS 2022 C++/SDK and LLVM and downloaded portable NASM; it built the pin and passed the Reddit-backed gate but exposed a caller hang from inherited handles. The corrected second run used the PowerShell 5.1 entrypoint as a standard user with the default Redlib root absent and fresh Cargo cache/target. It reused the installed C++ toolchain and LLVM, used bundled CMake, and freshly downloaded NASM. The pinned build completed in 284.8 seconds, the caller exited with captured output pipes closed, Redlib remained alive, and the gate returned HTTP 200 with 25 posts and 54 comment links. PowerShell 7, Git, Python, and Rust were preexisting, so their missing-tool bootstrap paths were not tested. This was not a pristine-VM test.
- Follow-up live acceptance returned 25 listing posts, 1 search post, and 21 RSS posts; a thread with 25 of 29 reported comments was correctly marked partial. Reuse, stop, restart, and a new content gate after restart passed; test instances were stopped afterward.

## 0.1.1 — 2026-10-09

- Make the native Windows install command install or reuse the complete skill and pinned local Redlib, with a Reddit-backed usability gate before reporting full success.
- Bootstrap missing supported Windows prerequisites and reuse healthy recorded Redlib installs without a compiler toolchain.
- Add ownership, loopback, endpoint, process cleanup, receipt-preservation, and saved-config validation.
- Add package completeness checks, cross-platform regression tests, and architecture diagrams.
- Preserve RSS as a separately available path and require explicit choice for RSS-only installation.

## 0.1.0 — 2026-09-15

- Initial published release of the Reddit Search + Redlib skill, parser, Windows lifecycle scripts, user manual, and project website.
