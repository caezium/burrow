import { expect, test, type Page } from '@playwright/test';
import type { BurrowAPI, LeftoverScope, ScanProgress, Snapshot } from '../../src/shared/contracts';

declare global {
  interface Window {
    leftoverTest: {
      scopes: LeftoverScope[];
      cancellations: number;
      revealed: string[];
      failInventory: boolean;
    };
  }
}

async function openLeftovers(page: Page) {
  await page
    .getByRole('navigation')
    .getByRole('button', { name: 'Leftovers', exact: true })
    .click();
  await expect(page.getByRole('heading', { name: 'Leftovers', exact: true })).toBeVisible();
}

async function desktop(page: Page, scenario: 'cancel' | 'inventory-error') {
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
      const listeners = new Set<(progress: ScanProgress) => void>();
      let finish: (() => void) | undefined;
      let cancelled = false;
      window.leftoverTest = {
        scopes: [],
        cancellations: 0,
        revealed: [],
        failInventory: scenario === 'inventory-error',
      };
      const settings = {
        theme: 'dark' as const,
        sampleInterval: 3,
        retentionDays: 30,
        minimizeToTray: true,
      };
      const api: BurrowAPI = {
        mode: 'desktop',
        getSnapshot: async () => snapshot,
        getHistory: async () => [],
        getActivity: async () => [],
        getSettings: async () => settings,
        saveSettings: async (value) => value,
        chooseFolder: async () => {
          throw new Error('Leftovers must not choose an arbitrary folder.');
        },
        scan: async () => {
          throw new Error('Use the fixed-scope leftover scanner.');
        },
        scanLeftovers: async (scope) => {
          window.leftoverTest.scopes.push(scope);
          cancelled = false;
          if (window.leftoverTest.failInventory)
            throw new Error(
              'Installed app inventory is unavailable. No leftover report was produced.',
            );
          const root = `C:\\Users\\Test\\AppData\\${scope === 'local' ? 'Local' : 'Roaming'}`;
          listeners.forEach((receive) =>
            receive({ scanned: 42, bytes: 512, path: `${root}\\Retired Editor\\Cache` }),
          );
          if (scenario === 'cancel')
            await new Promise<void>((resolve) => {
              finish = resolve;
            });
          return {
            id: 'leftover-report',
            scope,
            root,
            installedApps: 87,
            scanned: 106,
            skipped: 4,
            truncated: scenario === 'cancel',
            cancelled,
            timestamp: Date.now(),
            entries: [
              {
                id: 'editor-cache',
                name: 'Retired Editor / Cache',
                path: `${root}\\Retired Editor\\Cache`,
                bytes: 512,
                modified: Date.now() - 90 * 86_400_000,
                category: 'cache',
                evidence: [
                  'Known cache directory; its scanned contents are at least 60 days old.',
                  'No matching registered desktop app name or publisher.',
                ],
              },
            ],
          };
        },
        cancelScan: async () => {
          window.leftoverTest.cancellations++;
          cancelled = true;
          finish?.();
        },
        recycle: async () => {
          throw new Error('A leftover report cannot authorize removal.');
        },
        reveal: async (path) => {
          window.leftoverTest.revealed.push(path);
        },
        getApps: async () => [],
        getAppDetails: async () => {
          throw new Error('No app selected');
        },
        revealApp: async () => {},
        uninstallApp: async () => ({ status: 'cancelled', message: 'Cancelled' }),
        openAppsSettings: async () => {},
        getPorts: async () => [],
        diagnose: async () => [],
        optimize: async () => '',
        windowAction: async () => {},
        onSnapshot: () => () => {},
        onScanProgress: (receive) => {
          listeners.add(receive);
          return () => {
            listeners.delete(receive);
          };
        },
      };
      window.burrow = api;
    },
    { scenario },
  );
  await page.goto('/');
  await openLeftovers(page);
}

test('leftover preview reports evidence in both fixed scopes without destructive controls', async ({
  page,
}) => {
  await page.goto('/');
  await openLeftovers(page);
  await expect(page.getByRole('button', { name: /Local AppData/ })).toHaveAttribute(
    'aria-pressed',
    'true',
  );
  await expect(page.getByRole('button', { name: 'Choose folder', exact: true })).not.toBeVisible();
  await page.getByRole('button', { name: 'Scan leftovers', exact: true }).click();
  await expect(page.getByRole('article')).toHaveCount(2);
  await expect(page.getByText('Read-only report', { exact: true })).toBeVisible();
  await expect(page.getByRole('note')).toContainText('Portable and Microsoft Store apps');
  await expect(page.getByRole('article').first()).toContainText(
    'No matching registered desktop app name or publisher.',
  );
  await expect(page.getByRole('article').first()).toContainText('Cache');
  await expect(
    page.getByRole('button', { name: /Reveal .*AppData\\Local/ }).first(),
  ).toBeDisabled();
  await expect(page.getByRole('checkbox')).toHaveCount(0);
  await expect(page.getByRole('button', { name: /recycle|delete|remove/i })).toHaveCount(0);
  await page.getByRole('combobox', { name: 'Sort possible leftovers' }).selectOption('age');
  await expect(page.getByRole('article').first()).toContainText('Archive Player / Logs');
  await page
    .getByRole('searchbox', { name: 'Filter possible leftovers' })
    .fill('Known cache folder');
  await expect(page.getByRole('article')).toHaveCount(1);
  await page.getByRole('button', { name: /Roaming AppData/ }).click();
  await expect(page.getByRole('article')).toHaveCount(0);
  await page.getByRole('button', { name: 'Scan leftovers', exact: true }).click();
  await expect(page.getByRole('article')).toHaveCount(2);
  await expect(
    page.getByRole('button', { name: /Reveal .*AppData\\Roaming/ }).first(),
  ).toBeDisabled();
});

test('leftover cancellation remains available after navigation and labels partial evidence', async ({
  page,
}) => {
  await desktop(page, 'cancel');
  await page.getByRole('button', { name: 'Scan leftovers', exact: true }).click();
  await expect(page.getByRole('button', { name: /Roaming AppData/ })).toBeDisabled();
  await expect(page.getByRole('status')).toContainText('42 items');
  await page.getByRole('navigation').getByRole('button', { name: 'Clean', exact: true }).click();
  await openLeftovers(page);
  await page.getByRole('button', { name: 'Cancel scan', exact: true }).click();
  await expect(page.getByRole('status')).toContainText(
    'Scan cancelled. This report includes only folders checked before cancellation.',
  );
  await expect(page.getByRole('article')).toHaveCount(1);
  await expect(
    page.getByText('Scan limit reached · partial report', { exact: true }),
  ).toBeVisible();
  await expect(page.getByText('4 inaccessible or excluded', { exact: true })).toBeVisible();
  await expect(page.locator('.tool-leftover-summary')).toContainText('87');
  await expect(page.getByRole('button', { name: /Roaming AppData/ })).toBeEnabled();
  expect(await page.evaluate(() => window.leftoverTest.scopes)).toEqual(['local']);
  expect(await page.evaluate(() => window.leftoverTest.cancellations)).toBe(1);
  const reveal = page.getByRole('button', { name: /Reveal .*Retired Editor/ });
  await reveal.click();
  expect(await page.evaluate(() => window.leftoverTest.revealed)).toEqual([
    'C:\\Users\\Test\\AppData\\Local\\Retired Editor\\Cache',
  ]);
  await expect(page.getByRole('button', { name: /recycle|delete|remove/i })).toHaveCount(0);
});

test('inventory failure shows an error instead of an empty report and supports retry', async ({
  page,
}) => {
  await desktop(page, 'inventory-error');
  await page.getByRole('button', { name: /Roaming AppData/ }).click();
  await page.getByRole('button', { name: 'Scan leftovers', exact: true }).click();
  await expect(page.getByRole('alert')).toContainText('Installed app inventory is unavailable.');
  await expect(
    page.getByRole('heading', { name: 'No possible leftovers found.', exact: true }),
  ).not.toBeVisible();
  await expect(page.getByRole('article')).toHaveCount(0);
  await page.evaluate(() => {
    window.leftoverTest.failInventory = false;
  });
  await page.getByRole('button', { name: 'Scan leftovers', exact: true }).click();
  await expect(page.getByRole('article')).toHaveCount(1);
  await expect(page.getByRole('alert')).not.toBeVisible();
  expect(await page.evaluate(() => window.leftoverTest.scopes)).toEqual(['roaming', 'roaming']);
  await page.getByRole('searchbox', { name: 'Filter possible leftovers' }).fill('unmatched-folder');
  await expect(
    page.getByRole('heading', { name: 'No matching folders.', exact: true }),
  ).toBeVisible();
  await expect(page.getByRole('article')).toHaveCount(0);
});
