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

Open the local URL printed by Vite. Browser mode displays example device readings, scans, and application details. It cannot delete files, launch uninstallers, run maintenance, or open Windows Settings. Example data is separate from the desktop's real telemetry and local history.

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

| Area                             | Current behavior                                                                                                                     |
| -------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| Monitor                          | Real CPU, memory, disk, network, battery when available, and process readings. GPU and fan readings are not implemented.             |
| History and Activity             | Local persisted metric samples and operation records. No legacy history import.                                                      |
| Clean                            | Review and recycle files/complete trees older than seven days in the fixed user temporary folder. Other app caches are not included. |
| Project artifacts and installers | Scan, review selections, native confirmation, and Recycle Bin removal of supported candidates.                                       |
| Analyze                          | Read-only directory sizing and a size-proportional treemap.                                                                          |
| Duplicates                       | SHA-256 groups, select extra copies, and reviewed recycling while preserving an unselected matching copy.                            |
| Apps                             | Registered desktop app inventory, details, installation-folder reveal, and reviewed launch of supported registered uninstallers.     |
| Optimize                         | DNS cache flush only. Other macOS maintenance operations have not been ported.                                                       |
| Ports, Network, Get Online       | Local connections, addresses, DNS configuration, and a public DNS lookup.                                                            |
| Settings                         | Appearance, sampling interval, retention, and tray behavior.                                                                         |
| Leftovers                        | Read-only discovery of possible old cache/log leftovers in fixed Local or Roaming app-data scopes; evidence and reveal only.         |
| Similar Photos                   | Explicitly unavailable in this preview.                                                                                              |

Reviewed removal covers old user temporary files, project artifacts, old installers, and selected exact duplicates. It uses the desktop's reviewed scan record and a native confirmation before sending eligible entries to the Recycle Bin. There is no permanent-delete fallback. A scan does not itself authorize removal.

Temporary cleanup stays inside `%USERPROFILE%\AppData\Local\Temp` on Windows and does not accept a custom folder. Recently modified items, incomplete directory scans, symlinks, and junctions are skipped. For duplicates, the desktop verifies an unselected original-content copy before every move; selecting every copy in a group is rejected. Previews expire after 15 minutes. Cancellation and partial failures return the exact moved IDs, and the interface refreshes before allowing another operation. Space is freed only when the Recycle Bin is emptied.

## Reviewing an installed app

Select an app to see its publisher, version, reported size, installation date, user/machine scope, and registered installation folder when available. Folder reveal and uninstall resolve the app's identity in the desktop process; the interface cannot submit an executable or command line.

Supported uninstallers require a fresh review and a native confirmation. The desktop rereads the registry and checks the reviewed executable and installation directory again before launch. MSI removal uses the fixed Windows Installer executable and a validated product code with interactive UI and no automatic restart. EXE uninstallers must resolve to an allowed application directory; ambiguous paths, links, command/script hosts, recognized quiet flags, and entries that disable removal are unavailable. Unsupported entries retain a Windows Apps settings handoff. This inventory does not enumerate Store packages or unregistered portable apps.

A review expires after ten minutes. Once a launch is dispatched, its review cannot be reused. The interface requires refreshed details after every attempt. Activity saves the accepted request before launch and records the outcome with zero reclaimed bytes. “Uninstaller started” confirms only launch; finish the vendor's prompts and refresh the app list to check the registered inventory. An unknown result requires checking Windows before retrying. Quitting Burrow can stop a pending launch, but does not cancel an uninstaller already handed to Windows. Burrow does not remove related app data in this workflow.

## Reviewing possible leftovers

Leftovers compares fixed `%USERPROFILE%\AppData\Local` or `%USERPROFILE%\AppData\Roaming` folders with registered desktop application names and publishers. It considers only immediate `Cache`, `Caches`, `Log`, or `Logs` children of unmatched application folders, and only when the complete scanned subtree was last modified more than 60 days ago. Known shared/system folders and links are skipped; scan limits and incomplete results are shown.

A missing name match is not proof that an app was uninstalled. Portable and Microsoft Store apps may be absent from the desktop inventory. Findings show the evidence and can be revealed in Explorer; this page does not delete or recycle them. Empty, unreadable, or capped inventories stop discovery. Other cleanup tools do not receive removal authorization for these results.

## Structure and local data

- `src/`: React interface, design tokens, and browser preview adapter.
- `src/shared/contracts.ts`: typed interface between the renderer and desktop.
- `electron/`: desktop lifecycle, isolated preload bridge, telemetry, scanning, and local storage.
- `public/fonts/`: bundled fonts shared with Burrow's macOS visual identity.

The desktop writes `burrow-state.json` under a separate `BurrowTypeScript` folder in Electron's per-user application data directory (`%APPDATA%` on Windows). It stores settings, recent activity, and metric samples downsampled to fit the selected retention period: five-minute buckets at the default 30-day retention. Up to 600 recent samples remain in memory for live charts. Process lists are live-only and are omitted from saved history. Retention is bounded by both the selected number of days and the store's maximum sample count, so choosing a longer retention period does not guarantee that much history is available.

The TypeScript preview does not yet expose the legacy app's MCP or HTTP server, conductor integration, or AI Explain workflow. Existing WinUI release tooling and services remain separate.
