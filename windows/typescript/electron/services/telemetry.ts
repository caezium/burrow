import os from 'node:os';
import si from 'systeminformation';
import type { Snapshot } from '../../src/shared/contracts';

const percent = (value: number): number =>
  Number.isFinite(value) ? Math.min(100, Math.max(0, value)) : 0;
const nonnegative = (value: number): number => (Number.isFinite(value) ? Math.max(0, value) : 0);

/** Collects real operating-system measurements, with explicitly reported partial failures. */
export class TelemetryService {
  private pending: Promise<Snapshot> | undefined;
  private previousCpu = cpuTimes();
  private readonly providers = {
    load: singleFlight(() => si.currentLoad()),
    memory: singleFlight(() => si.mem()),
    disks: singleFlight(() => si.fsSize()),
    interfaces: singleFlight(() => si.networkInterfaces()),
    stats: singleFlight(() => si.networkStats('*')),
    battery: singleFlight(() => si.battery()),
    processes: singleFlight(() => si.processes()),
  };

  /** Shares a pending snapshot; individual providers remain shared after its deadline expires. */
  sample(): Promise<Snapshot> {
    if (!this.pending)
      this.pending = this.collect().finally(() => {
        this.pending = undefined;
      });
    return this.pending;
  }
  private async collect(): Promise<Snapshot> {
    const warnings: string[] = [];
    const safely = async <T>(name: string, request: Promise<T>, fallback: T): Promise<T> => {
      let timeout: ReturnType<typeof setTimeout> | undefined;
      try {
        return await Promise.race([
          request,
          new Promise<T>((_, reject) => {
            timeout = setTimeout(() => reject(new Error('Timed out')), 8_000);
          }),
        ]);
      } catch {
        warnings.push(`${name} is unavailable; this sample is partial.`);
        return fallback;
      } finally {
        if (timeout) clearTimeout(timeout);
      }
    };
    const [load, memory, disks, interfaces, stats, battery, processes] = await Promise.all([
      safely('CPU counters', this.providers.load(), null),
      safely('Memory counters', this.providers.memory(), null),
      safely('Disk counters', this.providers.disks(), []),
      safely('Network interfaces', this.providers.interfaces(), []),
      safely('Network traffic', this.providers.stats(), []),
      safely('Battery information', this.providers.battery(), null),
      safely('Process information', this.providers.processes(), null),
    ]);
    const currentCpu = cpuTimes();
    const elapsed = currentCpu.total - this.previousCpu.total;
    const fallbackCpu =
      elapsed > 0 ? 100 * (1 - (currentCpu.idle - this.previousCpu.idle) / elapsed) : 0;
    this.previousCpu = currentCpu;
    const total = memory?.total || os.totalmem();
    const used = memory ? total - memory.available : total - os.freemem();
    const cpus = os.cpus();
    const networkInterfaces = Array.isArray(interfaces) ? interfaces : [interfaces];
    let uptime = 0;
    try {
      uptime = os.uptime();
    } catch {
      warnings.push('System uptime is unavailable.');
    }
    if (!disks.length && !warnings.some((warning) => warning.startsWith('Disk counters')))
      warnings.push('Disk counters are unavailable; this sample is partial.');
    if (
      !processes?.list.length &&
      !warnings.some((warning) => warning.startsWith('Process information'))
    )
      warnings.push('Process information is unavailable; this sample is partial.');
    return {
      timestamp: Date.now(),
      hostname: os.hostname(),
      platform: os.platform(),
      osVersion: `${os.type()} ${os.release()}`,
      uptime,
      cpu: {
        usage: percent(load?.currentLoad ?? fallbackCpu),
        cores: cpus.length,
        model: cpus[0]?.model ?? 'Unavailable',
      },
      memory: { total, used: nonnegative(used), percent: percent((used / total) * 100) },
      disks: disks
        .filter((disk) => disk.size > 0)
        .slice(0, 24)
        .map((disk) => ({
          name: disk.fs,
          mount: disk.mount,
          used: nonnegative(disk.used),
          total: disk.size,
        })),
      network: networkInterfaces
        .filter((iface) => !iface.internal && iface.operstate === 'up')
        .slice(0, 24)
        .map((iface) => {
          const traffic = stats.find((stat) => stat.iface === iface.iface);
          return {
            name: iface.iface,
            address: iface.ip4 || iface.ip6 || 'Unassigned',
            rx: traffic && traffic.rx_sec >= 0 ? traffic.rx_sec : null,
            tx: traffic && traffic.tx_sec >= 0 ? traffic.tx_sec : null,
          };
        }),
      battery: battery?.hasBattery
        ? { percent: percent(battery.percent), charging: battery.isCharging }
        : null,
      processes: (processes?.list ?? [])
        .sort((a, b) => b.cpu - a.cpu)
        .slice(0, 12)
        .map((process) => ({
          pid: process.pid,
          name: process.name,
          cpu: nonnegative(process.cpu),
          memory: nonnegative(process.memRss) * 1024,
        })),
      warnings,
    };
  }
}

/** A caller's timeout must not release a provider that still has an OS request running. */
function singleFlight<T>(request: () => Promise<T>): () => Promise<T> {
  let pending: Promise<T> | undefined;
  return () => {
    if (!pending)
      pending = Promise.resolve()
        .then(request)
        .finally(() => {
          pending = undefined;
        });
    return pending;
  };
}

function cpuTimes(): { total: number; idle: number } {
  return os.cpus().reduce(
    (result, cpu) => ({
      total: result.total + Object.values(cpu.times).reduce((sum, value) => sum + value, 0),
      idle: result.idle + cpu.times.idle,
    }),
    { total: 0, idle: 0 },
  );
}
