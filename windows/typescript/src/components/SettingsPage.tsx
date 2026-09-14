import { useState } from 'react';
import { Check, Monitor, Moon, Sun, Settings as SettingsIcon } from 'lucide-react';
import type { Settings } from '../shared/contracts';
import { errorMessage } from '../lib/format';
export function SettingsPage({
  settings,
  onSave,
}: {
  settings: Settings;
  onSave: (settings: Settings) => Promise<void>;
}) {
  const [tab, setTab] = useState('General');
  const [error, setError] = useState('');
  const [saving, setSaving] = useState(false);
  const [saved, setSaved] = useState(false);
  const update = async (changes: Partial<Settings>) => {
    setError('');
    setSaving(true);
    setSaved(false);
    try {
      await onSave({ ...settings, ...changes });
      setSaved(true);
    } catch (e) {
      setError(errorMessage(e));
    } finally {
      setSaving(false);
    }
  };
  return (
    <div>
      <div className="home-toolbar">
        <div className="segmented" role="tablist" aria-label="Settings sections">
          {['General', 'Maintenance', 'Advanced'].map((item) => (
            <button
              role="tab"
              key={item}
              aria-selected={tab === item}
              className={tab === item ? 'active' : ''}
              onClick={() => setTab(item)}
            >
              {item}
            </button>
          ))}
        </div>
        <span className="muted">Esc to return</span>
      </div>
      <div className="page-body settings-page">
        <div className="page-heading">
          <div>
            <span className="eyebrow">Make yourself at home</span>
            <h1>Settings</h1>
            <p className="muted">Small preferences, a more familiar den.</p>
          </div>
          <SettingsIcon size={28} />
        </div>
        {error && (
          <p role="alert" className="error-banner">
            {error}
          </p>
        )}
        {tab === 'General' && (
          <>
            <div className="panel settings-group">
              <h2>Appearance</h2>
              <p className="muted">Burrow’s warm palette, day or night.</p>
              <div className="theme-options">
                {[
                  { value: 'system' as const, icon: Monitor, title: 'System' },
                  { value: 'light' as const, icon: Sun, title: 'Light' },
                  { value: 'dark' as const, icon: Moon, title: 'Dark' },
                ].map((theme) => (
                  <button
                    key={theme.value}
                    disabled={saving}
                    className={settings.theme === theme.value ? 'selected' : ''}
                    aria-pressed={settings.theme === theme.value}
                    onClick={() => update({ theme: theme.value })}
                  >
                    <theme.icon size={24} />
                    <span>{theme.title}</span>
                    {settings.theme === theme.value && <Check size={13} />}
                  </button>
                ))}
              </div>
            </div>
            <div className="panel settings-group">
              <div className="setting-row">
                <div>
                  <strong>Keep Burrow in the tray</strong>
                  <p className="muted">Closing the window keeps system history running.</p>
                </div>
                <input
                  type="checkbox"
                  role="switch"
                  aria-label="Keep Burrow in the tray"
                  checked={settings.minimizeToTray}
                  disabled={saving}
                  onChange={(e) => update({ minimizeToTray: e.target.checked })}
                />
              </div>
              <div className="setting-row">
                <div>
                  <strong>Sample interval</strong>
                  <p className="muted">How often to take a system snapshot.</p>
                </div>
                <select
                  aria-label="Sample interval"
                  value={settings.sampleInterval}
                  disabled={saving}
                  onChange={(e) => update({ sampleInterval: Number(e.target.value) })}
                >
                  {[2, 3, 5, 10, 30].map((value) => (
                    <option key={value} value={value}>
                      {value} seconds
                    </option>
                  ))}
                </select>
              </div>
            </div>
          </>
        )}
        {tab === 'Maintenance' && (
          <div className="panel settings-group">
            <h2>Review, then recycle.</h2>
            <p>
              Developer artifacts and old installers require a completed scan, selection, and native
              confirmation. Files move to the Windows Recycle Bin.
            </p>
            <p className="muted">
              System cache cleanup and duplicate removal remain read-only in this version. Moving a
              file to the Recycle Bin does not free disk space until it is emptied.
            </p>
          </div>
        )}
        {tab === 'Advanced' && (
          <>
            <div className="panel settings-group">
              <div className="setting-row">
                <div>
                  <strong>Keep history for</strong>
                  <p className="muted">
                    Older records are pruned automatically. The local store also has a size cap.
                  </p>
                </div>
                <select
                  aria-label="History retention"
                  value={settings.retentionDays}
                  disabled={saving}
                  onChange={(e) => update({ retentionDays: Number(e.target.value) })}
                >
                  {[1, 7, 30, 90].map((days) => (
                    <option key={days} value={days}>
                      {days} days
                    </option>
                  ))}
                </select>
              </div>
            </div>
            <div className="panel settings-group">
              <h2>Local by design</h2>
              <p className="muted">
                Settings, samples, and activity stay in this app’s local data folder. MCP and HTTP
                agent connections have not yet been migrated from the WinUI version.
              </p>
            </div>
          </>
        )}
        {saved && (
          <p className="saved-message" role="status">
            <Check size={14} />
            Preferences saved
          </p>
        )}
        <div className="settings-about">
          <span className="burrow-mark" />
          <strong>burrow</strong>
          <span>TypeScript preview · 0.1.0</span>
          <span>Made for a little more breathing room.</span>
        </div>
      </div>
    </div>
  );
}
