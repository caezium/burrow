import { contextBridge, ipcRenderer } from 'electron';
import type { BurrowAPI, ScanProgress, Snapshot } from '../src/shared/contracts';

function subscribe<T>(channel: string, callback: (value: T) => void): () => void {
  if (typeof callback !== 'function') throw new TypeError('A callback is required');
  const listener = (_event: Electron.IpcRendererEvent, value: T) => callback(value);
  ipcRenderer.on(channel, listener);
  return () => ipcRenderer.removeListener(channel, listener);
}
const api: BurrowAPI = {
  mode: 'desktop',
  getSnapshot: () => ipcRenderer.invoke('burrow:snapshot'),
  getHistory: (since) => ipcRenderer.invoke('burrow:history', since),
  getActivity: () => ipcRenderer.invoke('burrow:activity'),
  getSettings: () => ipcRenderer.invoke('burrow:settings'),
  saveSettings: (settings) => ipcRenderer.invoke('burrow:save-settings', settings),
  chooseFolder: () => ipcRenderer.invoke('burrow:choose-folder'),
  scan: (kind, root) => ipcRenderer.invoke('burrow:scan', kind, root),
  cancelScan: () => ipcRenderer.invoke('burrow:cancel-scan'),
  recycle: (scanId, ids) => ipcRenderer.invoke('burrow:recycle', scanId, ids),
  reveal: (file) => ipcRenderer.invoke('burrow:reveal', file),
  getApps: () => ipcRenderer.invoke('burrow:apps'),
  openAppsSettings: () => ipcRenderer.invoke('burrow:apps-settings'),
  getPorts: () => ipcRenderer.invoke('burrow:ports'),
  diagnose: () => ipcRenderer.invoke('burrow:diagnose'),
  optimize: (action) => ipcRenderer.invoke('burrow:optimize', action),
  windowAction: (action) => ipcRenderer.invoke('burrow:window', action),
  onSnapshot: (callback) => subscribe<Snapshot>('burrow:snapshot', callback),
  onScanProgress: (callback) => subscribe<ScanProgress>('burrow:scan-progress', callback),
};
contextBridge.exposeInMainWorld('burrow', Object.freeze(api));
