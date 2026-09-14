import { afterEach, describe, expect, it, vi } from 'vitest';
import { execFileSync } from 'node:child_process';
import { mkdir, mkdtemp, realpath, rm, symlink, writeFile } from 'node:fs/promises';
import path from 'node:path';
const execution = vi.hoisted(() => ({ run: vi.fn() }));
vi.mock('node:child_process', async (importOriginal) => {
  const actual = await importOriginal<typeof import('node:child_process')>();
  const { promisify } = await import('node:util');
  return { ...actual, execFile: Object.assign(vi.fn(), { [promisify.custom]: execution.run }) };
});
import {
  ApplicationsService,
  inspectApplicationPath,
  launchWindowsUninstaller,
  UNINSTALL_LAUNCH_SCRIPT,
  type ApplicationIdentity,
} from '../electron/services/applications';
import {
  parseWindowsCommandLine,
  type RegisteredApp,
  type UninstallPlan,
} from '../electron/services/applications-policy';

const paths = {
  windows: 'C:\\Windows',
  home: 'C:\\Users\\Test',
  programFiles: ['C:\\Program Files'],
  localPrograms: 'C:\\Users\\Test\\AppData\\Local\\Programs',
};
const registered: RegisteredApp = {
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
};
function setup() {
  const state = {
    app: { ...registered },
    now: 1000,
    executable: { fingerprint: 'exe-identity', digest: 'original-sha256' },
    directory: { fingerprint: 'directory-identity' },
  };
  const get = vi.fn(async () => [{ ...state.app }]);
  const inspect = vi.fn(async (_file: string, kind: string): Promise<ApplicationIdentity> => ({
    ...(kind === 'directory' ? state.directory : state.executable),
  }));
  const launch = vi.fn(async () => ({
    status: 'launched' as const,
    message: 'Launch requested',
    pid: 42,
  }));
  const service = new ApplicationsService(get, {
    platform: 'win32',
    paths,
    inspect,
    launch,
    now: () => state.now,
  });
  return { state, get, inspect, launch, service };
}
const fixtures: string[] = [];
afterEach(async () => {
  vi.restoreAllMocks();
  execution.run.mockReset();
  await Promise.all(fixtures.splice(0).map((file) => rm(file, { recursive: true, force: true })));
});
describe('registered application review capabilities', () => {
  it('exposes only display data and refuses app IDs not obtained from the listed inventory', async () => {
    const { service, get } = setup();
    await expect(service.details(registered.id)).rejects.toThrow('listed application');
    expect(get).not.toHaveBeenCalled();
    const apps = await service.list();
    expect(apps[0]).not.toHaveProperty('uninstallString');
    expect(apps[0]).not.toHaveProperty('installLocation');
    await expect(service.details('forged-id')).rejects.toThrow('listed application');
    const details = await service.details(registered.id);
    expect(details).toMatchObject({ canReveal: true, uninstall: { available: true, kind: 'exe' } });
    expect(details).not.toHaveProperty('uninstallString');
  });
  it('offers a validated folder but no uninstall action for NoRemove registrations', async () => {
    const { service, state, launch } = setup();
    state.app.noRemove = true;
    await service.list();
    const details = await service.details(registered.id);
    expect(details).toMatchObject({
      canReveal: true,
      reviewId: null,
      uninstall: { available: false },
    });
    expect(await service.installFolder(registered.id)).toBe(registered.installLocation);
    expect(launch).not.toHaveBeenCalled();
  });
  it('re-reads the registration after review and refuses changed commands, scope or metadata', async () => {
    for (const change of [
      { uninstallString: '"C:\\Program Files\\Example\\different.exe"' },
      { scope: 'machine' as const },
      { version: '2' },
      { noRemove: true },
    ]) {
      const { service, state, launch } = setup();
      await service.list();
      const details = await service.details(registered.id);
      Object.assign(state.app, change);
      expect((await service.launchReviewed(details.reviewId!)).status).toBe('failed');
      expect(launch).not.toHaveBeenCalled();
    }
  });
  it('rejects changed content even when an injected metadata fingerprint remains unchanged', async () => {
    const { service, state, launch } = setup();
    await service.list();
    const details = await service.details(registered.id);
    state.executable.digest = 'changed-sha256';
    expect(await service.launchReviewed(details.reviewId!)).toMatchObject({
      status: 'failed',
      message: expect.stringContaining('executable changed'),
    });
    expect(launch).not.toHaveBeenCalled();
  });
  it('rejects a changed installation folder and invalidates tokens on refresh', async () => {
    const { service, state, launch } = setup();
    await service.list();
    const details = await service.details(registered.id);
    state.directory.fingerprint = 'replacement-directory';
    await expect(service.validateReview(details.reviewId!)).rejects.toThrow('folder changed');
    await service.list();
    expect((await service.launchReviewed(details.reviewId!)).status).toBe('failed');
    expect(launch).not.toHaveBeenCalled();
  });
  it('refuses unavailable paths and expired reviews', async () => {
    const { service, state, inspect, launch } = setup();
    await service.list();
    const details = await service.details(registered.id);
    state.now += 11 * 60_000;
    expect((await service.launchReviewed(details.reviewId!)).status).toBe('failed');
    inspect.mockRejectedValue(new Error('Symbolic links are not supported'));
    expect(await service.details(registered.id)).toMatchObject({
      canReveal: false,
      reviewId: null,
      uninstall: { available: false },
    });
    await expect(service.installFolder(registered.id)).rejects.toThrow('Symbolic');
    expect(launch).not.toHaveBeenCalled();
  });
  it('launches once only and reports launching rather than removal', async () => {
    const { service, launch, get } = setup();
    await service.list();
    const details = await service.details(registered.id);
    await service.validateReview(details.reviewId!);
    expect((await service.launchReviewed(details.reviewId!)).status).toBe('launched');
    expect(launch).toHaveBeenCalledWith(
      expect.objectContaining({
        target: 'C:\\Program Files\\Example\\uninstall.exe',
        args: ['/uninstall'],
      }),
    );
    expect(get).toHaveBeenCalledTimes(4);
    expect((await service.launchReviewed(details.reviewId!)).status).toBe('failed');
    expect(launch).toHaveBeenCalledTimes(1);
  });
  it('checks cancellation again after asynchronous validation before any OS dispatch', async () => {
    const { service, inspect, launch } = setup();
    await service.list();
    const details = await service.details(registered.id);
    let stopped = false;
    const normal = inspect.getMockImplementation()!;
    inspect.mockImplementation(async (...args) => {
      const value = await normal(...args);
      stopped = true;
      return value;
    });
    expect((await service.launchReviewed(details.reviewId!, () => stopped)).status).toBe(
      'cancelled',
    );
    expect(launch).not.toHaveBeenCalled();
    expect((await service.launchReviewed(details.reviewId!)).status).toBe('failed');
  });
  it('treats a lost launcher response as unknown and still prevents replay', async () => {
    const { service, launch } = setup();
    await service.list();
    const details = await service.details(registered.id);
    launch.mockRejectedValue(new Error('transport lost after start'));
    expect((await service.launchReviewed(details.reviewId!)).status).toBe('unknown');
    expect((await service.launchReviewed(details.reviewId!)).status).toBe('failed');
    expect(launch).toHaveBeenCalledTimes(1);
  });
});

describe('executable identity without launching anything', () => {
  it('hashes regular files, detects changes, and refuses links or linked ancestors', async () => {
    const root = await mkdtemp(path.join(await realpath(process.cwd()), '.burrow-applications-'));
    fixtures.push(root);
    const directory = path.join(root, 'Example');
    await mkdir(directory);
    const file = path.join(directory, 'uninstall.exe');
    await writeFile(file, 'fixture executable bytes');
    const before = await inspectApplicationPath(file, 'file');
    expect(before.digest).toMatch(/^[a-f0-9]{64}$/);
    await writeFile(file, 'changed fixture contents');
    expect((await inspectApplicationPath(file, 'file')).digest).not.toBe(before.digest);
    await symlink(directory, path.join(root, 'link'), 'junction');
    await expect(
      inspectApplicationPath(path.join(root, 'link', 'uninstall.exe'), 'file'),
    ).rejects.toThrow('Symbolic links');
    await expect(inspectApplicationPath(path.join(root, 'link'), 'directory')).rejects.toThrow(
      'Symbolic links',
    );
    await expect(inspectApplicationPath(file, 'file', () => true)).rejects.toThrow('cancelled');
    await writeFile(file, '');
    await expect(inspectApplicationPath(file, 'file')).rejects.toThrow('empty');
  });
});

describe('Windows graphical launcher receipts', () => {
  const plan: UninstallPlan = {
    kind: 'exe',
    target: 'C:\\Program Files\\Example\\uninstall.exe',
    args: ['/uninstall', 'literal & data'],
    installFolder: registered.installLocation,
  };
  it('passes commands only as encoded data to a static shell-execute helper', async () => {
    execution.run.mockResolvedValue({ stdout: '{"status":"launched","pid":42}' });
    expect(await launchWindowsUninstaller(plan, paths.windows)).toMatchObject({
      status: 'launched',
      pid: 42,
    });
    const [executable, args, options] = execution.run.mock.calls[0];
    expect(executable).toBe('C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe');
    expect(args.at(-1)).toBe(UNINSTALL_LAUNCH_SCRIPT);
    expect(UNINSTALL_LAUNCH_SCRIPT).toContain('$info.UseShellExecute = $true');
    expect(UNINSTALL_LAUNCH_SCRIPT).not.toContain(plan.target);
    expect(UNINSTALL_LAUNCH_SCRIPT).not.toMatch(/Invoke-Expression|cmd\.exe|Verb\s*=\s*['"]runas/i);
    const payload = JSON.parse(
      Buffer.from(options.env.BURROW_UNINSTALL_PAYLOAD, 'base64').toString('utf8'),
    );
    expect(payload.target).toBe(plan.target);
    expect(parseWindowsCommandLine(payload.arguments)).toEqual(plan.args);
    expect(options.timeout).toBe(60_000);
  });
  it('distinguishes UAC cancellation, launch failure, post-start uncertainty and malformed responses', async () => {
    for (const [stdout, expected] of [
      ['{"status":"cancelled"}', 'cancelled'],
      ['{"status":"failed"}', 'failed'],
      ['{"status":"unknown"}', 'unknown'],
      ['not JSON', 'unknown'],
      ['{"status":"launched","pid":-1}', 'unknown'],
    ]) {
      execution.run.mockResolvedValue({ stdout });
      expect((await launchWindowsUninstaller(plan, paths.windows)).status).toBe(expected);
    }
    execution.run.mockRejectedValue(new Error('timeout'));
    expect((await launchWindowsUninstaller(plan, paths.windows)).status).toBe('unknown');
    expect(UNINSTALL_LAUNCH_SCRIPT).toContain('$started = $true');
    expect(UNINSTALL_LAUNCH_SCRIPT).toContain("if ($started) {\n    @{status='unknown'}");
    expect(UNINSTALL_LAUNCH_SCRIPT).toContain('NativeErrorCode -eq 1223');
  });
  it.runIf(process.platform === 'win32')(
    'parses the launcher script in Windows PowerShell without executing it',
    () => {
      const encoded = Buffer.from(UNINSTALL_LAUNCH_SCRIPT).toString('base64');
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
    // Keep the test budget above the child process's 10-second deadline.
    15_000,
  );
});
