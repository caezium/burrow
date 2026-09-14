import path from 'node:path';
import type { InstalledApp } from '../../src/shared/contracts';

/** Registry-only data; commands and locations never come from the renderer. */
export interface RegisteredApp extends InstalledApp {
  installLocation: string;
  uninstallString: string;
  windowsInstaller: boolean;
  noRemove: boolean;
  systemComponent: boolean;
  keyName: string;
  scope: 'user' | 'machine';
}
export interface ApplicationPaths {
  windows: string;
  home: string;
  programFiles: string[];
  localPrograms: string;
}
export interface UninstallPlan {
  kind: 'msi' | 'exe';
  target: string;
  args: string[];
  installFolder: string | null;
}
const GUID = /^\{[a-f\d]{8}-[a-f\d]{4}-[a-f\d]{4}-[a-f\d]{4}-[a-f\d]{12}\}$/i;
const BLOCKED_HOST =
  /^(?:cmd|powershell|powershell_ise|pwsh|wscript|cscript|mshta|rundll32|regsvr32|reg|schtasks|control|explorer|msiexec|bash|sh|py|pyw|python[\d.]*|pythonw[\d.]*|node|java|javaw|dotnet|ruby[\d.]*|perl|php|lua[\d.]*|msbuild|installutil|wmic|forfiles|sc|services|taskkill|certutil|bitsadmin|curl|wget|msdt|hh|regasm|regsvcs)\.exe$/i;
const QUIET =
  /^(?:[/-](?:s|silent|verysilent|quiet|q(?:n\+?|b[!+-]*|r)?|passive|suppressmsgboxes)|--(?:silent|quiet|unattended))(?:[=:].*)?$/i;

/** A deliberately strict subset of Windows argv: whole quoted tokens, no quote adjacency. */
export function parseWindowsCommandLine(command: string): string[] {
  if (!command || command.length > 32_768 || /[\0\r\n]/.test(command))
    throw new Error('The registered uninstall command is empty or invalid');
  const args: string[] = [];
  let index = 0;
  while (index < command.length) {
    while (/[ \t]/.test(command[index] ?? '') && index < command.length) index++;
    if (index === command.length) break;
    let token = '';
    if (command[index] === '"') {
      index++;
      let closed = false;
      while (index < command.length) {
        let slashes = 0;
        while (command[index] === '\\') {
          slashes++;
          index++;
        }
        if (command[index] === '"') {
          token += '\\'.repeat(Math.floor(slashes / 2));
          index++;
          if (slashes % 2) token += '"';
          else {
            closed = true;
            break;
          }
        } else {
          token += '\\'.repeat(slashes);
          if (index < command.length) token += command[index++];
        }
      }
      if (!closed || (index < command.length && !/[ \t]/.test(command[index])))
        throw new Error('Ambiguous quoted uninstall commands are not supported');
    } else {
      while (index < command.length && !/[ \t]/.test(command[index])) {
        if (command[index] === '"') throw new Error('Quote adjacency is not supported');
        token += command[index++];
      }
    }
    args.push(token);
    if (args.length > 128) throw new Error('The uninstall command contains too many arguments');
  }
  if (!args.length) throw new Error('No registered uninstaller was found');
  return args;
}

/** Quote argv for ProcessStartInfo.Arguments; this string is never passed to cmd.exe. */
export function quoteWindowsArgument(value: string): string {
  return `"${value.replace(/(\\*)"/g, '$1$1\\"').replace(/(\\+)$/g, '$1$1')}"`;
}

export function localWindowsPath(value: string): string {
  if (
    !/^[a-z]:[\\/]/i.test(value) ||
    value.length > 32_000 ||
    /[\0-\x1f<>"|?*]/.test(value) ||
    value.slice(2).includes(':')
  )
    throw new Error(
      'Only absolute local Windows paths without device or alternate-stream syntax are supported',
    );
  const parts = value.slice(3).split(/[\\/]/);
  if (
    parts.some(
      (part, index) =>
        part === '.' ||
        part === '..' ||
        /[ .]$/.test(part) ||
        (!part && index !== parts.length - 1) ||
        /^(?:con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)/i.test(part),
    )
  )
    throw new Error('Ambiguous Windows paths are not supported');
  return path.win32.normalize(value);
}
export function insideWindows(file: string, root: string): boolean {
  const relative = path.win32.relative(root, file);
  return (
    relative !== '' &&
    relative !== '..' &&
    !relative.startsWith('..\\') &&
    !path.win32.isAbsolute(relative)
  );
}
function samePath(left: string, right: string): boolean {
  return path.win32.relative(left, right) === '';
}
export function approvedInstallFolder(value: string, paths: ApplicationPaths): string {
  const folder = localWindowsPath(value.replace(/[\\/]+$/, ''));
  const roots = [
    path.win32.parse(folder).root,
    paths.home,
    ...paths.programFiles,
    paths.localPrograms,
    path.win32.join(paths.home, 'AppData'),
    path.win32.join(paths.home, 'AppData', 'Local'),
    path.win32.join(paths.home, 'AppData', 'Roaming'),
    path.win32.join(paths.home, 'Downloads'),
    path.win32.join(paths.home, 'Documents'),
    path.win32.join(paths.home, 'Desktop'),
    path.win32.join(path.win32.parse(paths.windows).root, 'Users'),
    path.win32.join(path.win32.parse(paths.windows).root, 'ProgramData'),
  ];
  if (
    roots.some((root) => samePath(folder, root)) ||
    samePath(folder, paths.windows) ||
    insideWindows(folder, paths.windows) ||
    paths.programFiles.some(
      (root) =>
        samePath(folder, path.win32.join(root, 'Common Files')) ||
        insideWindows(folder, path.win32.join(root, 'Common Files')),
    )
  )
    throw new Error(
      'A system, shared, drive, or profile directory cannot authorize an uninstaller',
    );
  return folder;
}

export function planRegisteredUninstall(
  app: RegisteredApp,
  paths: ApplicationPaths,
): UninstallPlan {
  if (app.noRemove || app.systemComponent)
    throw new Error('This registration does not allow removal');
  const argv = parseWindowsCommandLine(app.uninstallString);
  const first = argv[0];
  if (app.windowsInstaller) {
    if (!GUID.test(app.keyName))
      throw new Error('The Windows Installer product code is unavailable');
    const msiexec = path.win32.join(localWindowsPath(paths.windows), 'System32', 'msiexec.exe');
    if (first.toLowerCase() !== 'msiexec.exe' && !samePath(localWindowsPath(first), msiexec))
      throw new Error('The Windows Installer command does not use the system installer');
    const products: string[] = [];
    for (let index = 1; index < argv.length; index++) {
      const action = /^\/(?:x|i)(.*)$/i.exec(argv[index]);
      if (action) products.push(action[1] || argv[++index] || '');
    }
    if (
      products.length !== 1 ||
      !GUID.test(products[0]) ||
      products[0].toLowerCase() !== app.keyName.toLowerCase()
    )
      throw new Error('The registered command and Windows Installer product code do not match');
    return {
      kind: 'msi',
      target: msiexec,
      args: ['/x', app.keyName.toUpperCase(), '/qf', '/norestart'],
      installFolder: null,
    };
  }
  const target = localWindowsPath(first);
  if (!/\.exe$/i.test(target))
    throw new Error(
      'A direct .exe uninstaller is required; unquoted spaced paths are not supported',
    );
  if (BLOCKED_HOST.test(path.win32.basename(target)))
    throw new Error('Command, script, and system hosts are not permitted as uninstallers');
  if (samePath(target, paths.windows) || insideWindows(target, paths.windows))
    throw new Error('System-directory executables are not permitted as app uninstallers');
  if (argv.slice(1).some((arg) => QUIET.test(arg)))
    throw new Error('Silent uninstall commands are not supported; use Windows Installed apps');
  let installFolder: string;
  if (app.installLocation.trim()) {
    installFolder = approvedInstallFolder(app.installLocation.trim(), paths);
  } else {
    installFolder = approvedInstallFolder(path.win32.dirname(target), paths);
    const folderName = path.win32
      .basename(installFolder)
      .toLowerCase()
      .replace(/[^a-z\d]/g, '');
    const appName = app.name.toLowerCase().replace(/[^a-z\d]/g, '');
    if (
      ![...paths.programFiles, paths.localPrograms].some((root) =>
        insideWindows(installFolder, root),
      ) ||
      folderName.length < 3 ||
      !appName.includes(folderName)
    )
      throw new Error(
        'No validated per-app installation folder is registered for this uninstaller',
      );
  }
  if (!insideWindows(target, installFolder))
    throw new Error('The registered uninstaller is outside its app installation folder');
  return { kind: 'exe', target, args: argv.slice(1), installFolder };
}
