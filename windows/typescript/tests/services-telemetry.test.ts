import { afterEach, describe, expect, it, vi } from 'vitest';
import os from 'node:os';
import si from 'systeminformation';
import { TelemetryService } from '../electron/services/telemetry';

const providerMethods = [
  'currentLoad',
  'mem',
  'fsSize',
  'networkInterfaces',
  'networkStats',
  'battery',
  'processes',
] as const;

afterEach(() => {
  vi.useRealTimers();
  vi.restoreAllMocks();
});

describe('real telemetry with partial provider failures', () => {
  it('falls back to OS memory/CPU and marks unavailable providers instead of inventing data', async () => {
    for (const method of providerMethods) {
      vi.spyOn(si, method).mockRejectedValue(new Error('Counters unavailable'));
    }
    const sample = await new TelemetryService().sample();
    expect(sample.hostname).toBe(os.hostname());
    expect(sample.memory.total).toBe(os.totalmem());
    expect(sample.cpu.cores).toBe(os.cpus().length);
    expect(sample.cpu.usage).toBeGreaterThanOrEqual(0);
    expect(sample.cpu.usage).toBeLessThanOrEqual(100);
    expect(sample.disks).toEqual([]);
    expect(sample.network).toEqual([]);
    expect(sample.processes).toEqual([]);
    expect(sample.battery).toBeNull();
    expect(sample.warnings.length).toBeGreaterThanOrEqual(7);
  });
  it('keeps one OS request per hung provider across repeated snapshot deadlines', async () => {
    vi.useFakeTimers();
    const providers = providerMethods.map((method) =>
      vi.spyOn(si, method).mockImplementation(() => new Promise<never>(() => {})),
    );
    const service = new TelemetryService();

    for (let attempt = 0; attempt < 3; attempt++) {
      const pending = service.sample();
      await vi.advanceTimersByTimeAsync(8_000);
      const sample = await pending;
      expect(sample.warnings.length).toBeGreaterThanOrEqual(7);
      expect(sample.memory.total).toBe(os.totalmem());
      for (const provider of providers) expect(provider).toHaveBeenCalledTimes(1);
    }
  });
  it.each(['resolve', 'reject'] as const)(
    'reuses a timed-out request until it settles by %s, then permits recovery',
    async (outcome) => {
      vi.useFakeTimers();
      for (const method of providerMethods)
        vi.spyOn(si, method).mockRejectedValue(new Error('Unavailable'));
      type Memory = Awaited<ReturnType<typeof si.mem>>;
      let resolve!: (memory: Memory) => void;
      let reject!: (error: Error) => void;
      const request = new Promise<Memory>((done, fail) => {
        resolve = done;
        reject = fail;
      });
      const recovered = { total: 1_000, available: 400 } as Memory;
      const memory = vi.mocked(si.mem).mockReturnValueOnce(request).mockResolvedValue(recovered);
      const service = new TelemetryService();
      const first = service.sample();
      await vi.advanceTimersByTimeAsync(8_000);
      expect((await first).warnings).toContain(
        'Memory counters are unavailable; this sample is partial.',
      );

      const waiting = service.sample();
      await vi.advanceTimersByTimeAsync(0);
      expect(memory).toHaveBeenCalledTimes(1);
      if (outcome === 'resolve') resolve(recovered);
      else reject(new Error('Late provider failure'));
      const settled = await waiting;
      expect(settled.memory.total).toBe(outcome === 'resolve' ? recovered.total : os.totalmem());

      const next = await service.sample();
      expect(memory).toHaveBeenCalledTimes(2);
      expect(next.memory).toEqual({ total: 1_000, used: 600, percent: 60 });
      expect(next.warnings.some((warning) => warning.startsWith('Memory counters'))).toBe(false);
    },
  );
  it('collects a usable real sample on the development host', async () => {
    const service = new TelemetryService();
    const first = service.sample();
    expect(service.sample()).toBe(first);
    const sample = await first;
    expect(sample.hostname).toBe(os.hostname());
    expect(sample.platform).toBe(process.platform);
    expect(sample.timestamp).toBeGreaterThan(Date.now() - 30_000);
    expect(sample.memory.total).toBeGreaterThan(0);
    expect(Number.isFinite(sample.memory.used)).toBe(true);
    expect(Number.isFinite(sample.cpu.usage)).toBe(true);
    for (const connection of sample.network) {
      expect(connection.rx === null || connection.rx >= 0).toBe(true);
      expect(connection.tx === null || connection.tx >= 0).toBe(true);
    }
  }, 12_000);
});
