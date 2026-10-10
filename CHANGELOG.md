# Changelog

Project versions follow the root `VERSION` file. Redlib's upstream revision is tracked separately in `skills/reddit-search/scripts/redlib_windows_common.ps1` and the Windows reference.

## 0.1.1 — 2026-10-09

- Make the native Windows install command install or reuse the complete skill and pinned local Redlib, with a Reddit-backed usability gate before reporting full success.
- Bootstrap missing supported Windows prerequisites and reuse healthy recorded Redlib installs without a compiler toolchain.
- Add ownership, loopback, endpoint, process cleanup, receipt-preservation, and saved-config validation.
- Add package completeness checks, cross-platform regression tests, and architecture diagrams.
- Preserve RSS as a separately available path and require explicit choice for RSS-only installation.

## 0.1.0 — 2026-09-15

- Initial published release of the Reddit Search + Redlib skill, parser, Windows lifecycle scripts, user manual, and project website.
