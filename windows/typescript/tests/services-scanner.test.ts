import { afterEach, describe, expect, it } from 'vitest';
import { link, mkdtemp, mkdir, realpath, rm, symlink, utimes, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { ScanService } from '../electron/services/scanner';

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
  it('makes clean, analyze, and duplicate scans read-only', async () => {
    const root = await fixture();
    await oldInstaller(root);
    const scanner = new ScanService();
    for (const kind of ['clean', 'analyze', 'duplicates'] as const) {
      const result = await scanner.scan(kind, root);
      await expect(scanner.validateRecycle(result.id, ['any-id'])).rejects.toThrow('read-only');
    }
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
  it('does not count hard links as separately stored duplicate copies', async () => {
    const root = await fixture();
    await writeFile(path.join(root, 'original.txt'), 'shared storage');
    await link(path.join(root, 'original.txt'), path.join(root, 'hard-link.txt'));
    const result = await new ScanService().scan('duplicates', root);
    expect(result.entries).toHaveLength(0);
    expect(result.skipped).toBe(1);
  });
});
