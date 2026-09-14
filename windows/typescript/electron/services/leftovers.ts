import { randomUUID } from 'node:crypto';
import type { Stats } from 'node:fs';
import { lstat, opendir, realpath } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import type {
  InstalledApp,
  LeftoverEntry,
  LeftoverReport,
  LeftoverScope,
  ScanProgress,
} from '../../src/shared/contracts';

export const LEFTOVER_AGE_DAYS = 60;
export interface LeftoverLimits {
  maxEntries: number;
  maxResults: number;
  maxDepth: number;
  maxDurationMs: number;
}
const DEFAULT_LIMITS: LeftoverLimits = {
  maxEntries: 20_000,
  maxResults: 200,
  maxDepth: 12,
  maxDurationMs: 30_000,
};
const LEAVES = new Map<string, LeftoverEntry['category']>([
  ['cache', 'cache'],
  ['caches', 'cache'],
  ['log', 'logs'],
  ['logs', 'logs'],
]);
const SHARED_FOLDERS = new Set([
  'microsoft',
  'windows',
  'packages',
  'programs',
  'temp',
  'tmp',
  'temporaryinternetfiles',
  'applicationdata',
  'localsettings',
  'local',
  'locallow',
  'roaming',
  'appdata',
  'connecteddevicesplatform',
  'comms',
  'd3dscache',
  'crashdumps',
  'microsoftedge',
  'microsoftedgebackups',
  'packagecache',
  'squirreltemp',
  'npm',
  'pip',
  'nuget',
  'fontcache',
  'tiledatalayer',
  'elevateddiagnostics',
  'virtualstore',
  'publishers',
  'common',
  'shared',
  'startmenu',
  'recent',
  'sendto',
  'templates',
  'credentials',
  'protect',
  'crypto',
  'assembly',
  'isolatedstorage',
  'microsoftshared',
  'onedrive',
  'nvidia',
  'nvidiacorporation',
  'amd',
  'ati',
  'intel',
  'cache',
  'caches',
  'log',
  'logs',
  'userdata',
  'data',
  'config',
  'configuration',
  'settings',
  'preferences',
  'profiles',
  'profile',
  'databases',
  'database',
  'storage',
  'indexeddb',
  'localstorage',
  'serviceworker',
  'sessions',
  'backups',
  'backup',
  'user',
  'users',
]);
const GENERIC_TOKENS = new Set([
  'inc',
  'ltd',
  'llc',
  'corp',
  'corporation',
  'company',
  'limited',
  'software',
  'technologies',
  'technology',
  'version',
  'x64',
  'x86',
  'app',
  'apps',
  'application',
  'applications',
  'client',
  'desktop',
  'windows',
  'update',
  'updater',
  'the',
  'and',
  'for',
]);
type Label = { compact: string; tokens: Set<string> };
type Context = {
  controller: AbortController;
  report: LeftoverReport;
  started: number;
  lastProgress: number;
  bytes: number;
  progress?: (progress: ScanProgress) => void;
};
type Measurement = { bytes: number; complete: boolean; observed: Map<string, string> };
class StopScan extends Error {}

/** Read-only hints, never uninstall detection or an authorization to remove AppData. */
export class LeftoversService {
  private active: Context | undefined;
  private readonly roots: Record<LeftoverScope, string>;
  private readonly limits: LeftoverLimits;
  private readonly testRoots: boolean;

  constructor(
    private readonly getApps: () => Promise<InstalledApp[]>,
    options: { roots?: Record<LeftoverScope, string>; limits?: Partial<LeftoverLimits> } = {},
  ) {
    this.testRoots = !!options.roots;
    this.roots = options.roots ?? {
      local: path.join(os.homedir(), 'AppData', 'Local'),
      roaming: path.join(os.homedir(), 'AppData', 'Roaming'),
    };
    this.limits = { ...DEFAULT_LIMITS, ...options.limits };
  }

  cancel(): void {
    this.active?.controller.abort();
  }

  /** Roots are selected inside the service; the caller may only choose Local or Roaming. */
  async scan(
    scope: LeftoverScope,
    progress?: (progress: ScanProgress) => void,
  ): Promise<LeftoverReport> {
    if (scope !== 'local' && scope !== 'roaming')
      throw new Error('Choose Local or Roaming AppData');
    if (!this.testRoots && process.platform !== 'win32')
      throw new Error('Possible leftover discovery is available on Windows');
    this.cancel();
    const ctx: Context = {
      controller: new AbortController(),
      started: Date.now(),
      lastProgress: 0,
      bytes: 0,
      progress,
      report: {
        id: randomUUID(),
        scope,
        root: this.roots[scope],
        entries: [],
        installedApps: 0,
        scanned: 0,
        skipped: 0,
        truncated: false,
        cancelled: false,
        timestamp: Date.now(),
      },
    };
    this.active = ctx;
    try {
      const root = await validateRoot(this.roots[scope]);
      ctx.report.root = root;
      this.emit(ctx, root, true);
      const apps = await this.inventory(ctx);
      const labels = apps
        .flatMap((app) => [normalize(app.name), normalize(app.publisher)])
        .filter((label) => label.compact.length >= 3);
      if (!labels.length)
        throw new Error(
          'Desktop-app inventory is empty or unavailable. No leftovers were suggested.',
        );
      ctx.report.installedApps = apps.length;
      for await (const { file, stat } of this.children(ctx, root)) {
        const name = path.basename(file);
        if (
          !stat.isDirectory() ||
          stat.isSymbolicLink() ||
          !appShaped(name) ||
          matchesInventory(name, labels)
        ) {
          ctx.report.skipped++;
          continue;
        }
        // Only immediate exact cache/log leaves. Do not search profiles, settings, or databases.
        for await (const child of this.children(ctx, file)) {
          const category = LEAVES.get(path.basename(child.file).toLowerCase());
          if (!category || !child.stat.isDirectory() || child.stat.isSymbolicLink()) {
            ctx.report.skipped++;
            continue;
          }
          const cutoff = Date.now() - LEFTOVER_AGE_DAYS * 86_400_000;
          const measured = await this.measure(ctx, child.file, 0, cutoff);
          if (
            !measured.complete ||
            measured.observed.get(child.file) !== fingerprint(child.stat) ||
            !(await this.unchanged(ctx, measured.observed))
          ) {
            ctx.report.skipped++;
            continue;
          }
          this.check(ctx, child.file);
          ctx.report.entries.push({
            id: randomUUID(),
            name: `${name} / ${path.basename(child.file)}`,
            path: child.file,
            bytes: measured.bytes,
            modified: child.stat.mtimeMs,
            category,
            evidence: [
              `No normalized folder-name match for “${name}” in registered desktop-app names or publishers.`,
              `This exact ${category === 'cache' ? 'cache' : 'log'} folder and every measured descendant were last modified at least ${LEFTOVER_AGE_DAYS} days ago.`,
              'Possible leftover only: portable apps, Store apps, and unregistered software may still use this folder. Inventory absence does not prove an app was uninstalled.',
            ],
          });
        }
      }
    } catch (error) {
      if (!(error instanceof StopScan)) throw error;
    } finally {
      ctx.report.cancelled = ctx.controller.signal.aborted;
      ctx.report.entries.sort((a, b) => b.bytes - a.bytes || a.path.localeCompare(b.path));
      if (this.active === ctx) this.active = undefined;
      this.emit(ctx, ctx.report.root, true);
    }
    return structuredClone(ctx.report);
  }

  private async inventory(ctx: Context): Promise<InstalledApp[]> {
    this.check(ctx);
    const apps = await new Promise<InstalledApp[]>((resolve, reject) => {
      const stopped = () => finish(new StopScan());
      const timeout = setTimeout(
        () => {
          ctx.report.truncated = true;
          finish(new Error('Desktop-app inventory timed out. No leftovers were suggested.'));
        },
        Math.max(1, this.limits.maxDurationMs - (Date.now() - ctx.started)),
      );
      const finish = (error?: unknown, result?: InstalledApp[]) => {
        clearTimeout(timeout);
        ctx.controller.signal.removeEventListener('abort', stopped);
        if (error) reject(error);
        else resolve(result!);
      };
      ctx.controller.signal.addEventListener('abort', stopped, { once: true });
      Promise.resolve()
        .then(this.getApps)
        .then(
          (result) => finish(undefined, result),
          () => finish(new Error('Desktop-app inventory failed. No leftovers were suggested.')),
        );
    });
    this.check(ctx);
    if (!Array.isArray(apps) || !apps.length)
      throw new Error(
        'Desktop-app inventory is empty or unavailable. No leftovers were suggested.',
      );
    return apps;
  }

  private check(ctx: Context, file = ctx.report.root): void {
    if (ctx.controller.signal.aborted) throw new StopScan();
    if (
      ctx.report.scanned >= this.limits.maxEntries ||
      ctx.report.entries.length >= this.limits.maxResults ||
      Date.now() - ctx.started >= this.limits.maxDurationMs
    ) {
      ctx.report.truncated = true;
      throw new StopScan();
    }
    this.emit(ctx, file);
  }
  private emit(ctx: Context, file: string, force = false): void {
    if (ctx.progress && (force || Date.now() - ctx.lastProgress > 150)) {
      ctx.lastProgress = Date.now();
      ctx.progress({ scanned: ctx.report.scanned, bytes: ctx.bytes, path: file });
    }
  }
  private async *children(
    ctx: Context,
    directory: string,
  ): AsyncGenerator<{ file: string; stat: Stats }> {
    this.check(ctx, directory);
    let handle;
    try {
      await assertNoLinks(directory);
      handle = await opendir(directory);
    } catch {
      ctx.report.skipped++;
      return;
    }
    for await (const child of handle) {
      this.check(ctx, directory);
      const file = path.join(directory, child.name);
      ctx.report.scanned++;
      try {
        yield { file, stat: await lstat(file) };
      } catch (error) {
        if (error instanceof StopScan) throw error;
        ctx.report.skipped++;
      }
    }
  }
  private async measure(
    ctx: Context,
    directory: string,
    depth: number,
    cutoff: number,
  ): Promise<Measurement> {
    this.check(ctx, directory);
    const result: Measurement = { bytes: 0, complete: false, observed: new Map() };
    if (depth > this.limits.maxDepth) {
      ctx.report.truncated = true;
      return result;
    }
    let before: Stats;
    try {
      before = await lstat(directory);
    } catch {
      return result;
    }
    if (!before.isDirectory() || before.isSymbolicLink() || before.mtimeMs > cutoff) return result;
    result.observed.set(directory, fingerprint(before));
    const skipped = ctx.report.skipped;
    result.complete = true;
    for await (const { file, stat } of this.children(ctx, directory)) {
      if (
        stat.isSymbolicLink() ||
        (!stat.isFile() && !stat.isDirectory()) ||
        stat.mtimeMs > cutoff
      ) {
        result.complete = false;
        continue;
      }
      if (stat.isDirectory()) {
        const child = await this.measure(ctx, file, depth + 1, cutoff);
        result.complete &&= child.complete;
        result.bytes += child.bytes;
        for (const [name, value] of child.observed) result.observed.set(name, value);
      } else {
        result.bytes += stat.size;
        ctx.bytes += stat.size;
        result.observed.set(file, fingerprint(stat));
      }
    }
    result.complete &&= skipped === ctx.report.skipped;
    return result;
  }
  private async unchanged(ctx: Context, observed: Map<string, string>): Promise<boolean> {
    for (const [file, original] of observed) {
      this.check(ctx, file);
      try {
        await assertNoLinks(file);
        if (fingerprint(await lstat(file)) !== original) return false;
      } catch {
        return false;
      }
    }
    return true;
  }
}

function normalize(value: string): Label {
  const parts =
    value
      .replace(/([a-z])([A-Z])/g, '$1 $2')
      .normalize('NFKD')
      .replace(/\p{M}/gu, '')
      .toLowerCase()
      .match(/[\p{L}\p{N}]+/gu) ?? [];
  return {
    compact: parts.join(''),
    tokens: new Set(
      parts.filter((part) => part.length >= 3 && !GENERIC_TOKENS.has(part) && /\p{L}/u.test(part)),
    ),
  };
}
function appShaped(name: string): boolean {
  const label = normalize(name);
  return (
    !name.startsWith('.') &&
    label.compact.length >= 3 &&
    label.tokens.size > 0 &&
    !SHARED_FOLDERS.has(label.compact) &&
    !/^[\da-f-]{16,}$/i.test(name)
  );
}
function matchesInventory(folder: string, labels: Label[]): boolean {
  const label = normalize(folder);
  return labels.some(
    (installed) =>
      (label.compact.length >= 4 &&
        installed.compact.length >= 4 &&
        (installed.compact.includes(label.compact) || label.compact.includes(installed.compact))) ||
      [...label.tokens].some((token) => installed.tokens.has(token)),
  );
}
function fingerprint(stat: Stats): string {
  return [
    stat.dev,
    stat.ino,
    stat.mode,
    stat.size,
    stat.mtimeMs,
    stat.ctimeMs,
    stat.birthtimeMs,
  ].join(':');
}
async function validateRoot(root: string): Promise<string> {
  if (
    typeof root !== 'string' ||
    !path.isAbsolute(root) ||
    root.includes('\0') ||
    root.length > 32_000 ||
    /^\\\\/.test(root) ||
    (process.platform === 'win32' && root.slice(2).includes(':'))
  )
    throw new Error('Leftovers requires a fixed absolute local AppData folder');
  const normalized = path.resolve(root);
  if (normalized === path.parse(normalized).root || normalized === path.resolve(os.homedir()))
    throw new Error('A drive or profile root cannot be used for leftovers');
  await assertNoLinks(normalized);
  const stat = await lstat(normalized);
  if (!stat.isDirectory() || stat.isSymbolicLink())
    throw new Error('Leftovers requires an existing folder without links or junctions');
  const canonical = await realpath(normalized);
  if (path.relative(normalized, canonical) !== '')
    throw new Error('Symbolic links and junctions are not followed');
  return canonical;
}
async function assertNoLinks(file: string): Promise<void> {
  let cursor = path.resolve(file);
  while (true) {
    if ((await lstat(cursor)).isSymbolicLink())
      throw new Error('Symbolic links and junctions are not followed');
    const parent = path.dirname(cursor);
    if (parent === cursor) return;
    cursor = parent;
  }
}
