import { afterEach, describe, expect, it, vi } from 'vitest';
import { mkdtemp, readFile, realpath, rename, rm, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { recycleReviewed } from '../electron/services/recycle';
import { ScanService } from '../electron/services/scanner';
import type { ScanEntry } from '../src/shared/contracts';

const entries: ScanEntry[] = ['one', 'two'].map((id) => ({
  id,
  name: `${id}.tmp`,
  path: `/reviewed/${id}.tmp`,
  bytes: 10,
  category: 'Temporary files',
  modified: 1,
  isDirectory: false,
}));
function setup() {
  return {
    scanner: {
      validateRecycle: vi.fn(async () => entries),
      revalidateEntry: vi.fn(async (_scan: string, id: string) =>
        entries.find((item) => item.id === id)!,
      ),
      markRecycled: vi.fn(),
      getResult: vi.fn(() => undefined),
    },
    confirm: vi.fn(async () => true),
    trash: vi.fn(async (_file: string) => {}),
    record: vi.fn(),
    flush: vi.fn(async () => {}),
    shouldStop: vi.fn(() => false),
  };
}
const fixtures: string[] = [];
afterEach(async () => {
  await Promise.all(fixtures.splice(0).map((root) => rm(root, { recursive: true, force: true })));
});

describe('reviewed recycling and durable receipts', () => {
  it('does not move files or record success when native confirmation is cancelled', async () => {
    const deps = setup();
    deps.confirm.mockResolvedValue(false);
    expect(await recycleReviewed('scan', ['one', 'two'], deps)).toEqual({
      recycled: 0,
      recycledIds: [],
      bytes: 0,
      failures: [],
      cancelled: true,
    });
    expect(deps.trash).not.toHaveBeenCalled();
    expect(deps.record).not.toHaveBeenCalled();
  });

  it('reports a cancelled content check without showing confirmation or a file failure', async () => {
    const deps = setup();
    deps.scanner.validateRecycle.mockImplementation(async () => {
      deps.shouldStop.mockReturnValue(true);
      throw new Error('The scan or file validation was stopped');
    });
    const result = await recycleReviewed('scan', ['one', 'two'], deps);
    expect(result).toMatchObject({ cancelled: true, recycledIds: [], failures: [] });
    expect(deps.confirm).not.toHaveBeenCalled();
    expect(deps.trash).not.toHaveBeenCalled();
  });

  it('returns exact successful IDs and continues after an individual native failure', async () => {
    const deps = setup();
    deps.trash.mockRejectedValueOnce(new Error('File is in use'));
    const result = await recycleReviewed('scan', ['one', 'two'], deps);
    expect(result).toEqual({
      recycled: 1,
      recycledIds: ['two'],
      bytes: 10,
      failures: ['one.tmp: File is in use'],
      cancelled: false,
    });
    expect(deps.scanner.markRecycled).toHaveBeenCalledExactlyOnceWith('scan', 'two');
    expect(deps.record).toHaveBeenLastCalledWith(
      expect.objectContaining({ status: 'partial', bytes: 10 }),
    );
  });

  it('does not begin a native move if cancellation arrives during revalidation', async () => {
    const deps = setup();
    deps.scanner.revalidateEntry.mockImplementation(async () => {
      deps.shouldStop.mockReturnValue(true);
      return entries[0];
    });
    const result = await recycleReviewed('scan', ['one', 'two'], deps);
    expect(result.cancelled).toBe(true);
    expect(result.recycledIds).toEqual([]);
    expect(deps.trash).not.toHaveBeenCalled();
  });

  it('saves the completed move before stopping between items', async () => {
    const deps = setup();
    deps.trash.mockImplementation(async () => {
      deps.shouldStop.mockReturnValue(true);
    });
    const result = await recycleReviewed('scan', ['one', 'two'], deps);
    expect(result).toMatchObject({ recycledIds: ['one'], bytes: 10, cancelled: true });
    expect(deps.trash).toHaveBeenCalledTimes(1);
    expect(deps.flush).toHaveBeenCalledTimes(3);
    expect(deps.record).toHaveBeenLastCalledWith(
      expect.objectContaining({ status: 'cancelled', bytes: 10 }),
    );
  });

  it('stops before any move when intent cannot be persisted', async () => {
    const deps = setup();
    deps.flush.mockRejectedValue(new Error('Disk full'));
    await expect(recycleReviewed('scan', ['one', 'two'], deps)).rejects.toThrow('Disk full');
    expect(deps.trash).not.toHaveBeenCalled();
  });

  it('returns moved IDs and stops before the next file when its receipt cannot be persisted', async () => {
    const deps = setup();
    deps.flush.mockResolvedValueOnce(undefined).mockRejectedValue(new Error('Disk full'));
    const result = await recycleReviewed('scan', ['one', 'two'], deps);
    expect(result.recycledIds).toEqual(['one']);
    expect(result.bytes).toBe(10);
    expect(result.failures).toEqual([expect.stringContaining('Activity could not be saved')]);
    expect(deps.trash).toHaveBeenCalledExactlyOnceWith('/reviewed/one.tmp');
  });

  it('revalidates duplicate survivors between native moves and reports the partial batch', async () => {
    const root = await mkdtemp(path.join(await realpath(process.cwd()), '.burrow-test-'));
    fixtures.push(root);
    await Promise.all(
      ['keeper.txt', 'one.txt', 'two.txt'].map((name) =>
        writeFile(path.join(root, name), 'same content'),
      ),
    );
    const scanner = new ScanService();
    const scan = await scanner.scan('duplicates', root);
    const selected = scan.entries.filter((entry) => entry.name !== 'keeper.txt');
    const deps = {
      ...setup(),
      scanner,
      trash: vi.fn(async (file: string) => {
        await rename(file, `${file}.recycled`);
        await writeFile(path.join(root, 'keeper.txt'), 'changed copy');
      }),
    };
    const result = await recycleReviewed(
      scan.id,
      selected.map((entry) => entry.id),
      deps,
    );
    expect(result.recycledIds).toEqual([selected[0].id]);
    expect(result.failures).toHaveLength(1);
    expect(deps.trash).toHaveBeenCalledTimes(1);
    expect(await readFile(selected[1].path, 'utf8')).toBe('same content');
  });
});
