import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { execFileSync } from 'node:child_process';
import path from 'node:path';

const execution = vi.hoisted(() => ({ run: vi.fn() }));
vi.mock('node:child_process', async (importOriginal) => {
  const actual = await importOriginal<typeof import('node:child_process')>();
  const { promisify } = await import('node:util');
  return { ...actual, execFile: Object.assign(vi.fn(), { [promisify.custom]: execution.run }) };
});
import { SystemService } from '../electron/services/system';

const hostPlatform = process.platform;
const platformDescriptor = Object.getOwnPropertyDescriptor(process, 'platform')!;
const app = {
  id: 'HKCU:Example',
  name: 'Example Editor',
  publisher: 'Example',
  version: '1',
  size: 42,
  installDate: '',
};
beforeEach(() => {
  Object.defineProperty(process, 'platform', { value: 'win32' });
  execution.run.mockReset();
});
afterEach(() => Object.defineProperty(process, 'platform', platformDescriptor));

describe('registry inventory used for leftover evidence', () => {
  it('returns complete desktop inventory and uses strict reads only when requested', async () => {
    execution.run.mockResolvedValue({ stdout: JSON.stringify(app) });
    expect(await new SystemService().getApps(true)).toEqual([app]);
    const script = execution.run.mock.calls[0][1].at(-1) as string;
    expect(script).toContain('Get-ChildItem -LiteralPath $key -ErrorAction Stop');
    expect(script).not.toContain('SilentlyContinue');
    expect(execution.run.mock.calls[0][2]).toMatchObject({
      timeout: 20_000,
      maxBuffer: 4 * 1024 ** 2,
    });
  });

  it('does not replace inaccessible inventory with an empty successful result', async () => {
    execution.run.mockRejectedValue(new Error('Registry access denied'));
    await expect(new SystemService().getApps(true)).rejects.toThrow('Registry access denied');
  });

  it('shares pending registry work across cancelled UI attempts and allows a fresh request after settlement', async () => {
    let complete!: (result: { stdout: string }) => void;
    execution.run.mockImplementationOnce(
      () =>
        new Promise((resolve) => {
          complete = resolve;
        }),
    );
    const service = new SystemService();
    const first = service.getApps(true);
    const second = service.getApps(true);
    expect(second).toBe(first);
    expect(execution.run).toHaveBeenCalledTimes(1);
    complete({ stdout: JSON.stringify(app) });
    expect(await first).toEqual([app]);
    execution.run.mockResolvedValue({ stdout: JSON.stringify(app) });
    await service.getApps(true);
    expect(execution.run).toHaveBeenCalledTimes(2);
  });

  it('rejects capped inventories before they can imply an app is absent', async () => {
    execution.run.mockResolvedValue({
      stdout: JSON.stringify(
        Array.from({ length: 3001 }, (_, index) => ({ ...app, id: String(index) })),
      ),
    });
    await expect(new SystemService().getApps(true)).rejects.toThrow('completeness limit');
    expect(await new SystemService().getApps()).toHaveLength(3000);
  });

  it.runIf(hostPlatform === 'win32')(
    'parses the strict provider script in Windows PowerShell without executing registry reads',
    async () => {
      execution.run.mockResolvedValue({ stdout: JSON.stringify(app) });
      await new SystemService().getApps(true);
      const script = execution.run.mock.calls[0][1].at(-1) as string;
      const encoded = Buffer.from(script).toString('base64');
      const parse = `$tokens=$null; $errors=$null; [System.Management.Automation.Language.Parser]::ParseInput([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('${encoded}')), [ref]$tokens, [ref]$errors) | Out-Null; if ($errors.Count) { throw ($errors | Out-String) }`;
      expect(() =>
        execFileSync(
          path.join(
            process.env.SystemRoot || 'C:\\Windows',
            'System32',
            'WindowsPowerShell',
            'v1.0',
            'powershell.exe',
          ),
          ['-NoLogo', '-NoProfile', '-NonInteractive', '-Command', parse],
          { timeout: 10_000, windowsHide: true },
        ),
      ).not.toThrow();
    },
  );
});

describe('strict registered uninstaller inventory', () => {
  const registration = {
    ...app,
    scope: 'user',
    keyName: 'Example',
    installLocation: 'C:\\Program Files\\Example',
    uninstallString: '"C:\\Program Files\\Example\\uninstall.exe" /uninstall',
    windowsInstaller: false,
    noRemove: false,
    systemComponent: false,
  };
  it('reads commands as registry data with strict bounded discovery and respects NoRemove', async () => {
    execution.run.mockResolvedValue({
      stdout: JSON.stringify({ ...registration, noRemove: true }),
    });
    expect(await new SystemService().getAppRegistrations()).toEqual([
      { ...registration, noRemove: true },
    ]);
    const script = execution.run.mock.calls[0][1].at(-1) as string;
    expect(script).toContain('Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction Stop');
    expect(script).toContain('Select-Object -First 3001');
    expect(script).toContain("@{n='noRemove'");
    expect(script).not.toContain('SilentlyContinue');
    expect(script).not.toContain('QuietUninstallString');
  });
  it('preserves bounded registry identities, commands and locations without display-text truncation', async () => {
    const long = {
      ...registration,
      id: 'key:' + 'x'.repeat(1500),
      installLocation: 'C:\\' + 'a'.repeat(1500),
      uninstallString: '"C:\\Example\\uninstall.exe" "' + 'x'.repeat(1500) + '"',
    };
    execution.run.mockResolvedValue({ stdout: JSON.stringify(long) });
    expect(await new SystemService().getAppRegistrations()).toEqual([long]);
  });
  it('disables oversized or malformed executable metadata instead of truncating it into a valid command', async () => {
    for (const change of [
      { uninstallString: 'x'.repeat(32769) },
      { installLocation: 'x'.repeat(32001) },
      { keyName: 'x'.repeat(256) },
      { uninstallString: ['unexpected array'] },
      { noRemove: 'false' },
    ]) {
      execution.run.mockResolvedValue({ stdout: JSON.stringify({ ...registration, ...change }) });
      expect((await new SystemService().getAppRegistrations())[0]).toMatchObject({
        noRemove: true,
        uninstallString: '',
      });
    }
  });
  it('rejects invalid identities, unreadable sources and capped registration snapshots', async () => {
    execution.run.mockResolvedValue({
      stdout: JSON.stringify({ ...registration, id: 'x'.repeat(4097) }),
    });
    await expect(new SystemService().getAppRegistrations()).rejects.toThrow('identity');
    execution.run.mockRejectedValue(new Error('Registry denied'));
    await expect(new SystemService().getAppRegistrations()).rejects.toThrow('Registry denied');
    execution.run.mockResolvedValue({
      stdout: JSON.stringify(
        Array.from({ length: 3001 }, (_, index) => ({ ...registration, id: String(index) })),
      ),
    });
    await expect(new SystemService().getAppRegistrations()).rejects.toThrow('completeness limit');
  });
  it('shares only an in-flight registration request and re-reads after it settles', async () => {
    let complete!: (result: { stdout: string }) => void;
    execution.run.mockImplementationOnce(
      () =>
        new Promise((resolve) => {
          complete = resolve;
        }),
    );
    const service = new SystemService();
    const first = service.getAppRegistrations();
    expect(service.getAppRegistrations()).toBe(first);
    complete({ stdout: JSON.stringify(registration) });
    await first;
    execution.run.mockResolvedValue({ stdout: JSON.stringify(registration) });
    await service.getAppRegistrations();
    expect(execution.run).toHaveBeenCalledTimes(2);
  });
  it.runIf(hostPlatform === 'win32')(
    'parses the registration provider in Windows PowerShell without reading registry data',
    async () => {
      execution.run.mockResolvedValue({ stdout: JSON.stringify(registration) });
      await new SystemService().getAppRegistrations();
      const script = execution.run.mock.calls[0][1].at(-1) as string;
      const encoded = Buffer.from(script).toString('base64');
      const parse = `$tokens=$null; $errors=$null; [System.Management.Automation.Language.Parser]::ParseInput([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('${encoded}')), [ref]$tokens, [ref]$errors) | Out-Null; if ($errors.Count) { throw ($errors | Out-String) }`;
      expect(() =>
        execFileSync(
          path.join(
            process.env.SystemRoot || 'C:\\Windows',
            'System32',
            'WindowsPowerShell',
            'v1.0',
            'powershell.exe',
          ),
          ['-NoLogo', '-NoProfile', '-NonInteractive', '-Command', parse],
          { timeout: 10_000, windowsHide: true },
        ),
      ).not.toThrow();
    },
  );
});
