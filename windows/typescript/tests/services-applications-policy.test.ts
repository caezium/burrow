import { describe, expect, it } from 'vitest';
import {
  approvedInstallFolder,
  localWindowsPath,
  parseWindowsCommandLine,
  planRegisteredUninstall,
  quoteWindowsArgument,
  type ApplicationPaths,
  type RegisteredApp,
} from '../electron/services/applications-policy';

export const paths: ApplicationPaths = {
  windows: 'C:\\Windows',
  home: 'C:\\Users\\Test',
  programFiles: ['C:\\Program Files', 'C:\\Program Files (x86)'],
  localPrograms: 'C:\\Users\\Test\\AppData\\Local\\Programs',
};
export function registration(overrides: Partial<RegisteredApp> = {}): RegisteredApp {
  return {
    id: 'registry:example',
    name: 'Example Editor',
    version: '1',
    publisher: 'Example',
    size: 10,
    installDate: '',
    scope: 'user',
    installLocation: 'C:\\Program Files\\Example',
    uninstallString: '"C:\\Program Files\\Example\\uninstall.exe" /uninstall',
    windowsInstaller: false,
    noRemove: false,
    systemComponent: false,
    keyName: 'Example',
    ...overrides,
  };
}

describe('strict Windows uninstall plans', () => {
  it('preserves literal argv through Windows quoting without shell interpretation', () => {
    const argv = [
      'C:\\Program Files\\Example\\uninstall.exe',
      '',
      '/uninstall',
      'A & B',
      'quote "text"',
      'C:\\directory with spaces\\',
    ];
    expect(parseWindowsCommandLine(argv.map(quoteWindowsArgument).join(' '))).toEqual(argv);
    expect(planRegisteredUninstall(registration(), paths)).toMatchObject({
      kind: 'exe',
      target: argv[0],
      args: ['/uninstall'],
    });
  });
  it.each([
    '"unterminated',
    '"C:\\Apps\\uninstall.exe"/uninstall',
    'C:\\Apps\\un"install.exe',
    '"a""b"',
    '"a" b\ncommand',
  ])('rejects ambiguous or malformed quoting: %s', (command) => {
    expect(() => parseWindowsCommandLine(command)).toThrow();
  });
  it('does not guess the executable from an unquoted path containing spaces', () => {
    expect(() =>
      planRegisteredUninstall(
        registration({ uninstallString: 'C:\\Program Files\\Example\\uninstall.exe /uninstall' }),
        paths,
      ),
    ).toThrow();
  });
  it.each([
    'relative.exe',
    '\\\\server\\share\\uninstall.exe',
    '\\\\?\\C:\\App\\uninstall.exe',
    'C:\\App\\uninstall.exe:stream',
    'C:\\App\\..\\uninstall.exe',
    'C:\\App.\\uninstall.exe',
    'C:\\NUL\\uninstall.exe',
  ])('rejects unsafe Windows path: %s', (target) => {
    expect(() => localWindowsPath(target)).toThrow();
  });
  it.each([
    'cmd.exe',
    'powershell.exe',
    'powershell_ise.exe',
    'pwsh.exe',
    'wscript.exe',
    'rundll32.exe',
    'node.exe',
    'python3.12.exe',
    'py.exe',
    'pyw.exe',
    'msiexec.exe',
  ])('rejects command/script host %s even inside the registered app folder', (exe) => {
    expect(() =>
      planRegisteredUninstall(
        registration({ uninstallString: `"C:\\Program Files\\Example\\${exe}" /uninstall` }),
        paths,
      ),
    ).toThrow('hosts');
  });
  it.each([
    '/S',
    '/silent',
    '/verysilent',
    '/quiet',
    '/q',
    '/qn+',
    '/qb+!',
    '/qb!+',
    '/passive',
    '--unattended',
  ])('rejects known quiet EXE option %s', (flag) => {
    expect(() =>
      planRegisteredUninstall(
        registration({ uninstallString: `"C:\\Program Files\\Example\\uninstall.exe" ${flag}` }),
        paths,
      ),
    ).toThrow('Silent');
  });
  it('rejects external executables and system/shared or root installation locations', () => {
    expect(() =>
      planRegisteredUninstall(registration({ uninstallString: 'C:\\Other\\uninstall.exe' }), paths),
    ).toThrow('outside');
    for (const folder of [
      'C:\\',
      paths.home,
      paths.programFiles[0],
      paths.localPrograms,
      'C:\\Windows\\System32',
      'C:\\Program Files\\Common Files\\Example',
    ])
      expect(() => approvedInstallFolder(folder, paths)).toThrow();
  });
  it('only infers an app-named per-app Program Files or Local Programs folder when location is missing', () => {
    const known = registration({ installLocation: '' });
    expect(planRegisteredUninstall(known, paths).installFolder).toBe('C:\\Program Files\\Example');
    expect(() =>
      planRegisteredUninstall(
        { ...known, uninstallString: 'C:\\Other\\Example\\uninstall.exe' },
        paths,
      ),
    ).toThrow('per-app');
    expect(() =>
      planRegisteredUninstall(
        { ...known, uninstallString: '"C:\\Program Files\\SharedStuff\\uninstall.exe"' },
        paths,
      ),
    ).toThrow('per-app');
  });
  it('honors NoRemove and SystemComponent', () => {
    expect(() => planRegisteredUninstall(registration({ noRemove: true }), paths)).toThrow(
      'does not allow',
    );
    expect(() => planRegisteredUninstall(registration({ systemComponent: true }), paths)).toThrow(
      'does not allow',
    );
  });
  it('rebuilds MSI uninstall with matching product GUID, full UI and no automatic reboot', () => {
    const guid = '{01234567-89AB-CDEF-0123-456789ABCDEF}';
    const app = registration({
      windowsInstaller: true,
      keyName: guid,
      uninstallString: `MsiExec.exe /I${guid} /qn TRANSFORMS=ignored.mst`,
    });
    expect(planRegisteredUninstall(app, paths)).toEqual({
      kind: 'msi',
      target: 'C:\\Windows\\System32\\msiexec.exe',
      args: ['/x', guid, '/qf', '/norestart'],
      installFolder: null,
    });
    expect(() =>
      planRegisteredUninstall({ ...app, keyName: '{FFFFFFFF-89AB-CDEF-0123-456789ABCDEF}' }, paths),
    ).toThrow('do not match');
    expect(() =>
      planRegisteredUninstall(
        { ...app, uninstallString: `C:\\Other\\msiexec.exe /X${guid}` },
        paths,
      ),
    ).toThrow('system installer');
    expect(() =>
      planRegisteredUninstall(
        { ...app, uninstallString: `msiexec.exe /X${guid} /I${guid}` },
        paths,
      ),
    ).toThrow('do not match');
  });
});
