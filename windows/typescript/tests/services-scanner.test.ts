import { afterEach, describe, expect, it, vi } from 'vitest';
import { link, mkdtemp, mkdir, realpath, rm, symlink, utimes, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { ScanService, TEMP_RETENTION_DAYS } from '../electron/services/scanner';

const fixtures: string[] = [];
async function fixture(): Promise<string> {
  const root = await mkdtemp(path.join(await realpath(process.cwd()), '.burrow-test-'));
  fixtures.push(root);
  return root;
}
async function oldInstaller(root: string, name = 'setup.exe'): Promise<string> {
  const file = path.join(root, name);
  await writeFile(file, 'downloaded installer');
  const old = new Date(Date.now() - 40 * 86_400_000);
  await utimes(file, old, old);
  return file;
}
async function project(root: string): Promise<string> {
  await writeFile(path.join(root, 'package.json'), '{}');
  const artifact = path.join(root, 'node_modules');
  await mkdir(artifact);
  await writeFile(path.join(artifact, 'module.js'), 'export default 1;');
  return artifact;
}
afterEach(async () => {
  vi.useRealTimers();
  vi.restoreAllMocks();
  await Promise.all(fixtures.splice(0).map((root) => rm(root, { recursive: true, force: true })));
});

describe('scan authorization and filesystem safety', () => {
  it('only offers old installers in the selected folder and expires old previews', async () => {
    const root = await fixture();
    await oldInstaller(root);
    await writeFile(path.join(root, 'recent.exe'), 'recent');
    await oldInstaller(root, 'notes.txt');
    await mkdir(path.join(root, 'nested'));
    await oldInstaller(path.join(root, 'nested'));
    const scanner = new ScanService();
    const result = await scanner.scan('installers', root);
    expect(result.entries.map((entry) => entry.name)).toEqual(['setup.exe']);
    expect(await scanner.validateRecycle(result.id, [result.entries[0].id])).toHaveLength(1);
    await expect(scanner.validateRecycle(result.id, ['forged-id'])).rejects.toThrow(
      'not authorized',
    );
    await expect(
      scanner.validateRecycle(result.id, [result.entries[0].id, result.entries[0].id]),
    ).rejects.toThrow('Duplicate');
    await scanner.scan('analyze', root);
    await expect(scanner.revalidateEntry(result.id, result.entries[0].id)).rejects.toThrow(
      'expired',
    );
  });
  it('rejects mutation after preview and replay after successful recycling', async () => {
    const root = await fixture();
    const file = await oldInstaller(root);
    const scanner = new ScanService();
    const first = await scanner.scan('installers', root);
    await writeFile(file, 'different installer');
    await expect(scanner.revalidateEntry(first.id, first.entries[0].id)).rejects.toThrow('changed');
    await oldInstaller(root);
    const second = await scanner.scan('installers', root);
    scanner.markRecycled(second.id, second.entries[0].id);
    await expect(scanner.revalidateEntry(second.id, second.entries[0].id)).rejects.toThrow(
      'not in',
    );
  });
  it('requires project markers and catches changed contents inside an artifact', async () => {
    const root = await fixture();
    const artifact = await project(root);
    await mkdir(path.join(root, 'dist'));
    await writeFile(path.join(root, 'dist', 'important-document.txt'), 'user data');
    const scanner = new ScanService();
    const result = await scanner.scan('purge', root);
    expect(result.entries.map((entry) => entry.name)).toEqual(['node_modules']);
    expect(await scanner.revalidateEntry(result.id, result.entries[0].id)).toMatchObject({
      path: artifact,
    });
    await writeFile(path.join(artifact, 'module.js'), 'export default 2;');
    await expect(scanner.revalidateEntry(result.id, result.entries[0].id)).rejects.toThrow(
      'changed',
    );
  });
  it('matches Windows artifact and ignored directory names without case sensitivity', async () => {
    const root = await fixture();
    await writeFile(path.join(root, 'Package.JSON'), '{}');
    await mkdir(path.join(root, 'Node_Modules'));
    await writeFile(path.join(root, 'Node_Modules', 'module.js'), 'module');
    await mkdir(path.join(root, '.Git'));
    await project(path.join(root, '.Git'));
    await mkdir(path.join(root, 'dotnet'));
    await writeFile(path.join(root, 'dotnet', 'App.CSPROJ'), '<Project />');
    await mkdir(path.join(root, 'dotnet', 'BIN'));
    await writeFile(path.join(root, 'dotnet', 'BIN', 'App.dll'), 'assembly');
    const result = await new ScanService().scan('purge', root);
    expect(result.entries.map((entry) => entry.name).sort()).toEqual(['BIN', 'Node_Modules']);
  });
  it('does not traverse junctions/symlinks or authorize artifact trees containing them', async () => {
    const root = await fixture();
    const outside = await fixture();
    await writeFile(path.join(outside, 'secret'), 'outside');
    const artifact = await project(root);
    await symlink(outside, path.join(artifact, 'linked-folder'), 'junction');
    const scanner = new ScanService();
    const purge = await scanner.scan('purge', root);
    expect(purge.entries).toHaveLength(0);
    expect(purge.skipped).toBeGreaterThan(0);
    const readOnly = await scanner.scan('analyze', root);
    expect(readOnly.entries.find((entry) => entry.name === 'node_modules')?.bytes).toBe(
      Buffer.byteLength('export default 1;'),
    );
    await expect(scanner.scan('analyze', path.join(artifact, 'linked-folder'))).rejects.toThrow(
      'Symbolic links',
    );
  });
  it('rejects a symlink swapped into a previewed ancestor before recycling', async () => {
    const root = await fixture();
    const child = path.join(root, 'downloads');
    await mkdir(child);
    await oldInstaller(child);
    const scanner = new ScanService();
    const preview = await scanner.scan('installers', child);
    await rm(child, { recursive: true });
    const outside = await fixture();
    await oldInstaller(outside);
    await symlink(outside, child, 'junction');
    await expect(scanner.revalidateEntry(preview.id, preview.entries[0].id)).rejects.toThrow(
      'Symbolic links',
    );
  });
  it('keeps storage analysis read-only', async () => {
    const root = await fixture();
    await oldInstaller(root);
    const scanner = new ScanService();
    const result = await scanner.scan('analyze', root);
    await expect(scanner.validateRecycle(result.id, ['any-id'])).rejects.toThrow('read-only');
  });
});

async function age(file: string, days = TEMP_RETENTION_DAYS + 2): Promise<void> {
  const old = new Date(Date.now() - days * 86_400_000);
  await utimes(file, old, old);
}
async function oldTempTree(root: string): Promise<string> {
  const tree = path.join(root, 'old-job');
  await mkdir(path.join(tree, 'nested'), { recursive: true });
  const file = path.join(tree, 'nested', 'result.tmp');
  await writeFile(file, 'old temporary result');
  await age(file);
  await age(path.dirname(file));
  await age(tree);
  return tree;
}
describe('fixed user temp cleanup', () => {
  it('rejects every renderer-supplied root, including the configured temp folder', async () => {
    const root = await fixture();
    const scanner = new ScanService({}, { tempRoot: root });
    await expect(scanner.scan('clean', await fixture())).rejects.toThrow('fixed user temp');
    await expect(scanner.scan('clean', root)).rejects.toThrow('fixed user temp');
  });
  it('only authorizes old files and fully old trees below the fixed temp root', async () => {
    const root = await fixture();
    const tree = await oldTempTree(root);
    const file = path.join(root, 'old.tmp');
    await writeFile(file, 'old file');
    await age(file);
    await writeFile(path.join(root, 'active.tmp'), 'active file');
    const scanner = new ScanService({}, { tempRoot: root });
    const result = await scanner.scan('clean');
    expect(result.root).toBe(root);
    expect(result.entries.map((entry) => entry.path).sort()).toEqual([tree, file].sort());
    expect(result.entries.every((entry) => entry.path !== root)).toBe(true);
    expect(
      await scanner.validateRecycle(
        result.id,
        result.entries.map((entry) => entry.id),
      ),
    ).toHaveLength(2);
  });
  it.each(['file', 'directory'] as const)(
    'omits an old parent with a recent nested %s',
    async (kind) => {
      const root = await fixture();
      const tree = await oldTempTree(root);
      const nested = path.join(tree, 'nested');
      await age(kind === 'file' ? path.join(nested, 'result.tmp') : nested, 1);
      await age(tree);
      const result = await new ScanService({}, { tempRoot: root }).scan('clean');
      expect(result.entries).toHaveLength(0);
      expect(result.skipped).toBeGreaterThan(0);
    },
  );
  it('rejects linked temp roots and skips trees containing a link', async () => {
    const root = await fixture();
    const outside = await fixture();
    const tree = await oldTempTree(root);
    await symlink(outside, path.join(tree, 'linked'), 'junction');
    await age(tree);
    const scanner = new ScanService({}, { tempRoot: root });
    expect((await scanner.scan('clean')).entries).toHaveLength(0);
    const linkedRoot = path.join(outside, 'temp-link');
    await symlink(root, linkedRoot, 'junction');
    await expect(new ScanService({}, { tempRoot: linkedRoot }).scan('clean')).rejects.toThrow(
      'Symbolic links',
    );
    await expect(
      new ScanService({}, { tempRoot: path.join(linkedRoot, 'old-job') }).scan('clean'),
    ).rejects.toThrow('Symbolic links');
  });
  it('rejects a replaced temp-root ancestor and successful-item replay', async () => {
    const parent = await fixture();
    const root = path.join(parent, 'temp');
    await mkdir(root);
    await oldTempTree(root);
    const scanner = new ScanService({}, { tempRoot: root });
    const first = await scanner.scan('clean');
    scanner.markRecycled(first.id, first.entries[0].id);
    await expect(scanner.revalidateEntry(first.id, first.entries[0].id)).rejects.toThrow('not in');
    const second = await scanner.scan('clean');
    await rm(root, { recursive: true });
    const outside = await fixture();
    await oldTempTree(outside);
    await symlink(outside, root, 'junction');
    await expect(scanner.revalidateEntry(second.id, second.entries[0].id)).rejects.toThrow(
      'Symbolic links',
    );
  });
  it('never authorizes an incompletely measured temp tree', async () => {
    const root = await fixture();
    await oldTempTree(root);
    const result = await new ScanService({ maxEntries: 2 }, { tempRoot: root }).scan('clean');
    expect(result.entries).toHaveLength(0);
    expect(result.truncated).toBe(true);
  });
  it('rejects a changed temp file and a file added inside a previewed tree', async () => {
    const root = await fixture();
    const file = path.join(root, 'old.tmp');
    await writeFile(file, 'old file');
    await age(file);
    const tree = await oldTempTree(root);
    const scanner = new ScanService({}, { tempRoot: root });
    const result = await scanner.scan('clean');
    await writeFile(file, 'changed file');
    await expect(
      scanner.revalidateEntry(result.id, result.entries.find((entry) => entry.path === file)!.id),
    ).rejects.toThrow('changed');
    await writeFile(path.join(tree, 'nested', 'new.tmp'), 'active');
    await expect(
      scanner.revalidateEntry(result.id, result.entries.find((entry) => entry.path === tree)!.id),
    ).rejects.toThrow('changed');
  });
  it('checks temp age again if the system clock moves backwards after preview', async () => {
    const root = await fixture();
    const file = path.join(root, 'old.tmp');
    await writeFile(file, 'old file');
    await age(file);
    const scanner = new ScanService({}, { tempRoot: root });
    const result = await scanner.scan('clean');
    vi.spyOn(Date, 'now').mockReturnValue(Date.now() - 3 * 86_400_000);
    await expect(scanner.revalidateEntry(result.id, result.entries[0].id)).rejects.toThrow(
      'too recent',
    );
  });
});

async function duplicates(
  count = 3,
): Promise<{ scanner: ScanService; result: Awaited<ReturnType<ScanService['scan']>> }> {
  const root = await fixture();
  for (let i = 0; i < count; i++) await writeFile(path.join(root, `${i}.txt`), 'duplicate content');
  const scanner = new ScanService();
  return { scanner, result: await scanner.scan('duplicates', root) };
}
describe('duplicate recycle survivor protection', () => {
  it('requires a reviewed batch and refuses selecting every copy', async () => {
    const { scanner, result } = await duplicates();
    await expect(scanner.revalidateEntry(result.id, result.entries[0].id)).rejects.toThrow(
      'entire duplicate selection',
    );
    await expect(
      scanner.validateRecycle(
        result.id,
        result.entries.map((entry) => entry.id),
      ),
    ).rejects.toThrow('Keep at least one');
    expect(
      await scanner.validateRecycle(
        result.id,
        result.entries.slice(1).map((entry) => entry.id),
      ),
    ).toHaveLength(2);
  });
  it.each(['changed', 'missing'] as const)(
    'rejects a %s unselected keeper during batch review and just before recycle',
    async (change) => {
      for (const beforeReview of [true, false]) {
        const { scanner, result } = await duplicates(2);
        const [keeper, selected] = result.entries;
        if (!beforeReview) await scanner.validateRecycle(result.id, [selected.id]);
        if (change === 'missing') await rm(keeper.path);
        else await writeFile(keeper.path, 'different content');
        const operation = beforeReview
          ? scanner.validateRecycle(result.id, [selected.id])
          : scanner.revalidateEntry(result.id, selected.id);
        await expect(operation).rejects.toThrow('No unchanged duplicate copy');
      }
    },
  );
  it('excludes the entire selection from keepers and remembers successfully recycled copies', async () => {
    const { scanner, result } = await duplicates();
    const [keeper, first, second] = result.entries;
    await scanner.validateRecycle(result.id, [first.id, second.id]);
    await scanner.revalidateEntry(result.id, first.id);
    scanner.markRecycled(result.id, first.id);
    await expect(scanner.revalidateEntry(result.id, first.id)).rejects.toThrow('not in');
    await writeFile(keeper.path, 'changed keeper');
    await expect(scanner.revalidateEntry(result.id, second.id)).rejects.toThrow(
      'No unchanged duplicate copy',
    );
    // The old copy still exists on disk in this service-only test, but cannot become a keeper.
    await expect(scanner.validateRecycle(result.id, [keeper.id, second.id])).rejects.toThrow();
  });
  it('allows another unchanged unselected copy when the first keeper disappeared', async () => {
    const { scanner, result } = await duplicates();
    const [firstKeeper, , selected] = result.entries;
    await scanner.validateRecycle(result.id, [selected.id]);
    await rm(firstKeeper.path);
    expect(await scanner.revalidateEntry(result.id, selected.id)).toMatchObject({
      id: selected.id,
    });
  });
  it('does not let a previously recycled copy preserve the final remaining copy', async () => {
    const { scanner, result } = await duplicates(2);
    const [keeper, selected] = result.entries;
    await scanner.validateRecycle(result.id, [selected.id]);
    scanner.markRecycled(result.id, selected.id);
    await expect(scanner.validateRecycle(result.id, [keeper.id])).rejects.toThrow(
      'Keep at least one',
    );
  });
  it('expires duplicate previews after fifteen minutes', async () => {
    const { scanner, result } = await duplicates(2);
    vi.spyOn(Date, 'now').mockReturnValue(result.timestamp + 16 * 60_000);
    await expect(scanner.validateRecycle(result.id, [result.entries[0].id])).rejects.toThrow(
      'expired',
    );
  });
  it('cancels duplicate batch validation and immediate revalidation', async () => {
    const { scanner, result } = await duplicates(2);
    const id = result.entries[0].id;
    const pendingBatch = scanner.validateRecycle(result.id, [id]);
    scanner.cancel();
    await expect(pendingBatch).rejects.toThrow('stopped');
    await expect(scanner.revalidateEntry(result.id, id)).rejects.toThrow(
      'entire duplicate selection',
    );
    await scanner.validateRecycle(result.id, [id]);
    const pendingEntry = scanner.revalidateEntry(result.id, id);
    scanner.cancel();
    await expect(pendingEntry).rejects.toThrow('stopped');
  });
  it('rechecks the selected file after hashing the keeper', async () => {
    const { scanner, result } = await duplicates(2);
    const [keeper, selected] = result.entries;
    await scanner.validateRecycle(result.id, [selected.id]);
    const target = scanner as unknown as { hashFile: (...args: unknown[]) => Promise<string> };
    const hash = target.hashFile.bind(scanner);
    vi.spyOn(target, 'hashFile').mockImplementation(async (...args) => {
      const digest = await hash(...args);
      if (args[1] === keeper.path) await writeFile(selected.path, 'changed selected file');
      return digest;
    });
    await expect(scanner.revalidateEntry(result.id, selected.id)).rejects.toThrow('changed');
  });
});

describe('bounded scans and hashing', () => {
  it('supports cancellation and does not retain cancellation authorization', async () => {
    const root = await fixture();
    await oldInstaller(root);
    const scanner = new ScanService();
    const result = await scanner.scan('installers', root, () => scanner.cancel());
    expect(result.cancelled).toBe(true);
    expect(result.entries).toHaveLength(0);
    expect(scanner.getResult(result.id)).toBeUndefined();
  });
  it('stops at the filesystem entry limit and marks the result partial', async () => {
    const root = await fixture();
    await Promise.all(
      Array.from({ length: 12 }, (_, i) => writeFile(path.join(root, `${i}.txt`), 'data')),
    );
    const scanner = new ScanService({ maxEntries: 4 });
    const result = await scanner.scan('analyze', root);
    expect(result.truncated).toBe(true);
    expect(result.scanned).toBeLessThanOrEqual(4);
    expect(result.cancelled).toBe(false);
  });
  it('uses content hashes to separate same-size files and labels exact duplicate groups', async () => {
    const root = await fixture();
    await writeFile(path.join(root, 'one.txt'), 'content A');
    await writeFile(path.join(root, 'two.txt'), 'content A');
    await writeFile(path.join(root, 'three.txt'), 'content B');
    const result = await new ScanService().scan('duplicates', root);
    expect(result.entries.map((entry) => entry.name).sort()).toEqual(['one.txt', 'two.txt']);
    expect(new Set(result.entries.map((entry) => entry.group)).size).toBe(1);
    expect(result.entries[0].group).toMatch(/^[a-f0-9]{64}$/);
  });
  it('caps duplicate hashing work', async () => {
    const root = await fixture();
    await writeFile(path.join(root, 'one.txt'), 'identical data');
    await writeFile(path.join(root, 'two.txt'), 'identical data');
    const result = await new ScanService({ maxHashBytes: 8 }).scan('duplicates', root);
    expect(result.truncated).toBe(true);
    expect(result.entries).toHaveLength(0);
  });
  it('keeps confirmed duplicate pairs when the next file exceeds the hash budget', async () => {
    const root = await fixture();
    const content = 'identical data';
    for (const name of ['one.txt', 'two.txt', 'three.txt'])
      await writeFile(path.join(root, name), content);
    const result = await new ScanService({ maxHashBytes: Buffer.byteLength(content) * 2 }).scan(
      'duplicates',
      root,
    );
    expect(result.truncated).toBe(true);
    expect(result.entries).toHaveLength(2);
    expect(new Set(result.entries.map((entry) => entry.group)).size).toBe(1);
  });
  it('does not traverse mixed-case Git metadata directories while finding duplicates', async () => {
    const root = await fixture();
    await mkdir(path.join(root, '.Git'));
    await writeFile(path.join(root, 'one.txt'), 'identical data');
    await writeFile(path.join(root, '.Git', 'two.txt'), 'identical data');
    expect((await new ScanService().scan('duplicates', root)).entries).toHaveLength(0);
  });
  it('does not count hard links as separately stored duplicate copies', async () => {
    const root = await fixture();
    await writeFile(path.join(root, 'original.txt'), 'shared storage');
    await link(path.join(root, 'original.txt'), path.join(root, 'hard-link.txt'));
    const result = await new ScanService().scan('duplicates', root);
    expect(result.entries).toHaveLength(0);
    expect(result.skipped).toBe(1);
  });
});
