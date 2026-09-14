import { useEffect, useMemo, useRef, useState, type ReactNode } from 'react';
import {
  ExternalLink,
  FolderOpen,
  Info,
  LoaderCircle,
  Package,
  RefreshCw,
  Search,
  ShieldCheck,
  Trash2,
  X,
} from 'lucide-react';
import type { AppDetails, AppUninstallResult, BurrowAPI, InstalledApp } from '../shared/contracts';
import { errorMessage, formatBytes } from '../lib/format';

function Notice({ children, error = false }: { children: ReactNode; error?: boolean }) {
  return (
    <div className={`tool-notice ${error ? 'tool-error' : ''}`} role={error ? 'alert' : 'status'}>
      <Info size={16} aria-hidden="true" />
      <div>{children}</div>
    </div>
  );
}

function installedDate(value: string) {
  return /^\d{8}$/.test(value)
    ? `${value.slice(0, 4)}-${value.slice(4, 6)}-${value.slice(6)}`
    : value || 'Not reported';
}

export function AppsPage({ api }: { api: BurrowAPI }) {
  const [apps, setApps] = useState<InstalledApp[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');
  const [query, setQuery] = useState('');
  const [sort, setSort] = useState('name');
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [details, setDetails] = useState<AppDetails | null>(null);
  const [detailsLoading, setDetailsLoading] = useState(false);
  const [detailsError, setDetailsError] = useState('');
  const [launching, setLaunching] = useState(false);
  const [outcome, setOutcome] = useState<AppUninstallResult | null>(null);
  const [focusRequest, setFocusRequest] = useState(0);
  const mounted = useRef(true);
  const inventoryRequest = useRef(0);
  const detailRequest = useRef(0);
  const launchActive = useRef(false);
  const detailsPane = useRef<HTMLElement | null>(null);
  const appButtons = useRef(new Map<string, HTMLButtonElement>());

  async function refresh() {
    if (launchActive.current) return;
    const request = ++inventoryRequest.current;
    detailRequest.current++;
    setLoading(true);
    setError('');
    setSelectedId(null);
    setFocusRequest(0);
    setDetails(null);
    setDetailsLoading(false);
    setDetailsError('');
    setOutcome(null);
    try {
      const next = await api.getApps();
      if (mounted.current && request === inventoryRequest.current) setApps(next);
    } catch (failure) {
      if (mounted.current && request === inventoryRequest.current) setError(errorMessage(failure));
    } finally {
      if (mounted.current && request === inventoryRequest.current) setLoading(false);
    }
  }

  useEffect(() => {
    mounted.current = true;
    void refresh();
    return () => {
      mounted.current = false;
      inventoryRequest.current++;
      detailRequest.current++;
    };
  }, [api]);

  useEffect(() => {
    if (selectedId) detailsPane.current?.scrollIntoView({ block: 'nearest' });
  }, [selectedId, detailsLoading]);

  useEffect(() => {
    if (selectedId && focusRequest !== 0 && focusRequest === detailRequest.current)
      detailsPane.current?.focus({ preventScroll: true });
  }, [selectedId, focusRequest]);

  async function loadDetails(appId: string, moveFocus = false) {
    if (launchActive.current) return;
    const request = ++detailRequest.current;
    setFocusRequest(moveFocus ? request : 0);
    setSelectedId(appId);
    setDetails(null);
    setDetailsLoading(true);
    setDetailsError('');
    setOutcome(null);
    try {
      const next = await api.getAppDetails(appId);
      if (next.app.id !== appId)
        throw new Error('This app’s details changed. Refresh the app list and try again.');
      if (mounted.current && request === detailRequest.current) setDetails(next);
    } catch (failure) {
      if (mounted.current && request === detailRequest.current)
        setDetailsError(errorMessage(failure));
    } finally {
      if (mounted.current && request === detailRequest.current) setDetailsLoading(false);
    }
  }

  function closeDetails() {
    if (launchActive.current) return;
    detailRequest.current++;
    if (selectedId) appButtons.current.get(selectedId)?.focus();
    setSelectedId(null);
    setFocusRequest(0);
    setDetails(null);
    setDetailsLoading(false);
    setDetailsError('');
    setOutcome(null);
  }

  async function openSettings() {
    if (api.mode === 'preview') return;
    try {
      await api.openAppsSettings();
    } catch (failure) {
      if (mounted.current) setError(errorMessage(failure));
    }
  }

  async function reveal() {
    if (!details || !details.canReveal || api.mode === 'preview') return;
    const request = detailRequest.current;
    try {
      await api.revealApp(details.app.id);
    } catch (failure) {
      if (mounted.current && request === detailRequest.current)
        setDetailsError(errorMessage(failure));
    }
  }

  async function uninstall() {
    if (
      !details?.reviewId ||
      !details.uninstall.available ||
      launchActive.current ||
      api.mode === 'preview'
    )
      return;
    const reviewId = details.reviewId;
    launchActive.current = true;
    setLaunching(true);
    setDetailsError('');
    setOutcome(null);
    // Every attempt needs a fresh review, including a cancelled or unsuccessful launch.
    setDetails({ ...details, reviewId: null });
    try {
      const next = await api.uninstallApp(reviewId);
      if (mounted.current) setOutcome(next);
    } catch (failure) {
      if (mounted.current)
        setOutcome({
          status: 'unknown',
          message: `${errorMessage(failure)} Check Windows before trying again.`,
        });
    } finally {
      launchActive.current = false;
      if (mounted.current) setLaunching(false);
    }
  }

  const visible = useMemo(
    () =>
      apps
        .filter((app) => `${app.name} ${app.publisher}`.toLowerCase().includes(query.toLowerCase()))
        .sort((a, b) =>
          sort === 'size'
            ? b.size - a.size || a.name.localeCompare(b.name)
            : sort === 'publisher'
              ? a.publisher.localeCompare(b.publisher) || a.name.localeCompare(b.name)
              : a.name.localeCompare(b.name),
        ),
    [apps, query, sort],
  );

  return (
    <div className="tool-page tool-apps">
      <header className="page-heading tool-heading">
        <div>
          <p className="eyebrow">Room for what you use</p>
          <h1>Apps</h1>
          <p className="muted">Shed what you've outgrown.</p>
        </div>
        <button
          className="button"
          aria-label="Refresh apps"
          onClick={() => void refresh()}
          disabled={loading || launching}
        >
          <RefreshCw size={15} className={loading ? 'tool-spin' : ''} aria-hidden="true" />
          Refresh
        </button>
      </header>
      <section className="panel tool-scan-panel">
        <div className="tool-apps-summary">
          <div className="tool-orb tool-orb-coral">
            <Package size={29} strokeWidth={1.5} aria-hidden="true" />
          </div>
          <div>
            <strong>
              {loading ? 'Reading your apps…' : `${apps.length.toLocaleString()} installed apps`}
            </strong>
            <p className="muted">Inspect an app, then start its registered uninstall program.</p>
          </div>
          <button
            className="button primary"
            disabled={api.mode === 'preview' || launching}
            onClick={() => void openSettings()}
          >
            Manage in Windows
            <ExternalLink size={15} aria-hidden="true" />
          </button>
        </div>
        {api.mode === 'preview' && (
          <Notice>
            Example apps and details. Open the Windows desktop app to reveal folders or start an
            uninstall program.
          </Notice>
        )}
        {error && <Notice error>{error}</Notice>}
        <div className="tool-results-toolbar">
          <label className="tool-search">
            <Search size={16} aria-hidden="true" />
            <span className="tool-sr-only">Search apps or publishers</span>
            <input
              type="search"
              value={query}
              onChange={(event) => setQuery(event.target.value)}
              placeholder="Search apps or publishers"
            />
          </label>
          <label className="tool-select">
            <span>Sort by</span>
            <select
              aria-label="Sort apps"
              value={sort}
              onChange={(event) => setSort(event.target.value)}
            >
              <option value="name">Name</option>
              <option value="size">Size</option>
              <option value="publisher">Publisher</option>
            </select>
          </label>
        </div>
        {loading ? (
          <div className="tool-loading" role="status">
            <LoaderCircle className="tool-spin" size={20} aria-hidden="true" />
            <span>Reading installed apps from Windows…</span>
          </div>
        ) : visible.length ? (
          <div className="tool-table-wrap tool-apps-list">
            <table className="tool-table">
              <thead>
                <tr>
                  <th>Application</th>
                  <th>Publisher</th>
                  <th>Version</th>
                  <th className="tool-align-right">Reported size</th>
                </tr>
              </thead>
              <tbody>
                {visible.map((app) => (
                  <tr key={app.id} className={selectedId === app.id ? 'is-selected' : ''}>
                    <td>
                      <button
                        className="tool-file tool-app-select"
                        aria-label={`View details for ${app.name}`}
                        aria-pressed={selectedId === app.id}
                        aria-controls="app-details"
                        ref={(button) => {
                          if (button) appButtons.current.set(app.id, button);
                          else appButtons.current.delete(app.id);
                        }}
                        onClick={(event) => void loadDetails(app.id, event.detail === 0)}
                        disabled={launching}
                      >
                        <span className="tool-app-avatar">
                          {app.name.slice(0, 1).toUpperCase()}
                        </span>
                        <strong>{app.name}</strong>
                      </button>
                    </td>
                    <td className="muted">{app.publisher || '—'}</td>
                    <td className="tool-mono muted">{app.version || '—'}</td>
                    <td className="tool-align-right tool-mono">
                      {app.size > 0 ? formatBytes(app.size) : 'Not reported'}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        ) : (
          !error && (
            <div className="empty-state tool-empty">
              <Package size={31} aria-hidden="true" />
              <h3>{query ? 'No apps match your search.' : 'No applications reported.'}</h3>
              <p className="muted">
                {query
                  ? 'Try an app name or publisher.'
                  : 'Refresh to read the Windows app inventory again.'}
              </p>
            </div>
          )
        )}
        <p className="tool-caption muted">
          Reported sizes and dates come from Windows and may be unavailable. Select an app to review
          its installation details.
        </p>
      </section>
      {selectedId && (
        <section
          className="panel tool-app-details"
          id="app-details"
          aria-label="App details"
          ref={detailsPane}
          tabIndex={-1}
        >
          <header>
            <div>
              <p className="eyebrow">A closer look</p>
              <h2>
                {details?.app.name ||
                  apps.find((app) => app.id === selectedId)?.name ||
                  'App details'}
              </h2>
            </div>
            <div className="tool-app-detail-actions">
              <button
                className="button tool-small"
                onClick={() => void loadDetails(selectedId)}
                disabled={detailsLoading || launching}
              >
                <RefreshCw size={14} aria-hidden="true" />
                Refresh app details
              </button>
              <button
                className="tool-icon-button"
                aria-label="Close app details"
                onClick={closeDetails}
                disabled={launching}
              >
                <X size={17} aria-hidden="true" />
              </button>
            </div>
          </header>
          {detailsLoading && (
            <div className="tool-loading" role="status">
              <LoaderCircle className="tool-spin" size={20} aria-hidden="true" />
              <span>Reading app details…</span>
            </div>
          )}
          {detailsError && <Notice error>{detailsError}</Notice>}
          {details && (
            <>
              <dl className="tool-app-facts">
                <div>
                  <dt>Publisher</dt>
                  <dd>{details.app.publisher || 'Not reported'}</dd>
                </div>
                <div>
                  <dt>Version</dt>
                  <dd>{details.app.version || 'Not reported'}</dd>
                </div>
                <div>
                  <dt>Reported size</dt>
                  <dd>{details.app.size > 0 ? formatBytes(details.app.size) : 'Not reported'}</dd>
                </div>
                <div>
                  <dt>Installed for</dt>
                  <dd>{details.scope === 'user' ? 'Current user' : 'All users'}</dd>
                </div>
                <div>
                  <dt>Reported install date</dt>
                  <dd>{installedDate(details.app.installDate)}</dd>
                </div>
              </dl>
              <div className="tool-app-location">
                <div>
                  <span className="tool-label">Installation folder</span>
                  <p className="tool-path" title={details.installLocation || undefined}>
                    {details.installLocation || 'Not reported'}
                  </p>
                </div>
                <button
                  className="button tool-small"
                  onClick={() => void reveal()}
                  disabled={!details.canReveal || api.mode === 'preview' || launching}
                >
                  <FolderOpen size={15} aria-hidden="true" />
                  Reveal installation folder
                </button>
              </div>
              <div className="tool-app-uninstall">
                <div className="tool-app-uninstall-heading">
                  <ShieldCheck size={21} aria-hidden="true" />
                  <div>
                    <h3>
                      {details.uninstall.available
                        ? 'Start the app’s uninstall program'
                        : 'Manage this app in Windows'}
                    </h3>
                    <p className="muted">{details.uninstall.reason}</p>
                  </div>
                </div>
                {details.uninstall.target && (
                  <div className="tool-app-target">
                    <span className="tool-label">Registered uninstall program</span>
                    <p className="tool-path" title={details.uninstall.target}>
                      {details.uninstall.target}
                    </p>
                  </div>
                )}
                <p className="muted tool-caption">
                  {details.uninstall.available
                    ? 'Review before starting the app’s uninstall program. Follow any Windows or vendor prompts; Windows may request administrator permission.'
                    : 'Open Windows settings to see the removal options available for this app.'}
                </p>
              </div>
              {outcome && (
                <Notice error={outcome.status === 'failed' || outcome.status === 'unknown'}>
                  <strong>
                    {outcome.status === 'launched'
                      ? 'Uninstall program started.'
                      : outcome.status === 'cancelled'
                        ? 'Uninstall review cancelled.'
                        : outcome.status === 'failed'
                          ? 'Uninstall could not start.'
                          : 'Check Windows before trying again.'}
                  </strong>
                  <p className="tool-app-outcome-message">{outcome.message}</p>
                  {(outcome.status === 'launched' || outcome.status === 'unknown') && (
                    <p className="tool-app-outcome-message">
                      This app stays in the list until you refresh the Windows inventory.{' '}
                      {outcome.status === 'unknown'
                        ? 'Check whether its uninstall program is already open before starting another review.'
                        : 'Complete any Windows or vendor prompts before refreshing the app list.'}
                    </p>
                  )}
                </Notice>
              )}
              <footer>
                <span className="muted tool-caption">
                  {launching
                    ? 'Waiting for Windows…'
                    : details.uninstall.available && !details.reviewId
                      ? 'Refresh app details before starting another review.'
                      : details.uninstall.available
                        ? 'Review the app and its registered uninstall program before continuing.'
                        : 'This app’s removal is managed in Windows settings.'}
                </span>
                {details.uninstall.available ? (
                  <button
                    className="button primary"
                    disabled={api.mode === 'preview' || launching || !details.reviewId}
                    onClick={() => void uninstall()}
                  >
                    {launching ? (
                      <LoaderCircle className="tool-spin" size={16} aria-hidden="true" />
                    ) : (
                      <Trash2 size={16} aria-hidden="true" />
                    )}
                    {launching ? 'Opening uninstall program…' : 'Review & uninstall'}
                  </button>
                ) : (
                  <button
                    className="button primary"
                    disabled={api.mode === 'preview' || launching}
                    onClick={() => void openSettings()}
                  >
                    Manage in Windows
                    <ExternalLink size={15} aria-hidden="true" />
                  </button>
                )}
              </footer>
            </>
          )}
        </section>
      )}
    </div>
  );
}
