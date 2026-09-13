export type Route =
  | 'monitor'
  | 'clean'
  | 'optimize'
  | 'apps'
  | 'analyze'
  | 'duplicates'
  | 'leftovers'
  | 'photos'
  | 'ports'
  | 'network'
  | 'connectivity'
  | 'settings';
export type ScanKind = 'clean' | 'purge' | 'installers' | 'analyze' | 'duplicates';
export interface ProcessInfo {
  pid: number;
  name: string;
  cpu: number;
  memory: number;
}
export interface Snapshot {
  timestamp: number;
  hostname: string;
  platform: string;
  osVersion: string;
  uptime: number;
  cpu: { usage: number; cores: number; model: string };
  memory: { used: number; total: number; percent: number };
  disks: { name: string; mount: string; used: number; total: number }[];
  network: { name: string; address: string; rx: number | null; tx: number | null }[];
  battery: { percent: number; charging: boolean } | null;
  processes: ProcessInfo[];
  warnings: string[];
}
export interface Settings {
  theme: 'system' | 'dark' | 'light';
  sampleInterval: number;
  retentionDays: number;
  minimizeToTray: boolean;
}
export interface ActivityEntry {
  id: string;
  timestamp: number;
  title: string;
  detail: string;
  status: 'success' | 'partial' | 'error' | 'cancelled';
  bytes: number;
}
export interface ScanEntry {
  id: string;
  name: string;
  path: string;
  bytes: number;
  category: string;
  modified: number;
  isDirectory: boolean;
  group?: string;
}
export interface ScanResult {
  id: string;
  kind: ScanKind;
  root: string;
  entries: ScanEntry[];
  totalBytes: number;
  scanned: number;
  skipped: number;
  truncated: boolean;
  cancelled: boolean;
  timestamp: number;
}
export interface ScanProgress {
  scanned: number;
  bytes: number;
  path: string;
}
export type LeftoverScope = 'local' | 'roaming';
export interface LeftoverEntry {
  id: string;
  name: string;
  path: string;
  bytes: number;
  modified: number;
  category: 'cache' | 'logs';
  evidence: string[];
}
export interface LeftoverReport {
  id: string;
  scope: LeftoverScope;
  root: string;
  entries: LeftoverEntry[];
  installedApps: number;
  scanned: number;
  skipped: number;
  truncated: boolean;
  cancelled: boolean;
  timestamp: number;
}
export interface RecycleResult {
  recycled: number;
  recycledIds: string[];
  bytes: number;
  failures: string[];
  cancelled: boolean;
}
export interface InstalledApp {
  id: string;
  name: string;
  version: string;
  publisher: string;
  size: number;
  installDate: string;
}
export interface PortInfo {
  port: number;
  address: string;
  pid: number;
  name: string;
  protocol: string;
}
export interface Diagnostic {
  name: string;
  status: 'pass' | 'warning' | 'fail';
  detail: string;
}
export interface BurrowAPI {
  readonly mode: 'desktop' | 'preview';
  getSnapshot(): Promise<Snapshot>;
  getHistory(since: number): Promise<Snapshot[]>;
  getActivity(): Promise<ActivityEntry[]>;
  getSettings(): Promise<Settings>;
  saveSettings(settings: Settings): Promise<Settings>;
  chooseFolder(): Promise<string | null>;
  scan(kind: ScanKind, root?: string): Promise<ScanResult>;
  scanLeftovers(scope: LeftoverScope): Promise<LeftoverReport>;
  cancelScan(): Promise<void>;
  recycle(scanId: string, ids: string[]): Promise<RecycleResult>;
  reveal(path: string): Promise<void>;
  getApps(): Promise<InstalledApp[]>;
  openAppsSettings(): Promise<void>;
  getPorts(): Promise<PortInfo[]>;
  diagnose(): Promise<Diagnostic[]>;
  optimize(action: 'flush-dns'): Promise<string>;
  windowAction(action: 'minimize' | 'maximize' | 'close'): Promise<void>;
  onSnapshot(callback: (snapshot: Snapshot) => void): () => void;
  onScanProgress(callback: (progress: ScanProgress) => void): () => void;
}
export const DEFAULT_SETTINGS: Settings = {
  theme: 'system',
  sampleInterval: 3,
  retentionDays: 30,
  minimizeToTray: true,
};
