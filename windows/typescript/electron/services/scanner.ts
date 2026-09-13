import { constants, type Stats } from 'node:fs';
import { lstat, open, opendir, realpath } from 'node:fs/promises';
import { createHash, randomUUID } from 'node:crypto';
import os from 'node:os';
import path from 'node:path';
import type { ScanEntry, ScanKind, ScanProgress, ScanResult } from '../../src/shared/contracts';

export interface ScanLimits {
  maxEntries: number;
  maxResults: number;
  maxDepth: number;
  maxDurationMs: number;
  maxHashBytes: number;
  maxFileBytes: number;
}
const DEFAULT_LIMITS: ScanLimits = {
  maxEntries: 40_000,
  maxResults: 4_000,
  maxDepth: 32,
  maxDurationMs: 60_000,
  maxHashBytes: 2 * 1024 ** 3,
  maxFileBytes: 512 * 1024 ** 2,
};
type Candidate = { entry: ScanEntry; fingerprint: string; treeFingerprint?: string };
type Context = {
  controller: AbortController;
  result: ScanResult;
  started: number;
  lastProgress: number;
  progress?: (progress: ScanProgress) => void;
  bytes: number;
  hashBytes: number;
  candidates: Map<string, Candidate>;
};
type TreeSize = { bytes: number; digest: string; safe: boolean };
class StopScan extends Error {}

export class ScanService {
  private active: Context | undefined;
  private latest: { result: ScanResult; candidates: Map<string, Candidate> } | undefined;
  private readonly limits: ScanLimits;
  constructor(limits: Partial<ScanLimits> = {}) {
    this.limits = { ...DEFAULT_LIMITS, ...limits };
  }

  cancel(): void {
    this.active?.controller.abort();
  }
  getResult(scanId: string): ScanResult | undefined {
    return this.latest?.result.id === scanId ? structuredClone(this.latest.result) : undefined;
  }
  async scan(
    kind: ScanKind,
    root?: string,
    progress?: (progress: ScanProgress) => void,
  ): Promise<ScanResult> {
    if (!['clean', 'purge', 'installers', 'analyze', 'duplicates'].includes(kind))
      throw new Error('Unknown scan kind');
    this.cancel();
    this.latest = undefined;
    const chosenRoot = root || defaultRoot(kind);
    const ctx: Context = {
      controller: new AbortController(),
      started: Date.now(),
      lastProgress: 0,
      progress,
      bytes: 0,
      hashBytes: 0,
      candidates: new Map(),
      result: {
        id: randomUUID(),
        kind,
        root: chosenRoot,
        entries: [],
        totalBytes: 0,
        scanned: 0,
        skipped: 0,
        truncated: false,
        cancelled: false,
        timestamp: Date.now(),
      },
    };
    this.active = ctx;
    try {
      const checkedRoot = await validateRoot(chosenRoot, kind === 'purge' || kind === 'installers');
      ctx.result.root = checkedRoot;
      this.emit(ctx, checkedRoot, true);
      if (kind === 'clean' || kind === 'analyze') await this.analyze(ctx, checkedRoot);
      else if (kind === 'purge') await this.purge(ctx, checkedRoot, 0);
      else if (kind === 'installers') await this.installers(ctx, checkedRoot);
      else await this.duplicates(ctx, checkedRoot);
    } catch (error) {
      if (!(error instanceof StopScan)) throw error;
    } finally {
      ctx.result.cancelled = ctx.controller.signal.aborted;
      ctx.result.entries.sort((a, b) => b.bytes - a.bytes || a.path.localeCompare(b.path));
      ctx.result.totalBytes = ctx.result.entries.reduce((sum, item) => sum + item.bytes, 0);
      if (this.active === ctx) {
        this.active = undefined;
        if (!ctx.result.cancelled)
          this.latest = { result: structuredClone(ctx.result), candidates: ctx.candidates };
      }
      this.emit(ctx, ctx.result.root, true);
    }
    return structuredClone(ctx.result);
  }

  /** Validates server-owned IDs, never renderer-supplied file paths. Does not delete anything. */
  async validateRecycle(scanId: string, ids: string[]): Promise<ScanEntry[]> {
    const latest = this.requireLatest(scanId);
    if (
      !Array.isArray(ids) ||
      ids.length === 0 ||
      ids.length > 200 ||
      ids.some((id) => typeof id !== 'string')
    )
      throw new Error('Select between 1 and 200 scanned items');
    if (new Set(ids).size !== ids.length)
      throw new Error('Duplicate selection IDs are not allowed');
    const selected: ScanEntry[] = [];
    for (const id of ids) {
      const candidate = latest.candidates.get(id);
      if (!candidate)
        throw new Error('This item was not authorized by the latest complete preview');
      selected.push(await this.revalidateEntry(scanId, id));
    }
    return selected;
  }

  /** Call immediately before each native recycle-bin operation, after confirmation. */
  async revalidateEntry(scanId: string, id: string): Promise<ScanEntry> {
    const latest = this.requireLatest(scanId);
    const candidate = latest.candidates.get(id);
    if (!candidate) throw new Error('This item is not in the latest authorized preview');
    const { entry } = candidate;
    const root = await validateRoot(latest.result.root, true);
    if (!isInside(entry.path, root))
      throw new Error('The selected item is outside the preview folder');
    await assertNoSymlinkAncestors(entry.path);
    assertUnprotected(entry.path);
    const stat = await lstat(entry.path);
    if (stat.isSymbolicLink() || fingerprint(stat) !== candidate.fingerprint)
      throw new Error('The selected item changed after preview. Scan again.');
    if (candidate.treeFingerprint) {
      const ctx: Context = {
        controller: new AbortController(),
        started: Date.now(),
        lastProgress: 0,
        bytes: 0,
        hashBytes: 0,
        candidates: new Map(),
        result: { ...latest.result, entries: [], scanned: 0, skipped: 0, truncated: false },
      };
      let measured: TreeSize;
      try {
        measured = await this.measure(ctx, entry.path, 0);
      } catch {
        throw new Error('The directory could not be fully revalidated. Scan again.');
      }
      if (!measured.safe || measured.digest !== candidate.treeFingerprint)
        throw new Error('The directory contents changed after preview. Scan again.');
    }
    this.requireLatest(scanId);
    return { ...entry };
  }

  /** Remove a successfully recycled item from the allowlist to prevent replay. */
  markRecycled(scanId: string, id: string): void {
    if (this.latest?.result.id === scanId) this.latest.candidates.delete(id);
  }

  private requireLatest(scanId: string) {
    if (!this.latest || this.latest.result.id !== scanId)
      throw new Error('Preview expired. Scan again before recycling.');
    if (!['purge', 'installers'].includes(this.latest.result.kind))
      throw new Error(
        'This scan is read-only. Only development artifacts and old installers can be recycled.',
      );
    if (this.latest.result.cancelled)
      throw new Error('Cancelled previews cannot authorize recycling');
    if (Date.now() - this.latest.result.timestamp > 15 * 60_000)
      throw new Error('Preview expired. Scan again before recycling.');
    return this.latest;
  }
  private check(ctx: Context, file = ctx.result.root): void {
    if (ctx.controller.signal.aborted) throw new StopScan();
    if (
      ctx.result.scanned >= this.limits.maxEntries ||
      Date.now() - ctx.started >= this.limits.maxDurationMs ||
      ctx.result.entries.length >= this.limits.maxResults
    ) {
      ctx.result.truncated = true;
      throw new StopScan();
    }
    this.emit(ctx, file);
  }
  private emit(ctx: Context, file: string, force = false): void {
    if (ctx.progress && (force || Date.now() - ctx.lastProgress > 150)) {
      ctx.lastProgress = Date.now();
      ctx.progress({ scanned: ctx.result.scanned, bytes: ctx.bytes, path: file });
    }
  }
  private async *children(
    ctx: Context,
    directory: string,
  ): AsyncGenerator<{ file: string; stat: Stats }> {
    this.check(ctx, directory);
    let handle;
    try {
      await assertNoSymlinkAncestors(directory);
      handle = await opendir(directory);
    } catch {
      ctx.result.skipped++;
      return;
    }
    for await (const item of handle) {
      this.check(ctx, directory);
      const file = path.join(directory, item.name);
      ctx.result.scanned++;
      try {
        const stat = await lstat(file);
        yield { file, stat };
      } catch (error) {
        if (error instanceof StopScan) throw error;
        ctx.result.skipped++;
      }
    }
  }
  private async measure(ctx: Context, directory: string, depth: number): Promise<TreeSize> {
    this.check(ctx, directory);
    if (depth > this.limits.maxDepth) {
      ctx.result.truncated = true;
      return { bytes: 0, digest: '', safe: false };
    }
    const before = await lstat(directory);
    if (!before.isDirectory() || before.isSymbolicLink())
      return { bytes: 0, digest: '', safe: false };
    let bytes = 0;
    let safe = true;
    const children: string[] = [];
    const skippedBefore = ctx.result.skipped;
    for await (const { file, stat } of this.children(ctx, directory)) {
      if (stat.isSymbolicLink() || (!stat.isDirectory() && !stat.isFile())) {
        ctx.result.skipped++;
        safe = false;
        continue;
      }
      if (stat.isDirectory()) {
        const child = await this.measure(ctx, file, depth + 1);
        bytes += child.bytes;
        safe &&= child.safe;
        children.push(`${path.basename(file)}\0${fingerprint(stat)}\0${child.digest}`);
      } else {
        bytes += stat.size;
        ctx.bytes += stat.size;
        children.push(`${path.basename(file)}\0${fingerprint(stat)}`);
      }
    }
    const after = await lstat(directory);
    safe &&= skippedBefore === ctx.result.skipped && fingerprint(before) === fingerprint(after);
    const digest = createHash('sha256')
      .update(fingerprint(before))
      .update(children.sort().join('\n'))
      .digest('hex');
    return { bytes, digest, safe };
  }
  private add(
    ctx: Context,
    file: string,
    stat: Stats,
    bytes: number,
    category: string,
    treeFingerprint?: string,
    group?: string,
  ): void {
    this.check(ctx, file);
    const entry: ScanEntry = {
      id: randomUUID(),
      name: path.basename(file),
      path: file,
      bytes,
      category,
      modified: stat.mtimeMs,
      isDirectory: stat.isDirectory(),
      ...(group ? { group } : {}),
    };
    ctx.result.entries.push(entry);
    ctx.candidates.set(entry.id, {
      entry: { ...entry },
      fingerprint: fingerprint(stat),
      treeFingerprint,
    });
  }
  private async analyze(ctx: Context, root: string): Promise<void> {
    for await (const { file, stat } of this.children(ctx, root)) {
      if (stat.isSymbolicLink()) {
        ctx.result.skipped++;
        continue;
      }
      if (stat.isDirectory()) {
        const size = await this.measure(ctx, file, 0);
        this.add(
          ctx,
          file,
          stat,
          size.bytes,
          ctx.result.kind === 'clean' ? 'Cache preview' : 'Folder',
        );
      } else if (stat.isFile()) {
        ctx.bytes += stat.size;
        this.add(
          ctx,
          file,
          stat,
          stat.size,
          ctx.result.kind === 'clean' ? 'Cache preview' : 'File',
        );
      }
    }
  }
  private async purge(ctx: Context, directory: string, depth: number): Promise<void> {
    if (depth > Math.min(this.limits.maxDepth, 8)) {
      ctx.result.truncated = true;
      return;
    }
    let protectedPath = false;
    try {
      assertUnprotected(directory);
    } catch {
      protectedPath = true;
    }
    if (protectedPath) {
      ctx.result.skipped++;
      return;
    }
    const entries: { file: string; stat: Stats }[] = [];
    for await (const item of this.children(ctx, directory)) entries.push(item);
    const names = new Set(
      entries
        .filter((item) => item.stat.isFile() && !item.stat.isSymbolicLink())
        .map((item) => path.basename(item.file).toLowerCase()),
    );
    for (const { file, stat } of entries) {
      this.check(ctx, file);
      if (stat.isSymbolicLink()) {
        ctx.result.skipped++;
        continue;
      }
      if (!stat.isDirectory()) continue;
      const name = path.basename(file);
      if (name === '.git' || name === '.ssh' || name === '.gnupg') continue;
      const category = artifactCategory(name, names);
      if (category) {
        const size = await this.measure(ctx, file, 0);
        if (size.safe && size.bytes > 0)
          this.add(ctx, file, stat, size.bytes, category, size.digest);
        else ctx.result.skipped++;
      } else if (
        !['node_modules', 'vendor', '.venv', 'venv', 'target', 'bin', 'obj'].includes(name)
      ) {
        await this.purge(ctx, file, depth + 1);
      }
    }
  }
  private async installers(ctx: Context, root: string): Promise<void> {
    const cutoff = Date.now() - 30 * 86_400_000;
    for await (const { file, stat } of this.children(ctx, root)) {
      if (stat.isSymbolicLink()) {
        ctx.result.skipped++;
        continue;
      }
      if (
        stat.isFile() &&
        stat.mtimeMs < cutoff &&
        /\.(exe|msi|msix|msixbundle|iso|zip|7z|rar|tar\.gz)$/i.test(file)
      ) {
        ctx.bytes += stat.size;
        this.add(ctx, file, stat, stat.size, 'Installer / archive · older than 30 days');
      }
    }
  }
  private async duplicates(ctx: Context, root: string): Promise<void> {
    const bySize = new Map<number, { file: string; stat: Stats }[]>();
    const physicalFiles = new Set<string>();
    const walk = async (directory: string, depth: number): Promise<void> => {
      if (depth > this.limits.maxDepth) {
        ctx.result.truncated = true;
        return;
      }
      for await (const item of this.children(ctx, directory)) {
        if (item.stat.isSymbolicLink()) {
          ctx.result.skipped++;
          continue;
        }
        if (item.stat.isDirectory()) {
          if (path.basename(item.file) !== '.git') await walk(item.file, depth + 1);
        } else if (item.stat.isFile() && item.stat.size > 0) {
          if (item.stat.size > this.limits.maxFileBytes) {
            ctx.result.skipped++;
            ctx.result.truncated = true;
            continue;
          }
          // Multiple hard links share the same storage; do not report them as extra copies.
          if (item.stat.ino && item.stat.nlink > 1) {
            const physicalId = `${item.stat.dev}:${item.stat.ino}`;
            if (physicalFiles.has(physicalId)) {
              ctx.result.skipped++;
              continue;
            }
            physicalFiles.add(physicalId);
          }
          const group = bySize.get(item.stat.size) ?? [];
          group.push(item);
          bySize.set(item.stat.size, group);
          ctx.bytes += item.stat.size;
        }
      }
    };
    await walk(root, 0);
    for (const group of bySize.values()) {
      if (group.length < 2) continue;
      const hashes = new Map<string, typeof group>();
      for (const item of group) {
        this.check(ctx, item.file);
        if (ctx.hashBytes + item.stat.size > this.limits.maxHashBytes) {
          ctx.result.truncated = true;
          throw new StopScan();
        }
        let digest;
        try {
          digest = await this.hashFile(ctx, item.file, item.stat);
        } catch (error) {
          if (error instanceof StopScan) throw error;
          ctx.result.skipped++;
          continue;
        }
        const matches = hashes.get(digest) ?? [];
        matches.push(item);
        hashes.set(digest, matches);
      }
      for (const [digest, items] of hashes) {
        if (items.length < 2) continue;
        for (const { file, stat } of items)
          this.add(ctx, file, stat, stat.size, 'SHA-256 match', undefined, digest);
      }
    }
  }
  private async hashFile(ctx: Context, file: string, original: Stats): Promise<string> {
    await assertNoSymlinkAncestors(file);
    const handle = await open(file, constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0));
    try {
      if (fingerprint(await handle.stat()) !== fingerprint(original))
        throw new Error('File changed before hashing');
      const hash = createHash('sha256');
      const buffer = Buffer.allocUnsafe(1024 * 1024);
      let position = 0;
      while (position < original.size) {
        this.check(ctx, file);
        const { bytesRead } = await handle.read(
          buffer,
          0,
          Math.min(buffer.length, original.size - position),
          position,
        );
        if (!bytesRead) throw new Error('File changed while hashing');
        hash.update(buffer.subarray(0, bytesRead));
        position += bytesRead;
        ctx.hashBytes += bytesRead;
      }
      if (
        fingerprint(await handle.stat()) !== fingerprint(original) ||
        fingerprint(await lstat(file)) !== fingerprint(original)
      )
        throw new Error('File changed while hashing');
      return hash.digest('hex');
    } finally {
      await handle.close();
    }
  }
}

function defaultRoot(kind: ScanKind): string {
  if (kind === 'clean') {
    if (process.platform === 'win32') return path.join(os.homedir(), 'AppData', 'Local', 'Temp');
    if (process.platform === 'darwin') return path.join(os.homedir(), 'Library', 'Caches');
    return path.join(os.homedir(), '.cache');
  }
  return path.join(os.homedir(), kind === 'installers' ? 'Downloads' : 'Documents');
}
function artifactCategory(name: string, markers: Set<string>): string | undefined {
  if (
    markers.has('package.json') &&
    ['node_modules', '.next', '.nuxt', '.turbo', '.parcel-cache'].includes(name)
  )
    return 'JavaScript dependencies / cache';
  if (markers.has('cargo.toml') && name === 'target') return 'Rust build output';
  if (
    (markers.has('pom.xml') || markers.has('build.gradle')) &&
    ['target', '.gradle'].includes(name)
  )
    return 'Java build output';
  if (
    [...markers].some((marker) => /\.(csproj|fsproj|vbproj)$/.test(marker)) &&
    ['bin', 'obj'].includes(name)
  )
    return '.NET build output';
  if (
    ['requirements.txt', 'pyproject.toml', 'setup.py'].some((marker) => markers.has(marker)) &&
    ['.venv', '__pycache__', '.pytest_cache', '.mypy_cache'].includes(name)
  )
    return 'Python environment / cache';
  return undefined;
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
function isInside(file: string, root: string): boolean {
  const relative = path.relative(root, file);
  return (
    relative !== '' &&
    !relative.startsWith(`..${path.sep}`) &&
    relative !== '..' &&
    !path.isAbsolute(relative)
  );
}
function assertUnprotected(file: string): void {
  const protectedRoots =
    process.platform === 'win32'
      ? [
          process.env.SystemRoot || 'C:\\Windows',
          process.env.ProgramFiles || 'C:\\Program Files',
          process.env['ProgramFiles(x86)'] || 'C:\\Program Files (x86)',
          process.env.ProgramData || 'C:\\ProgramData',
          path.join(os.homedir(), 'AppData'),
        ]
      : [
          '/System',
          '/Library',
          '/Applications',
          '/usr',
          '/bin',
          '/sbin',
          '/etc',
          '/private/etc',
          '/var',
          '/private/var',
          path.join(os.homedir(), 'Library'),
        ];
  for (const root of protectedRoots) {
    const normalized = path.resolve(root);
    if (path.relative(normalized, file) === '' || isInside(file, normalized))
      throw new Error('System and application-data folders cannot be recycled');
  }
}
async function validateRoot(root: string, deletionScope: boolean): Promise<string> {
  if (
    typeof root !== 'string' ||
    !path.isAbsolute(root) ||
    root.includes('\0') ||
    root.length > 32_000
  )
    throw new Error('Choose an absolute local folder path');
  if (
    process.platform === 'win32' &&
    (/^\\\\/.test(root) || /^\\\?\?\\/.test(root) || root.slice(2).includes(':'))
  )
    throw new Error('Network, device, and alternate-stream paths are not supported');
  const normalized = path.resolve(root);
  if (deletionScope && (normalized === path.parse(normalized).root || normalized === os.homedir()))
    throw new Error('Choose a project or downloads folder, not a drive or profile root');
  if (deletionScope) assertUnprotected(normalized);
  await assertNoSymlinkAncestors(normalized);
  const stat = await lstat(normalized);
  if (!stat.isDirectory() || stat.isSymbolicLink())
    throw new Error('Choose an existing folder that is not a symbolic link or junction');
  const canonical = await realpath(normalized);
  if (path.relative(normalized, canonical) !== '')
    throw new Error('Symbolic links and junctions are not followed');
  return canonical;
}
async function assertNoSymlinkAncestors(file: string): Promise<void> {
  let cursor = path.resolve(file);
  while (true) {
    const stat = await lstat(cursor);
    if (stat.isSymbolicLink()) throw new Error('Symbolic links and junctions are not followed');
    const parent = path.dirname(cursor);
    if (parent === cursor) return;
    cursor = parent;
  }
}
