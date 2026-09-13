# Windows TypeScript migration

## Starting point

The rewrite lives in `windows/typescript/` alongside the retained WinUI implementation. At the start of this work the remote did not advertise a `windows` branch, so the local `windows` branch was created from `main`. No remote branch or release is implied by that local setup.

Electron owns the desktop window, tray, native dialogs, and operating-system services. React owns rendering and interaction state. TypeScript contracts connect the two through a preload bridge. This allows the interface to follow macOS without trying to translate SwiftUI into WinUI control templates.

## UI reference

The implementation follows current macOS source rather than older Windows screenshots:

| macOS reference                                      | Windows adaptation                                                                                                                                  |
| ---------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| `macos/Sources/Brand.swift` and `Fonts.swift`        | Warm dark/light surfaces, restrained tool accents, Geist UI text, Geist Mono labels, and Cal Sans display text.                                     |
| `FloatingRail.swift`, `Tool.swift`, `RootView.swift` | Floating left icon rail with Monitor at the top, tool destinations, and Settings at the bottom.                                                     |
| `HomeView.swift`                                     | Segmented Monitor navigation for Overview, Tune-Up, History, Activity, and Doctor. Available sections use the Windows preview's supported services. |
| `StatusView.swift`                                   | Health summary above metric cards, memory detail, and process list. Unsupported sensors are identified as unavailable.                              |
| `CleanHub.swift`                                     | One Clean destination containing caches, project build artifacts, and installers.                                                                   |
| `AnalyzeView.swift`                                  | Directory list, breadcrumb navigation, and a size-proportional treemap.                                                                             |

The README's older Windows screenshots use top navigation and an older dashboard layout. They are not the target for this rewrite. Native Windows window controls and operating-system prompts remain Windows-specific.

## Service migration boundary

The preview has its own local state and desktop services. It does not silently connect to a running WinUI instance or claim parity with that app's existing engine and agent integrations.

- Real device telemetry, local settings, history, and activity are implemented in the desktop. The browser adapter is explicitly an example-data preview.
- Directory analysis, project-artifact scans, installer scans, and duplicate detection use local filesystem services. Duplicate and Analyze results are read-only.
- Cache cleanup stops at preview. It must not be presented as a working cache-removal implementation.
- Recycle Bin removal is limited to reviewed project-artifact and installer candidates, with a native confirmation. Native removal failures are reported; there is no permanent-delete fallback.
- Apps inventory hands removal to Windows Apps settings. In-app uninstall, leftover deletion, application updates, and startup/service management remain migration work.
- Optimize currently offers DNS cache flushing. It does not reproduce the macOS engine's maintenance suite.
- GPU and fan telemetry, leftover discovery, and similar-photo detection remain unavailable.
- MCP, HTTP, conductor/engine integration, AI Explain, legacy store import, and broader macOS feature parity are not migrated.

The legacy C# implementation, its tests, bundled engine, and release workflows remain intact. Any migration of its security-sensitive path handling, deletion receipts, authenticated agent APIs, or shared state should be assessed independently before replacing the released application.

## Validation and release boundary

The TypeScript workflow runs on Windows with Node.js 24. It installs from the lockfile, checks types, runs unit tests, builds the renderer and desktop bundles, installs Chromium, runs browser UI tests, and packages unsigned x64 artifacts. It is separate from the WinUI workflow and does not publish a GitHub release.

Development and UI verification on a Mac can validate shared TypeScript behavior and browser rendering. They do not establish successful native Windows execution. Native Windows smoke testing remains required for tray behavior, device readings, registry-backed app inventory, folder selection, cancellation, Recycle Bin confirmation and failure handling, and install/uninstall behavior. No completed native Windows smoke test is claimed by this migration document.

Before replacing the legacy Windows release, review the remaining service gaps, run those native checks against the packaged build, decide how existing user data will migrate, and establish the signing and release process for the new application.
