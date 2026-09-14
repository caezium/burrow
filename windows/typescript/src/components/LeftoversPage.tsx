import { useEffect, useMemo, useRef, useState } from 'react';
import {
  Archive,
  CheckCircle2,
  ExternalLink,
  FolderOpen,
  Info,
  LoaderCircle,
  Search,
  ShieldCheck,
  X,
} from 'lucide-react';
import type { BurrowAPI, LeftoverReport, LeftoverScope, ScanProgress } from '../shared/contracts';
import { errorMessage, formatBytes } from '../lib/format';

export function LeftoversPage({ api }: { api: BurrowAPI }) {
  const [scope, setScope] = useState<LeftoverScope>('local');
  const [report, setReport] = useState<LeftoverReport | null>(null);
  const [scanning, setScanning] = useState(false);
  const [cancelling, setCancelling] = useState(false);
  const [progress, setProgress] = useState<ScanProgress | null>(null);
  const [error, setError] = useState('');
  const [query, setQuery] = useState('');
  const [sort, setSort] = useState('size');
  const active = useRef(false);
  const mounted = useRef(true);

  useEffect(() => {
    mounted.current = true;
    const unsubscribe = api.onScanProgress((next) => {
      if (mounted.current && active.current) setProgress(next);
    });
    return () => {
      mounted.current = false;
      unsubscribe();
    };
  }, [api]);

  async function scan() {
    if (active.current) return;
    active.current = true;
    setScanning(true);
    setCancelling(false);
    setError('');
    setReport(null);
    setProgress(null);
    try {
      const next = await api.scanLeftovers(scope);
      if (mounted.current) setReport(next);
    } catch (failure) {
      if (mounted.current) setError(errorMessage(failure));
    } finally {
      active.current = false;
      if (mounted.current) {
        setScanning(false);
        setCancelling(false);
      }
    }
  }

  async function cancel() {
    setCancelling(true);
    try {
      await api.cancelScan();
    } catch (failure) {
      if (mounted.current) {
        setError(errorMessage(failure));
        setCancelling(false);
      }
    }
  }

  async function reveal(path: string) {
    if (api.mode === 'preview') return;
    try {
      await api.reveal(path);
    } catch (failure) {
      if (mounted.current) setError(errorMessage(failure));
    }
  }

  function chooseScope(next: LeftoverScope) {
    if (active.current || next === scope) return;
    setScope(next);
    setReport(null);
    setError('');
    setQuery('');
  }

  const entries = useMemo(() => {
    const filter = query.trim().toLowerCase();
    return (report?.entries ?? [])
      .filter((entry) =>
        `${entry.name} ${entry.path} ${entry.category} ${entry.evidence.join(' ')}`
          .toLowerCase()
          .includes(filter),
      )
      .sort(
        (a, b) =>
          (sort === 'age' ? a.modified - b.modified : b.bytes - a.bytes) ||
          a.path.localeCompare(b.path),
      );
  }, [report, query, sort]);
  const totalBytes = (report?.entries ?? []).reduce((total, entry) => total + entry.bytes, 0);

  return (
    <div className="tool-page tool-leftovers">
      <header className="page-heading tool-heading">
        <div>
          <p className="eyebrow">After the move</p>
          <h1>Leftovers</h1>
          <p className="muted">A careful look at what remains.</p>
        </div>
        <span className="pill">
          <ShieldCheck size={13} aria-hidden="true" />
          Read-only report
        </span>
      </header>
      <section className="panel tool-scan-panel">
        <div className="tool-section-heading">
          <div>
            <h2>Old folders, a little context.</h2>
            <p className="muted">
              Find cache and log folders unchanged for at least 60 days, with no matching app in
              Windows’ installed desktop-app list.
            </p>
          </div>
        </div>
        <div className="tool-notice" role="note">
          <Info size={16} aria-hidden="true" />
          <div>
            These are possible leftovers. Portable and Microsoft Store apps may be missing from the
            app list, so a finding does not prove an app was uninstalled. Review the evidence and
            folder contents; this report leaves every file in place.
          </div>
        </div>
        <div className="tool-leftover-scopes" role="group" aria-label="AppData location">
          <button
            className={`button ${scope === 'local' ? 'is-active' : ''}`}
            aria-pressed={scope === 'local'}
            disabled={scanning}
            onClick={() => chooseScope('local')}
          >
            Local AppData<span className="muted">Data kept on this PC</span>
          </button>
          <button
            className={`button ${scope === 'roaming' ? 'is-active' : ''}`}
            aria-pressed={scope === 'roaming'}
            disabled={scanning}
            onClick={() => chooseScope('roaming')}
          >
            Roaming AppData<span className="muted">Data in your roaming profile</span>
          </button>
        </div>
        <div className="tool-scan-controls">
          <div className="tool-folder-path">
            <FolderOpen size={19} aria-hidden="true" />
            <div>
              <span className="tool-label">
                Current user · {scope === 'local' ? 'Local' : 'Roaming'} AppData
              </span>
              <span title={report?.root}>
                {report?.root ??
                  `Windows user ${scope === 'local' ? 'Local' : 'Roaming'} AppData folder`}
              </span>
            </div>
          </div>
          <button className="button primary" onClick={() => void scan()} disabled={scanning}>
            <Search size={15} aria-hidden="true" />
            {scanning ? 'Scanning…' : 'Scan leftovers'}
          </button>
        </div>
        {api.mode === 'preview' && (
          <p className="muted tool-caption">
            Example data. Open the desktop app to inspect your own Windows folders.
          </p>
        )}
        {error && (
          <div className="tool-notice tool-error" role="alert">
            <Info size={16} aria-hidden="true" />
            <div>{error}</div>
          </div>
        )}
        {scanning && (
          <div className="tool-scan-progress" role="status">
            <div className="tool-progress-top">
              <LoaderCircle size={17} className="tool-spin" aria-hidden="true" />
              <strong>{cancelling ? 'Stopping the scan' : 'Reading app data'}</strong>
              <span className="muted">
                {progress
                  ? `${progress.scanned.toLocaleString()} items · ${formatBytes(progress.bytes)}`
                  : 'Checking the installed app list…'}
              </span>
              <button
                className="button tool-small"
                onClick={() => void cancel()}
                disabled={cancelling}
              >
                <X size={14} aria-hidden="true" />
                {cancelling ? 'Cancelling…' : 'Cancel scan'}
              </button>
            </div>
            <div className="tool-indeterminate" />
            <p className="tool-path muted">{progress?.path || 'Preparing a read-only scan.'}</p>
          </div>
        )}
        {report && !scanning ? (
          <>
            {(report.cancelled || report.truncated) && (
              <div className="tool-notice" role="status">
                <Info size={16} aria-hidden="true" />
                <div>
                  {report.cancelled
                    ? 'Scan cancelled. This report includes only folders checked before cancellation.'
                    : 'Scan limit reached. This report covers only part of the selected location.'}
                </div>
              </div>
            )}
            <div className="tool-leftover-summary">
              <div>
                <strong>{report.entries.length.toLocaleString()}</strong>
                <span>possible {report.entries.length === 1 ? 'leftover' : 'leftovers'}</span>
              </div>
              <div>
                <strong>{formatBytes(totalBytes)}</strong>
                <span>in reported folders</span>
              </div>
              <div>
                <strong>{report.installedApps.toLocaleString()}</strong>
                <span>desktop apps checked</span>
              </div>
            </div>
            <div className="tool-results-toolbar">
              <label className="tool-search">
                <Search size={16} aria-hidden="true" />
                <span className="tool-sr-only">Filter possible leftovers</span>
                <input
                  type="search"
                  value={query}
                  onChange={(event) => setQuery(event.target.value)}
                  placeholder="Filter possible leftovers"
                />
              </label>
              <label className="tool-leftover-sort">
                <span className="tool-sr-only">Sort possible leftovers</span>
                <select
                  aria-label="Sort possible leftovers"
                  value={sort}
                  onChange={(event) => setSort(event.target.value)}
                >
                  <option value="size">Largest first</option>
                  <option value="age">Oldest first</option>
                </select>
              </label>
            </div>
            {entries.length ? (
              <div className="tool-leftover-candidates">
                {entries.map((entry) => (
                  <article
                    className="tool-leftover-card"
                    key={entry.id}
                    aria-label={`Possible leftover: ${entry.name}`}
                  >
                    <header>
                      <span className="tool-file-icon">
                        <Archive size={20} aria-hidden="true" />
                      </span>
                      <div>
                        <h3>{entry.name}</h3>
                        <p className="tool-path muted" title={entry.path}>
                          {entry.path}
                        </p>
                      </div>
                      <span className="tool-mono">{formatBytes(entry.bytes)}</span>
                    </header>
                    <div className="tool-leftover-meta">
                      <span className="tool-tag">
                        {entry.category === 'cache' ? 'Cache' : 'Logs'}
                      </span>
                      <span className="muted">
                        Last modified {new Date(entry.modified).toLocaleDateString()} ·{' '}
                        {Math.max(
                          0,
                          Math.floor((report.timestamp - entry.modified) / 86_400_000),
                        ).toLocaleString()}{' '}
                        days ago
                      </span>
                    </div>
                    <div className="tool-leftover-evidence">
                      <strong>Why it appears here</strong>
                      <ul>
                        {entry.evidence.map((evidence, index) => (
                          <li key={`${index}-${evidence}`}>{evidence}</li>
                        ))}
                      </ul>
                    </div>
                    <footer>
                      <span className="muted">Possible leftover · ownership not confirmed</span>
                      <button
                        className="button tool-small"
                        aria-label={`Reveal ${entry.path}`}
                        disabled={api.mode === 'preview'}
                        onClick={() => void reveal(entry.path)}
                      >
                        Reveal in Explorer
                        <ExternalLink size={13} aria-hidden="true" />
                      </button>
                    </footer>
                  </article>
                ))}
              </div>
            ) : (
              <div className="empty-state tool-empty">
                <CheckCircle2 size={31} aria-hidden="true" />
                <h3>
                  {query
                    ? 'No matching folders.'
                    : report.cancelled || report.truncated
                      ? 'No candidates in this partial report.'
                      : 'No possible leftovers found.'}
                </h3>
                <p className="muted">
                  {query
                    ? 'Try a different folder name or evidence phrase.'
                    : report.cancelled || report.truncated
                      ? 'Run another scan to inspect more of this location.'
                      : 'No old cache or log folders met the report criteria. Other app data stays outside this report.'}
                </p>
              </div>
            )}
            <div className="tool-scan-footnote">
              <span>
                Scanned {report.scanned.toLocaleString()} items ·{' '}
                {new Date(report.timestamp).toLocaleTimeString([], {
                  hour: '2-digit',
                  minute: '2-digit',
                })}
              </span>
              {report.skipped > 0 && (
                <span>{report.skipped.toLocaleString()} inaccessible or excluded</span>
              )}
              {report.truncated && (
                <span className="tool-warning-text">Scan limit reached · partial report</span>
              )}
              {report.cancelled && (
                <span className="tool-warning-text">Scan cancelled · partial report</span>
              )}
            </div>
          </>
        ) : (
          !scanning &&
          !error && (
            <div className="empty-state tool-empty">
              <div className="tool-orb tool-orb-olive">
                <Archive size={34} strokeWidth={1.4} aria-hidden="true" />
              </div>
              <h3>A few clues from old folders.</h3>
              <p className="muted">
                Choose Local or Roaming AppData to inspect old cache and log folders.
                <br />
                The scan compares folder names with Windows’ installed desktop-app list.
              </p>
            </div>
          )
        )}
      </section>
    </div>
  );
}
