import { afterEach, describe, expect, it, vi } from 'vitest';
import si from 'systeminformation';
import { SystemService } from '../electron/services/system';

type Connections = Awaited<ReturnType<typeof si.networkConnections>>;
function connection(overrides: Partial<Connections[number]> = {}): Connections[number] {
  return {
    protocol: 'tcp',
    localAddress: '127.0.0.1',
    localPort: '8080',
    peerAddress: '0.0.0.0',
    peerPort: '0',
    state: 'LISTEN',
    pid: 12,
    process: 'example',
    ...overrides,
  };
}
afterEach(() => {
  vi.useRealTimers();
  vi.restoreAllMocks();
});

describe('bounded port inventory', () => {
  it('preserves listening TCP/UDP filtering, valid ports and sorted display data', async () => {
    vi.useFakeTimers();
    vi.spyOn(si, 'networkConnections').mockResolvedValue([
      connection(),
      connection({
        protocol: 'udp6',
        localAddress: '::1',
        localPort: '53',
        state: '',
        process: '',
        pid: 0,
      }),
      connection({ localPort: '443', state: 'LISTENING' }),
      connection({ localPort: '22', state: 'ESTABLISHED' }),
      ...['0', '65536', '1.5', 'invalid'].map((localPort) => connection({ localPort })),
    ]);
    expect(await new SystemService().getPorts()).toEqual([
      { port: 53, address: '::1', pid: 0, name: 'Unavailable', protocol: 'UDP6' },
      { port: 443, address: '127.0.0.1', pid: 12, name: 'example', protocol: 'TCP' },
      { port: 8080, address: '127.0.0.1', pid: 12, name: 'example', protocol: 'TCP' },
    ]);
    expect(vi.getTimerCount()).toBe(0);
  });

  it('keeps the existing 2000-result cap', async () => {
    vi.useFakeTimers();
    vi.spyOn(si, 'networkConnections').mockResolvedValue(
      Array.from({ length: 2005 }, (_, index) => connection({ localPort: String(2005 - index) })),
    );
    const ports = await new SystemService().getPorts();
    expect(ports).toHaveLength(2000);
    expect(ports[0].port).toBe(1);
    expect(ports.at(-1)?.port).toBe(2000);
    expect(vi.getTimerCount()).toBe(0);
  });

  it('shares concurrent callers and one native request across repeated eight-second deadlines', async () => {
    vi.useFakeTimers();
    const provider = vi
      .spyOn(si, 'networkConnections')
      .mockImplementation(() => new Promise<Connections>(() => {}));
    const service = new SystemService();
    for (let attempt = 0; attempt < 3; attempt++) {
      const pending = service.getPorts();
      expect(service.getPorts()).toBe(pending);
      const rejection = expect(pending).rejects.toThrow(
        'Port lookup timed out. The system lookup may still be running',
      );
      await vi.advanceTimersByTimeAsync(7_999);
      expect(vi.getTimerCount()).toBe(1);
      expect(provider).toHaveBeenCalledTimes(1);
      await vi.advanceTimersByTimeAsync(1);
      await rejection;
      expect(vi.getTimerCount()).toBe(0);
    }
  });

  it.each(['resolve', 'reject'] as const)(
    'retains a timed-out provider until late %s and then permits a fresh lookup',
    async (outcome) => {
      vi.useFakeTimers();
      let resolve!: (connections: Connections) => void;
      let reject!: (error: Error) => void;
      const request = new Promise<Connections>((done, fail) => {
        resolve = done;
        reject = fail;
      });
      const provider = vi
        .spyOn(si, 'networkConnections')
        .mockReturnValueOnce(request)
        .mockResolvedValue([connection({ localPort: '9090' })]);
      const service = new SystemService();
      const first = expect(service.getPorts()).rejects.toThrow('timed out');
      await vi.advanceTimersByTimeAsync(8_000);
      await first;
      const waiting = service.getPorts();
      const waitingOutcome =
        outcome === 'reject'
          ? expect(waiting).rejects.toThrow('Late provider failure')
          : expect(waiting).resolves.toEqual([expect.objectContaining({ port: 8080 })]);
      await vi.advanceTimersByTimeAsync(0);
      expect(provider).toHaveBeenCalledTimes(1);
      if (outcome === 'resolve') resolve([connection()]);
      else reject(new Error('Late provider failure'));
      await waitingOutcome;
      expect(vi.getTimerCount()).toBe(0);
      expect(await service.getPorts()).toEqual([expect.objectContaining({ port: 9090 })]);
      expect(provider).toHaveBeenCalledTimes(2);
      expect(vi.getTimerCount()).toBe(0);
    },
  );

  it.each(['reject', 'throw'] as const)(
    'cleans the deadline on provider %s without inventing an empty successful inventory',
    async (outcome) => {
      vi.useFakeTimers();
      const provider = vi.spyOn(si, 'networkConnections');
      if (outcome === 'reject')
        provider.mockRejectedValueOnce(new Error('Port inventory unavailable'));
      else
        provider.mockImplementationOnce(() => {
          throw new Error('Port inventory unavailable');
        });
      provider.mockResolvedValue([connection()]);
      const service = new SystemService();
      await expect(service.getPorts()).rejects.toThrow('Port inventory unavailable');
      expect(vi.getTimerCount()).toBe(0);
      expect(await service.getPorts()).toHaveLength(1);
      expect(provider).toHaveBeenCalledTimes(2);
      expect(vi.getTimerCount()).toBe(0);
    },
  );

  it('handles a late rejection after the timed-out UI stopped waiting and allows recovery', async () => {
    vi.useFakeTimers();
    let reject!: (error: Error) => void;
    const provider = vi
      .spyOn(si, 'networkConnections')
      .mockReturnValueOnce(
        new Promise<Connections>((_, fail) => {
          reject = fail;
        }),
      )
      .mockResolvedValue([connection()]);
    const service = new SystemService();
    const expired = expect(service.getPorts()).rejects.toThrow('timed out');
    await vi.advanceTimersByTimeAsync(8_000);
    await expired;
    reject(new Error('Native lookup failed after the UI deadline'));
    await vi.advanceTimersByTimeAsync(0);
    expect(await service.getPorts()).toHaveLength(1);
    expect(provider).toHaveBeenCalledTimes(2);
    expect(vi.getTimerCount()).toBe(0);
  });
});
