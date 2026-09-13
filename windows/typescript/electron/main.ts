import {
  app,
  BrowserWindow,
  dialog,
  ipcMain,
  Menu,
  nativeImage,
  net,
  protocol,
  session,
  shell,
  Tray,
  type IpcMainInvokeEvent,
} from 'electron';
import path from 'node:path';
import { existsSync } from 'node:fs';
import { lstat, realpath } from 'node:fs/promises';
import { pathToFileURL } from 'node:url';
import { LocalStore, ScanService, SystemService, TelemetryService } from './services';
import { drainWithin } from './services/lifecycle';
import { recycleReviewed } from './services/recycle';
import type { ScanKind, Settings, Snapshot } from '../src/shared/contracts';

protocol.registerSchemesAsPrivileged([
  { scheme: 'burrow', privileges: { standard: true, secure: true, supportFetchAPI: true } },
]);
const devUrl =
  !app.isPackaged && process.env.BURROW_DEV_URL === 'http://127.0.0.1:5173'
    ? process.env.BURROW_DEV_URL
    : undefined;
let mainWindow: BrowserWindow | null = null;
let tray: Tray | null = null;
let quitting = false;
let quitReady = false;
let shutdown: Promise<void> | null = null;
let creatingWindow: Promise<void> | null = null;
let store: LocalStore;
const telemetry = new TelemetryService();
const scanner = new ScanService();
const system = new SystemService();
let latest: Snapshot | null = null;
const recentSamples: Snapshot[] = [];
let sampling: Promise<Snapshot> | null = null;
let timer: ReturnType<typeof setTimeout>;
let operation: 'scan' | 'recycle' | 'optimize' | null = null;
let operationCompletion: Promise<void> | null = null;
let stopRequested = false;
let choosingFolder = false;
const authorizedRoots = new Set<string>();
const revealedPaths = new Set<string>();

function appIcon(): string {
  const built = path.join(app.getAppPath(), 'dist', 'burrow.png');
  return existsSync(built) ? built : path.join(app.getAppPath(), 'public', 'burrow.png');
}
function rememberRoot(root: string): void {
  authorizedRoots.add(path.resolve(root));
  while (authorizedRoots.size > 32) authorizedRoots.delete(authorizedRoots.values().next().value!);
}
function within(file: string, root: string): boolean {
  const relative = path.relative(root, file);
  return (
    relative === '' ||
    (relative !== '..' && !relative.startsWith(`..${path.sep}`) && !path.isAbsolute(relative))
  );
}
function localPath(value: unknown): string {
  const file = textArg(value);
  if (
    !path.isAbsolute(file) ||
    /^\\\\/.test(file) ||
    (process.platform === 'win32' && file.slice(2).includes(':'))
  )
    throw new Error('An absolute local path is required');
  return path.resolve(file);
}
function runOperation<T>(kind: NonNullable<typeof operation>, work: () => Promise<T>): Promise<T> {
  if (quitting) throw new Error('Burrow is preparing to quit.');
  if (operation) throw new Error('Another operation is running. Stop it or wait for it to finish.');
  operation = kind;
  stopRequested = false;
  const result = Promise.resolve().then(work);
  const completion = result
    .then(
      () => undefined,
      () => undefined,
    )
    .finally(() => {
      if (operationCompletion === completion) {
        operation = null;
        operationCompletion = null;
      }
    });
  operationCompletion = completion;
  return result;
}

async function sample(): Promise<Snapshot> {
  if (sampling) return sampling;
  sampling = telemetry
    .sample()
    .then((snapshot) => {
      latest = snapshot;
      recentSamples.push({ ...snapshot, processes: [] });
      if (recentSamples.length > 600) recentSamples.shift();
      store.addSnapshot(snapshot);
      if (mainWindow && !mainWindow.isDestroyed())
        mainWindow.webContents.send('burrow:snapshot', snapshot);
      tray?.setToolTip(
        `Burrow · CPU ${snapshot.cpu.usage.toFixed(0)}% · Memory ${snapshot.memory.percent.toFixed(0)}%`,
      );
      return snapshot;
    })
    .finally(() => {
      sampling = null;
    });
  return sampling;
}
function scheduleSample() {
  clearTimeout(timer);
  if (quitting) return;
  timer = setTimeout(async () => {
    try {
      await sample();
    } catch (error) {
      console.error(
        'System sampling failed:',
        error instanceof Error ? error.message : 'Unknown error',
      );
    }
    if (!quitting) scheduleSample();
  }, store.getSettings().sampleInterval * 1000);
}
function verifySender(event: IpcMainInvokeEvent) {
  if (
    !mainWindow ||
    event.sender !== mainWindow.webContents ||
    event.senderFrame !== mainWindow.webContents.mainFrame
  )
    throw new Error('Untrusted request');
  const source = new URL(event.senderFrame.url);
  if (devUrl ? source.origin !== devUrl : source.protocol !== 'burrow:' || source.host !== 'app')
    throw new Error('Untrusted request origin');
}
function handle<Args extends unknown[], Result>(
  channel: string,
  callback: (...args: Args) => Result,
) {
  ipcMain.handle(`burrow:${channel}`, (event, ...args) => {
    verifySender(event);
    if (quitting) throw new Error('Burrow is preparing to quit.');
    if (args.length > 4) throw new Error('Invalid arguments');
    return callback(...(args as Args));
  });
}
function textArg(value: unknown, maxLength = 32768): string {
  if (typeof value !== 'string' || !value || value.length > maxLength || value.includes('\0'))
    throw new Error('Invalid input');
  return value;
}
async function confirm(
  title: string,
  message: string,
  detail: string,
  button: string,
): Promise<boolean> {
  if (!mainWindow || mainWindow.isDestroyed() || quitting) return false;
  const result = await dialog.showMessageBox(mainWindow, {
    type: 'warning',
    title,
    message,
    detail,
    buttons: ['Cancel', button],
    defaultId: 0,
    cancelId: 0,
    noLink: true,
  });
  return result.response === 1 && !quitting && !stopRequested;
}
function registerIPC() {
  handle('snapshot', () => latest ?? sample());
  handle('history', (since: unknown) => {
    if (typeof since !== 'number' || !Number.isFinite(since) || since < 0)
      throw new Error('Invalid history range');
    const points = new Map(store.getHistory(since).map((point) => [point.timestamp, point]));
    for (const point of recentSamples)
      if (point.timestamp >= since) points.set(point.timestamp, point);
    return [...points.values()].sort((a, b) => a.timestamp - b.timestamp).slice(-10_680);
  });
  handle('activity', () => store.getActivity());
  handle('settings', () => store.getSettings());
  handle('save-settings', async (settings: Settings) => {
    if (
      !settings ||
      typeof settings !== 'object' ||
      Array.isArray(settings) ||
      !['system', 'light', 'dark'].includes(settings.theme) ||
      typeof settings.minimizeToTray !== 'boolean' ||
      !Number.isInteger(settings.sampleInterval) ||
      settings.sampleInterval < 2 ||
      settings.sampleInterval > 60 ||
      !Number.isInteger(settings.retentionDays) ||
      settings.retentionDays < 1 ||
      settings.retentionDays > 90
    )
      throw new Error('Invalid settings');
    const saved = await store.saveSettings(settings);
    scheduleSample();
    return saved;
  });
  handle('choose-folder', async () => {
    if (choosingFolder || !mainWindow || mainWindow.isDestroyed())
      throw new Error('Folder chooser is unavailable');
    choosingFolder = true;
    try {
      const result = await dialog.showOpenDialog(mainWindow, {
        title: 'Choose a folder to scan',
        properties: ['openDirectory'],
      });
      if (result.canceled || !result.filePaths[0]) return null;
      const chosen = localPath(result.filePaths[0]);
      rememberRoot(chosen);
      return chosen;
    } finally {
      choosingFolder = false;
    }
  });
  handle('scan', (kind: ScanKind, root?: string) => {
    if (!['clean', 'purge', 'installers', 'analyze', 'duplicates'].includes(kind))
      throw new Error('Unknown scan kind');
    if (kind === 'clean' && root !== undefined)
      throw new Error('Temporary file cleanup uses only your user temporary folder.');
    if (root !== undefined) {
      root = localPath(root);
      if (![...authorizedRoots].some((approved) => within(root!, approved)))
        throw new Error('Choose this folder with the folder picker before scanning.');
    }
    return runOperation('scan', async () => {
      try {
        const result = await scanner.scan(kind, root, (progress) => {
          if (mainWindow && !mainWindow.isDestroyed())
            mainWindow.webContents.send('burrow:scan-progress', progress);
        });
        rememberRoot(result.root);
        revealedPaths.clear();
        revealedPaths.add(path.resolve(result.root));
        for (const item of result.entries) revealedPaths.add(path.resolve(item.path));
        store.addActivity({
          title: `${kind.charAt(0).toUpperCase() + kind.slice(1)} scan`,
          detail: `${result.entries.length} results in ${result.root}${result.truncated ? ' · scan limit reached' : ''}${result.skipped ? ` · ${result.skipped} skipped` : ''}`,
          status: result.cancelled
            ? 'cancelled'
            : result.truncated || result.skipped
              ? 'partial'
              : 'success',
          bytes: 0,
        });
        return result;
      } catch (error) {
        store.addActivity({
          title: 'Scan failed',
          detail: error instanceof Error ? error.message : 'Unknown error',
          status: 'error',
          bytes: 0,
        });
        throw error;
      }
    });
  });
  handle('cancel-scan', () => {
    scanner.cancel();
    stopRequested = true;
  });
  handle('recycle', (scanId: string, ids: string[]) => {
    if (process.platform !== 'win32')
      throw new Error('Recycling is enabled only in the Windows desktop app.');
    textArg(scanId, 100);
    return runOperation('recycle', () =>
      recycleReviewed(scanId, ids, {
        scanner,
        confirm: (selected) => {
          const review = selected
            .slice(0, 12)
            .map((item) => item.path)
            .join('\n');
          const duplicateNote =
            scanner.getResult(scanId)?.kind === 'duplicates'
              ? '\nAn unselected matching copy will be checked before each move.'
              : '';
          return confirm(
            'Review cleanup',
            `Move ${selected.length} selected item${selected.length === 1 ? '' : 's'} to the Recycle Bin?`,
            `${review}${selected.length > 12 ? `\n… and ${selected.length - 12} more selected items.` : ''}\n\nSpace is freed only after you empty the Recycle Bin. Files that changed since the scan will be skipped.${duplicateNote}`,
            'Move to Recycle Bin',
          );
        },
        trash: (file) => shell.trashItem(file),
        record: (entry) => store.addActivity(entry),
        flush: () => store.flush(),
        shouldStop: () => stopRequested || quitting,
      }),
    );
  });
  handle('reveal', async (file: string) => {
    const checked = localPath(file);
    if (!revealedPaths.has(checked))
      throw new Error('Only files from the latest scan can be revealed. Scan this folder again.');
    // A replaced local ancestor must not redirect Explorer to a network share.
    if (
      path.relative(checked, await realpath(checked)) !== '' ||
      (await lstat(checked)).isSymbolicLink()
    )
      throw new Error('The file path changed after the scan. Scan again.');
    shell.showItemInFolder(checked);
  });
  handle('apps', () => system.getApps());
  handle('apps-settings', async () => {
    if (process.platform !== 'win32')
      throw new Error('Installed Apps settings are available on Windows.');
    await shell.openExternal('ms-settings:appsfeatures');
  });
  handle('ports', () => system.getPorts());
  handle('diagnose', () => system.diagnose());
  handle('optimize', (action: string) => {
    if (action !== 'flush-dns') throw new Error('Unknown maintenance action');
    if (process.platform !== 'win32')
      throw new Error('Windows maintenance is available on Windows.');
    return runOperation('optimize', async () => {
      try {
        if (
          !(await confirm(
            'Review maintenance',
            'Flush the Windows DNS cache?',
            'Windows will resolve addresses again as apps reconnect. No personal files will be changed.',
            'Flush DNS cache',
          ))
        )
          return 'Cancelled. No changes were made.';
        const result = await system.optimize(action);
        store.addActivity({
          title: 'DNS cache refreshed',
          detail: result,
          status: 'success',
          bytes: 0,
        });
        return result;
      } catch (error) {
        store.addActivity({
          title: 'DNS refresh failed',
          detail: error instanceof Error ? error.message : 'Unknown error',
          status: 'error',
          bytes: 0,
        });
        throw error;
      } finally {
        await store.flush();
      }
    });
  });
  handle('window', (action: string) => {
    if (action === 'minimize') mainWindow?.minimize();
    else if (action === 'maximize') {
      if (mainWindow?.isMaximized()) mainWindow.unmaximize();
      else mainWindow?.maximize();
    } else if (action === 'close') mainWindow?.close();
    else throw new Error('Unknown window action');
  });
}
function createWindow(): Promise<void> {
  if (creatingWindow) return creatingWindow;
  creatingWindow = loadWindow().finally(() => {
    creatingWindow = null;
  });
  return creatingWindow;
}
async function loadWindow(): Promise<void> {
  if (mainWindow && !mainWindow.isDestroyed()) return;
  mainWindow = new BrowserWindow({
    width: 1220,
    height: 900,
    minWidth: 940,
    minHeight: 760,
    show: false,
    frame: false,
    backgroundColor: '#17120A',
    title: 'Burrow',
    icon: appIcon(),
    webPreferences: {
      preload: path.join(__dirname, 'preload.cjs'),
      sandbox: true,
      contextIsolation: true,
      nodeIntegration: false,
      webSecurity: true,
      spellcheck: false,
    },
  });
  mainWindow.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
  mainWindow.webContents.on('will-navigate', (event) => event.preventDefault());
  mainWindow.webContents.on('will-attach-webview', (event) => event.preventDefault());
  mainWindow.on('close', (event) => {
    if (!quitting && tray && store.getSettings().minimizeToTray) {
      event.preventDefault();
      mainWindow?.hide();
    } else if (!quitReady && operation) {
      event.preventDefault();
      app.quit();
    }
  });
  mainWindow.on('closed', () => {
    mainWindow = null;
  });
  mainWindow.once('ready-to-show', () => mainWindow?.show());
  await mainWindow.loadURL(devUrl ?? 'burrow://app/index.html');
}
function showWindow() {
  if (!store || !app.isReady() || quitting) return;
  if (!mainWindow)
    void createWindow().catch((error) =>
      dialog.showErrorBox(
        'Burrow could not open',
        error instanceof Error ? error.message : String(error),
      ),
    );
  else {
    mainWindow.show();
    mainWindow.restore();
    mainWindow.focus();
  }
}
async function prepareQuit(): Promise<void> {
  const drained = await drainWithin(
    (async () => {
      await operationCompletion;
      await sampling?.catch(() => undefined);
      await store?.flush();
    })(),
    15_000,
  );
  if (drained.status !== 'complete') {
    quitting = false;
    if (store) scheduleSample();
    showWindow();
    const detail =
      drained.status === 'timeout'
        ? 'Windows is still finishing an operation or Burrow is saving its receipt. Burrow will stay open so the result can be recorded. No further items will be moved. Try quitting again after it finishes.'
        : 'Burrow could not save its latest activity. It will stay open so the receipt can be retried. Check that the app data folder is writable, then try quitting again.';
    dialog.showErrorBox('Burrow is still finishing up', detail);
    return;
  }
  quitReady = true;
  tray?.destroy();
  tray = null;
  app.quit();
}
if (!app.requestSingleInstanceLock()) app.quit();
else {
  app.on('second-instance', showWindow);
  app
    .whenReady()
    .then(async () => {
      app.setAppUserModelId('computer.burrow.windows.typescript');
      // A separate data folder keeps the WinUI preview's history untouched.
      const devData =
        !app.isPackaged &&
        process.env.BURROW_DEV_DATA_DIR &&
        path.isAbsolute(process.env.BURROW_DEV_DATA_DIR)
          ? process.env.BURROW_DEV_DATA_DIR
          : undefined;
      app.setPath('userData', devData ?? path.join(app.getPath('appData'), 'BurrowTypeScript'));
      store = new LocalStore(app.getPath('userData'));
      await store.init();
      protocol.handle('burrow', (request) => {
        try {
          const url = new URL(request.url);
          if (url.host !== 'app' || !['GET', 'HEAD'].includes(request.method))
            return new Response('Forbidden', { status: 403 });
          const root = path.join(app.getAppPath(), 'dist');
          const file = path.resolve(root, `.${decodeURIComponent(url.pathname)}`);
          if (
            path.relative(root, file).startsWith('..') ||
            path.isAbsolute(path.relative(root, file))
          )
            return new Response('Forbidden', { status: 403 });
          return net.fetch(pathToFileURL(file).toString());
        } catch {
          return new Response('Invalid request', { status: 400 });
        }
      });
      session.defaultSession.setPermissionRequestHandler((_contents, _permission, callback) =>
        callback(false),
      );
      session.defaultSession.setPermissionCheckHandler(() => false);
      Menu.setApplicationMenu(null);
      registerIPC();
      try {
        const source = nativeImage.createFromPath(appIcon());
        if (source.isEmpty()) throw new Error('Tray icon unavailable');
        const icon = source.resize({ width: 20, height: 20 });
        tray = new Tray(icon);
        tray.setToolTip('Burrow');
        tray.setContextMenu(
          Menu.buildFromTemplate([
            { label: 'Open Burrow', click: showWindow },
            { type: 'separator' },
            { label: 'Quit Burrow', click: () => app.quit() },
          ]),
        );
        tray.on('click', showWindow);
      } catch {
        tray = null;
      }
      await createWindow();
      try {
        await sample();
      } catch (error) {
        console.error(
          'Initial system sample unavailable:',
          error instanceof Error ? error.message : 'Unknown error',
        );
      }
      scheduleSample();
    })
    .catch((error) => {
      dialog.showErrorBox(
        'Burrow could not start',
        error instanceof Error ? error.message : String(error),
      );
      app.quit();
    });
  app.on('activate', showWindow);
  app.on('window-all-closed', () => {
    if (!tray || !store?.getSettings().minimizeToTray) app.quit();
  });
  app.on('before-quit', (event) => {
    if (quitReady) return;
    event.preventDefault();
    if (shutdown) return;
    quitting = true;
    clearTimeout(timer);
    scanner.cancel();
    stopRequested = true;
    shutdown = prepareQuit().finally(() => {
      shutdown = null;
    });
  });
}
