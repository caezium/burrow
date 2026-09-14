import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { createHash, randomUUID } from 'node:crypto';
import { constants, type Stats } from 'node:fs';
import { lstat, open, realpath } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import type { AppDetails, AppUninstallResult, InstalledApp } from '../../src/shared/contracts';
import {
  approvedInstallFolder,
  planRegisteredUninstall,
  quoteWindowsArgument,
  type ApplicationPaths,
  type RegisteredApp,
  type UninstallPlan,
} from './applications-policy';
export type { RegisteredApp } from './applications-policy';

const run = promisify(execFile);
const REVIEW_LIFETIME_MS = 10 * 60_000;
const MAX_EXECUTABLE_BYTES = 128 * 1024 ** 2;
export interface ApplicationIdentity {
  fingerprint: string;
  digest?: string;
}
type Inspect = (
  file: string,
  kind: 'file' | 'directory' | 'executable-metadata',
  shouldStop?: () => boolean,
) => Promise<ApplicationIdentity>;
type Review = {
  registration: string;
  appId: string;
  details: AppDetails;
  plan: UninstallPlan;
  executable: ApplicationIdentity;
  directory: ApplicationIdentity | null;
  expires: number;
};
export interface ApplicationsOptions {
  platform?: NodeJS.Platform;
  paths?: ApplicationPaths;
  inspect?: Inspect;
  launch?: (plan: UninstallPlan) => Promise<AppUninstallResult>;
  now?: () => number;
}

/** Reviews are capabilities for one registered uninstaller, not renderer-supplied commands. */
export class ApplicationsService {
  private readonly platform: NodeJS.Platform;
  private readonly paths: ApplicationPaths;
  private readonly inspect: Inspect;
  private readonly launch: (plan: UninstallPlan) => Promise<AppUninstallResult>;
  private readonly now: () => number;
  private readonly listed = new Set<string>();
  private readonly reviews = new Map<string, Review>();

  constructor(
    private readonly getRegistrations: () => Promise<RegisteredApp[]>,
    options: ApplicationsOptions = {},
  ) {
    this.platform = options.platform ?? process.platform;
    this.paths = options.paths ?? {
      windows: process.env.SystemRoot || 'C:\\Windows',
      home: os.homedir(),
      programFiles: [
        ...new Set([
          process.env.ProgramFiles || 'C:\\Program Files',
          process.env['ProgramFiles(x86)'] || 'C:\\Program Files (x86)',
        ]),
      ],
      localPrograms: path.win32.join(os.homedir(), 'AppData', 'Local', 'Programs'),
    };
    this.inspect = options.inspect ?? inspectApplicationPath;
    this.launch = options.launch ?? ((plan) => launchWindowsUninstaller(plan, this.paths.windows));
    this.now = options.now ?? Date.now;
  }

  async list(): Promise<InstalledApp[]> {
    this.requireWindows();
    this.listed.clear();
    this.reviews.clear();
    const registrations = await this.getRegistrations();
    const apps = registrations.filter((app) => app.name && !app.systemComponent).map(publicApp);
    for (const app of apps) this.listed.add(app.id);
    return apps.sort((a, b) => a.name.localeCompare(b.name));
  }

  async details(appId: string): Promise<AppDetails> {
    const app = await this.registration(appId);
    let installLocation: string | null = null;
    if (app.installLocation.trim()) {
      try {
        installLocation = approvedInstallFolder(app.installLocation.trim(), this.paths);
        await this.inspect(installLocation, 'directory');
      } catch {
        installLocation = null;
      }
    }
    const details: AppDetails = {
      app: publicApp(app),
      scope: app.scope,
      installLocation,
      canReveal: !!installLocation,
      reviewId: null,
      uninstall: { available: false, kind: null, target: null, reason: '' },
    };
    try {
      const plan = planRegisteredUninstall(app, this.paths);
      const directory = plan.installFolder
        ? await this.inspect(plan.installFolder, 'directory')
        : null;
      const executable = await this.inspect(plan.target, 'file');
      const id = randomUUID();
      if (plan.installFolder) {
        details.installLocation = plan.installFolder;
        details.canReveal = true;
      }
      details.reviewId = id;
      details.uninstall = {
        available: true,
        kind: plan.kind,
        target: plan.target,
        reason:
          'Opens the registered uninstaller. Windows may request administrator approval; launching does not confirm removal.',
      };
      for (const [key, review] of this.reviews)
        if (review.expires <= this.now()) this.reviews.delete(key);
      while (this.reviews.size >= 200) this.reviews.delete(this.reviews.keys().next().value!);
      this.reviews.set(id, {
        appId,
        registration: registrationFingerprint(app),
        details: structuredClone(details),
        plan,
        directory,
        executable,
        expires: this.now() + REVIEW_LIFETIME_MS,
      });
    } catch (error) {
      details.uninstall.reason =
        error instanceof Error ? error.message : 'The registered uninstaller could not be verified';
    }
    return details;
  }

  /** Refresh registry metadata and executable identity immediately before native confirmation. */
  async validateReview(reviewId: string): Promise<AppDetails> {
    const review = this.review(reviewId);
    await this.revalidate(review);
    return structuredClone(review.details);
  }

  /** Consume once, revalidate after confirmation, then request launch; never reports an app removed. */
  async launchReviewed(
    reviewId: string,
    shouldStop: () => boolean = () => false,
  ): Promise<AppUninstallResult> {
    let dispatched = false;
    try {
      const review = this.review(reviewId);
      this.reviews.delete(reviewId);
      if (shouldStop()) return cancelled();
      await this.revalidate(review, shouldStop);
      if (shouldStop()) return cancelled();
      dispatched = true;
      return await this.launch(structuredClone(review.plan));
    } catch (error) {
      if (!dispatched && shouldStop()) return cancelled();
      return {
        status: dispatched ? 'unknown' : 'failed',
        message: dispatched
          ? 'Windows may have opened the uninstaller. Check for its window before trying again.'
          : error instanceof Error
            ? error.message
            : 'The uninstaller could not be verified and was not launched.',
      };
    }
  }

  async installFolder(appId: string): Promise<string> {
    const app = await this.registration(appId);
    const folder = app.installLocation.trim()
      ? approvedInstallFolder(app.installLocation.trim(), this.paths)
      : planRegisteredUninstall(app, this.paths).installFolder;
    if (!folder) throw new Error('No verified installation folder is registered for this app');
    await this.inspect(folder, 'directory');
    return folder;
  }

  private requireWindows(): void {
    if (this.platform !== 'win32')
      throw new Error('Registered application management is available on Windows');
  }
  private async registration(appId: string): Promise<RegisteredApp> {
    this.requireWindows();
    if (typeof appId !== 'string' || !this.listed.has(appId))
      throw new Error('Refresh Installed apps and select a listed application');
    const matches = (await this.getRegistrations()).filter((app) => app.id === appId);
    if (matches.length !== 1 || matches[0].systemComponent)
      throw new Error(
        'This app registration changed or is no longer available. Refresh Installed apps.',
      );
    return matches[0];
  }
  private review(reviewId: string): Review {
    this.requireWindows();
    const review = this.reviews.get(reviewId);
    if (!review || review.expires <= this.now()) {
      this.reviews.delete(reviewId);
      throw new Error('The uninstall review expired or was already used. Review the app again.');
    }
    return review;
  }
  private async revalidate(review: Review, shouldStop: () => boolean = () => false): Promise<void> {
    const app = await this.registration(review.appId);
    if (this.now() >= review.expires || registrationFingerprint(app) !== review.registration)
      throw new Error('The app registration changed after review. Review the app again.');
    const plan = planRegisteredUninstall(app, this.paths);
    if (JSON.stringify(plan) !== JSON.stringify(review.plan))
      throw new Error('The uninstall plan changed after review');
    if (plan.installFolder) {
      const directory = await this.inspect(plan.installFolder, 'directory', shouldStop);
      if (!sameIdentity(directory, review.directory))
        throw new Error('The installation folder changed after review');
    }
    const executable = await this.inspect(plan.target, 'file', shouldStop);
    if (!sameIdentity(executable, review.executable))
      throw new Error('The uninstaller executable changed after review');
    // Hashing may take time. Check directory ancestry/identity once more before dispatch.
    if (
      plan.installFolder &&
      !sameIdentity(
        await this.inspect(plan.installFolder, 'directory', shouldStop),
        review.directory,
      )
    )
      throw new Error('The installation folder changed during verification');
    if (
      (await this.inspect(plan.target, 'executable-metadata', shouldStop)).fingerprint !==
      review.executable.fingerprint
    )
      throw new Error('The uninstaller changed immediately before launch');
    if (this.now() >= review.expires)
      throw new Error('The uninstall review expired during verification');
  }
}

function publicApp(app: RegisteredApp): InstalledApp {
  return {
    id: app.id,
    name: app.name,
    version: app.version,
    publisher: app.publisher,
    size: app.size,
    installDate: app.installDate,
  };
}
function registrationFingerprint(app: RegisteredApp): string {
  return createHash('sha256')
    .update(
      JSON.stringify([
        publicApp(app),
        app.installLocation,
        app.uninstallString,
        app.windowsInstaller,
        app.noRemove,
        app.systemComponent,
        app.keyName,
        app.scope,
      ]),
    )
    .digest('hex');
}
function sameIdentity(left: ApplicationIdentity, right: ApplicationIdentity | null): boolean {
  return !!right && left.fingerprint === right.fingerprint && left.digest === right.digest;
}
function cancelled(): AppUninstallResult {
  return { status: 'cancelled', message: 'Uninstall launch was cancelled.' };
}
function fingerprint(stat: Stats): string {
  return [
    stat.dev,
    stat.ino,
    stat.mode,
    stat.size,
    stat.mtimeMs,
    stat.ctimeMs,
    stat.birthtimeMs,
  ].join(':');
}
async function assertNoLinks(file: string): Promise<void> {
  let cursor = path.resolve(file);
  while (true) {
    if ((await lstat(cursor)).isSymbolicLink())
      throw new Error('Symbolic links and junctions are not supported for app management');
    const parent = path.dirname(cursor);
    if (parent === cursor) return;
    cursor = parent;
  }
}

/** Bounded SHA-256 of the executable plus canonical-path and all-ancestor link checks. */
export async function inspectApplicationPath(
  file: string,
  kind: 'file' | 'directory' | 'executable-metadata',
  shouldStop: () => boolean = () => false,
): Promise<ApplicationIdentity> {
  const check = () => {
    if (shouldStop()) throw new Error('Uninstall verification was cancelled');
  };
  check();
  await assertNoLinks(file);
  if (path.relative(path.resolve(file), await realpath(file)) !== '')
    throw new Error('An installation path resolves outside its registered location');
  const before = await lstat(file);
  if (before.isSymbolicLink() || (kind === 'directory' ? !before.isDirectory() : !before.isFile()))
    throw new Error('The registered installation path has an unsupported file type');
  if (kind === 'directory' || kind === 'executable-metadata') {
    check();
    return { fingerprint: fingerprint(before) };
  }
  if (!before.size || before.size > MAX_EXECUTABLE_BYTES)
    throw new Error('The uninstaller is empty or exceeds the verification size limit');
  const handle = await open(file, constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0));
  const started = Date.now();
  try {
    if (fingerprint(await handle.stat()) !== fingerprint(before))
      throw new Error('The uninstaller changed before verification');
    const hash = createHash('sha256');
    const buffer = Buffer.allocUnsafe(1024 * 1024);
    let position = 0;
    while (position < before.size) {
      check();
      if (Date.now() - started > 10_000)
        throw new Error('Uninstaller verification exceeded its time limit');
      const { bytesRead } = await handle.read(
        buffer,
        0,
        Math.min(buffer.length, before.size - position),
        position,
      );
      if (!bytesRead) throw new Error('The uninstaller changed while being verified');
      hash.update(buffer.subarray(0, bytesRead));
      position += bytesRead;
    }
    await assertNoLinks(file);
    if (
      fingerprint(await handle.stat()) !== fingerprint(before) ||
      fingerprint(await lstat(file)) !== fingerprint(before)
    )
      throw new Error('The uninstaller changed while being verified');
    check();
    return { fingerprint: fingerprint(before), digest: hash.digest('hex') };
  } finally {
    await handle.close();
  }
}

export const UNINSTALL_LAUNCH_SCRIPT = String.raw`
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding = [Console]::OutputEncoding
$started = $false
try {
  $data = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($env:BURROW_UNINSTALL_PAYLOAD)) | ConvertFrom-Json
  Remove-Item Env:BURROW_UNINSTALL_PAYLOAD -ErrorAction SilentlyContinue
  $info = [Diagnostics.ProcessStartInfo]::new()
  $info.FileName = [string]$data.target
  $info.Arguments = [string]$data.arguments
  $info.WorkingDirectory = [IO.Path]::GetDirectoryName($info.FileName)
  $info.UseShellExecute = $true
  $process = [Diagnostics.Process]::Start($info)
  $started = $true
  $result = @{status='launched'}
  if ($null -ne $process) { $result.pid = $process.Id; $process.Dispose() }
  $result | ConvertTo-Json -Compress
} catch {
  $exception = $_.Exception
  while ($null -ne $exception.InnerException) { $exception = $exception.InnerException }
  if ($started) {
    @{status='unknown'} | ConvertTo-Json -Compress
  } elseif ($exception -is [ComponentModel.Win32Exception] -and $exception.NativeErrorCode -eq 1223) {
    @{status='cancelled'} | ConvertTo-Json -Compress
  } else {
    @{status='failed'} | ConvertTo-Json -Compress
  }
}
`;

/** Use the Windows graphical launcher for normal manifest/UAC behavior, without a command shell. */
export async function launchWindowsUninstaller(
  plan: UninstallPlan,
  windowsDirectory: string,
): Promise<AppUninstallResult> {
  const payload = Buffer.from(
    JSON.stringify({
      target: plan.target,
      arguments: plan.args.map(quoteWindowsArgument).join(' '),
    }),
    'utf8',
  ).toString('base64');
  try {
    const { stdout } = await run(
      path.win32.join(windowsDirectory, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe'),
      ['-NoLogo', '-NoProfile', '-NonInteractive', '-Command', UNINSTALL_LAUNCH_SCRIPT],
      {
        env: { ...process.env, BURROW_UNINSTALL_PAYLOAD: payload },
        windowsHide: true,
        timeout: 60_000,
        maxBuffer: 64 * 1024,
        encoding: 'utf8',
      },
    );
    const result: unknown = JSON.parse(stdout.trim());
    if (!result || typeof result !== 'object') throw new Error('Missing launch receipt');
    const receipt = result as Record<string, unknown>;
    if (receipt.status === 'cancelled')
      return {
        status: 'cancelled',
        message: 'Windows administrator approval was cancelled. The uninstaller was not launched.',
      };
    if (receipt.status === 'failed')
      return { status: 'failed', message: 'Windows could not open the registered uninstaller.' };
    if (
      receipt.status !== 'launched' ||
      (receipt.pid !== undefined &&
        (!Number.isSafeInteger(receipt.pid) || Number(receipt.pid) <= 0))
    )
      throw new Error('Invalid launch receipt');
    return {
      status: 'launched',
      message:
        'Windows accepted the uninstaller launch request. Follow its window; Burrow has not confirmed removal.',
      ...(typeof receipt.pid === 'number' ? { pid: receipt.pid } : {}),
    };
  } catch {
    return {
      status: 'unknown',
      message:
        'The launch receipt was unavailable. Windows may have opened the uninstaller; check for its window before trying again.',
    };
  }
}
