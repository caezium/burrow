import { useEffect, useMemo, useState, type CSSProperties, type ReactNode } from 'react';
import {
  Activity,
  ArrowUpRight,
  Battery,
  Check,
  Cpu,
  Fan,
  Gauge,
  HardDrive,
  MemoryStick,
  Network,
  Pin,
  Search,
  ShieldCheck,
  Sparkles,
} from 'lucide-react';
import type { ActivityEntry, Diagnostic, Route, Snapshot } from '../shared/contracts';
import { api } from '../lib/api';
import { errorMessage, formatBytes, formatUptime } from '../lib/format';

const sections = ['Overview', 'Tune-Up', 'History', 'Activity', 'Doctor'] as const;
type Section = (typeof sections)[number];
export function Sparkline({
  values,
  color = '#3CB371',
  bars = false,
  timestamps,
  maxGap = 15 * 60000,
}: {
  values: number[];
  color?: string;
  bars?: boolean;
  timestamps?: number[];
  maxGap?: number;
}) {
  if (values.length < 2) return <div className="chart-wait muted">Collecting samples…</div>;
  const max = Math.max(...values, 1) * 1.12;
  const minTime = timestamps?.[0] ?? 0;
  const span = (timestamps?.at(-1) ?? 0) - minTime;
  const x = (i: number) =>
    timestamps && span > 0
      ? ((timestamps[i] - minTime) / span) * 300
      : (i / (values.length - 1)) * 300;
  const y = (v: number) => 46 - (v / max) * 42;
  const segments: string[][] = [[]];
  values.forEach((value, i) => {
    if (timestamps && i && timestamps[i] - timestamps[i - 1] > maxGap) segments.push([]);
    segments.at(-1)!.push(`${x(i)},${y(value)}`);
  });
  return (
    <svg className="sparkline" viewBox="0 0 300 50" preserveAspectRatio="none" aria-hidden="true">
      {bars
        ? values.map((value, index) => (
            <rect
              key={index}
              x={(index / values.length) * 300}
              y={y(value)}
              width={Math.max(1, 300 / values.length - 4)}
              height={48 - y(value)}
              rx="1.5"
              fill={color}
              opacity=".8"
            />
          ))
        : segments.map((points, i) => (
            <polyline
              key={i}
              points={points.join(' ')}
              fill="none"
              stroke={color}
              strokeWidth="2"
              vectorEffect="non-scaling-stroke"
              strokeLinecap="round"
              strokeLinejoin="round"
            />
          ))}
    </svg>
  );
}
function Metric({
  label,
  icon,
  color,
  value,
  unit,
  chip,
  foot,
  children,
}: {
  label: string;
  icon: ReactNode;
  color: string;
  value: string;
  unit?: string;
  chip?: string;
  foot: string;
  children?: ReactNode;
}) {
  return (
    <article className="panel metric-card" style={{ '--metric': color } as CSSProperties}>
      <div className="metric-header">
        <span className="eyebrow">
          {icon}
          {label}
        </span>
        {chip && <span className="pill">{chip}</span>}
      </div>
      <div className="metric-value">
        {value}
        <span>{unit}</span>
      </div>
      <div className="metric-chart">{children}</div>
      <p className="metric-foot">{foot}</p>
    </article>
  );
}
function Overview({ snapshot: s, samples }: { snapshot: Snapshot; samples: Snapshot[] }) {
  const [query, setQuery] = useState('');
  const [sort, setSort] = useState<'cpu' | 'memory' | 'name'>('cpu');
  const [pins, setPins] = useState<number[]>([]);
  const [inspected, setInspected] = useState<number | null>(null);
  const disk = s.disks[0];
  const network = s.network.find((n) => n.rx !== null) ?? s.network[0];
  const diskPercent = disk && disk.total ? (disk.used / disk.total) * 100 : 0;
  const attention = s.cpu.usage > 85 || s.memory.percent > 90 || diskPercent > 90;
  const processes = [...s.processes]
    .filter((p) => `${p.name} ${p.pid}`.toLowerCase().includes(query.toLowerCase()))
    .sort(
      (a, b) =>
        Number(pins.includes(b.pid)) - Number(pins.includes(a.pid)) ||
        (sort === 'name' ? a.name.localeCompare(b.name) : b[sort] - a[sort]),
    );
  const history = samples.slice(-36);
  const process = s.processes.find((p) => p.pid === inspected);
  return (
    <div className="overview-content">
      <div className="health-hero">
        <div className={`health-icon ${attention ? 'attention' : ''}`}>
          <ShieldCheck size={31} strokeWidth={1.4} />
        </div>
        <div className="health-copy">
          <div className="eyebrow">Every pulse of the den</div>
          <h1>
            {s.warnings.length
              ? 'A partial view of your system.'
              : attention
                ? 'A little room to improve.'
                : 'Looking good in here.'}
          </h1>
          <p>
            {s.warnings.length
              ? 'Some system measurements are unavailable.'
              : s.cpu.usage > 85
                ? 'CPU is busy right now.'
                : s.memory.percent > 90
                  ? 'Memory usage is high.'
                  : diskPercent > 90
                    ? 'Your disk is getting full.'
                    : 'CPU, memory, and disk have breathing room.'}
          </p>
        </div>
        <div className="machine-info">
          <strong>{s.hostname}</strong>
          <span>
            {s.cpu.cores} cores · {formatBytes(s.memory.total, 0)} RAM
          </span>
          <span>
            {s.warnings.some((w) => w.includes('uptime is unavailable'))
              ? 'Uptime unavailable'
              : `up ${formatUptime(s.uptime)}`}
          </span>
        </div>
      </div>
      {s.warnings.length > 0 && (
        <div className="notice" role="status">
          {s.warnings.join(' · ')}
        </div>
      )}
      <div className="metric-grid">
        <Metric
          label="CPU"
          icon={<Cpu size={14} />}
          color="#3CB371"
          value={s.cpu.usage.toFixed(1)}
          unit="%"
          chip={`${s.cpu.cores} cores`}
          foot={s.cpu.model}
        >
          <Sparkline values={history.map((h) => h.cpu.usage)} bars />
        </Metric>
        <Metric
          label="Memory"
          icon={<MemoryStick size={14} />}
          color="#E6A93C"
          value={s.memory.percent.toFixed(0)}
          unit="%"
          chip={s.memory.percent > 90 ? 'high use' : 'in use'}
          foot={`${formatBytes(s.memory.used)} / ${formatBytes(s.memory.total)}`}
        >
          <Sparkline color="#E6A93C" values={history.map((h) => h.memory.percent)} />
        </Metric>
        <Metric
          label="GPU"
          icon={<Cpu size={14} />}
          color="#F0714E"
          value="—"
          chip="unavailable"
          foot="GPU metrics are awaiting Windows integration."
        >
          <div className="sensor-placeholder">
            <span />
            <span />
            <span />
            <span />
            <span />
            <span />
            <span />
          </div>
        </Metric>
        <Metric
          label="Disk"
          icon={<HardDrive size={14} />}
          color="#4FA3E3"
          value={disk ? formatBytes(Math.max(0, disk.total - disk.used)).split(' ')[0] : '—'}
          unit={
            disk ? `${formatBytes(Math.max(0, disk.total - disk.used)).split(' ')[1]} free` : ''
          }
          chip={disk ? formatBytes(disk.total, 0) : undefined}
          foot={
            disk ? `${diskPercent.toFixed(0)}% used · ${disk.mount}` : 'Disk capacity unavailable'
          }
        >
          <div className="disk-track">
            <span style={{ width: `${Math.min(100, diskPercent)}%` }} />
          </div>
        </Metric>
        <Metric
          label="Network"
          icon={<Network size={14} />}
          color="#3CB371"
          value={network?.rx != null ? formatBytes(network.rx).split(' ')[0] : '—'}
          unit={network?.rx != null ? `${formatBytes(network.rx).split(' ')[1]}/s` : ''}
          chip={network?.name}
          foot={
            network?.tx != null
              ? `↓ receive · ↑ ${formatBytes(network.tx)}/s sent`
              : 'Throughput unavailable'
          }
        >
          <Sparkline
            color="#4FA3E3"
            values={history
              .map((h) => h.network.find((n) => n.name === network?.name)?.rx)
              .filter((v): v is number => v != null)}
          />
        </Metric>
        <Metric
          label="Fan"
          icon={<Fan size={14} />}
          color="#b5afa4"
          value="—"
          foot="Windows manages cooling automatically."
        >
          <div className="sensor-note">No fan sensor data</div>
        </Metric>
      </div>
      <div className="memory-strip">
        <span>
          <MemoryStick size={14} /> Memory
        </span>
        <div>
          <small>Used</small>
          <strong className="gold">{formatBytes(s.memory.used)}</strong>
        </div>
        <div>
          <small>Available</small>
          <strong>{formatBytes(s.memory.total - s.memory.used)}</strong>
        </div>
        <div className="memory-strip-track">
          <span style={{ width: `${Math.min(s.memory.percent, 100)}%` }} />
        </div>
        <span>{s.memory.percent.toFixed(0)}% in use</span>
      </div>
      <div className="panel battery-card">
        <div>
          <span className="eyebrow gold">
            <Battery size={14} />
            Power
          </span>
          <strong>{s.battery ? `${s.battery.percent}%` : 'Desktop power'}</strong>
        </div>
        <span className="muted">
          {s.battery
            ? s.battery.charging
              ? 'Connected to power · charging'
              : 'Running on battery'
            : 'No battery reported by this device'}
        </span>
        <div className="power-glyph">
          <Battery size={30} />
        </div>
      </div>
      <article className="panel processes-card">
        <div className="process-heading">
          <div>
            <span className="eyebrow">
              <Activity size={14} />
              Top processes
            </span>
            <span className="process-count">{s.processes.length} sampled</span>
          </div>
          <label className="search-field">
            <Search size={14} />
            <input
              aria-label="Filter processes"
              placeholder="Filter by name or PID…"
              value={query}
              onChange={(e) => setQuery(e.target.value)}
            />
            <kbd>⌕</kbd>
          </label>
        </div>
        <div className="process-table-wrap">
          <table className="process-table">
            <thead>
              <tr>
                <th aria-label="Pinned" />
                <th>
                  <button onClick={() => setSort('name')}>Process {sort === 'name' && '↓'}</button>
                </th>
                <th>PID</th>
                <th>
                  <button onClick={() => setSort('cpu')}>CPU {sort === 'cpu' && '↓'}</button>
                </th>
                <th>
                  <button onClick={() => setSort('memory')}>
                    Memory {sort === 'memory' && '↓'}
                  </button>
                </th>
              </tr>
            </thead>
            <tbody>
              {processes.map((p) => (
                <tr key={p.pid}>
                  <td>
                    <button
                      className={`pin-button ${pins.includes(p.pid) ? 'pinned' : ''}`}
                      aria-label={`${pins.includes(p.pid) ? 'Unpin' : 'Pin'} ${p.name}`}
                      onClick={() =>
                        setPins((all) =>
                          all.includes(p.pid) ? all.filter((id) => id !== p.pid) : [...all, p.pid],
                        )
                      }
                    >
                      <Pin size={12} />
                    </button>
                  </td>
                  <td>
                    <button
                      className="process-name"
                      onClick={() => setInspected(inspected === p.pid ? null : p.pid)}
                    >
                      <span className="process-avatar">{p.name.charAt(0).toUpperCase()}</span>
                      {p.name}
                    </button>
                  </td>
                  <td>{p.pid}</td>
                  <td className="green">{p.cpu.toFixed(1)}%</td>
                  <td>{formatBytes(p.memory)}</td>
                </tr>
              ))}
            </tbody>
          </table>
          {!processes.length && <p className="empty-inline">No processes match your filter.</p>}
        </div>
        {process && (
          <div className="process-inspector">
            <Cpu size={18} />
            <strong>{process.name}</strong>
            <span>PID {process.pid}</span>
            <span>{process.cpu.toFixed(1)}% CPU</span>
            <span>{formatBytes(process.memory)} memory</span>
            <button onClick={() => setInspected(null)}>Close</button>
          </div>
        )}
        <div className="table-footer">
          Live process sample<span>Pin a process to keep it in view.</span>
        </div>
      </article>
    </div>
  );
}
function History({ active }: { active: boolean }) {
  const [range, setRange] = useState(3600);
  const [maxGap, setMaxGap] = useState(15 * 60000);
  useEffect(() => {
    api
      .getSettings()
      .then((settings) =>
        setMaxGap(Math.max(1, Math.ceil((settings.retentionDays * 24 * 60) / 10080)) * 3 * 60000),
      )
      .catch(() => {});
  }, []);
  const [rows, setRows] = useState<Snapshot[]>([]);
  const [error, setError] = useState('');
  useEffect(() => {
    if (!active) return;
    let alive = true;
    const refresh = () =>
      api
        .getHistory(Date.now() - range * 1000)
        .then((r) => {
          if (alive) {
            setRows(r);
            setError('');
          }
        })
        .catch((e) => alive && setError(errorMessage(e)));
    void refresh();
    const timer = setInterval(refresh, 15000);
    return () => {
      alive = false;
      clearInterval(timer);
    };
  }, [range, active]);
  return (
    <div className="page-body">
      <div className="page-heading">
        <div>
          <span className="eyebrow">The longer view</span>
          <h1>History</h1>
          <p className="muted">A little perspective on your system.</p>
        </div>
        <div className="range-control" aria-label="History range">
          {[
            [300, '5m'],
            [3600, '1h'],
            [21600, '6h'],
            [86400, '24h'],
            [604800, '7d'],
            [2592000, '30d'],
            [7776000, '90d'],
          ].map(([seconds, label]) => (
            <button
              key={seconds}
              className={range === seconds ? 'active' : ''}
              onClick={() => setRange(Number(seconds))}
            >
              {label}
            </button>
          ))}
        </div>
      </div>
      {error && (
        <p role="alert" className="error-banner">
          {error}
        </p>
      )}
      {rows.length < 2 ? (
        <div className="panel empty-state">
          <Activity size={32} />
          <h2>Your story starts here.</h2>
          <p>
            Keep Burrow running to collect system history. Charts appear after the first two
            samples.
          </p>
        </div>
      ) : (
        <>
          <div className="history-grid">
            {[
              { title: 'CPU usage', color: '#3CB371', values: rows.map((r) => r.cpu.usage) },
              {
                title: 'Memory usage',
                color: '#E6A93C',
                values: rows.map((r) => r.memory.percent),
              },
            ].map((chart) => (
              <div className="panel history-card" key={chart.title}>
                <span className="eyebrow" style={{ color: chart.color }}>
                  {chart.title}
                </span>
                <strong>
                  {(chart.values.reduce((a, b) => a + b, 0) / chart.values.length).toFixed(1)}
                  <small>% average</small>
                </strong>
                <Sparkline
                  color={chart.color}
                  values={chart.values}
                  timestamps={rows.map((r) => r.timestamp)}
                  maxGap={maxGap}
                />
                <div className="chart-axis">
                  <span>{new Date(rows[0].timestamp).toLocaleString()}</span>
                  <span>{new Date(rows.at(-1)!.timestamp).toLocaleTimeString()}</span>
                </div>
              </div>
            ))}
          </div>
          <p className="muted history-note">
            {rows.length} samples · stored locally · breaks in sampling remain gaps
          </p>
        </>
      )}
    </div>
  );
}
function ActivityPage({ active }: { active: boolean }) {
  const [rows, setRows] = useState<ActivityEntry[]>([]);
  const [error, setError] = useState('');
  useEffect(() => {
    if (!active) return;
    let alive = true;
    api
      .getActivity()
      .then((value) => alive && setRows(value))
      .catch((e) => alive && setError(errorMessage(e)));
    return () => {
      alive = false;
    };
  }, [active]);
  return (
    <div className="page-body">
      <div className="page-heading">
        <div>
          <span className="eyebrow">A tidy paper trail</span>
          <h1>Activity</h1>
          <p className="muted">What Burrow has done, right here on your computer.</p>
        </div>
        <span className="pill">{rows.length} operations</span>
      </div>
      {error && <p role="alert">{error}</p>}
      {rows.length ? (
        <div className="panel activity-list">
          {rows.map((row) => (
            <div className="activity-row" key={row.id}>
              <span className={`activity-status ${row.status}`}>
                {row.status === 'success' ? <Check size={17} /> : <Activity size={17} />}
              </span>
              <div>
                <strong>{row.title}</strong>
                <p className="muted">{row.detail}</p>
              </div>
              <span>
                {new Date(row.timestamp).toLocaleString()}
                <small>
                  {row.status}
                  {row.bytes > 0 ? ` · ${formatBytes(row.bytes)} moved to Recycle Bin` : ''}
                </small>
              </span>
            </div>
          ))}
        </div>
      ) : (
        <div className="panel empty-state">
          <Activity size={34} />
          <h2>A fresh start.</h2>
          <p>Your scans and maintenance results will appear here.</p>
        </div>
      )}
    </div>
  );
}
function Doctor() {
  const [checks, setChecks] = useState<Diagnostic[]>([]);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const run = async () => {
    setBusy(true);
    setError('');
    try {
      setChecks(await api.diagnose());
    } catch (e) {
      setError(errorMessage(e));
    } finally {
      setBusy(false);
    }
  };
  return (
    <div className="page-body">
      <div className="page-heading">
        <div>
          <span className="eyebrow">A check-in for your computer</span>
          <h1>Doctor</h1>
          <p className="muted">Check your network interfaces and DNS configuration.</p>
        </div>
        <button className="button primary" disabled={busy} onClick={run}>
          <ShieldCheck size={16} />
          {busy ? 'Checking…' : 'Run checkup'}
        </button>
      </div>
      {error && (
        <p className="error-banner" role="alert">
          {error}
        </p>
      )}
      {checks.length ? (
        <div className="panel diagnostic-list">
          {checks.map((check, i) => (
            <div className="diagnostic-row" key={i}>
              <span className={`pill ${check.status}`}>{check.status}</span>
              <div>
                <strong>{check.name}</strong>
                <p className="muted">{check.detail}</p>
              </div>
            </div>
          ))}
        </div>
      ) : (
        <div className="panel empty-state">
          <ShieldCheck size={38} />
          <h2>How is your system feeling?</h2>
          <p>A read-only checkup. No settings will be changed.</p>
        </div>
      )}
    </div>
  );
}
export function MonitorPage({
  snapshot,
  active,
  navigate,
}: {
  snapshot: Snapshot | null;
  active: boolean;
  navigate: (route: Route) => void;
}) {
  const [section, setSection] = useState<Section>('Overview');
  const [samples, setSamples] = useState<Snapshot[]>([]);
  useEffect(() => {
    if (!active) return;
    let alive = true;
    api
      .getHistory(Date.now() - 30 * 60000)
      .then((rows) => alive && setSamples(rows.slice(-90)))
      .catch(() => {});
    return () => {
      alive = false;
    };
  }, [active]);
  useEffect(() => {
    if (snapshot && active)
      setSamples((rows) =>
        rows.at(-1)?.timestamp === snapshot.timestamp ? rows : [...rows.slice(-89), snapshot],
      );
  }, [snapshot, active]);
  const subtitle = useMemo(
    () =>
      snapshot
        ? new Date(snapshot.timestamp).toLocaleTimeString([], {
            hour: '2-digit',
            minute: '2-digit',
          })
        : 'waiting',
    [snapshot],
  );
  return (
    <div className="monitor-page">
      <div className="home-toolbar">
        <div className="segmented" role="tablist" aria-label="Monitor sections">
          {sections.map((tab) => (
            <button
              key={tab}
              role="tab"
              aria-selected={section === tab}
              className={section === tab ? 'active' : ''}
              onClick={() => setSection(tab)}
            >
              {tab}
            </button>
          ))}
        </div>
        <span className="live-badge">
          <span className="status-dot" />
          {api.mode === 'preview' ? 'Example' : 'Live'}
          <span>{subtitle}</span>
        </span>
      </div>
      {section === 'Overview' &&
        (snapshot ? (
          <Overview snapshot={snapshot} samples={samples} />
        ) : (
          <div className="empty-state">
            <Gauge className="spin" size={32} />
            <h2>Listening to your system…</h2>
            <p>The first sample will be here in a moment.</p>
          </div>
        ))}
      {section === 'History' && <History active={active} />}
      {section === 'Activity' && <ActivityPage active={active} />}
      {section === 'Doctor' && <Doctor />}
      {section === 'Tune-Up' && (
        <div className="page-body tuneup-page">
          <div className="tool-orb">
            <Sparkles size={37} />
          </div>
          <h1>One pass, a tidier den.</h1>
          <p className="muted">Start with a look around. Every cleanup begins with a review.</p>
          <div className="tuneup-cards">
            {[
              {
                route: 'clean' as const,
                title: 'Make some room',
                detail: 'Review caches, build artifacts, and old installers.',
                icon: Sparkles,
                color: '#35C2A5',
              },
              {
                route: 'analyze' as const,
                title: 'See the big picture',
                detail: 'Find the folders taking up space on your disk.',
                icon: HardDrive,
                color: '#4FA3E3',
              },
              {
                route: 'optimize' as const,
                title: 'A small fresh start',
                detail: 'Review available Windows maintenance.',
                icon: Gauge,
                color: '#8E84F0',
              },
            ].map((card) => (
              <button
                key={card.route}
                className="panel tuneup-card"
                onClick={() => navigate(card.route)}
              >
                <card.icon size={25} color={card.color} />
                <h2>{card.title}</h2>
                <p className="muted">{card.detail}</p>
                <span style={{ color: card.color }}>
                  Open {card.route}
                  <ArrowUpRight size={15} />
                </span>
              </button>
            ))}
          </div>
          <p className="subtle-note">
            Choose a step to get started. A saved, automatic routine is coming in a later version.
          </p>
        </div>
      )}
    </div>
  );
}
