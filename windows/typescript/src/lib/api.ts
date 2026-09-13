import {
  DEFAULT_SETTINGS,
  type BurrowAPI,
  type Settings,
  type Snapshot,
  type ScanResult,
  type ScanKind,
} from '../shared/contracts';

declare global {
  interface Window {
    burrow?: BurrowAPI;
  }
}
const GB = 1024 ** 3;
const example: Snapshot = {
  timestamp: Date.now(),
  hostname: 'DESKTOP-BURROW',
  platform: 'win32',
  osVersion: 'Windows 11 · example device',
  uptime: 183420,
  cpu: { usage: 18.6, cores: 16, model: 'AMD Ryzen 7 9700X' },
  memory: { used: 12.8 * GB, total: 32 * GB, percent: 40 },
  disks: [{ name: 'Windows', mount: 'C:\\', used: 342 * GB, total: 953 * GB }],
  network: [{ name: 'Ethernet', address: '192.168.1.42', rx: 845312, tx: 92160 }],
  battery: null,
  processes: [
    { pid: 12480, name: 'Code.exe', cpu: 6.4, memory: 824 * 1024 ** 2 },
    { pid: 8612, name: 'msedge.exe', cpu: 3.2, memory: 1204 * 1024 ** 2 },
    { pid: 2036, name: 'explorer.exe', cpu: 1.8, memory: 186 * 1024 ** 2 },
    { pid: 19040, name: 'Burrow.exe', cpu: 0.6, memory: 142 * 1024 ** 2 },
    { pid: 4680, name: 'WindowsTerminal.exe', cpu: 0.3, memory: 84 * 1024 ** 2 },
    { pid: 9024, name: 'SearchHost.exe', cpu: 0.1, memory: 76 * 1024 ** 2 },
  ],
  warnings: [],
};
let previewSettings: Settings = { ...DEFAULT_SETTINGS, theme: 'dark' };
let cancelled = false;
const unavailable = async (): Promise<never> => {
  throw new Error('Open the desktop app to use this feature on your computer.');
};
const preview: BurrowAPI = {
  mode: 'preview',
  getSnapshot: async () => ({ ...example, timestamp: Date.now() }),
  getHistory: async (since) =>
    Array.from({ length: 90 }, (_, i) => ({
      ...example,
      timestamp: Date.now() - (89 - i) * 30000,
      cpu: { ...example.cpu, usage: 18 + Math.sin(i * 0.7) * 8 + Math.cos(i * 0.21) * 5 },
      memory: { ...example.memory, percent: 38 + Math.sin(i / 14) * 3 },
    })).filter((s) => s.timestamp >= since),
  getActivity: async () => [],
  getSettings: async () => previewSettings,
  saveSettings: async (settings) => (previewSettings = settings),
  chooseFolder: async () => 'C:\\Users\\You\\Projects',
  scan: async (kind: ScanKind, root?: string): Promise<ScanResult> => {
    cancelled = false;
    await new Promise((resolve) => setTimeout(resolve, 650));
    const names =
      kind === 'purge'
        ? ['website\\node_modules', 'burrow\\target', 'api\\__pycache__']
        : kind === 'installers'
          ? ['VSCodeSetup.exe', 'Git-2.49.0.exe', 'PowerToysSetup.msi']
          : kind === 'analyze'
            ? ['Projects', 'Downloads', 'Documents', 'Pictures', 'Videos']
            : kind === 'duplicates'
              ? ['report.pdf', 'report-copy.pdf', 'report-backup.pdf']
              : ['old-session.tmp', 'installer-cache', 'crash-report.tmp'];
    const previewRoot =
      root ??
      (kind === 'clean' ? 'C:\\Users\\You\\AppData\\Local\\Temp' : 'C:\\Users\\You\\Downloads');
    const entries = cancelled
      ? []
      : names.map((name, index) => ({
          id: `preview-${index}`,
          name,
          path: `${previewRoot}\\${name}`,
          bytes:
            (kind === 'duplicates' ? 1 : names.length - index) *
            (kind === 'analyze' ? 4.6 * GB : 0.24 * GB),
          category: kind === 'clean' ? 'Temporary files · older than 7 days' : kind,
          modified: Date.now() - 86400000 * 45,
          isDirectory: kind === 'analyze' || kind === 'purge' || (kind === 'clean' && index === 1),
          ...(kind === 'duplicates' ? { group: 'example-match' } : {}),
        }));
    return {
      id: 'preview-scan',
      kind,
      root: previewRoot,
      entries,
      totalBytes: entries.reduce((n, e) => n + e.bytes, 0),
      scanned: entries.length,
      skipped: 0,
      truncated: false,
      cancelled,
      timestamp: Date.now(),
    };
  },
  cancelScan: async () => {
    cancelled = true;
  },
  recycle: unavailable,
  reveal: unavailable,
  getApps: async () => [
    {
      id: 'code',
      name: 'Visual Studio Code',
      publisher: 'Microsoft',
      version: '1.105.0',
      size: 410 * 1024 ** 2,
      installDate: '2026-08-24',
    },
    {
      id: 'firefox',
      name: 'Mozilla Firefox',
      publisher: 'Mozilla',
      version: '142.0',
      size: 280 * 1024 ** 2,
      installDate: '2026-08-12',
    },
  ],
  openAppsSettings: unavailable,
  getPorts: async () => [
    { port: 5173, address: '127.0.0.1', pid: 12480, name: 'node.exe', protocol: 'TCP' },
  ],
  diagnose: async () => [
    {
      name: 'Example network adapter',
      status: 'pass',
      detail: 'Ethernet · 192.168.1.42. Preview data; no network checks were performed.',
    },
  ],
  optimize: unavailable,
  windowAction: async () => {},
  onSnapshot: () => () => {},
  onScanProgress: () => () => {},
};
export const api: BurrowAPI = window.burrow ?? preview;
