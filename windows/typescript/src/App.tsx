import { useCallback, useEffect, useState, type CSSProperties } from 'react';
import {
  Sparkles,
  WandSparkles,
  Package,
  LayoutGrid,
  Copy,
  HardDrive,
  Images,
  Network,
  ArrowUpDown,
  Wifi,
  Settings as SettingsIcon,
  Minus,
  Square,
  X,
  Monitor,
  CircleHelp,
} from 'lucide-react';
import { api } from './lib/api';
import { errorMessage } from './lib/format';
import { DEFAULT_SETTINGS, type Route, type Settings, type Snapshot } from './shared/contracts';
import { MonitorPage } from './components/MonitorPage';
import { SettingsPage } from './components/SettingsPage';
import { ToolPage } from './components/ToolPages';

const tools = [
  { id: 'clean', name: 'Clean', icon: Sparkles, color: '#35C2A5' },
  { id: 'optimize', name: 'Optimize', icon: WandSparkles, color: '#8E84F0' },
  { id: 'apps', name: 'Apps', icon: Package, color: '#F0714E' },
  { id: 'analyze', name: 'Analyze', icon: LayoutGrid, color: '#4FA3E3' },
  { id: 'duplicates', name: 'Duplicates', icon: Copy, color: '#DB7E9C' },
  { id: 'leftovers', name: 'Leftovers', icon: HardDrive, color: '#B7BE5A' },
  { id: 'photos', name: 'Similar Photos', icon: Images, color: '#D57BC4' },
  { id: 'ports', name: 'Ports', icon: Network, color: '#B58BD6' },
  { id: 'network', name: 'Network', icon: ArrowUpDown, color: '#6E8FE0' },
  { id: 'connectivity', name: 'Get Online', icon: Wifi, color: '#4FC3D9' },
] as const;
const validRoutes: string[] = ['monitor', 'settings', ...tools.map((t) => t.id)];
export default function App() {
  const [route, setRoute] = useState<Route>('monitor');
  const [previous, setPrevious] = useState<Route>('monitor');
  const [visited, setVisited] = useState<Route[]>([]);
  const [settings, setSettings] = useState<Settings>(DEFAULT_SETTINGS);
  const [snapshot, setSnapshot] = useState<Snapshot | null>(null);
  const [error, setError] = useState('');
  const [help, setHelp] = useState(false);
  const navigate = useCallback((next: Route) => {
    setRoute((current) => {
      if (current !== 'settings') setPrevious(current);
      return next;
    });
    if (next !== 'monitor' && next !== 'settings')
      setVisited((all) => (all.includes(next) ? all : [...all, next]));
  }, []);
  useEffect(() => {
    let active = true;
    api
      .getSettings()
      .then((value) => active && setSettings(value))
      .catch((e) => active && setError(errorMessage(e)));
    api
      .getSnapshot()
      .then((value) => active && setSnapshot(value))
      .catch((e) => active && setError(errorMessage(e)));
    const unsubscribe = api.onSnapshot((value) => {
      setSnapshot(value);
      setError('');
    });
    return () => {
      active = false;
      unsubscribe();
    };
  }, []);
  useEffect(() => {
    const media = window.matchMedia('(prefers-color-scheme: dark)');
    const apply = () => {
      document.documentElement.dataset.theme =
        settings.theme === 'system' ? (media.matches ? 'dark' : 'light') : settings.theme;
    };
    apply();
    media.addEventListener('change', apply);
    return () => media.removeEventListener('change', apply);
  }, [settings.theme]);
  useEffect(() => {
    const external = (event: Event) => {
      const next = (event as CustomEvent<string>).detail;
      if (validRoutes.includes(next)) navigate(next as Route);
    };
    const keyboard = (event: KeyboardEvent) => {
      if (event.key === 'Escape') {
        setHelp(false);
        if (route === 'settings') navigate(previous);
      }
      if ((event.ctrlKey || event.metaKey) && event.key === ',') {
        event.preventDefault();
        navigate('settings');
      }
      if ((event.ctrlKey || event.metaKey) && event.key === '1') {
        event.preventDefault();
        navigate('monitor');
      }
    };
    window.addEventListener('burrow:navigate', external);
    window.addEventListener('keydown', keyboard);
    return () => {
      window.removeEventListener('burrow:navigate', external);
      window.removeEventListener('keydown', keyboard);
    };
  }, [route, previous, navigate]);
  const control = (action: 'minimize' | 'maximize' | 'close') =>
    api.windowAction(action).catch((e) => setError(errorMessage(e)));
  return (
    <div className="app-shell">
      <header className="titlebar">
        <span className="titlebar-brand">
          burrow <span className="titlebar-platform">/ windows</span>
        </span>
        <div className="titlebar-right">
          {api.mode === 'preview' && (
            <span className="preview-label">UI preview · example data</span>
          )}
          {api.mode === 'desktop' && (
            <div className="window-controls">
              <button aria-label="Minimize window" onClick={() => control('minimize')}>
                <Minus size={15} />
              </button>
              <button aria-label="Maximize or restore window" onClick={() => control('maximize')}>
                <Square size={12} />
              </button>
              <button
                aria-label="Close window"
                className="close-window"
                onClick={() => control('close')}
              >
                <X size={16} />
              </button>
            </div>
          )}
        </div>
      </header>
      <a className="skip-link" href="#main-content">
        Skip to content
      </a>
      <nav className="floating-rail" aria-label="Main navigation">
        <button
          className={`rail-button brand-button ${route === 'monitor' ? 'selected' : ''}`}
          aria-label="Monitor"
          aria-current={route === 'monitor' ? 'page' : undefined}
          onClick={() => navigate('monitor')}
        >
          <span className="burrow-mark" />
          <span className="rail-tooltip">Monitor</span>
        </button>
        <div className="rail-divider" />
        <div className="rail-tools">
          {tools.map((tool) => (
            <button
              key={tool.id}
              className={`rail-button ${route === tool.id ? 'selected' : ''}`}
              style={{ '--tool-accent': tool.color } as CSSProperties}
              aria-label={tool.name}
              aria-current={route === tool.id ? 'page' : undefined}
              onClick={() => navigate(tool.id)}
            >
              <tool.icon size={19} strokeWidth={1.7} />
              <span className="rail-tooltip">{tool.name}</span>
            </button>
          ))}
        </div>
        <button
          className={`rail-button settings-button ${route === 'settings' ? 'selected' : ''}`}
          aria-label="Settings"
          aria-current={route === 'settings' ? 'page' : undefined}
          onClick={() => navigate('settings')}
        >
          <SettingsIcon size={19} />
          <span className="rail-tooltip">
            Settings <kbd>Ctrl ,</kbd>
          </span>
        </button>
      </nav>
      <main id="main-content" className="main-content" tabIndex={-1}>
        {error && (
          <div className="error-banner" role="alert">
            {error}
            <button aria-label="Dismiss error" onClick={() => setError('')}>
              <X size={16} />
            </button>
          </div>
        )}
        <section hidden={route !== 'monitor'}>
          <MonitorPage snapshot={snapshot} active={route === 'monitor'} navigate={navigate} />
        </section>
        {visited.map((tool) => (
          <section key={tool} hidden={route !== tool}>
            <ToolPage route={tool} api={api} />
          </section>
        ))}
        {route === 'settings' && (
          <SettingsPage
            settings={settings}
            onSave={async (value) => {
              const saved = await api.saveSettings(value);
              setSettings(saved);
            }}
          />
        )}
      </main>
      <footer className="app-status">
        <span>
          <span className="status-dot" />
          {api.mode === 'preview'
            ? 'Design preview'
            : snapshot
              ? `${snapshot.hostname} · Connected`
              : 'Connecting to your system'}
        </span>
        <span>
          Local to your computer{' '}
          <button aria-label="About this preview" onClick={() => setHelp(true)}>
            <CircleHelp size={13} />
          </button>
        </span>
      </footer>
      {help && (
        <div className="modal-backdrop" onClick={() => setHelp(false)}>
          <div
            className="panel about-modal"
            role="dialog"
            aria-modal="true"
            aria-label="About Burrow"
            onKeyDown={(e) => {
              if (e.key === 'Tab') e.preventDefault();
            }}
            onClick={(e) => e.stopPropagation()}
          >
            <Monitor size={28} />
            <h2>Make room for what matters.</h2>
            <p>
              Burrow for Windows brings the macOS interface to a TypeScript desktop app. System data
              and activity stay on your computer.
            </p>
            <p className="muted">
              {api.mode === 'preview'
                ? 'This browser preview uses example data. Launch the desktop app for real metrics and scans.'
                : 'This is the first TypeScript preview. Features awaiting Windows integration are identified in their tool pages.'}
            </p>
            <button className="button primary" autoFocus onClick={() => setHelp(false)}>
              Got it
            </button>
          </div>
        </div>
      )}
    </div>
  );
}
