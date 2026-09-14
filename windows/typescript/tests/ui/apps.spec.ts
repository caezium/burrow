import { expect, test, type Page } from '@playwright/test';
import type {
  AppUninstallResult,
  BurrowAPI,
  InstalledApp,
  Snapshot,
} from '../../src/shared/contracts';

declare global {
  interface Window {
    appsTest: {
      details: string[];
      uninstall: string[];
      reveals: string[];
      settings: number;
      inventoryReads: number;
      omitAlpha: boolean;
      finishAlpha?: () => void;
      finishLaunch?: () => void;
    };
  }
}

async function openApps(page: Page) {
  await page.getByRole('navigation').getByRole('button', { name: 'Apps', exact: true }).click();
  await expect(page.getByRole('heading', { name: 'Apps', exact: true })).toBeVisible();
}

async function desktop(
  page: Page,
  status: AppUninstallResult['status'] = 'launched',
  race = false,
) {
  await page.addInitScript(
    ({ status, race }) => {
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
      const apps: InstalledApp[] = [
        {
          id: 'alpha',
          name: 'Alpha Studio',
          publisher: 'Alpha Labs',
          version: '2.0',
          size: 512 * 1024 ** 2,
          installDate: '20260203',
        },
        {
          id: 'beta',
          name: 'Beta Player',
          publisher: 'Beta LLC',
          version: '4.0',
          size: 128 * 1024 ** 2,
          installDate: '2026-01-20',
        },
        {
          id: 'unsupported',
          name: 'Legacy Tool',
          publisher: 'Legacy Co',
          version: '1.0',
          size: 0,
          installDate: '',
        },
      ];
      const settings = {
        theme: 'dark' as const,
        sampleInterval: 3,
        retentionDays: 30,
        minimizeToTray: true,
      };
      window.appsTest = {
        details: [],
        uninstall: [],
        reveals: [],
        settings: 0,
        inventoryReads: 0,
        omitAlpha: false,
      };
      const api: BurrowAPI = {
        mode: 'desktop',
        getSnapshot: async () => snapshot,
        getHistory: async () => [],
        getActivity: async () => [],
        getSettings: async () => settings,
        saveSettings: async (next) => next,
        chooseFolder: async () => null,
        scan: async () => {
          throw new Error('Not used.');
        },
        scanLeftovers: async () => {
          throw new Error('Not used.');
        },
        cancelScan: async () => {},
        recycle: async () => {
          throw new Error('Apps must not recycle files.');
        },
        reveal: async () => {
          throw new Error('Apps must reveal by registered app identity.');
        },
        getApps: async () => {
          window.appsTest.inventoryReads++;
          return apps.filter((app) => !window.appsTest.omitAlpha || app.id !== 'alpha');
        },
        getAppDetails: async (appId) => {
          window.appsTest.details.push(appId);
          const revision = window.appsTest.details.length;
          if (race && appId === 'alpha')
            await new Promise<void>((resolve) => {
              window.appsTest.finishAlpha = resolve;
            });
          const app = apps.find((app) => app.id === appId)!;
          const supported = appId !== 'unsupported';
          return {
            app,
            scope: appId === 'alpha' ? 'user' : 'machine',
            installLocation: supported ? `C:\\Program Files\\${app.name}` : null,
            canReveal: supported,
            reviewId: supported ? `${appId}-review-${revision}` : null,
            uninstall: {
              available: supported,
              kind: supported ? 'exe' : null,
              target: supported ? `C:\\Program Files\\${app.name}\\uninstall.exe` : null,
              reason: supported
                ? 'A registered uninstall program is available for review.'
                : 'This app does not provide a supported registered uninstall program. Use Windows settings.',
            },
          };
        },
        revealApp: async (appId) => {
          window.appsTest.reveals.push(appId);
        },
        uninstallApp: async (reviewId) => {
          window.appsTest.uninstall.push(reviewId);
          await new Promise<void>((resolve) => {
            window.appsTest.finishLaunch = resolve;
          });
          return {
            status,
            message:
              status === 'launched'
                ? 'The registered program started. Follow its prompts.'
                : status === 'cancelled'
                  ? 'The review was cancelled.'
                  : status === 'failed'
                    ? 'Windows could not start the registered program.'
                    : 'Windows did not return a confirmed launch result.',
            ...(status === 'launched' ? { pid: 42 } : {}),
          };
        },
        openAppsSettings: async () => {
          window.appsTest.settings++;
        },
        getPorts: async () => [],
        diagnose: async () => [],
        optimize: async () => '',
        windowAction: async () => {},
        onSnapshot: () => () => {},
        onScanProgress: () => () => {},
      };
      window.burrow = api;
    },
    { status, race },
  );
  await page.goto('/');
  await openApps(page);
}

test('preview app details show metadata while native actions remain disabled', async ({ page }) => {
  await page.goto('/');
  await openApps(page);
  await page
    .getByRole('button', { name: 'View details for Visual Studio Code', exact: true })
    .click();
  const details = page.getByRole('region', { name: 'App details', exact: true });
  await expect(
    details.getByRole('heading', { name: 'Visual Studio Code', exact: true }),
  ).toBeVisible();
  await expect(details).toContainText('Current user');
  await expect(details).toContainText('Microsoft');
  await expect(
    details.getByRole('button', { name: 'Reveal installation folder', exact: true }),
  ).toBeDisabled();
  await expect(
    details.getByRole('button', { name: 'Manage in Windows', exact: true }),
  ).toBeDisabled();
  await expect(
    page.getByRole('status').filter({ hasText: 'Example apps and details.' }),
  ).toBeVisible();
  await expect(page.getByRole('checkbox')).toHaveCount(0);
  await page.getByRole('searchbox', { name: 'Search apps or publishers' }).fill('Mozilla');
  await expect(
    page.getByRole('button', { name: 'View details for Mozilla Firefox', exact: true }),
  ).toBeVisible();
  await expect(
    page.getByRole('button', { name: 'View details for Visual Studio Code', exact: true }),
  ).not.toBeVisible();
});

test('a late detail response cannot replace the selected app or its review identity', async ({
  page,
}) => {
  await desktop(page, 'launched', true);
  await page.getByRole('button', { name: 'View details for Alpha Studio', exact: true }).click();
  await expect(page.getByRole('status')).toContainText('Reading app details…');
  await page.getByRole('button', { name: 'View details for Beta Player', exact: true }).click();
  const details = page.getByRole('region', { name: 'App details', exact: true });
  await expect(details.getByRole('heading', { name: 'Beta Player', exact: true })).toBeVisible();
  await page.evaluate(async () => {
    window.appsTest.finishAlpha!();
    await new Promise(requestAnimationFrame);
  });
  await expect(details.getByRole('heading', { name: 'Beta Player', exact: true })).toBeVisible();
  await expect(details).toContainText('C:\\Program Files\\Beta Player\\uninstall.exe');
  await details.getByRole('button', { name: 'Reveal installation folder', exact: true }).click();
  expect(await page.evaluate(() => window.appsTest.reveals)).toEqual(['beta']);
  await details.getByRole('button', { name: 'Review & uninstall', exact: true }).click();
  expect(await page.evaluate(() => window.appsTest.uninstall)).toEqual(['beta-review-2']);
  await page.evaluate(() => window.appsTest.finishLaunch!());
  await expect(details.getByText('Uninstall program started.', { exact: true })).toBeVisible();
});

test('unsupported apps explain the limit and hand off to Windows settings', async ({ page }) => {
  await desktop(page);
  await page.getByRole('button', { name: 'View details for Legacy Tool', exact: true }).click();
  const details = page.getByRole('region', { name: 'App details', exact: true });
  await expect(details).toContainText(
    'This app does not provide a supported registered uninstall program.',
  );
  await expect(
    details.getByRole('button', { name: 'Review & uninstall', exact: true }),
  ).not.toBeVisible();
  await expect(
    details.getByRole('button', { name: 'Reveal installation folder', exact: true }),
  ).toBeDisabled();
  await details.getByRole('button', { name: 'Manage in Windows', exact: true }).click();
  expect(await page.evaluate(() => window.appsTest.settings)).toBe(1);
  expect(await page.evaluate(() => window.appsTest.uninstall)).toEqual([]);
});

test('keyboard selection focuses details and closing restores the row without late-response focus jumps', async ({
  page,
}) => {
  await desktop(page, 'launched', true);
  const details = page.getByRole('region', { name: 'App details', exact: true });
  await page.getByRole('button', { name: 'View details for Alpha Studio', exact: true }).focus();
  await page.keyboard.press('Enter');
  await expect(details).toBeFocused();
  const beta = page.getByRole('button', { name: 'View details for Beta Player', exact: true });
  await beta.focus();
  await page.keyboard.press('Enter');
  await expect(details).toBeFocused();
  await expect(details.getByRole('heading', { name: 'Beta Player', exact: true })).toBeVisible();
  await page.keyboard.press('Tab');
  const refresh = details.getByRole('button', { name: 'Refresh app details', exact: true });
  await expect(refresh).toBeFocused();
  await page.evaluate(async () => {
    window.appsTest.finishAlpha!();
    await new Promise(requestAnimationFrame);
  });
  await expect(refresh).toBeFocused();
  await page.keyboard.press('Tab');
  await expect(
    details.getByRole('button', { name: 'Close app details', exact: true }),
  ).toBeFocused();
  await page.keyboard.press('Enter');
  await expect(details).not.toBeVisible();
  await expect(beta).toBeFocused();
});

for (const status of ['launched', 'cancelled', 'failed', 'unknown'] as const) {
  test(`${status} uninstall result consumes the review without removing the app or double launching`, async ({
    page,
  }) => {
    await desktop(page, status);
    await page.getByRole('button', { name: 'View details for Alpha Studio', exact: true }).click();
    const details = page.getByRole('region', { name: 'App details', exact: true });
    await expect(details).toContainText('2026-02-03');
    const inventoryReads = await page.evaluate(() => window.appsTest.inventoryReads);
    await details.getByRole('button', { name: 'Review & uninstall', exact: true }).dblclick();
    await expect(
      details.getByRole('button', { name: 'Opening uninstall program…', exact: true }),
    ).toBeDisabled();
    await expect(page.getByRole('button', { name: 'Refresh apps', exact: true })).toBeDisabled();
    expect(await page.evaluate(() => window.appsTest.uninstall)).toEqual(['alpha-review-1']);
    await page.evaluate(() => window.appsTest.finishLaunch!());
    const message =
      status === 'launched'
        ? 'Uninstall program started.'
        : status === 'cancelled'
          ? 'Uninstall review cancelled.'
          : status === 'failed'
            ? 'Uninstall could not start.'
            : 'Check Windows before trying again.';
    await expect(details.getByText(message, { exact: true })).toBeVisible();
    await expect(
      details.getByRole('button', { name: 'Review & uninstall', exact: true }),
    ).toBeDisabled();
    await expect(
      page.getByRole('button', { name: 'View details for Alpha Studio', exact: true }),
    ).toBeVisible();
    expect(await page.evaluate(() => window.appsTest.inventoryReads)).toBe(inventoryReads);
    if (status === 'unknown')
      await expect(details).toContainText('Check whether its uninstall program is already open');
    await details.getByRole('button', { name: 'Refresh app details', exact: true }).click();
    await expect(
      details.getByRole('button', { name: 'Review & uninstall', exact: true }),
    ).toBeEnabled();
    expect(await page.evaluate(() => window.appsTest.details)).toEqual(['alpha', 'alpha']);
    await page.evaluate(() => {
      window.appsTest.omitAlpha = true;
    });
    await page.getByRole('button', { name: 'Refresh apps', exact: true }).click();
    await expect(
      page.getByRole('button', { name: 'View details for Alpha Studio', exact: true }),
    ).not.toBeVisible();
    await expect(page.getByRole('region', { name: 'App details', exact: true })).not.toBeVisible();
    expect(await page.evaluate(() => window.appsTest.inventoryReads)).toBe(inventoryReads + 1);
    expect(await page.evaluate(() => window.appsTest.uninstall)).toHaveLength(1);
  });
}
