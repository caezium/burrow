import { afterEach, describe, expect, it } from 'vitest';
import { mkdtemp, readFile, readdir, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { DEFAULT_SETTINGS, type Snapshot } from '../src/shared/contracts';
import { LocalStore, sanitizeSettings } from '../electron/services/store';

const fixtures: string[] = [];
async function fixture(): Promise<string> {
  const root = await mkdtemp(path.join(os.tmpdir(), 'burrow-store-'));
  fixtures.push(root);
  return root;
}
function snapshot(timestamp = Date.now()): Snapshot {
  return {
    timestamp,
    hostname: 'test',
    platform: 'test',
    osVersion: 'test',
    uptime: 0,
    cpu: { usage: 10, cores: 1, model: 'test' },
    memory: { used: 1, total: 2, percent: 50 },
    disks: [],
    network: [],
    battery: null,
    processes: [{ pid: 1, name: 'private-name', cpu: 0, memory: 0 }],
    warnings: [],
  };
}
afterEach(async () => {
  await Promise.all(fixtures.splice(0).map((root) => rm(root, { recursive: true, force: true })));
});

describe('local settings, activity and telemetry history', () => {
  it('validates settings and restores them from an atomic persisted file', async () => {
    const root = await fixture();
    const store = new LocalStore(root);
    await store.init();
    expect(store.getSettings()).toEqual(DEFAULT_SETTINGS);
    await store.saveSettings({
      theme: 'dark',
      sampleInterval: -5,
      retentionDays: 5_000,
      minimizeToTray: false,
    });
    const reopened = new LocalStore(root);
    await reopened.init();
    expect(reopened.getSettings()).toEqual({
      theme: 'dark',
      sampleInterval: 2,
      retentionDays: 90,
      minimizeToTray: false,
    });
    expect(JSON.parse(await readFile(path.join(root, 'burrow-state.json'), 'utf8')).version).toBe(
      1,
    );
    expect(sanitizeSettings({ theme: 'unsafe', sampleInterval: NaN })).toEqual(DEFAULT_SETTINGS);
  });
  it('downsamples history, strips process names, and bounds activity', async () => {
    const store = new LocalStore(await fixture());
    await store.init();
    const now = Math.floor(Date.now() / 60_000) * 60_000;
    store.addSnapshot(snapshot(now));
    store.addSnapshot(snapshot(now + 1_000));
    store.addSnapshot(snapshot(now - 91 * 86_400_000));
    for (let i = 0; i < 310; i++)
      store.addActivity({ title: `operation ${i}`, detail: '', status: 'success', bytes: i });
    await store.flush();
    expect(store.getHistory(0)).toHaveLength(1);
    expect(store.getHistory(0)[0].processes).toEqual([]);
    expect(store.getActivity()).toHaveLength(300);
    expect(store.getActivity()[0].title).toBe('operation 309');
    const copy = store.getHistory(0);
    copy[0].cpu.usage = 99;
    expect(store.getHistory(0)[0].cpu.usage).toBe(10);
  });
  it('preserves malformed state for recovery and uses default settings', async () => {
    const root = await fixture();
    await writeFile(path.join(root, 'burrow-state.json'), '{ invalid JSON');
    const store = new LocalStore(root);
    await store.init();
    expect(store.getSettings()).toEqual(DEFAULT_SETTINGS);
    expect(
      (await readdir(root)).some((file) => file.startsWith('burrow-state.json.corrupt-')),
    ).toBe(true);
  });
  it('rejects malformed history scalars and nested records while retaining a complete sample', async () => {
    const root = await fixture();
    const valid = {
      ...snapshot(),
      disks: [{ name: 'C:', mount: 'C:\\', used: 1, total: 2 }],
      network: [{ name: 'Ethernet', address: '127.0.0.1', rx: null, tx: 0 }],
      battery: { percent: 50, charging: true },
    };
    const invalid = [
      { memory: { used: 1, total: 2 } },
      { memory: { used: 1, total: 2, percent: null } },
      { cpu: { usage: 10, cores: '1', model: 'test' } },
      { osVersion: undefined },
      { uptime: -1 },
      { disks: [null] },
      { disks: [{ name: 'C:', mount: 'C:\\', used: '1', total: 2 }] },
      { network: [{ name: 'Ethernet', address: '127.0.0.1', rx: -1, tx: 0 }] },
      { network: [{ name: 'Ethernet', address: '127.0.0.1', tx: 0 }] },
      { processes: [{ pid: 1, name: 'test', cpu: 0 }] },
      { battery: { percent: 101, charging: true } },
      { warnings: [null] },
    ].map((patch) => ({ ...valid, ...patch }));
    await writeFile(
      path.join(root, 'burrow-state.json'),
      JSON.stringify({
        version: 1,
        settings: DEFAULT_SETTINGS,
        history: [...invalid, valid],
        activity: [],
      }),
    );
    const store = new LocalStore(root);
    await store.init();
    expect(store.getHistory(0)).toEqual([valid]);
    expect(Number.isFinite(store.getHistory(0)[0].memory.percent)).toBe(true);
  });
  it('serializes concurrent settings writes without losing the last update', async () => {
    const root = await fixture();
    const store = new LocalStore(root);
    await store.init();
    await Promise.all([
      store.saveSettings({ ...DEFAULT_SETTINGS, theme: 'dark' }),
      store.saveSettings({ ...DEFAULT_SETTINGS, theme: 'light' }),
    ]);
    const reopened = new LocalStore(root);
    await reopened.init();
    expect(reopened.getSettings().theme).toBe('light');
  });
});
