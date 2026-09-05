# Burrow Windows Alignment

## Product understanding

Burrow is a native GUI around the Mole CLI (`mo`). It is not a background service first and it is not a raw command launcher. The upstream macOS app presents the system maintenance tools as one cohesive desktop utility: live status, cleanup, purge, installers, optimize, software uninstall, disk analyze, history, activity, and agent access.

The upstream Burrow architecture is centered on shared data and command paths:

- `mo status --json` feeds a sampler and local history store, then powers Status, History, HTTP, and MCP.
- `mo analyze --json` feeds the disk analyzer and treemap.
- `mo clean`, `mo purge`, installer cleanup, and `mo optimize` run through a streamed command runner used by the GUI and agent surfaces.
- `mo uninstall --list` feeds the Software view.
- The GUI, local HTTP server, and stdio MCP server expose the same recent system state instead of separate interpretations.

Research references:

- `caezium/Burrow` main at `813334df0f274216d7012ff6e66cb6e566d881c0`
- `tw93/Mole` windows at `627342b3b59b21e39d0aac3bda1c06024047c79c`

## Windows adaptation rule

BurrowWin should keep the GUI-first product shape while using the Windows Mole branch as the OS engine. When Mole Windows does not yet expose a non-interactive JSON contract, BurrowWin may use a native Windows fallback, but the fallback should be presented as a compatibility layer and keep the same GUI/MCP surface as much as possible.

Current Windows-specific adaptations:

- Status uses native Windows telemetry because `mo status` is currently a TUI wrapper on Windows.
- GPU utilization retains each performance counter between captures so interval readings use two samples. A new counter reports unavailable while its first sample is primed; disappeared or failed counters are disposed and re-primed if they return.
- A background telemetry sampler records snapshots every 60 seconds and is now the shared source for Dashboard, History, HTTP, MCP, tray status menu, and tray HUD.
- Analyze uses a native size-ranked tree plus Burrow-style treemap because `mo analyze` is currently interactive on Windows.
- Cleanup is currently a guarded pending route in the WinUI preview. It does not claim a stable GUI preview/removal flow until Mole Windows exposes a safe non-interactive cleanup contract.
- Purge now uses a Burrow-style non-interactive preview/removal flow built from the same Windows Mole project markers and artifact patterns because Mole Windows `mo purge` is an interactive selector and does not expose `--dry-run`.
- Installers uses a Burrow-style preview/removal flow for old top-level Downloads installers and archives, mirroring Mole Windows `Clear-OldDownloads` rules because Mole Windows documents that there is no dedicated installer-file cleanup command yet.
- Purge, old-installer cleanup, and uninstall-leftover removal share one fail-closed Windows path policy. Raw traversal, roots, UNC/device/NT paths, alternate data streams, protected roots, scope escapes, and any reparse point from the volume root through the target are rejected before the Shell is invoked. This includes junctions above the approved scope, which could otherwise redirect a lexically safe path into a protected tree.
- Native fallback removal is asynchronous and Recycle Bin-only. It uses Windows `IFileOperation` with `FOFX_RECYCLEONDELETE`, silent/no-error-UI flags, and early failure. A Shell failure is returned as `Failed`; there is no permanent-delete fallback.
- Destructive service calls require an immutable authorization object bound to the operation ID and the exact selected candidate fingerprints. Every selected item must also belong to the latest completed preview. Purge rules/project markers, direct-Downloads installer rules plus preview metadata, and approved discovered uninstall leftovers are revalidated after confirmation and immediately before recycling.
- Native deletion returns per-item `Recycled`, `AlreadyAbsent`, `Rejected`, `Failed`, or `Cancelled` dispositions and a batch outcome of `Success`, `PartialSuccess`, `Failed`, or `Cancelled`. Already-absent items are idempotent no-ops and never count as removed or freed bytes.
- Cancellation stops future targets but does not interrupt an in-flight Shell operation; Burrow waits for that observable result, preserves all completed item results, then returns a cancelled batch. Determinate removal progress is monotonic and capped below 100% for partial/cancelled outcomes; preview scans remain indeterminate because their total is unknown.
- Deletion receipts are appended to `%LOCALAPPDATA%\BurrowWin\deletion-receipts.jsonl` with operation correlation, original/canonical paths, expected/observed sizes, disposition, source flow, and failure reason. Windows Shell does not reliably expose the newly-created Recycle Bin item locator through this contract, so the exact recovery locator is explicitly recorded as unavailable rather than fabricated.
- Optimize uses Mole `optimize --dry-run` for preview and requires explicit confirmation before real `mo optimize` changes.
- Uninstall lists installed apps natively, auto-loads the inventory on first view, supports search plus size/name/source sorting, and launches vendor uninstallers only after confirmation because the current Mole uninstall command is interactive.
- History and Activity are persisted locally and surfaced in the GUI and MCP/HTTP paths. Mole command executions, Windows uninstall actions, and BurrowWin native fallback preview/removal flows now write into the same operation history.
- Mole command history summaries are normalized before storage so GUI Activity, History, tray HUD, HTTP, and MCP surfaces do not show ANSI terminal escapes or CLI icon placeholders.
- History now renders Burrow-style trend cards for CPU, memory, disk, and network, has selectable 5m/1h/6h/24h/7d/30d/90d ranges, and shows a Top CPU Processes table backed by the same filtered telemetry history.
- MCP is local-only and authenticated: HTTP binds to loopback, requires the per-install bearer credential plus an exact localhost Host, rejects browser Origin/fetch metadata, and bounds methods, bodies, and request rate. The published stdio bridge reads the user-private credential from Settings automatically. The REST surface exposes `/health`, `/info`, `/snapshot`, and `/metrics`; disabling REST keeps only the authenticated `/mcp` route available for the stdio bridge.
- MCP now includes the upstream read-only tool shape: `burrow_snapshot`, `burrow_history`, `burrow_top_processes`, `burrow_process_usage`, `burrow_info`, `burrow_list_apps`, `burrow_purge`, and `burrow_installer`. Windows process usage can rank by `peak_cpu`, `avg_cpu`, `cpu_time`, `peak_mem`, or `avg_mem` using locally recorded telemetry, while purge and installer MCP calls remain preview-only.
- GUI startup now activates the main WinUI window before hosted background services finish, records startup phases to `%LOCALAPPDATA%\BurrowWin\startup.log`, and treats tray/background failures as diagnostics instead of blocking the first visible window.
- The Windows tray now provides a Burrow icon with live tooltip text, a left-click Burrow-style HUD window, a right-click status menu, quick navigation to Status, History, Activity, Clean, Optimize, and Settings, and a safe Exit Burrow command.
- Native tray registration uses the Windows `Shell_NotifyIconW` entry point and a window subclass callback for left-click HUD and right-click menu behavior.
- Tray HUD diagnostics can be triggered with `BURROWWIN_SHOW_TRAY_HUD=1` or `--show-tray-hud` so visible HUD smoke can be repeated when Windows allows the unsigned debug build to run.
- Settings are persisted in `%LOCALAPPDATA%\BurrowWin\settings.json` and now control sampling interval, history retention, REST endpoint enablement/port, tray visibility, and MCP destructive-action opt-in. Sampling, tray visibility, REST enablement/port changes, and destructive-action gates apply immediately.
- Settings now uses the same Burrow dark card surface as the other utility panes while keeping the existing engine, agent access, behavior, local history, and recent activity bindings.
- Repository release readiness now includes MIT license, README, contribution/security/telemetry docs, Windows architecture and Mole gap docs, GitHub Actions CI/release workflows, and an unsigned Inno Setup installer plus portable ZIP fallback release script with SHA256 output.
- Windows installation now follows upstream Burrow's package-manager-first rhythm: WinGet package `Caezium.Burrow` is the recommended user path, while direct setup exe and ZIP downloads remain fallback paths.

## Latest verification

- `dotnet build BurrowWin.csproj -p:Platform=x64 -nr:false -v:minimal` succeeds with 0 warnings and 0 errors.
- `dotnet build Tests\BurrowWin.Tests\BurrowWin.Tests.csproj -nr:false -v:minimal` succeeds with 0 warnings and 0 errors.
- The current source is 137 xUnit cases (121 facts plus 16 inline theory cases). The exact build/test result must be taken from Windows CI, because the implementation environment has no .NET/Windows SDK — the last Windows-host figure quoted here (66 tests) predates the authenticated loopback work and no longer describes this suite.
- Mole command history normalization is covered by `ExecuteCommandAsync_RecordsAnsiFreeHistorySummary`, including ANSI color removal, control character removal, and CLI icon placeholder removal.
- HTTP runtime settings changes are covered by `HttpServerSettingsPlannerTests`, including no-op, start, stop, restart, and disabled-stays-disabled decisions.
- `.\run-local.ps1 -NoBuild -SmokeTest -Restart -RequireHealth -TimeoutSeconds 45` starts the x64 Debug GUI, confirms the `BurrowWin` main window is visible, confirms `/health` returns `ok: true`, and writes startup diagnostics to `%LOCALAPPDATA%\BurrowWin\startup.log`.
- `.\run-local.ps1 -NoBuild -SmokeTest -Restart -RequireHealth -Route purge -TimeoutSeconds 45` starts the x64 Debug GUI, confirms `/health` returns `ok: true`, and startup diagnostics record `Opening startup route: purge`.
- Clean GUI scan/clean is intentionally not counted as complete in this preview; the current route shows the pending state and does not run cleanup.
- `.\run-local.ps1 -NoBuild -SmokeTest -Restart -RequireHealth -Route optimize -OptimizeAutoScan -TimeoutSeconds 120` starts the x64 Debug GUI, confirms `/health` returns `ok: true`, waits for startup diagnostics to record `Opening startup route: optimize`, and waits for `Optimize auto-preview finished`.
- The Optimize autoscan smoke records Mole `optimize --dry-run` in `%LOCALAPPDATA%\BurrowWin\history.jsonl` with a normalized summary, confirming the preview path stays tied to the shared Mole command/activity path without terminal escape output.
- `.\run-local.ps1 -NoBuild -SmokeTest -Restart -RequireHealth -Route settings -TimeoutSeconds 45` starts the x64 Debug GUI, confirms `/health` returns `ok: true`, and waits for startup diagnostics to record `Opening startup route: settings`.
- `run-local.ps1` now supports `-ScreenshotPath` for repeatable local GUI evidence. The capture path restores the BurrowWin window, brings it to the foreground, writes a PNG, and then releases the topmost state.
- Screenshot smoke captured `artifacts\ui-smoke\burrowwin-settings.png`, `artifacts\ui-smoke\burrowwin-history.png`, `artifacts\ui-smoke\burrowwin-clean.png`, `artifacts\ui-smoke\burrowwin-installer.png`, and `artifacts\ui-smoke\burrowwin-analyze.png` from the same `run-local.ps1` health-gated GUI startup flow.
- The History screenshot smoke confirms the Burrow-style range selector and CPU, memory, disk, and network trend cards render on the default `1h` range.
- Clean screenshot evidence needs to be refreshed against the pending-state route before claiming any GUI cleanup preview.
- `.\run-local.ps1 -NoBuild -SmokeTest -Restart -RequireHealth -Route installer -InstallerRoot artifacts\installer-smoke -InstallerAutoScan -TimeoutSeconds 45` starts the x64 Debug GUI, confirms `/health` returns `ok: true`, waits for startup diagnostics to record `Opening startup route: installer`, and fails if the current launch records a XAML unhandled exception.
- Installer autoscan diagnostics from the sample directory record `Installer autoscan finished: 3 files - 14 KB`, proving the page applied the old Downloads installer/archive matcher and ignored the fresh sample file.
- The Installer screenshot smoke uses an absolute sample root and visually confirms the 3 old installer/archive rows, sizes, dates, and preview/remove action area.
- The same installer autoscan smoke appends `%LOCALAPPDATA%\BurrowWin\history.jsonl` with `Source=burrowwin`, `Operation=installer-preview`, and `Summary=3 files - 14 KB`, confirming native fallback activity reaches the shared operation history.
- `.\run-local.ps1 -NoBuild -SmokeTest -Restart -RequireHealth -Route analyze -TimeoutSeconds 45` starts the x64 Debug GUI and confirms the Analyze route opens cleanly.
- `artifacts\burrowwin-analyze-treemap-smoke.png` was captured from a temporary sample directory with `BURROWWIN_ANALYZE_AUTOSCAN=1` and confirms the Analyze treemap renders real size-proportional tiles.
- The latest Analyze screenshot smoke uses an absolute controlled sample root, waits for `Analyze autoscan finished: Scanned ...\artifacts\ui-smoke-sample`, and visually confirms a size-proportional treemap for `AppCache`, `Logs`, and `Downloads`.
- `.\run-local.ps1 -NoBuild -SmokeTest -Restart -RequireHealth -Route apps -TimeoutSeconds 45` starts the x64 Debug GUI, confirms `/health` returns `ok: true`, and opens the Apps route cleanly.
- `artifacts\burrowwin-apps-smoke.png` visually confirms the Apps route auto-loads installed applications, renders readable app rows, and shows the active sort state.
- `dotnet .\Tools\McpStdioBridge\bin\Debug\net8.0\burrow-mcp-stdio.dll` responds to `tools/list` and exposes the `metric` input on `burrow_top_processes`.
- History chart, time-range, and Top CPU Process UI changes compile through WinUI XAML generation in the x64 Debug build. Range resolution, read-limit estimation, and sample filtering are covered by unit tests.
- Tray HUD/menu changes compile through the x64 Debug build; tray menu and tray HUD status formatter coverage are included in the test suite.
- Runtime smoke verified the x64 Debug app starts, authenticated requests to `http://127.0.0.1:9277/health`, `/snapshot`, and `/metrics?limit=2` return live local telemetry, and `Assets\Mcp\burrow-mcp-stdio.exe` reads the per-install credential and can call `burrow_snapshot`, `burrow_info`, `burrow_top_processes`, and `burrow_process_usage`.
- Runtime smoke after the tray HUD/menu work launched `bin\x64\Debug\...\BurrowWin.exe` and confirmed `/health` returned `ok: true`, engine availability, and a fresh `latest_sample_at`.
- Latest tray HUD screenshot smoke launched `bin\x64\Debug\...\BurrowWin.exe` with `BURROWWIN_SHOW_TRAY_HUD=1`, captured `artifacts\burrowwin-tray-hud-smoke.png`, and visually confirmed the HUD window, status cards, activity card, top CPU process rows, and quick navigation buttons render without clipping.
- `.\scripts\build-release.ps1` restores, builds Release x64, runs the Windows test suite, publishes the portable WinUI payload, creates `Burrow-v0.1.0-preview.1-win-x64-setup.exe`, creates `Burrow-v0.1.0-preview.1-win-x64.zip`, writes `SHA256SUMS.txt`, writes WinGet manifests, and copies release docs into the payload.
- The generated installer and ZIP contain `BurrowWin.exe`, `Assets\Mole\mo.exe`, `Assets\Mcp\burrow-mcp-stdio.exe`, README, LICENSE, release notes, Windows alignment notes, and Mole gap notes.
- The generated installer and ZIP hashes verify against `artifacts\release\SHA256SUMS.txt`.
- The generated WinGet manifest targets `Caezium.Burrow`, package name `Burrow`, `InstallerType: inno`, `Scope: user`, x64 architecture, and the GitHub Release setup exe URL.
- `winget validate artifacts\release\winget\Caezium\Burrow\0.1.0-preview.1` succeeds. WinGet reports dependency validation is deferred for `Microsoft.DotNet.DesktopRuntime.8`, which must exist in the community repository before submission.
- A clean extraction of `Burrow-v0.1.0-preview.1-win-x64.zip` launches `BurrowWin.exe`, shows the main window, and returns `/health` with `ok: true` on port 9277.
- Silent installer smoke could not run on this workstation because local Application Control policy blocks unsigned setup executables. This is consistent with the preview's unsigned release model and is now documented for direct-download users.

## Release gates (windows-release.yml)

The Windows release is a manual `workflow_dispatch` run, kept deliberately separate from the macOS tag-triggered `release.yml`. What it must do before an artifact exists, and where each rule came from:

- **Test the checked-out release commit.** After restore, the workflow builds and runs the Windows xUnit suite with the same configuration as the app publish. A failed test blocks publication even when the dispatched commit has no successful `windows-ci` run.

- **Bundle the `burrow` conductor at its pinned commit (#252).** `windows/vendor/burrow-cli` is a submodule; the workflow reads its gitlink, clones caezium/burrow-cli, checks out that exact SHA, cargo-builds `burrow.exe` and stages it into `Assets\` so the csproj's conditional `Content Include` bundles it. `Assets\Mole\burrow-engine.cmd` is the entrypoint name the conductor resolves on Windows; it and `mo.cmd` forward their arguments to `invoke-mole.ps1` through `powershell -File` (an argv array, never a `-Command` string with interpolated arguments).
- **Hard-fail instead of warn (#269, #363).** The conductor build used to be a try/catch that downgraded any failure to a `::warning::` and shipped a build with dead features — the same silent-degradation shape that produced a broken macOS 0.10.0. The build step now fails the run, and a post-publish validator requires `Assets\burrow.exe`, the Mole entrypoints, both `bin\clean.ps1` and `bin\optimize.ps1`, and all their imported source modules. Missing command files now fail before an artifact can be uploaded.
- **Authenticated clone only, fail closed (#269, BUR-144).** burrow-cli is private and burrow-cli depends on the private burrow-engine crate over git. `ENGINE_PAT` is required (the step exits 1 without it), the clone is exactly one authenticated `git -c url.…insteadOf` invocation, and cargo's fetch uses a process-scoped `GIT_CONFIG_COUNT`/`GIT_CONFIG_KEY_0`/`GIT_CONFIG_VALUE_0` rewrite that is removed again in `finally`. The token is never written to global git config and reaches no other step; `scripts/tests/test_release_workflows.py` pins all of this.
- **Every action pinned to a commit SHA (BUR-144).** `actions/checkout`, `actions/setup-dotnet` and `actions/upload-artifact` are referenced by 40-hex SHA with a version comment, in both `windows-ci.yml` and `windows-release.yml`, matching the macOS `ci.yml`. The Python tests reject any floating tag.
- **Telemetry keys baked from secrets, presence surfaced.** `BURROWWIN_SENTRY_DSN` / `BURROWWIN_POSTHOG_*` are read from repository secrets into MSBuild properties; an empty one is logged as a warning so a release that silently shipped inert telemetry is easy to spot.
- Installer/WinGet packaging still runs locally through `scripts\build-release.ps1` (see `docs/release.md`); the artifact remains unsigned, as documented for direct-download users.

## Known gaps before calling the Windows port complete

- Broaden screenshot/UI automation coverage for tray-menu actions and navigation, beyond the diagnostic tray HUD visual smoke.
- Move history storage closer to upstream Burrow's SQLite/WAL model or prove the JSONL store meets the same retention, pruning, and query requirements.
- Broaden History screenshot/UI automation from the default rendered range to explicit range-switching interactions.
- Replace Windows fallbacks with Mole JSON paths when the Mole windows branch exposes safe non-interactive contracts for status, analyze, uninstall, purge, and installer scans.
- BUR-9 remains responsible for the currently pending Clean GUI apply flow; BUR-10 does not enable it or add any destructive MCP path.
- A future Shell integration may add an exact Recycle Bin recovery locator only if Windows exposes one reliably for the completed operation; current receipts intentionally record it as unavailable.
- Add pixel/interaction comparison for the Windows Burrow visual shell against the upstream reference screens, beyond the current route-level screenshot smoke.

## Completion criteria for this port

- The first visible experience must be a desktop GUI, not documentation, logs, or a CLI-only launcher.
- The user must be able to navigate the main Burrow tool areas from the shell.
- Mole must be the bundled/primary engine path where it is safe and non-interactive.
- Windows fallbacks must be explicit and task-scoped where Mole Windows lacks JSON or safe background behavior.
- GUI history/activity and MCP/HTTP state must come from the same recorded local state where possible.
- Destructive actions must remain preview-first and confirmation-gated.
