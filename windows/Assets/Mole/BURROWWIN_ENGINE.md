# BurrowWin Mole Engine Asset

This folder vendors the `tw93/Mole` Windows branch runtime scripts so BurrowWin can resolve a local OS engine before falling back to a user PATH installation.

- Upstream repository: https://github.com/tw93/Mole/tree/windows
- Upstream commit: `627342b3b59b21e39d0aac3bda1c06024047c79c`
- License: MIT, see `LICENSE` in this folder.

BurrowWin builds and copies a local `mo.exe` shim from `Tools/MoShim` into this folder. The shim forwards arguments, stdout, stderr, and exit codes to `mole.ps1`. The upstream Windows branch currently exposes the engine as PowerShell scripts plus optional TUI binaries rather than a stable standalone `mo.exe`, so this shim provides the PRD-compatible executable entrypoint while preserving Mole as the OS engine.

The `bin/clean.ps1` and `bin/optimize.ps1` sources come from the same upstream commit. They were omitted by the repository's general `bin/` ignore rule; a source-only exception now keeps them in the app payload. Local adaptations preserve the documented `MOLE_DRY_RUN=1` guard, propagate cleanup and optimization failures, reject cache paths with reparse-point ancestors, and keep the optional SFC question limited to interactive terminals so redirected MCP calls cannot hang on it. Optimization checks native exit codes, terminates and reaps its owned `wsreset` child after a timeout, and restores services/Explorer after cache repair failures. SFC owns a unique temporary output file. GUI Clean/Optimize remain behind their existing pending-feature gates.

`windows/scripts/verify-mole-runtime.ps1` checks the two command files and every required import in both CI and release publish outputs. `test-mole-runtime.ps1` exercises their routing, preview guards, failure propagation, process timeouts, and prompt gating with fake OS actions; it never performs host maintenance. CI runs it under Windows PowerShell 5.1, matching the packaged shim. Its path-safety check uses fake metadata plus isolated temporary Windows junctions, with no cleanup calls.
