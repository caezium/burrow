import { afterEach, describe, expect, it, vi } from 'vitest';
import {
  lstat,
  mkdir,
  mkdtemp,
  readFile,
  realpath,
  rm,
  symlink,
  utimes,
  writeFile,
} from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { LEFTOVER_AGE_DAYS, LeftoversService } from '../electron/services/leftovers';
import type { InstalledApp, LeftoverScope } from '../src/shared/contracts';

const fixtures: string[] = [];
async function fixture(): Promise<string> {
  const root = await mkdtemp(path.join(await realpath(process.cwd()), '.burrow-leftovers-'));
  fixtures.push(root);
  return root;
}
function app(name = 'Sapphire Browser', publisher = 'Sapphire Foundation'): InstalledApp {
  return { id: name, name, publisher, version: '1.0', size: 0, installDate: '' };
}
async function age(file: string, days = LEFTOVER_AGE_DAYS + 2): Promise<void> {
  const date = new Date(Date.now() - days * 86_400_000);
  await utimes(file, date, date);
}
async function leaf(root: string, folder = 'RetiredWidget', type = 'Cache'): Promise<string> {
  const directory = path.join(root, folder, type);
  await mkdir(directory, { recursive: true });
  const file = path.join(directory, 'old.bin');
  await writeFile(file, 'old cache bytes');
  await age(file);
  await age(directory);
  await age(path.dirname(directory));
  return directory;
}
async function setup(apps = [app()]) {
  const roots = { local: await fixture(), roaming: await fixture() };
  const inventory = vi.fn(async () => apps);
  return { roots, inventory, service: new LeftoversService(inventory, { roots }) };
}
afterEach(async () => {
  vi.useRealTimers();
  vi.restoreAllMocks();
  await Promise.all(fixtures.splice(0).map((root) => rm(root, { recursive: true, force: true })));
});

describe('read-only possible leftover discovery', () => {
  it('reports only aged exact cache/log leaves with cautious evidence and measured size', async () => {
    const { roots, service } = await setup();
    const cache = await leaf(roots.local);
    const logs = await leaf(roots.local, 'RetiredWidget', 'LOGS');
    await leaf(roots.local, 'RetiredWidget', 'Settings');
    await leaf(roots.local, 'RetiredWidget', 'Database');
    await leaf(roots.local, 'RetiredWidget', 'CacheStorage');
    const before = await lstat(path.join(cache, 'old.bin'));
    const result = await service.scan('local');
    expect(result.root).toBe(roots.local);
    expect(result.installedApps).toBe(1);
    expect(result.entries.map((entry) => entry.path).sort()).toEqual([cache, logs].sort());
    expect(result.entries.map((entry) => entry.category).sort()).toEqual(['cache', 'logs']);
    expect(result.entries[0].bytes).toBe(Buffer.byteLength('old cache bytes'));
    expect(result.entries[0].evidence.join(' ')).toContain(
      'registered desktop-app names or publishers',
    );
    expect(result.entries[0].evidence.join(' ')).toContain('does not prove an app was uninstalled');
    expect(result.cancelled).toBe(false);
    expect(result.truncated).toBe(false);
    expect(await readFile(path.join(cache, 'old.bin'), 'utf8')).toBe('old cache bytes');
    const after = await lstat(path.join(cache, 'old.bin'));
    expect(after.mtimeMs).toBe(before.mtimeMs);
    expect(after.ctimeMs).toBe(before.ctimeMs);
  });
  it.each([
    ['Acme Editor', 'Acme Editor Desktop', 'Different Publisher'],
    ['Acme', 'Unrelated Product', 'Acme Corporation'],
    ['Code', 'Microsoft Visual Studio Code', 'Microsoft'],
    ['ACME-EDITOR', 'Acme Editor', 'Different Publisher'],
    ['AcmeEditor', 'Acme Editor', 'Different Publisher'],
    ['AcmeLabs', 'Unrelated Product', 'Acme Labs LLC'],
  ])(
    'suppresses %s when its normalized name or publisher matches the inventory',
    async (folder, name, publisher) => {
      const { roots, service } = await setup([app(name, publisher)]);
      await leaf(roots.local, folder);
      expect((await service.scan('local')).entries).toHaveLength(0);
    },
  );
  it('keeps scopes separate and accepts only the fixed configured scope roots', async () => {
    const { roots, service, inventory } = await setup();
    await leaf(roots.local, 'LocalWidget');
    const roaming = await leaf(roots.roaming, 'RoamingWidget', 'Logs');
    expect((await service.scan('roaming')).entries.map((entry) => entry.path)).toEqual([roaming]);
    expect((await service.scan('local')).entries).toHaveLength(1);
    await expect(service.scan('../outside' as LeftoverScope)).rejects.toThrow('Local or Roaming');
    await expect(service.scan(roots.local as LeftoverScope)).rejects.toThrow('Local or Roaming');
    expect(inventory).toHaveBeenCalledTimes(2);
  });
  it('never treats shared/OS folders, profile caches, or generic top-level folders as app leftovers', async () => {
    const { roots, service } = await setup();
    for (const folder of [
      'Microsoft',
      'Windows',
      'Packages',
      'Programs',
      'Temp',
      'Roaming',
      'CrashDumps',
      'NVIDIA Corporation',
      'AMD',
      'Cache',
      'Logs',
      'Settings',
      'User Data',
      'Database',
      'Profiles',
      '.private',
      '0f68c338-3598-4dc5-aa01-abcdef654321',
    ])
      await leaf(roots.local, folder);
    await leaf(roots.local, path.join('RetiredWidget', 'Profiles'));
    await leaf(roots.local, path.join('RetiredWidget', 'Local Storage'));
    await leaf(roots.local, path.join('RetiredWidget', 'IndexedDB'));
    await leaf(roots.local, path.join('RetiredWidget', 'Service Worker'));
    expect((await service.scan('local')).entries).toHaveLength(0);
  });
  it.each(['root', 'file', 'directory'])(
    'rejects a recently modified %s anywhere in a candidate tree',
    async (target) => {
      const { roots, service } = await setup();
      const cache = await leaf(roots.local);
      const nested = path.join(cache, 'nested');
      await mkdir(nested);
      const file = path.join(nested, 'nested.bin');
      await writeFile(file, 'old nested data');
      await age(file);
      await age(nested);
      await age(cache);
      await age(target === 'root' ? cache : target === 'file' ? file : nested, 1);
      expect((await service.scan('local')).entries).toHaveLength(0);
    },
  );
  it('skips candidate links, linked top-level folders, and trees containing links', async () => {
    const { roots, service } = await setup();
    const outside = await fixture();
    const cache = await leaf(roots.local);
    await symlink(outside, path.join(cache, 'linked'), 'junction');
    await age(cache);
    await symlink(outside, path.join(roots.local, 'LinkedWidget'), 'junction');
    await mkdir(path.join(roots.local, 'AnotherWidget'));
    await symlink(outside, path.join(roots.local, 'AnotherWidget', 'Cache'), 'junction');
    const result = await service.scan('local');
    expect(result.entries).toHaveLength(0);
    expect(result.skipped).toBeGreaterThan(0);
  });
  it('rejects a root or root ancestor linked outside its configured location', async () => {
    const parent = await fixture();
    const outside = await fixture();
    await leaf(outside);
    const linked = path.join(parent, 'linked');
    await symlink(outside, linked, 'junction');
    for (const local of [linked, path.join(linked, 'RetiredWidget')]) {
      const service = new LeftoversService(async () => [app()], {
        roots: { local, roaming: outside },
      });
      await expect(service.scan('local')).rejects.toThrow('Symbolic links');
    }
  });
  it('rejects relative, drive-root, and profile-root configurations', async () => {
    const roaming = await fixture();
    for (const local of ['relative/path', path.parse(roaming).root, os.homedir()]) {
      const service = new LeftoversService(async () => [app()], { roots: { local, roaming } });
      await expect(service.scan('local')).rejects.toThrow();
    }
  });
  it('fails closed when app inventory fails or is empty', async () => {
    const roots = { local: await fixture(), roaming: await fixture() };
    await leaf(roots.local);
    const empty = new LeftoversService(async () => [], { roots });
    const failed = new LeftoversService(
      async () => {
        throw new Error('Registry unavailable');
      },
      { roots },
    );
    await expect(empty.scan('local')).rejects.toThrow('inventory is empty');
    await expect(failed.scan('local')).rejects.toThrow('inventory failed');
  });
});

describe('bounded leftovers scans', () => {
  it('does not offer a partly measured tree at the entry or depth limit', async () => {
    const { roots } = await setup();
    const cache = await leaf(roots.local);
    const nested = path.join(cache, 'nested');
    await mkdir(nested);
    await writeFile(path.join(nested, 'data'), 'cache');
    await age(path.join(nested, 'data'));
    await age(nested);
    await age(cache);
    for (const limits of [{ maxEntries: 3 }, { maxDepth: 0 }]) {
      const service = new LeftoversService(async () => [app()], { roots, limits });
      const result = await service.scan('local');
      expect(result.entries).toHaveLength(0);
      expect(result.truncated).toBe(true);
    }
  });
  it('limits result count without returning incomplete measurements', async () => {
    const { roots } = await setup();
    await leaf(roots.local, 'FirstWidget');
    await leaf(roots.local, 'SecondWidget');
    const service = new LeftoversService(async () => [app()], { roots, limits: { maxResults: 1 } });
    const result = await service.scan('local');
    expect(result.entries).toHaveLength(1);
    expect(result.entries[0].bytes).toBe(Buffer.byteLength('old cache bytes'));
    expect(result.truncated).toBe(true);
  });
  it('supports cancellation through progress and does not continue discovery', async () => {
    const { roots, service, inventory } = await setup();
    await leaf(roots.local);
    const progress = vi.fn(() => service.cancel());
    const result = await service.scan('local', progress);
    expect(result.cancelled).toBe(true);
    expect(result.entries).toHaveLength(0);
    expect(result.scanned).toBe(0);
    expect(inventory).not.toHaveBeenCalled();
    expect(progress).toHaveBeenCalled();
  });
  it('can cancel while waiting for inventory and times out an unavailable provider', async () => {
    const { roots } = await setup();
    let signalStarted!: () => void;
    const started = new Promise<void>((resolve) => {
      signalStarted = resolve;
    });
    const service = new LeftoversService(
      () => {
        signalStarted();
        return new Promise(() => {});
      },
      { roots },
    );
    const pending = service.scan('local');
    await started;
    service.cancel();
    expect((await pending).cancelled).toBe(true);
    vi.useFakeTimers();
    let signalWaiting!: () => void;
    const waiting = new Promise<void>((resolve) => {
      signalWaiting = resolve;
    });
    const timeout = new LeftoversService(
      () => {
        signalWaiting();
        return new Promise(() => {});
      },
      {
        roots,
        limits: { maxDurationMs: 1_000 },
      },
    );
    const rejection = expect(timeout.scan('local')).rejects.toThrow('inventory timed out');
    await waiting;
    await vi.advanceTimersByTimeAsync(1_001);
    await rejection;
  });
});
