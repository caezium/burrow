import { expect, test, type Page } from '@playwright/test';
import type { BurrowAPI, Snapshot } from '../../src/shared/contracts';

declare global {
  interface Window {
    portsTest: {
      mode: 'timeout' | 'ready';
      port: number;
      requests: number;
      finishStale?: () => void;
    };
  }
}

async function desktop(page: Page, scenario: 'timeout' | 'stale-result' | 'stale-error') {
  await page.addInitScript(
    ({ scenario }) => {
      const snapshot: Snapshot = {
        timestamp: Date.now(),
        hostname: 'TEST-PC',
        platform: 'win32',
        osVersion: 'Windows 11',
        uptime: 100,
        cpu: { usage: 10, cores: 4, model: 'Test CPU' },
        memory: { used: 100, total: 1000, percent: 10 },
        disks: [],
        network: [],
        battery: null,
        processes: [],
        warnings: [],
      };
      const settings = {
        theme: 'dark' as const,
        sampleInterval: 3,
        retentionDays: 30,
        minimizeToTray: true,
      };
      window.portsTest = {
        mode: scenario === 'timeout' ? 'timeout' : 'ready',
        port: 9090,
        requests: 0,
      };
      const unused = async (): Promise<never> => {
        throw new Error('This API is outside the Ports test.');
      };
      const api: BurrowAPI = {
        mode: 'desktop',
        getSnapshot: async () => snapshot,
        getSettings: async () => settings,
        getHistory: async () => [],
        getActivity: async () => [],
        onSnapshot: () => () => {},
        getPorts: async () => {
          const request = ++window.portsTest.requests;
          // The first Strict Mode effect is cleaned up before its replacement resolves.
          if (scenario !== 'timeout' && request === 1) {
            await new Promise<void>((resolve, reject) => {
              window.portsTest.finishStale = () =>
                scenario === 'stale-error' ? reject(new Error('Old lookup timed out.')) : resolve();
            });
            return [
              { port: 8080, address: '127.0.0.1', pid: 80, name: 'outdated.exe', protocol: 'TCP' },
            ];
          }
          if (window.portsTest.mode === 'timeout')
            throw new Error('Reading listening ports timed out.');
          return [
            {
              port: window.portsTest.port,
              address: '127.0.0.1',
              pid: 90,
              name: 'current.exe',
              protocol: 'TCP',
            },
          ];
        },
        saveSettings: unused,
        chooseFolder: unused,
        scan: unused,
        scanLeftovers: unused,
        cancelScan: unused,
        recycle: unused,
        reveal: unused,
        getApps: unused,
        getAppDetails: unused,
        revealApp: unused,
        uninstallApp: unused,
        openAppsSettings: unused,
        diagnose: unused,
        optimize: unused,
        windowAction: async () => {},
        onScanProgress: () => () => {},
      };
      window.burrow = api;
    },
    { scenario },
  );
  await page.goto('/');
  await page.getByRole('navigation').getByRole('button', { name: 'Ports', exact: true }).click();
}

test('Ports timeout does not claim an empty inventory and refresh recovers without stale errors', async ({
  page,
}) => {
  await desktop(page, 'timeout');
  await expect(page.getByRole('alert')).toContainText(
    'Reading listening ports timed out. Refresh to try again.',
  );
  await expect(page.getByText('Endpoint list unavailable', { exact: true })).toBeVisible();
  await expect(page.getByText('0 listening endpoints', { exact: true })).not.toBeVisible();
  await expect(
    page.getByRole('heading', { name: 'No listening endpoints reported.', exact: true }),
  ).not.toBeVisible();
  const refresh = page.getByRole('button', { name: 'Refresh', exact: true });
  await expect(refresh).toBeEnabled();
  await page.evaluate(() => {
    window.portsTest.mode = 'ready';
  });
  await refresh.click();
  await expect(page.getByRole('cell', { name: '9090', exact: true })).toBeVisible();
  await expect(page.getByRole('alert')).not.toBeVisible();
  await page.evaluate(() => {
    window.portsTest.mode = 'timeout';
  });
  await refresh.click();
  await expect(page.getByRole('alert')).toContainText('Reading listening ports timed out.');
  await expect(page.getByRole('cell', { name: '9090', exact: true })).toBeVisible();
  await expect(page.getByText(/Showing the last successful result from/)).toBeVisible();
  await page.evaluate(() => {
    window.portsTest.mode = 'ready';
    window.portsTest.port = 9443;
  });
  await refresh.click();
  await expect(page.getByRole('cell', { name: '9443', exact: true })).toBeVisible();
  await expect(page.getByRole('cell', { name: '9090', exact: true })).not.toBeVisible();
  await expect(page.getByRole('alert')).not.toBeVisible();
});

for (const scenario of ['stale-result', 'stale-error'] as const) {
  test(`${scenario} from a cleaned-up Ports request cannot overwrite the newer result`, async ({
    page,
  }) => {
    await desktop(page, scenario);
    await expect(page.getByRole('cell', { name: '9090', exact: true })).toBeVisible();
    expect(await page.evaluate(() => window.portsTest.requests)).toBeGreaterThanOrEqual(2);
    await page.evaluate(async () => {
      window.portsTest.finishStale!();
      await new Promise(requestAnimationFrame);
    });
    await expect(page.getByRole('cell', { name: '9090', exact: true })).toBeVisible();
    await expect(page.getByRole('cell', { name: '8080', exact: true })).not.toBeVisible();
    await expect(page.getByRole('alert')).not.toBeVisible();
    await expect(page.getByRole('button', { name: 'Refresh', exact: true })).toBeEnabled();
  });
}
