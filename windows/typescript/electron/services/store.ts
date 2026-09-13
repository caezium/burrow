import { mkdir, readFile, rename, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import {
  DEFAULT_SETTINGS,
  type ActivityEntry,
  type Settings,
  type Snapshot,
} from '../../src/shared/contracts';

const MAX_HISTORY = 10_080;
const MAX_ACTIVITY = 300;
const MAX_FILE_BYTES = 24 * 1024 * 1024;
type State = { version: 1; settings: Settings; history: Snapshot[]; activity: ActivityEntry[] };

export function sanitizeSettings(value: unknown): Settings {
  const raw = value && typeof value === 'object' ? (value as Partial<Settings>) : {};
  const bounded = (n: unknown, fallback: number, min: number, max: number) =>
    typeof n === 'number' && Number.isFinite(n)
      ? Math.min(max, Math.max(min, Math.round(n)))
      : fallback;
  return {
    theme: raw.theme === 'light' || raw.theme === 'dark' ? raw.theme : 'system',
    sampleInterval: bounded(raw.sampleInterval, DEFAULT_SETTINGS.sampleInterval, 2, 60),
    retentionDays: bounded(raw.retentionDays, DEFAULT_SETTINGS.retentionDays, 1, 90),
    minimizeToTray:
      typeof raw.minimizeToTray === 'boolean'
        ? raw.minimizeToTray
        : DEFAULT_SETTINGS.minimizeToTray,
  };
}

/** Single-writer local JSON store. History is downsampled to fit the retention window. */
export class LocalStore {
  private state: State = {
    version: 1,
    settings: { ...DEFAULT_SETTINGS },
    history: [],
    activity: [],
  };
  private pending: Promise<void> = Promise.resolve();
  private timer: ReturnType<typeof setTimeout> | undefined;
  private dirty = false;
  private readonly file: string;
  constructor(private readonly directory: string) {
    this.file = join(directory, 'burrow-state.json');
  }

  async init(): Promise<void> {
    await mkdir(this.directory, { recursive: true });
    try {
      const { stat } = await import('node:fs/promises');
      if ((await stat(this.file)).size > MAX_FILE_BYTES)
        throw new Error('Stored history exceeds the size limit');
      const raw = JSON.parse(await readFile(this.file, 'utf8')) as Partial<State>;
      this.state.settings = sanitizeSettings(raw.settings);
      this.state.history = Array.isArray(raw.history)
        ? raw.history.filter(isSnapshot).slice(-MAX_HISTORY)
        : [];
      this.state.activity = Array.isArray(raw.activity)
        ? raw.activity.filter(isActivity).slice(0, MAX_ACTIVITY)
        : [];
      this.prune();
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== 'ENOENT') {
        // Preserve an unreadable store for recovery instead of silently overwriting it.
        await rename(this.file, `${this.file}.corrupt-${Date.now()}`).catch(() => undefined);
      }
    }
  }

  getSettings(): Settings {
    return { ...this.state.settings };
  }
  async saveSettings(settings: Settings): Promise<Settings> {
    this.state.settings = sanitizeSettings(settings);
    this.prune();
    this.dirty = true;
    await this.flush();
    return this.getSettings();
  }
  getHistory(since: number): Snapshot[] {
    const cutoff = Number.isFinite(since) ? since : 0;
    this.prune();
    return structuredClone(this.state.history.filter((point) => point.timestamp >= cutoff));
  }
  getActivity(): ActivityEntry[] {
    return structuredClone(this.state.activity);
  }
  addSnapshot(snapshot: Snapshot): void {
    const last = this.state.history.at(-1);
    const bucketMs =
      Math.max(1, Math.ceil((this.state.settings.retentionDays * 24 * 60) / MAX_HISTORY)) * 60_000;
    if (last && Math.floor(last.timestamp / bucketMs) === Math.floor(snapshot.timestamp / bucketMs))
      return;
    // Process lists are live-only: retaining every process costs space and can reveal document names.
    this.state.history.push({ ...structuredClone(snapshot), processes: [] });
    this.prune();
    this.schedule();
  }
  addActivity(entry: Omit<ActivityEntry, 'id' | 'timestamp'>): ActivityEntry {
    const item = { ...entry, id: randomUUID(), timestamp: Date.now() };
    this.state.activity.unshift(item);
    this.state.activity.length = Math.min(this.state.activity.length, MAX_ACTIVITY);
    this.schedule();
    return { ...item };
  }
  private prune(): void {
    const cutoff = Date.now() - this.state.settings.retentionDays * 86_400_000;
    this.state.history = this.state.history
      .filter((point) => point.timestamp >= cutoff)
      .slice(-MAX_HISTORY);
  }
  private schedule(): void {
    this.dirty = true;
    if (!this.timer) {
      this.timer = setTimeout(() => {
        this.timer = undefined;
        void this.flush().catch(() => undefined);
      }, 5_000);
      this.timer.unref?.();
    }
  }
  async flush(): Promise<void> {
    if (this.timer) {
      clearTimeout(this.timer);
      this.timer = undefined;
    }
    if (!this.dirty) return this.pending;
    this.dirty = false;
    const body = JSON.stringify(this.state);
    this.pending = this.pending
      .catch(() => undefined)
      .then(async () => {
        const temp = `${this.file}.${randomUUID()}.tmp`;
        await writeFile(temp, body, { encoding: 'utf8', mode: 0o600 });
        await rename(temp, this.file);
      });
    try {
      await this.pending;
    } catch (error) {
      this.dirty = true;
      throw error;
    }
  }
}

function isSnapshot(value: unknown): value is Snapshot {
  if (!value || typeof value !== 'object') return false;
  const s = value as Snapshot;
  return (
    Number.isFinite(s.timestamp) &&
    typeof s.hostname === 'string' &&
    typeof s.platform === 'string' &&
    !!s.cpu &&
    Number.isFinite(s.cpu.usage) &&
    !!s.memory &&
    Number.isFinite(s.memory.total) &&
    Array.isArray(s.disks) &&
    Array.isArray(s.network) &&
    Array.isArray(s.processes) &&
    Array.isArray(s.warnings)
  );
}
function isActivity(value: unknown): value is ActivityEntry {
  if (!value || typeof value !== 'object') return false;
  const e = value as ActivityEntry;
  return (
    typeof e.id === 'string' &&
    Number.isFinite(e.timestamp) &&
    typeof e.title === 'string' &&
    typeof e.detail === 'string' &&
    ['success', 'partial', 'error', 'cancelled'].includes(e.status) &&
    Number.isFinite(e.bytes)
  );
}
