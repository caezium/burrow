import { useEffect, useMemo, useRef, useState, type CSSProperties, type ReactNode } from 'react';
import {
  ArrowDownLeft,
  ArrowRight,
  ArrowUpRight,
  Boxes,
  Check,
  CheckCircle2,
  ChevronRight,
  CircleHelp,
  Copy,
  Download,
  ExternalLink,
  File,
  Folder,
  FolderOpen,
  HardDrive,
  Image,
  Info,
  LoaderCircle,
  Network,
  Package,
  Radio,
  RefreshCw,
  Search,
  ShieldCheck,
  Sparkles,
  Trash2,
  Wifi,
  X,
} from 'lucide-react';
import type {
  BurrowAPI,
  Diagnostic,
  PortInfo,
  Route,
  ScanEntry,
  ScanKind,
  ScanProgress,
  ScanResult,
  Snapshot,
} from '../shared/contracts';
import { formatBytes } from '../lib/format';
import { LeftoversPage } from './LeftoversPage';
import { AppsPage } from './AppsPage';
import '../styles/tools.css';

type ToolProps = { api: BurrowAPI };
const errorMessage = (error: unknown) =>
  error instanceof Error ? error.message : 'Something went wrong. Please try again.';
const navigate = (route: Route) =>
  window.dispatchEvent(new CustomEvent('burrow:navigate', { detail: route }));
const count = (value: number) => value.toLocaleString();
const accents = [
  '#4FA3E3',
  '#35C2A5',
  '#E6A93C',
  '#F0714E',
  '#8E84F0',
  '#DB7E9C',
  '#6FB06A',
  '#D98C5F',
];

function Heading({
  eyebrow,
  title,
  description,
  action,
}: {
  eyebrow: string;
  title: string;
  description: string;
  action?: ReactNode;
}) {
  return (
    <header className="page-heading tool-heading">
      <div>
        <p className="eyebrow">{eyebrow}</p>
        <h1>{title}</h1>
        <p className="muted">{description}</p>
      </div>
      {action}
    </header>
  );
}

function Notice({ children, error = false }: { children: ReactNode; error?: boolean }) {
  return (
    <div className={`tool-notice ${error ? 'tool-error' : ''}`} role={error ? 'alert' : 'status'}>
      <Info size={16} aria-hidden="true" />
      <div>{children}</div>
    </div>
  );
}

function SearchField({
  value,
  onChange,
  placeholder,
}: {
  value: string;
  onChange: (value: string) => void;
  placeholder: string;
}) {
  return (
    <label className="tool-search">
      <Search size={16} aria-hidden="true" />
      <span className="tool-sr-only">{placeholder}</span>
      <input
        value={value}
        onChange={(event) => onChange(event.target.value)}
        placeholder={placeholder}
        type="search"
      />
    </label>
  );
}

function Busy({ text }: { text: string }) {
  return (
    <div className="tool-loading" role="status">
      <LoaderCircle className="tool-spin" size={20} aria-hidden="true" />
      <span>{text}</span>
    </div>
  );
}

function useScan(api: BurrowAPI, kind: ScanKind) {
  const [result, setResult] = useState<ScanResult | null>(null);
  const [scanning, setScanning] = useState(false);
  const [progress, setProgress] = useState<ScanProgress | null>(null);
  const [error, setError] = useState('');
  const [root, setRoot] = useState('');
  const [choosing, setChoosing] = useState(false);
  const active = useRef(false);
  useEffect(
    () =>
      api.onScanProgress((value) => {
        if (active.current) setProgress(value);
      }),
    [api],
  );

  async function start(path = root) {
    if (active.current) return;
    active.current = true;
    setScanning(true);
    setError('');
    setProgress(null);
    try {
      const next = await api.scan(kind, kind === 'clean' ? undefined : path || undefined);
      setResult(next);
      setRoot(next.root);
      return next;
    } catch (failure) {
      setError(errorMessage(failure));
    } finally {
      active.current = false;
      setScanning(false);
    }
  }

  async function choose() {
    setChoosing(true);
    setError('');
    try {
      const selected = await api.chooseFolder();
      if (selected) {
        setRoot(selected);
        setResult(null);
      }
    } catch (failure) {
      setError(errorMessage(failure));
    } finally {
      setChoosing(false);
    }
  }

  async function cancel() {
    try {
      await api.cancelScan();
      return true;
    } catch (failure) {
      setError(errorMessage(failure));
      return false;
    }
  }

  return {
    result,
    scanning,
    progress,
    error,
    setError,
    root,
    choosing,
    start,
    choose,
    cancel,
    invalidate: () => setResult(null),
  };
}

type ScanState = ReturnType<typeof useScan>;
function ScanControls({
  state,
  action = 'Scan folder',
  disabled = false,
  fixedScope = false,
}: {
  state: ScanState;
  action?: string;
  disabled?: boolean;
  fixedScope?: boolean;
}) {
  return (
    <>
      <div className="tool-scan-controls">
        <div className="tool-folder-path">
          <FolderOpen size={19} aria-hidden="true" />
          <div>
            <span className="tool-label">
              {fixedScope ? 'Current user · temporary files' : 'Selected folder'}
            </span>
            <span
              title={
                state.root || (fixedScope ? 'Windows user Temp folder' : 'Choose a folder to begin')
              }
            >
              {state.root || (fixedScope ? 'Windows user Temp folder' : 'Choose a folder to begin')}
            </span>
          </div>
        </div>
        {!fixedScope && (
          <button
            className="button"
            onClick={() => void state.choose()}
            disabled={disabled || state.scanning || state.choosing}
          >
            <Folder size={15} aria-hidden="true" />
            {state.choosing ? 'Choosing…' : 'Choose folder'}
          </button>
        )}
        <button
          className="button primary"
          onClick={() => void state.start()}
          disabled={disabled || (!fixedScope && !state.root) || state.scanning || state.choosing}
        >
          <Search size={15} aria-hidden="true" />
          {action}
        </button>
      </div>
      {state.scanning && (
        <div className="tool-scan-progress" role="status">
          <div className="tool-progress-top">
            <LoaderCircle size={17} className="tool-spin" aria-hidden="true" />
            <strong>Reading your files</strong>
            <span className="muted">
              {state.progress
                ? `${count(state.progress.scanned)} items · ${formatBytes(state.progress.bytes)}`
                : 'Preparing scan…'}
            </span>
            <button className="button tool-small" onClick={() => void state.cancel()}>
              <X size={14} aria-hidden="true" />
              Cancel
            </button>
          </div>
          <div className="tool-indeterminate" />
          <p className="tool-path muted">
            {state.progress?.path || 'This can take a moment for large folders.'}
          </p>
        </div>
      )}
      {state.error && <Notice error>{state.error}</Notice>}
    </>
  );
}

function ScanFootnote({ result }: { result: ScanResult }) {
  return (
    <div className="tool-scan-footnote">
      <span>
        Scanned {count(result.scanned)} items ·{' '}
        {new Date(result.timestamp).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}
      </span>
      {result.skipped > 0 && <span>{count(result.skipped)} inaccessible or excluded</span>}
      {result.truncated && (
        <span className="tool-warning-text">Scan limit reached · results are partial</span>
      )}
      {result.cancelled && (
        <span className="tool-warning-text">Scan cancelled · results are partial</span>
      )}
    </div>
  );
}

const cleanCategories = [
  {
    kind: 'clean',
    title: 'Temporary files',
    label: 'Temporary files',
    description: 'Clear old files from your user Temp folder.',
    icon: Sparkles,
    color: '#35C2A5',
  },
  {
    kind: 'purge',
    title: 'Project build artifacts',
    label: 'Developer artifacts',
    description: 'Clear the diggings dev work leaves behind.',
    icon: Boxes,
    color: '#6FB06A',
  },
  {
    kind: 'installers',
    title: 'Leftover installers',
    label: 'Installers',
    description: 'Sweep out the crates you unpacked.',
    icon: Download,
    color: '#D98C5F',
  },
] as const;

function CleanPage({ api }: ToolProps) {
  const [category, setCategory] = useState<'clean' | 'purge' | 'installers'>('clean');
  return (
    <div className="tool-page tool-clean">
      <Heading
        eyebrow="Make a little room"
        title="Clean"
        description="Fresh air through old tunnels."
      />
      <div className="tool-category-grid" aria-label="Cleanup categories">
        {cleanCategories.map((item) => (
          <button
            key={item.kind}
            className={`panel tool-category ${category === item.kind ? 'is-active' : ''}`}
            style={{ '--tool-accent': item.color } as CSSProperties}
            aria-pressed={category === item.kind}
            onClick={() => setCategory(item.kind)}
          >
            <item.icon size={25} strokeWidth={1.7} aria-hidden="true" />
            <div>
              <strong>{item.title}</strong>
              <span>{item.description}</span>
            </div>
            <ChevronRight size={17} aria-hidden="true" />
          </button>
        ))}
      </div>
      <div hidden={category !== 'clean'}>
        <CleanupScan api={api} kind="clean" />
      </div>
      <div hidden={category !== 'purge'}>
        <CleanupScan api={api} kind="purge" />
      </div>
      <div hidden={category !== 'installers'}>
        <CleanupScan api={api} kind="installers" />
      </div>
    </div>
  );
}

function useRecycle(api: BurrowAPI, state: ScanState) {
  const [recycling, setRecycling] = useState(false);
  const [stopping, setStopping] = useState(false);
  const [message, setMessage] = useState('');
  const active = useRef(false);

  async function recycle(ids: string[]) {
    if (!state.result || !ids.length || active.current || api.mode === 'preview') return;
    const snapshot = state.result;
    active.current = true;
    setRecycling(true);
    state.setError('');
    setMessage('');
    try {
      const outcome = await api.recycle(snapshot.id, ids);
      const moved = `${count(outcome.recycled)} ${outcome.recycled === 1 ? 'item' : 'items'} · ${formatBytes(outcome.bytes)} moved to Recycle Bin.`;
      setMessage(
        `${outcome.cancelled ? (outcome.recycled > 0 ? `Removal stopped. ${moved}` : 'Removal cancelled. No items were moved.') : moved}${outcome.failures.length ? ` ${outcome.failures.length} ${outcome.failures.length === 1 ? 'issue' : 'issues'}: ${outcome.failures.slice(0, 3).join('; ')}` : ''}`,
      );
      if (!outcome.cancelled || outcome.recycled > 0) {
        // Never expose IDs from the pre-removal scan after a partial or completed batch.
        state.invalidate();
        await state.start(snapshot.root);
      }
    } catch (failure) {
      state.invalidate();
      state.setError(`${errorMessage(failure)} Scan again to review the current files.`);
    } finally {
      active.current = false;
      setRecycling(false);
      setStopping(false);
    }
  }
  async function stop() {
    setStopping(true);
    if (!(await state.cancel())) setStopping(false);
  }
  return { recycling, stopping, message, setMessage, recycle, stop };
}

function CleanupScan({ api, kind }: ToolProps & { kind: 'clean' | 'purge' | 'installers' }) {
  const state = useScan(api, kind);
  const [query, setQuery] = useState('');
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const { recycling, stopping, message, setMessage, recycle, stop } = useRecycle(api, state);
  const entries = state.result?.entries || [];
  const visible = useMemo(
    () =>
      entries
        .filter((entry) =>
          `${entry.name} ${entry.path} ${entry.category}`
            .toLowerCase()
            .includes(query.toLowerCase()),
        )
        .sort((a, b) => b.bytes - a.bytes),
    [entries, query],
  );
  useEffect(() => {
    setSelected(new Set());
  }, [state.result]);
  const selectedBytes = entries.reduce(
    (total, entry) => total + (selected.has(entry.id) ? entry.bytes : 0),
    0,
  );
  const allVisibleSelected = visible.length > 0 && visible.every((entry) => selected.has(entry.id));
  const someVisibleSelected = visible.some((entry) => selected.has(entry.id));
  function toggle(id: string) {
    if (!selected.has(id) && selected.size >= 200) {
      setMessage('You can review up to 200 items at a time. Recycle or deselect some items first.');
      return;
    }
    setSelected((current) => {
      const next = new Set(current);
      if (next.has(id)) next.delete(id);
      else if (next.size < 200) next.add(id);
      return next;
    });
  }
  function toggleVisible() {
    const clear = allVisibleSelected || (selected.size >= 200 && someVisibleSelected);
    if (!clear && visible.filter((entry) => !selected.has(entry.id)).length + selected.size > 200)
      setMessage('Selected up to 200 items. Review this batch before selecting more.');
    setSelected((current) => {
      const next = new Set(current);
      for (const entry of visible) {
        if (clear) next.delete(entry.id);
        else if (next.size < 200) next.add(entry.id);
      }
      return next;
    });
  }
  async function reveal(path: string) {
    try {
      await api.reveal(path);
    } catch (failure) {
      state.setError(errorMessage(failure));
    }
  }

  return (
    <section className="panel tool-scan-panel">
      <div className="tool-section-heading">
        <div>
          <h2>
            {kind === 'clean'
              ? 'A little room to breathe.'
              : kind === 'purge'
                ? 'Clear the build-up.'
                : 'Unpacked. No longer needed?'}
          </h2>
          <p className="muted">
            {kind === 'clean'
              ? 'Review temporary files last modified more than seven days ago. Recent or changing files stay in place.'
              : kind === 'purge'
                ? 'Find generated development folders. Review each project before recycling anything.'
                : 'Find installation packages in a folder you choose. Keep the ones you still need.'}
          </p>
        </div>
        <span className="pill">{api.mode === 'preview' ? 'Preview data' : 'Local scan'}</span>
      </div>
      <ScanControls
        state={state}
        disabled={recycling}
        fixedScope={kind === 'clean'}
        action={kind === 'clean' ? 'Scan temporary files' : 'Scan folder'}
      />
      {kind === 'clean' && (
        <Notice>
          Only your Windows user Temp folder is included. App caches, browser data, and system
          folders are outside this cleanup.
        </Notice>
      )}
      {api.mode === 'preview' && (
        <Notice>
          Example files only. Open the desktop app to review and recycle files on your computer.
        </Notice>
      )}
      {message && <Notice>{message}</Notice>}
      {state.result && !state.scanning ? (
        <>
          <div className="tool-results-toolbar">
            <div>
              <strong>{formatBytes(state.result.totalBytes)}</strong>
              <span className="muted"> across {count(entries.length)} found items</span>
            </div>
            <SearchField value={query} onChange={setQuery} placeholder="Filter files and folders" />
          </div>
          {visible.length ? (
            <div className="tool-table-wrap">
              <table className="tool-table">
                <thead>
                  <tr>
                    <th className="tool-check-cell">
                      <input
                        type="checkbox"
                        aria-label="Select up to 200 filtered items"
                        ref={(element) => {
                          if (element)
                            element.indeterminate = someVisibleSelected && !allVisibleSelected;
                        }}
                        checked={allVisibleSelected}
                        onChange={toggleVisible}
                        disabled={recycling}
                      />
                    </th>
                    <th>Item</th>
                    <th>Category</th>
                    <th className="tool-align-right">Size</th>
                    <th>
                      <span className="tool-sr-only">Actions</span>
                    </th>
                  </tr>
                </thead>
                <tbody>
                  {visible.map((entry) => (
                    <tr key={entry.id} className={selected.has(entry.id) ? 'is-selected' : ''}>
                      <td className="tool-check-cell">
                        <input
                          type="checkbox"
                          checked={selected.has(entry.id)}
                          aria-label={`Select ${entry.name}`}
                          onChange={() => toggle(entry.id)}
                          disabled={recycling}
                        />
                      </td>
                      <td>
                        <div className="tool-file">
                          <span className="tool-file-icon">
                            {entry.isDirectory ? (
                              <Folder size={19} aria-hidden="true" />
                            ) : kind === 'clean' ? (
                              <File size={19} aria-hidden="true" />
                            ) : (
                              <Package size={19} aria-hidden="true" />
                            )}
                          </span>
                          <span>
                            <strong>{entry.name}</strong>
                            <small title={entry.path}>{entry.path}</small>
                          </span>
                        </div>
                      </td>
                      <td>
                        <span className="tool-tag">{entry.category}</span>
                      </td>
                      <td className="tool-align-right tool-mono">{formatBytes(entry.bytes)}</td>
                      <td>
                        <button
                          className="tool-icon-button"
                          aria-label={`Reveal ${entry.name}`}
                          title="Reveal in Explorer"
                          onClick={() => void reveal(entry.path)}
                        >
                          <ExternalLink size={16} aria-hidden="true" />
                        </button>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          ) : (
            <div className="empty-state tool-empty">
              <CheckCircle2 size={30} aria-hidden="true" />
              <h3>{query ? 'No matches in this scan.' : 'Nothing to clear here.'}</h3>
              <p className="muted">
                {query
                  ? 'Try a different file name or path.'
                  : kind === 'clean'
                    ? 'No eligible temporary files older than seven days were found. Recent files stay in place.'
                    : 'Try another folder, or enjoy the breathing room.'}
              </p>
            </div>
          )}
          <div className="tool-selection-bar">
            <span>
              <strong>{selected.size} selected</strong>
              <span className="muted"> · {formatBytes(selectedBytes)}</span>
            </span>
            <div className="tool-recycle-actions">
              {recycling && (
                <button className="button" onClick={() => void stop()} disabled={stopping}>
                  {stopping ? 'Stopping…' : 'Stop after current item'}
                </button>
              )}
              <button
                className="button primary"
                disabled={selected.size === 0 || recycling || api.mode === 'preview'}
                onClick={() => void recycle([...selected])}
              >
                {recycling ? (
                  <LoaderCircle size={16} className="tool-spin" aria-hidden="true" />
                ) : (
                  <Trash2 size={16} aria-hidden="true" />
                )}
                {recycling ? 'Moving to Recycle Bin…' : 'Review & recycle'}
              </button>
            </div>
          </div>
          <p className="muted tool-caption">
            Review up to 200 items at a time. Windows asks for confirmation before removal. Items go
            to the Recycle Bin; disk space is released when you empty it.{' '}
            {kind === 'purge' && 'Generated files may take time to rebuild.'}
          </p>
          <ScanFootnote result={state.result} />
        </>
      ) : (
        !state.scanning && (
          <div className="empty-state tool-empty">
            <FolderOpen size={33} strokeWidth={1.4} aria-hidden="true" />
            <h3>
              {kind === 'clean' ? 'Take a look before clearing space.' : 'Start with a folder.'}
            </h3>
            <p className="muted">
              {kind === 'clean'
                ? 'Scan your user Temp folder for old files. Nothing is removed during the scan.'
                : kind === 'purge'
                  ? 'Choose your projects folder to look for generated build artifacts.'
                  : 'Choose Downloads or a folder where you keep installers.'}
            </p>
            <span className="tool-caption muted">
              Nothing is selected or removed automatically.
            </span>
          </div>
        )
      )}
    </section>
  );
}

type MapItem = { entry: ScanEntry | null; name: string; bytes: number; color: string };
type MapRect = MapItem & { x: number; y: number; width: number; height: number };
function partitionMap(items: MapItem[], x = 0, y = 0, width = 100, height = 100): MapRect[] {
  if (!items.length) return [];
  if (items.length === 1) return [{ ...items[0], x, y, width, height }];
  const total = items.reduce((sum, item) => sum + item.bytes, 0);
  let split = 1;
  let leftBytes = items[0].bytes;
  while (
    split < items.length - 1 &&
    Math.abs(leftBytes + items[split].bytes - total / 2) < Math.abs(leftBytes - total / 2)
  ) {
    leftBytes += items[split].bytes;
    split++;
  }
  const ratio = total > 0 ? leftBytes / total : split / items.length;
  return width * 1.8 >= height
    ? [
        ...partitionMap(items.slice(0, split), x, y, width * ratio, height),
        ...partitionMap(items.slice(split), x + width * ratio, y, width * (1 - ratio), height),
      ]
    : [
        ...partitionMap(items.slice(0, split), x, y, width, height * ratio),
        ...partitionMap(items.slice(split), x, y + height * ratio, width, height * (1 - ratio)),
      ];
}

function AnalyzePage({ api }: ToolProps) {
  const state = useScan(api, 'analyze');
  const [query, setQuery] = useState('');
  const [trail, setTrail] = useState<{ name: string; path: string }[]>([]);
  const entries = useMemo(
    () => [...(state.result?.entries || [])].sort((a, b) => b.bytes - a.bytes),
    [state.result],
  );
  const visible = entries.filter((entry) =>
    `${entry.name} ${entry.path}`.toLowerCase().includes(query.toLowerCase()),
  );
  const rectangles = useMemo(() => {
    const positive = entries.filter((entry) => entry.bytes > 0);
    const mapped: MapItem[] = positive.slice(0, 48).map((entry, index) => ({
      entry,
      name: entry.name,
      bytes: entry.bytes,
      color: accents[index % accents.length],
    }));
    const remaining = positive.slice(48).reduce((sum, entry) => sum + entry.bytes, 0);
    if (remaining > 0)
      mapped.push({
        entry: null,
        name: `${positive.length - 48} more items`,
        bytes: remaining,
        color: '#8B8171',
      });
    return partitionMap(mapped);
  }, [entries]);
  useEffect(() => {
    if (state.result && !trail.some((crumb) => crumb.path === state.result!.root))
      setTrail([
        {
          name: state.result.root.split(/[\\/]/).filter(Boolean).pop() || state.result.root,
          path: state.result.root,
        },
      ]);
  }, [state.result]);
  async function reveal(path: string) {
    try {
      await api.reveal(path);
    } catch (failure) {
      state.setError(errorMessage(failure));
    }
  }
  async function drill(entry: ScanEntry) {
    if (!entry.isDirectory || state.scanning) return;
    const previousTrail = trail;
    setTrail((current) => [...current, { name: entry.name, path: entry.path }]);
    setQuery('');
    if (!(await state.start(entry.path))) setTrail(previousTrail);
  }
  async function goTo(index: number) {
    const previousTrail = trail;
    setTrail((current) => current.slice(0, index + 1));
    setQuery('');
    if (!(await state.start(trail[index].path))) setTrail(previousTrail);
  }
  return (
    <div className="tool-page tool-analyze">
      <Heading eyebrow="Know your space" title="Analyze" description="Map every chamber below." />
      <section className="panel tool-scan-panel">
        <ScanControls state={state} action="Map folder" />
        {state.result && !state.scanning ? (
          <>
            <div className="tool-results-toolbar">
              <nav className="tool-breadcrumbs" aria-label="Folder path">
                {trail.map((crumb, index) => (
                  <span key={crumb.path}>
                    {index > 0 && <ChevronRight size={13} aria-hidden="true" />}
                    <button
                      onClick={() => void goTo(index)}
                      disabled={index === trail.length - 1}
                      title={crumb.path}
                    >
                      {crumb.name}
                    </button>
                  </span>
                ))}
              </nav>
              <strong className="tool-mono">{formatBytes(state.result.totalBytes)}</strong>
            </div>
            {rectangles.length > 0 ? (
              <div
                className="tool-treemap"
                aria-label="Folder size map. Tile areas represent file size."
              >
                {rectangles.map((rect, index) => (
                  <button
                    key={rect.entry?.id || 'remaining'}
                    className="tool-map-tile"
                    disabled={!rect.entry}
                    title={`${rect.name} · ${formatBytes(rect.bytes)}${rect.entry?.isDirectory ? ' · Open folder' : ' · Reveal file'}`}
                    aria-label={`${rect.name}, ${formatBytes(rect.bytes)}. ${rect.entry?.isDirectory ? 'Open folder' : 'Reveal file'}`}
                    style={
                      {
                        left: `${rect.x}%`,
                        top: `${rect.y}%`,
                        width: `${rect.width}%`,
                        height: `${rect.height}%`,
                        '--tile-color': rect.color,
                      } as CSSProperties
                    }
                    onClick={() =>
                      rect.entry &&
                      (rect.entry.isDirectory
                        ? void drill(rect.entry)
                        : void reveal(rect.entry.path))
                    }
                  >
                    {rect.width * rect.height > 160 && (
                      <>
                        <span>
                          {rect.entry?.isDirectory ? (
                            <Folder size={17} aria-hidden="true" />
                          ) : (
                            <File size={17} aria-hidden="true" />
                          )}
                          {rect.name}
                        </span>
                        <strong>{formatBytes(rect.bytes)}</strong>
                        {index < 3 && (
                          <small>
                            {state.result!.totalBytes > 0
                              ? `${((rect.bytes / state.result!.totalBytes) * 100).toFixed(1)}% of this folder`
                              : ''}
                          </small>
                        )}
                      </>
                    )}
                  </button>
                ))}
              </div>
            ) : (
              <div className="empty-state tool-empty">
                <Folder size={32} aria-hidden="true" />
                <h3>This folder has no measured file content.</h3>
                <p className="muted">
                  Empty folders and skipped files do not take up space on this map.
                </p>
              </div>
            )}
            <div className="tool-results-toolbar">
              <span className="muted">Click a folder to explore. Tile area reflects its size.</span>
              <SearchField value={query} onChange={setQuery} placeholder="Filter this folder" />
            </div>
            <div className="tool-table-wrap">
              <table className="tool-table">
                <thead>
                  <tr>
                    <th>Name</th>
                    <th className="tool-align-right">Size</th>
                    <th className="tool-align-right">Share</th>
                    <th>
                      <span className="tool-sr-only">Reveal</span>
                    </th>
                  </tr>
                </thead>
                <tbody>
                  {visible.map((entry, index) => (
                    <tr key={entry.id}>
                      <td>
                        <button
                          className="tool-file tool-file-link"
                          onClick={() =>
                            entry.isDirectory ? void drill(entry) : void reveal(entry.path)
                          }
                        >
                          <span
                            className="tool-file-icon"
                            style={{ color: accents[index % accents.length] }}
                          >
                            {entry.isDirectory ? (
                              <Folder size={19} aria-hidden="true" />
                            ) : (
                              <File size={19} aria-hidden="true" />
                            )}
                          </span>
                          <strong>{entry.name}</strong>
                          {entry.isDirectory && <ChevronRight size={14} aria-hidden="true" />}
                        </button>
                      </td>
                      <td className="tool-align-right tool-mono">{formatBytes(entry.bytes)}</td>
                      <td className="tool-align-right tool-mono muted">
                        {state.result!.totalBytes > 0
                          ? `${((entry.bytes / state.result!.totalBytes) * 100).toFixed(1)}%`
                          : '—'}
                      </td>
                      <td>
                        <button
                          className="tool-icon-button"
                          aria-label={`Reveal ${entry.name}`}
                          onClick={() => void reveal(entry.path)}
                        >
                          <ExternalLink size={16} aria-hidden="true" />
                        </button>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
              {visible.length === 0 && query && (
                <p className="tool-empty muted">No items match “{query}”.</p>
              )}
            </div>
            <ScanFootnote result={state.result} />
          </>
        ) : (
          !state.scanning && (
            <div className="empty-state tool-empty tool-large-empty">
              <div className="tool-orb tool-orb-blue">
                <HardDrive size={34} strokeWidth={1.4} aria-hidden="true" />
              </div>
              <h2>A map of what matters.</h2>
              <p className="muted">
                Choose a folder to see where the space goes.
                <br />
                Open any folder in the map to dig deeper.
              </p>
            </div>
          )
        )}
      </section>
    </div>
  );
}

function DuplicatesPage({ api }: ToolProps) {
  const state = useScan(api, 'duplicates');
  const [query, setQuery] = useState('');
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const { recycling, stopping, message, setMessage, recycle, stop } = useRecycle(api, state);
  const allGroups = useMemo(() => {
    const byGroup = new Map<string, ScanEntry[]>();
    for (const entry of state.result?.entries || []) {
      if (!entry.group) continue;
      byGroup.set(entry.group, [...(byGroup.get(entry.group) || []), entry]);
    }
    return [...byGroup.values()]
      .filter((group) => group.length > 1)
      .map((group) => group.sort((a, b) => a.modified - b.modified || a.path.localeCompare(b.path)))
      .sort((a, b) => b[0].bytes * (b.length - 1) - a[0].bytes * (a.length - 1));
  }, [state.result]);
  const groups = allGroups.filter((group) =>
    group.some((entry) =>
      `${entry.name} ${entry.path}`.toLowerCase().includes(query.toLowerCase()),
    ),
  );
  const extraBytes = groups.reduce(
    (total, group) => total + group[0].bytes * (group.length - 1),
    0,
  );
  const selectedBytes = allGroups
    .flat()
    .reduce((total, entry) => total + (selected.has(entry.id) ? entry.bytes : 0), 0);
  const retained = allGroups.flat().length - selected.size;
  const hiddenSelection = allGroups.some(
    (group) => !groups.includes(group) && group.some((entry) => selected.has(entry.id)),
  );
  useEffect(() => setSelected(new Set()), [state.result]);

  function toggle(entry: ScanEntry, group: ScanEntry[]) {
    setSelected((current) => {
      const next = new Set(current);
      if (next.has(entry.id)) next.delete(entry.id);
      else if (next.size < 200 && group.some((copy) => copy.id !== entry.id && !next.has(copy.id)))
        next.add(entry.id);
      return next;
    });
  }
  function selectExtraCopies() {
    setSelected((current) => {
      const next = new Set(current);
      for (const group of groups) for (const entry of group) next.delete(entry.id);
      for (const group of groups)
        for (const entry of group.slice(1)) if (next.size < 200) next.add(entry.id);
      return next;
    });
    setMessage(
      'Extra copies selected, up to 200 items. The oldest modified copy in each group is kept; matching dates use the file path. Review the paths before continuing.',
    );
  }
  async function reveal(path: string) {
    try {
      await api.reveal(path);
    } catch (failure) {
      state.setError(errorMessage(failure));
    }
  }
  return (
    <div className="tool-page tool-duplicates">
      <Heading
        eyebrow="One is often enough"
        title="Duplicates"
        description="Find what you've stashed twice."
      />
      <section className="panel tool-scan-panel">
        <ScanControls state={state} action="Find duplicates" disabled={recycling} />
        <Notice>
          Files are grouped by matching content. Choose copies to recycle and keep at least one file
          in every group. Contents are checked again before removal.
        </Notice>
        {api.mode === 'preview' && (
          <Notice>
            Example files only. Open the desktop app to review and recycle files on your computer.
          </Notice>
        )}
        {message && <Notice>{message}</Notice>}
        {state.result && !state.scanning ? (
          <>
            <div className="tool-results-toolbar">
              <div>
                <strong>{groups.length} groups</strong>
                <span className="muted">
                  {' '}
                  · {formatBytes(extraBytes)} in extra copies{query ? ' matching your filter' : ''}
                </span>
              </div>
              <SearchField
                value={query}
                onChange={setQuery}
                placeholder="Filter duplicate groups"
              />
            </div>
            {groups.length ? (
              <>
                <div className="tool-duplicate-actions">
                  <span className="muted">
                    Keep one copy per group. Nothing is selected automatically.
                  </span>
                  <button
                    className="button tool-small"
                    onClick={selectExtraCopies}
                    disabled={recycling}
                  >
                    Select extra copies
                  </button>
                  <button
                    className="button tool-small"
                    onClick={() => setSelected(new Set())}
                    disabled={recycling || selected.size === 0}
                  >
                    Clear selection
                  </button>
                </div>
                <div className="tool-duplicate-groups">
                  {groups.map((group) => {
                    const remaining = group.filter((entry) => !selected.has(entry.id)).length;
                    return (
                      <article
                        className="tool-duplicate-group"
                        key={group[0].group}
                        aria-label={`Duplicate group: ${group[0].name}`}
                      >
                        <header>
                          <span className="tool-file-icon">
                            <Copy size={18} aria-hidden="true" />
                          </span>
                          <div>
                            <strong>{group[0].name}</strong>
                            <p className="muted">
                              {group.length} identical files · {formatBytes(group[0].bytes)} each
                            </p>
                          </div>
                          <span className="pill">
                            Keeping {remaining} {remaining === 1 ? 'copy' : 'copies'}
                          </span>
                        </header>
                        {group.map((entry) => {
                          const isSelected = selected.has(entry.id);
                          const lastCopy = !isSelected && remaining === 1;
                          return (
                            <div
                              className={`tool-duplicate-file ${isSelected ? 'is-selected' : ''}`}
                              key={entry.id}
                            >
                              <input
                                type="checkbox"
                                checked={isSelected}
                                aria-label={`Select copy ${entry.path}`}
                                onChange={() => toggle(entry, group)}
                                disabled={
                                  recycling || lastCopy || (!isSelected && selected.size >= 200)
                                }
                                title={
                                  lastCopy
                                    ? 'Keep at least one copy. Deselect another copy to change which file is kept.'
                                    : undefined
                                }
                              />
                              <File size={15} aria-hidden="true" />
                              <div className="tool-duplicate-detail">
                                <span className="tool-path" title={entry.path}>
                                  {entry.path}
                                </span>
                                <small className="muted">
                                  Modified {new Date(entry.modified).toLocaleDateString()}
                                  {lastCopy ? ' · Kept copy' : ''}
                                </small>
                              </div>
                              {lastCopy && (
                                <span className="tool-keep-tag">
                                  <ShieldCheck size={12} aria-hidden="true" />
                                  Keep
                                </span>
                              )}
                              <button
                                className="button tool-small"
                                aria-label={`Reveal ${entry.path}`}
                                onClick={() => void reveal(entry.path)}
                              >
                                Reveal
                                <ExternalLink size={13} aria-hidden="true" />
                              </button>
                            </div>
                          );
                        })}
                      </article>
                    );
                  })}
                </div>
              </>
            ) : (
              <div className="empty-state tool-empty">
                <CheckCircle2 size={31} aria-hidden="true" />
                <h3>{query ? 'No matching groups.' : 'No identical copies found.'}</h3>
                <p className="muted">
                  {query
                    ? 'Try a different file name or folder.'
                    : 'The scanned files have room to be themselves.'}
                </p>
              </div>
            )}
            <div className="tool-selection-bar">
              <div>
                <strong>{selected.size} selected</strong>
                <span className="muted"> · {formatBytes(selectedBytes)}</span>
                <p className="muted tool-caption">
                  Keeping {retained} {retained === 1 ? 'file' : 'files'} across {allGroups.length}{' '}
                  {allGroups.length === 1 ? 'group' : 'groups'}
                  {hiddenSelection ? ' · Selection includes hidden groups' : ''}.
                </p>
              </div>
              <div className="tool-recycle-actions">
                {recycling && (
                  <button className="button" onClick={() => void stop()} disabled={stopping}>
                    {stopping ? 'Stopping…' : 'Stop after current item'}
                  </button>
                )}
                <button
                  className="button primary"
                  disabled={selected.size === 0 || recycling || api.mode === 'preview'}
                  onClick={() => void recycle([...selected])}
                >
                  {recycling ? (
                    <LoaderCircle size={16} className="tool-spin" aria-hidden="true" />
                  ) : (
                    <Trash2 size={16} aria-hidden="true" />
                  )}
                  {recycling ? 'Moving to Recycle Bin…' : 'Review & recycle'}
                </button>
              </div>
            </div>
            <p className="muted tool-caption">
              Review up to 200 copies at a time. To change the kept file, deselect another copy
              first. Windows asks for confirmation before removal. Files go to the Recycle Bin; disk
              space is released when you empty it.
            </p>
            <ScanFootnote result={state.result} />
          </>
        ) : (
          !state.scanning && (
            <div className="empty-state tool-empty">
              <Copy size={33} strokeWidth={1.4} aria-hidden="true" />
              <h3>Find the files that echo.</h3>
              <p className="muted">
                Choose a folder to compare file content locally.
                <br />
                Larger collections may take a little longer.
              </p>
            </div>
          )
        )}
      </section>
    </div>
  );
}

function OptimizePage({ api }: ToolProps) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [result, setResult] = useState('');
  async function flush() {
    setBusy(true);
    setError('');
    setResult('');
    try {
      setResult(await api.optimize('flush-dns'));
    } catch (failure) {
      setError(errorMessage(failure));
    } finally {
      setBusy(false);
    }
  }
  return (
    <div className="tool-page tool-optimize">
      <Heading
        eyebrow="Keep things moving"
        title="Optimize"
        description="Small turns, a smoother run."
      />
      <section className="panel tool-optimize-hero">
        <div className="tool-orb tool-orb-violet">
          <Sparkles size={34} strokeWidth={1.4} aria-hidden="true" />
        </div>
        <div>
          <p className="eyebrow">A considered tune-up</p>
          <h2>Give your connection a fresh start.</h2>
          <p className="muted">
            Clear Windows’ cached DNS records when a website address has changed or a connection
            seems stuck.
          </p>
        </div>
      </section>
      <section className="panel tool-operation">
        <div className="tool-operation-heading">
          <div className="tool-file-icon">
            <Wifi size={24} aria-hidden="true" />
          </div>
          <div>
            <h2>Flush DNS cache</h2>
            <p className="muted">A small reset for domain name lookups.</p>
          </div>
          <span className="pill">Available on Windows</span>
        </div>
        <div className="tool-operation-details">
          <div>
            <span className="tool-label">What changes</span>
            <p>
              Cached domain lookups are cleared. Windows fetches fresh records when you next
              connect.
            </p>
          </div>
          <div>
            <span className="tool-label">Before you run</span>
            <p>
              Windows asks for confirmation. Your saved Wi-Fi networks and personal files stay in
              place.
            </p>
          </div>
        </div>
        {error && <Notice error>{error}</Notice>}
        {result && <Notice>{result}</Notice>}
        <div className="tool-operation-footer">
          <span className="muted tool-caption">
            {api.mode === 'preview'
              ? 'Open the Windows desktop build to run this action.'
              : 'Runs locally with your permission.'}
          </span>
          <button
            className="button primary"
            disabled={busy || api.mode === 'preview'}
            onClick={() => void flush()}
          >
            {busy ? (
              <LoaderCircle className="tool-spin" size={16} aria-hidden="true" />
            ) : (
              <Sparkles size={16} aria-hidden="true" />
            )}
            {busy ? 'Refreshing DNS…' : 'Review & flush DNS'}
          </button>
        </div>
      </section>
      <button className="tool-next-link" onClick={() => navigate('connectivity')}>
        <CircleHelp size={17} aria-hidden="true" />
        <span>Still having trouble? Run connectivity diagnostics.</span>
        <ArrowRight size={17} aria-hidden="true" />
      </button>
    </div>
  );
}

function PortsPage({ api }: ToolProps) {
  const [ports, setPorts] = useState<PortInfo[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');
  const [query, setQuery] = useState('');
  const [updated, setUpdated] = useState<number | null>(null);
  async function refresh() {
    setLoading(true);
    setError('');
    try {
      setPorts(await api.getPorts());
      setUpdated(Date.now());
    } catch (failure) {
      setError(errorMessage(failure));
    } finally {
      setLoading(false);
    }
  }
  useEffect(() => {
    void refresh();
  }, [api]);
  const visible = ports
    .filter((port) =>
      `${port.port} ${port.pid} ${port.name} ${port.address} ${port.protocol}`
        .toLowerCase()
        .includes(query.toLowerCase()),
    )
    .sort((a, b) => a.port - b.port);
  return (
    <div className="tool-page tool-ports">
      <Heading
        eyebrow="At the tunnel entrance"
        title="Ports"
        description="See who's listening."
        action={
          <button className="button" onClick={() => void refresh()} disabled={loading}>
            <RefreshCw size={15} className={loading ? 'tool-spin' : ''} aria-hidden="true" />
            Refresh
          </button>
        }
      />
      <section className="panel tool-scan-panel">
        <div className="tool-results-toolbar">
          <div>
            <strong>{ports.length} listening endpoints</strong>
            <p className="tool-caption muted">Local TCP listeners and UDP bindings.</p>
          </div>
          <SearchField
            value={query}
            onChange={setQuery}
            placeholder="Search port, process, or PID"
          />
        </div>
        {error && <Notice error>{error}</Notice>}
        {loading ? (
          <Busy text="Checking local listening ports…" />
        ) : visible.length ? (
          <div className="tool-table-wrap">
            <table className="tool-table">
              <thead>
                <tr>
                  <th>Port</th>
                  <th>Process</th>
                  <th>PID</th>
                  <th>Protocol</th>
                  <th>Address</th>
                </tr>
              </thead>
              <tbody>
                {visible.map((port, index) => (
                  <tr key={`${port.protocol}-${port.address}-${port.port}-${port.pid}-${index}`}>
                    <td>
                      <span className="tool-port-number">
                        <Radio size={14} aria-hidden="true" />
                        {port.port}
                      </span>
                    </td>
                    <td>
                      <strong>{port.name || 'Unknown process'}</strong>
                    </td>
                    <td className="tool-mono muted">{port.pid}</td>
                    <td>
                      <span className="tool-tag">{port.protocol}</span>
                    </td>
                    <td className="tool-mono muted">{port.address}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        ) : (
          <div className="empty-state tool-empty">
            <Network size={31} aria-hidden="true" />
            <h3>{query ? 'No matching listeners.' : 'No listening endpoints reported.'}</h3>
            <p className="muted">
              {query
                ? 'Try a port number or process name.'
                : 'Refresh after starting a local service.'}
            </p>
          </div>
        )}
        <p className="tool-caption muted">
          {updated ? `Updated ${new Date(updated).toLocaleTimeString()}. ` : ''}Read-only
          inspection. Burrow does not stop processes or close ports.
        </p>
      </section>
    </div>
  );
}

function NetworkPage({ api }: ToolProps) {
  const [snapshot, setSnapshot] = useState<Snapshot | null>(null);
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(true);
  const [recent, setRecent] = useState<{ rx: number | null; tx: number | null }[]>([]);
  useEffect(() => {
    let current = true;
    function receive(next: Snapshot) {
      if (!current) return;
      setSnapshot(next);
      setError('');
      setLoading(false);
      const validRx = next.network.filter((item) => item.rx !== null);
      const validTx = next.network.filter((item) => item.tx !== null);
      setRecent((history) => [
        ...history.slice(-29),
        {
          rx: validRx.length ? validRx.reduce((sum, item) => sum + item.rx!, 0) : null,
          tx: validTx.length ? validTx.reduce((sum, item) => sum + item.tx!, 0) : null,
        },
      ]);
    }
    void api
      .getSnapshot()
      .then(receive)
      .catch((failure) => {
        if (current) {
          setError(errorMessage(failure));
          setLoading(false);
        }
      });
    const unsubscribe = api.onSnapshot(receive);
    return () => {
      current = false;
      unsubscribe();
    };
  }, [api]);
  const samples = recent.filter((item) => item.rx !== null || item.tx !== null);
  const last = recent[recent.length - 1];
  const maximum = Math.max(1, ...samples.flatMap((item) => [item.rx || 0, item.tx || 0]));
  const lines = (key: 'rx' | 'tx') => {
    const segments: string[] = [];
    let points: string[] = [];
    for (const [index, item] of recent.entries()) {
      const value = item[key];
      if (value === null) {
        if (points.length) segments.push(points.join(' '));
        points = [];
      } else {
        points.push(
          `${10 + (index / Math.max(1, recent.length - 1)) * 780},${130 - (value / maximum) * 105}`,
        );
      }
    }
    if (points.length) segments.push(points.join(' '));
    return segments;
  };
  return (
    <div className="tool-page tool-network">
      <Heading
        eyebrow="Traffic in the tunnels"
        title="Network"
        description="Watch what travels the tunnels."
        action={
          <span className="pill">
            <span className="tool-live-dot" />
            {api.mode === 'preview' ? 'Preview' : 'Live'}
          </span>
        }
      />
      {error && <Notice error>{error}</Notice>}
      {loading ? (
        <section className="panel">
          <Busy text="Reading network interfaces…" />
        </section>
      ) : (
        <>
          <section className="panel tool-network-overview">
            <div className="tool-network-metrics">
              <div>
                <span>
                  <ArrowDownLeft size={18} aria-hidden="true" />
                  Received
                </span>
                <strong>{last?.rx != null ? `${formatBytes(last.rx)}/s` : '—'}</strong>
                <small className="muted">per second</small>
              </div>
              <div>
                <span>
                  <ArrowUpRight size={18} aria-hidden="true" />
                  Sent
                </span>
                <strong>{last?.tx != null ? `${formatBytes(last.tx)}/s` : '—'}</strong>
                <small className="muted">per second</small>
              </div>
            </div>
            {samples.length > 1 ? (
              <div className="tool-network-chart">
                <svg
                  viewBox="0 0 800 155"
                  role="img"
                  aria-label="Recent received and sent network transfer rates"
                >
                  <path className="tool-chart-grid" d="M10 25H790M10 77H790M10 130H790" />
                  {lines('rx').map((points, index) => (
                    <polyline key={`rx-${index}`} points={points} className="tool-chart-rx" />
                  ))}
                  {lines('tx').map((points, index) => (
                    <polyline key={`tx-${index}`} points={points} className="tool-chart-tx" />
                  ))}
                </svg>
                <div className="tool-chart-labels">
                  <span>Earlier</span>
                  <span>Most recent samples</span>
                  <span>Now</span>
                </div>
              </div>
            ) : (
              <div className="tool-network-wait muted">
                <Radio size={19} aria-hidden="true" />
                <p>
                  {samples.length
                    ? 'Collecting samples for the live chart…'
                    : 'Traffic rates are not available from this network provider.'}
                </p>
              </div>
            )}
          </section>
          <div className="tool-section-heading">
            <div>
              <h2>Network interfaces</h2>
              <p className="muted">Addresses and traffic reported by your system.</p>
            </div>
            <span className="pill">{snapshot?.network.length || 0} interfaces</span>
          </div>
          <div className="tool-interface-grid">
            {snapshot?.network.map((item, index) => (
              <section
                className="panel tool-interface"
                key={`${item.name}-${item.address}-${index}`}
              >
                <header>
                  <span className="tool-file-icon">
                    <Network size={22} aria-hidden="true" />
                  </span>
                  <div>
                    <h3>{item.name}</h3>
                    <p className="tool-mono muted">{item.address || 'No address reported'}</p>
                  </div>
                </header>
                <div className="tool-interface-stats">
                  <div>
                    <span className="tool-label">Received</span>
                    <strong>
                      {item.rx !== null ? `${formatBytes(item.rx)}/s` : 'Unavailable'}
                    </strong>
                  </div>
                  <div>
                    <span className="tool-label">Sent</span>
                    <strong>
                      {item.tx !== null ? `${formatBytes(item.tx)}/s` : 'Unavailable'}
                    </strong>
                  </div>
                </div>
              </section>
            ))}
          </div>
          {!snapshot?.network.length && (
            <div className="panel empty-state tool-empty">
              <Network size={31} aria-hidden="true" />
              <h3>No network interfaces reported.</h3>
              <p className="muted">Connect a network adapter to see its details here.</p>
            </div>
          )}
          <p className="tool-caption muted">
            Transfer rates are reported by the operating system; unavailable values are left blank.{' '}
            {snapshot && `Last sample ${new Date(snapshot.timestamp).toLocaleTimeString()}.`}
          </p>
        </>
      )}
      <button className="tool-next-link" onClick={() => navigate('connectivity')}>
        <Wifi size={17} aria-hidden="true" />
        <span>Having trouble getting online?</span>
        <ArrowRight size={17} aria-hidden="true" />
      </button>
    </div>
  );
}

function ConnectivityPage({ api }: ToolProps) {
  const [running, setRunning] = useState(false);
  const [results, setResults] = useState<Diagnostic[] | null>(null);
  const [error, setError] = useState('');
  async function diagnose() {
    setRunning(true);
    setError('');
    try {
      setResults(await api.diagnose());
    } catch (failure) {
      setError(errorMessage(failure));
    } finally {
      setRunning(false);
    }
  }
  const healthy =
    results && results.length > 0 && results.every((result) => result.status === 'pass');
  return (
    <div className="tool-page tool-connectivity">
      <Heading
        eyebrow="Find a way back"
        title="Get Online"
        description="Find your way back to the surface."
      />
      <section className="panel tool-connectivity-hero">
        <div className="tool-orb tool-orb-cyan">
          <Wifi size={36} strokeWidth={1.4} aria-hidden="true" />
        </div>
        <h2>
          {results
            ? results.length === 0
              ? 'No diagnostic results were reported.'
              : healthy
                ? 'Your network and DNS checks passed.'
                : 'Here’s what your connection tells us.'
            : 'Follow the connection.'}
        </h2>
        <p className="muted">
          Check local addresses, DNS configuration, and a public DNS lookup.
          <br />
          Burrow reports what it finds so you can choose the next step.
        </p>
        <button className="button primary" disabled={running} onClick={() => void diagnose()}>
          {running ? (
            <LoaderCircle size={16} className="tool-spin" aria-hidden="true" />
          ) : (
            <Wifi size={16} aria-hidden="true" />
          )}
          {running ? 'Checking connection…' : results ? 'Run again' : 'Run diagnostics'}
        </button>
      </section>
      {error && <Notice error>{error}</Notice>}
      {running && <Busy text="Checking each part of your connection…" />}
      {results && !running && (
        <section className="panel tool-diagnostics" aria-label="Diagnostic results">
          {results.map((result, index) => (
            <article
              className={`tool-diagnostic tool-diagnostic-${result.status}`}
              key={`${result.name}-${index}`}
            >
              <span className="tool-diagnostic-icon">
                {result.status === 'pass' ? (
                  <Check size={18} aria-hidden="true" />
                ) : result.status === 'fail' ? (
                  <X size={18} aria-hidden="true" />
                ) : (
                  <Info size={18} aria-hidden="true" />
                )}
              </span>
              <div>
                <h3>{result.name}</h3>
                <p className="muted">{result.detail}</p>
              </div>
              <span className="tool-tag">
                {result.status === 'pass'
                  ? 'Passed'
                  : result.status === 'fail'
                    ? 'Failed'
                    : 'Needs attention'}
              </span>
            </article>
          ))}
        </section>
      )}
      <div className="tool-hint-grid">
        <section className="panel tool-hint">
          <Network size={20} aria-hidden="true" />
          <h3>Check your network</h3>
          <p className="muted">Make sure Wi-Fi is connected or your Ethernet cable is seated.</p>
        </section>
        <section className="panel tool-hint">
          <RefreshCw size={20} aria-hidden="true" />
          <h3>Refresh a stale address</h3>
          <p className="muted">
            If DNS is the issue, clearing its cache can prompt a fresh lookup.
          </p>
          <button className="tool-text-button" onClick={() => navigate('optimize')}>
            Open Optimize
            <ArrowRight size={14} aria-hidden="true" />
          </button>
        </section>
      </div>
    </div>
  );
}

function MigrationPage({ route }: { route: 'leftovers' | 'photos' }) {
  const photos = route === 'photos';
  const Icon = photos ? Image : Boxes;
  return (
    <div className={`tool-page ${photos ? 'tool-photos' : 'tool-leftovers'}`}>
      <Heading
        eyebrow={photos ? 'A little less repetition' : 'After the move'}
        title={photos ? 'Similar Photos' : 'Leftovers'}
        description={photos ? 'Spot the shots that echo.' : 'Traces of tenants long gone.'}
      />
      <section className="panel tool-migration">
        <div className={`tool-orb ${photos ? 'tool-orb-rose' : 'tool-orb-olive'}`}>
          <Icon size={35} strokeWidth={1.4} aria-hidden="true" />
        </div>
        <span className="pill">Windows migration in progress</span>
        <h2>{photos ? 'A thoughtful second look.' : 'A careful look at what remains.'}</h2>
        <p className="muted">
          {photos
            ? 'Visual similarity scanning is not available in this build. The Windows photo indexing and comparison engine still needs to be implemented.'
            : 'Leftover app detection is not available in this build. Windows registry and app data checks still need validated ownership rules before files can be safely suggested.'}
        </p>
        <div className="tool-migration-alternative">
          <span className="tool-file-icon">
            {photos ? (
              <Copy size={22} aria-hidden="true" />
            ) : (
              <HardDrive size={22} aria-hidden="true" />
            )}
          </span>
          <div>
            <h3>{photos ? 'Find exact duplicates today' : 'Explore the space yourself'}</h3>
            <p className="muted">
              {photos
                ? 'Compare identical file content and reveal copies for review.'
                : 'Map a folder and open items in Explorer for a closer look.'}
            </p>
          </div>
          <button className="button" onClick={() => navigate(photos ? 'duplicates' : 'analyze')}>
            {photos ? 'Open Duplicates' : 'Open Analyze'}
            <ArrowRight size={15} aria-hidden="true" />
          </button>
        </div>
      </section>
    </div>
  );
}

export function ToolPage({ route, api }: { route: Route; api: BurrowAPI }) {
  switch (route) {
    case 'clean':
      return <CleanPage api={api} />;
    case 'analyze':
      return <AnalyzePage api={api} />;
    case 'duplicates':
      return <DuplicatesPage api={api} />;
    case 'apps':
      return <AppsPage api={api} />;
    case 'optimize':
      return <OptimizePage api={api} />;
    case 'ports':
      return <PortsPage api={api} />;
    case 'network':
      return <NetworkPage api={api} />;
    case 'connectivity':
      return <ConnectivityPage api={api} />;
    case 'leftovers':
      return <LeftoversPage api={api} />;
    case 'photos':
      return <MigrationPage route={route} />;
    default:
      return null;
  }
}
