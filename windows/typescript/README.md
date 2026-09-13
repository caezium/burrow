# Burrow for Windows — TypeScript preview

This is the Electron, React, and TypeScript rewrite of Burrow's Windows app. Its interface follows the current macOS source: a floating navigation rail, warm adaptive surfaces, Geist and Cal Sans typography, a Monitor with segmented sections, and a shared Clean hub for caches, project artifacts, and installers.

The installer is named **Burrow Preview**, with a separate install directory and shortcuts so it can coexist with the WinUI release.

The existing WinUI application remains in the parent `windows/` directory while this implementation is developed. This preview does not yet replace the existing Windows release. See [MIGRATION.md](MIGRATION.md) for the feature boundary and remaining work.

## Run locally

Use Node.js 24 and npm. Run these commands from `windows/typescript/`:

```sh
npm ci
npm run dev
```

`dev` starts the renderer and Electron desktop app. Real device readings and filesystem operations run through the desktop bridge. Windows-specific actions require Windows; running the desktop app on another platform is useful for interface development but does not validate those actions.

For a browser-only interface preview:

```sh
npm run dev:web
```

Open the local URL printed by Vite. Browser mode displays example device readings and example scan results. It cannot delete files, run maintenance, or open Windows Settings. Example data is separate from the desktop's real telemetry and local history.

## Check and package

```sh
npm run typecheck
npm test
npm run build
npx playwright install chromium
npm run test:ui
npm run package:win
```

`build` produces the renderer in `dist/` and the Electron main process and preload bridge in `dist-electron/`. `npm start` opens the built desktop app. `package:win` builds the app and generates the configured Windows packages under `release/`. Run packaging on Windows for the supported build path. These development packages are unsigned.

For the x64-only installer and ZIP used in CI, run this after `npm run build`:

```sh
npx electron-builder --win nsis zip --x64 --publish never
```

Explicit target names matter: adding `--x64` alone does not remove architectures explicitly listed in the package configuration.

The [Windows TypeScript workflow](../../.github/workflows/windows-typescript.yml) installs dependencies from the lockfile, checks types, runs unit tests, builds the application, runs Chromium UI tests, and uploads unsigned x64 installer and ZIP artifacts. UI tests exercise browser mode. They do not replace a native Windows smoke test of the tray, telemetry, dialogs, filesystem access, or installer.

## What works in the desktop preview

| Area                             | Current behavior                                                                                                         |
| -------------------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| Monitor                          | Real CPU, memory, disk, network, battery when available, and process readings. GPU and fan readings are not implemented. |
| History and Activity             | Local persisted metric samples and operation records. No legacy history import.                                          |
| Clean                            | Read-only size preview of the current user’s temporary/cache folder. Cache deletion is not enabled.                      |
| Project artifacts and installers | Scan, review selections, native confirmation, and Recycle Bin removal of supported candidates.                           |
| Analyze                          | Read-only directory sizing and a size-proportional treemap.                                                              |
| Duplicates                       | Read-only duplicate scan. No duplicate deletion.                                                                         |
| Apps                             | Installed app inventory and a handoff to Windows Apps settings for removal.                                              |
| Optimize                         | DNS cache flush only. Other macOS maintenance operations have not been ported.                                           |
| Ports, Network, Get Online       | Local connections, addresses, DNS configuration, and a public DNS lookup.                                                |
| Settings                         | Appearance, sampling interval, retention, and tray behavior.                                                             |
| Leftovers and Similar Photos     | Explicitly unavailable in this preview.                                                                                  |

Reviewed removal is restricted to project artifacts and old installers. It uses the desktop's reviewed scan record and a native confirmation before sending eligible entries to the Recycle Bin. There is no permanent-delete fallback. A scan does not itself authorize removal.

## Structure and local data

- `src/`: React interface, design tokens, and browser preview adapter.
- `src/shared/contracts.ts`: typed interface between the renderer and desktop.
- `electron/`: desktop lifecycle, isolated preload bridge, telemetry, scanning, and local storage.
- `public/fonts/`: bundled fonts shared with Burrow's macOS visual identity.

The desktop writes `burrow-state.json` under a separate `BurrowTypeScript` folder in Electron's per-user application data directory (`%APPDATA%` on Windows). It stores settings, recent activity, and metric samples downsampled to fit the selected retention period: five-minute buckets at the default 30-day retention. Up to 600 recent samples remain in memory for live charts. Process lists are live-only and are omitted from saved history. Retention is bounded by both the selected number of days and the store's maximum sample count, so choosing a longer retention period does not guarantee that much history is available.

The TypeScript preview does not yet expose the legacy app's MCP or HTTP server, conductor integration, or AI Explain workflow. Existing WinUI release tooling and services remain separate.
