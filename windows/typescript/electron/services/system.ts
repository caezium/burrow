import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { Resolver } from 'node:dns/promises';
import { getServers } from 'node:dns';
import os from 'node:os';
import path from 'node:path';
import si from 'systeminformation';
import type { Diagnostic, InstalledApp, PortInfo } from '../../src/shared/contracts';
import type { RegisteredApp } from './applications-policy';

const run = promisify(execFile);
const APPS_SCRIPT = String.raw`
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding = [Console]::OutputEncoding
$paths = @('HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*')
@(Get-ItemProperty -Path $paths -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -and -not $_.SystemComponent } | Select-Object -First 3000 @{n='id';e={$_.PSPath}}, @{n='name';e={$_.DisplayName}}, @{n='version';e={$_.DisplayVersion}}, @{n='publisher';e={$_.Publisher}}, @{n='size';e={[double]$_.EstimatedSize * 1024}}, @{n='installDate';e={$_.InstallDate}}) | ConvertTo-Json -Compress -Depth 3
`;
// Leftover matching must fail if a present registry source is unreadable. Missing
// architecture-specific keys are allowed; installed Store/portable apps remain out of scope.
const STRICT_APPS_SCRIPT = APPS_SCRIPT.replace(
  'Get-ItemProperty -Path $paths -ErrorAction SilentlyContinue',
  String.raw`$paths | ForEach-Object {
    $key = $_.Substring(0, $_.Length - 2)
    if (Test-Path -LiteralPath $key -ErrorAction Stop) {
      Get-ChildItem -LiteralPath $key -ErrorAction Stop | ForEach-Object {
        Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction Stop
      }
    }
  }`,
).replace('Select-Object -First 3000', 'Select-Object -First 3001');

const REGISTRATIONS_SCRIPT = String.raw`
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding = [Console]::OutputEncoding
$keys = @('HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall')
@($keys | ForEach-Object {
  if (Test-Path -LiteralPath $_ -ErrorAction Stop) {
    Get-ChildItem -LiteralPath $_ -ErrorAction Stop | ForEach-Object {
      Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction Stop
    }
  }
} | Where-Object { $_.DisplayName } | Select-Object -First 3001 @{n='id';e={$_.PSPath}}, @{n='name';e={$_.DisplayName}}, @{n='version';e={$_.DisplayVersion}}, @{n='publisher';e={$_.Publisher}}, @{n='size';e={[double]$_.EstimatedSize * 1024}}, @{n='installDate';e={$_.InstallDate}}, @{n='installLocation';e={$_.InstallLocation}}, @{n='uninstallString';e={$_.UninstallString}}, @{n='windowsInstaller';e={[bool]($_.WindowsInstaller -eq 1)}}, @{n='noRemove';e={[bool]($_.NoRemove -eq 1)}}, @{n='systemComponent';e={[bool]($_.SystemComponent -eq 1)}}, @{n='keyName';e={$_.PSChildName}}, @{n='scope';e={if ($_.PSPath -match 'HKEY_CURRENT_USER') {'user'} else {'machine'}}}) | ConvertTo-Json -Compress -Depth 3
`;

export class SystemService {
  private readonly appRequests = new Map<boolean, Promise<InstalledApp[]>>();
  private registrationRequest: Promise<RegisteredApp[]> | undefined;

  /** Strict, fresh registry registrations; never returns QuietUninstallString or shell-expanded paths. */
  getAppRegistrations(): Promise<RegisteredApp[]> {
    if (!this.registrationRequest) {
      this.registrationRequest = this.readAppRegistrations().finally(() => {
        this.registrationRequest = undefined;
      });
    }
    return this.registrationRequest;
  }

  private async readAppRegistrations(): Promise<RegisteredApp[]> {
    requireWindows('Installed-app registrations');
    const powershell = path.join(
      process.env.SystemRoot || 'C:\\Windows',
      'System32',
      'WindowsPowerShell',
      'v1.0',
      'powershell.exe',
    );
    const { stdout } = await run(
      powershell,
      ['-NoLogo', '-NoProfile', '-NonInteractive', '-Command', REGISTRATIONS_SCRIPT],
      { windowsHide: true, timeout: 20_000, maxBuffer: 8 * 1024 ** 2, encoding: 'utf8' },
    );
    const parsed: unknown = stdout.trim() ? JSON.parse(stdout) : [];
    const rows: unknown[] = Array.isArray(parsed) ? parsed : [parsed];
    if (rows.length > 3000)
      throw new Error('Registered-app inventory exceeds the completeness limit');
    const display = (value: unknown) => (typeof value === 'string' ? value.slice(0, 1024) : '');
    const bounded = (value: unknown, limit: number) =>
      value == null
        ? ''
        : typeof value === 'string' && value.length <= limit && !value.includes('\0')
          ? value
          : null;
    return rows
      .map((row): RegisteredApp => {
        if (!row || typeof row !== 'object') throw new Error('Malformed registered-app inventory');
        const value = row as Record<string, unknown>;
        const id = bounded(value.id, 4096);
        if (!id || (value.scope !== 'user' && value.scope !== 'machine'))
          throw new Error('Malformed registration identity');
        const installLocation = bounded(value.installLocation, 32_000);
        const uninstallString = bounded(value.uninstallString, 32_768);
        const keyName = bounded(value.keyName, 255);
        const invalid =
          installLocation === null ||
          uninstallString === null ||
          keyName === null ||
          typeof value.noRemove !== 'boolean' ||
          typeof value.systemComponent !== 'boolean' ||
          typeof value.windowsInstaller !== 'boolean';
        return {
          id,
          name: display(value.name),
          version: display(value.version),
          publisher: display(value.publisher),
          size:
            typeof value.size === 'number' && Number.isFinite(value.size)
              ? Math.max(0, value.size)
              : 0,
          installDate: display(value.installDate),
          scope: value.scope,
          installLocation: installLocation ?? '',
          uninstallString: invalid ? '' : uninstallString,
          keyName: keyName ?? '',
          windowsInstaller: value.windowsInstaller === true,
          noRemove: invalid || value.noRemove === true,
          systemComponent: value.systemComponent === true,
        };
      })
      .filter((app) => app.name)
      .sort((a, b) => a.name.localeCompare(b.name));
  }

  /** Strict inventory refuses unreadable registry sources or capped results for leftover matching. */
  getApps(strict = false): Promise<InstalledApp[]> {
    let pending = this.appRequests.get(strict);
    if (!pending) {
      // Cancelling the UI does not terminate PowerShell; reuse that bounded request until it settles.
      pending = this.readApps(strict).finally(() => this.appRequests.delete(strict));
      this.appRequests.set(strict, pending);
    }
    return pending;
  }

  private async readApps(strict: boolean): Promise<InstalledApp[]> {
    requireWindows('Installed-app inventory');
    const powershell = path.join(
      process.env.SystemRoot || 'C:\\Windows',
      'System32',
      'WindowsPowerShell',
      'v1.0',
      'powershell.exe',
    );
    const { stdout } = await run(
      powershell,
      [
        '-NoLogo',
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        strict ? STRICT_APPS_SCRIPT : APPS_SCRIPT,
      ],
      { windowsHide: true, timeout: 20_000, maxBuffer: 4 * 1024 ** 2, encoding: 'utf8' },
    );
    const parsed: unknown = stdout.trim() ? JSON.parse(stdout) : [];
    const rows: unknown[] = Array.isArray(parsed) ? parsed : [parsed];
    if (strict && rows.length > 3000)
      throw new Error(
        'Installed-app inventory exceeds the completeness limit. Leftover detection is unavailable.',
      );
    const text = (value: unknown) => (typeof value === 'string' ? value.slice(0, 1_024) : '');
    const apps = rows
      .filter((row): row is Record<string, unknown> => !!row && typeof row === 'object')
      .map((row) => ({
        id: text(row.id),
        name: text(row.name),
        version: text(row.version),
        publisher: text(row.publisher),
        size: typeof row.size === 'number' && Number.isFinite(row.size) ? Math.max(0, row.size) : 0,
        installDate: text(row.installDate),
      }));
    return apps
      .filter((app) => app.name)
      .sort((a, b) => a.name.localeCompare(b.name))
      .slice(0, 3_000);
  }
  async getPorts(): Promise<PortInfo[]> {
    const connections = await si.networkConnections();
    return connections
      .filter(
        (connection) =>
          connection.state === 'LISTEN' ||
          connection.state === 'LISTENING' ||
          connection.protocol.toLowerCase().startsWith('udp'),
      )
      .map((connection) => ({
        port: Number(connection.localPort),
        address: connection.localAddress,
        pid: Number(connection.pid) || 0,
        name: connection.process || 'Unavailable',
        protocol: connection.protocol.toUpperCase(),
      }))
      .filter(
        (connection) =>
          Number.isInteger(connection.port) && connection.port > 0 && connection.port <= 65535,
      )
      .sort((a, b) => a.port - b.port)
      .slice(0, 2_000);
  }
  async diagnose(): Promise<Diagnostic[]> {
    const connected = Object.values(os.networkInterfaces())
      .flat()
      .filter((iface) => iface && !iface.internal);
    const results: Diagnostic[] = [
      {
        name: 'Network interface',
        status: connected.length ? 'pass' : 'fail',
        detail: connected.length
          ? `${connected.length} active local address${connected.length === 1 ? '' : 'es'}.`
          : 'No non-loopback network address is available.',
      },
    ];
    const servers = getServers();
    results.push({
      name: 'DNS configuration',
      status: servers.length ? 'pass' : 'warning',
      detail: servers.length ? servers.join(', ') : 'No DNS servers were reported.',
    });
    const resolver = new Resolver({ timeout: 3_000, tries: 1 });
    try {
      const addresses = await resolver.resolve4('example.com');
      results.push({
        name: 'Public DNS lookup',
        status: addresses.length ? 'pass' : 'warning',
        detail: addresses.length
          ? 'Resolved example.com successfully.'
          : 'The DNS query returned no IPv4 addresses.',
      });
    } catch {
      results.push({
        name: 'Public DNS lookup',
        status: 'fail',
        detail:
          'Could not resolve example.com. Check DNS settings, your network connection, or VPN.',
      });
    }
    return results;
  }
  async optimize(action: 'flush-dns'): Promise<string> {
    if (action !== 'flush-dns') throw new Error('Unsupported optimization action');
    requireWindows('DNS cache flush');
    const ipconfig = path.join(process.env.SystemRoot || 'C:\\Windows', 'System32', 'ipconfig.exe');
    const { stdout } = await run(ipconfig, ['/flushdns'], {
      windowsHide: true,
      timeout: 15_000,
      maxBuffer: 64 * 1024,
      encoding: 'utf8',
    });
    return stdout.trim() || 'Windows reported that the DNS cache was flushed.';
  }
}
function requireWindows(feature: string): void {
  if (process.platform !== 'win32')
    throw new Error(`${feature} is available when running Burrow on Windows.`);
}
