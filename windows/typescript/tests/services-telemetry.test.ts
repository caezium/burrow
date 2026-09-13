import { afterEach, describe, expect, it, vi } from 'vitest';
import os from 'node:os';
import si from 'systeminformation';
import { TelemetryService } from '../electron/services/telemetry';

afterEach(() => vi.restoreAllMocks());

describe('real telemetry with partial provider failures', () => {
  it('falls back to OS memory/CPU and marks unavailable providers instead of inventing data', async () => {
    for (const method of [
      'currentLoad',
      'mem',
      'fsSize',
      'networkInterfaces',
      'networkStats',
      'battery',
      'processes',
    ] as const) {
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
