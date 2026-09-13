import { expect, test, type Page } from '@playwright/test';
import type { BurrowAPI, ScanKind, Snapshot } from '../../src/shared/contracts';

type TestState = {
  scans: { kind: ScanKind; root: string | null }[];
  removals: { scanId: string; ids: string[] }[];
  cancellations: number;
  historyFails?: boolean;
  finishRecycle?: () => void;
  receive: (rx: number | null, tx: number | null) => void;
};
declare global {
  interface Window {
    cleanupTest: TestState;
  }
}

async function desktop(
  page: Page,
  scenario: 'cancel-then-partial' | 'refresh-failure' | 'clean' | 'stop-after-current',
) {
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
        network: [{ name: 'Ethernet', address: '192.0.2.1', rx: 10, tx: 20 }],
        battery: null,
        processes: [],
        warnings: [],
      };
      const listeners = new Set<(value: Snapshot) => void>();
      window.cleanupTest = {
        scans: [],
        removals: [],
        cancellations: 0,
        receive: (rx, tx) => {
          const next = {
            ...snapshot,
            timestamp: Date.now(),
            network: [{ ...snapshot.network[0], rx, tx }],
          };
          listeners.forEach((receive) => receive(next));
        },
      };
      const removed = new Set<number>();
      let stopped = false;
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
        saveSettings: async (next) => next,
        chooseFolder: async () => 'C:\\Users\\Test\\Documents',
        scan: async (kind, root) => {
          window.cleanupTest.scans.push({ kind, root: root ?? null });
          const iteration = window.cleanupTest.scans.length;
          if (iteration > 1 && scenario === 'refresh-failure')
            throw new Error('Folder could not be read.');
          const actualRoot = kind === 'clean' ? 'C:\\Users\\Test\\AppData\\Local\\Temp' : root!;
          const names = ['original.pdf', 'copy-a.pdf', 'copy-b.pdf'];
          const entries = names.flatMap((name, index) =>
            removed.has(index)
              ? []
              : [
                  {
                    id: `${index}-${iteration}`,
                    name,
                    path: `${actualRoot}\\${name}`,
                    bytes: 512,
                    category: kind,
                    modified: Date.now() - (10 - index) * 86_400_000,
                    isDirectory: false,
                    ...(kind === 'duplicates' ? { group: 'matching-content' } : {}),
                  },
                ],
          );
          return {
            id: `scan-${iteration}`,
            kind,
            root: actualRoot,
            entries,
            totalBytes: entries.length * 512,
            scanned: 10,
            skipped: 0,
            truncated: false,
            cancelled: false,
            timestamp: Date.now(),
          };
        },
        cancelScan: async () => {
          window.cleanupTest.cancellations++;
          stopped = true;
          window.cleanupTest.finishRecycle?.();
        },
        recycle: async (scanId, ids) => {
          window.cleanupTest.removals.push({ scanId, ids });
          if (
            (scenario === 'cancel-then-partial' && window.cleanupTest.removals.length === 2) ||
            scenario === 'stop-after-current'
          )
            await new Promise<void>((resolve) => {
              window.cleanupTest.finishRecycle = resolve;
            });
          if (scenario === 'cancel-then-partial' && window.cleanupTest.removals.length === 1)
            return { recycled: 0, recycledIds: [], bytes: 0, failures: [], cancelled: true };
          removed.add(Number(ids[0].split('-')[0]));
          return {
            recycled: 1,
            recycledIds: [ids[0]],
            bytes: 512,
            failures: ids.length > 1 && !stopped ? ['copy-b.pdf: file is in use'] : [],
            cancelled: stopped,
          };
        },
        reveal: async () => {},
        getApps: async () => [],
        openAppsSettings: async () => {},
        getPorts: async () => [],
        diagnose: async () => [],
        optimize: async () => '',
        windowAction: async () => {},
        onSnapshot: (receive) => {
          listeners.add(receive);
          return () => {
            listeners.delete(receive);
          };
        },
        onScanProgress: () => () => {},
      };
      window.burrow = api;
    },
    { scenario },
  );
  await page.goto('/');
}

async function selectDuplicates(page: Page) {
  await page
    .getByRole('navigation')
    .getByRole('button', { name: 'Duplicates', exact: true })
    .click();
  await page.getByRole('button', { name: 'Choose folder', exact: true }).click();
  await page.getByRole('button', { name: 'Find duplicates', exact: true }).click();
  await page.getByRole('button', { name: 'Select extra copies', exact: true }).click();
  await expect(page.getByText('Keeping 1 copy', { exact: true })).toBeVisible();
}

test('native review cancellation keeps selection; a partial batch refreshes and clears stale IDs', async ({
  page,
}) => {
  await desktop(page, 'cancel-then-partial');
  await selectDuplicates(page);
  await page.getByRole('button', { name: 'Review & recycle', exact: true }).click();
  await expect(
    page.getByText('Removal cancelled. No items were moved.', { exact: true }),
  ).toBeVisible();
  await expect(page.getByRole('checkbox', { checked: true })).toHaveCount(2);
  expect(await page.evaluate(() => window.cleanupTest.scans.length)).toBe(1);
  expect(await page.evaluate(() => window.cleanupTest.removals)).toEqual([
    { scanId: 'scan-1', ids: ['1-1', '2-1'] },
  ]);
  await page.getByRole('button', { name: 'Review & recycle', exact: true }).click();
  await expect(
    page.getByRole('button', { name: 'Moving to Recycle Bin…', exact: true }),
  ).toBeDisabled();
  await page.getByRole('navigation').getByRole('button', { name: 'Clean', exact: true }).click();
  await page
    .getByRole('navigation')
    .getByRole('button', { name: 'Duplicates', exact: true })
    .click();
  await page.evaluate(() => window.cleanupTest.finishRecycle!());
  await expect(page.getByText(/1 item.*moved to Recycle Bin.*file is in use/)).toBeVisible();
  await expect(page.getByRole('checkbox')).toHaveCount(2);
  await expect(page.getByRole('checkbox', { checked: true })).toHaveCount(0);
  await expect(page.getByRole('checkbox', { name: /copy-a.pdf/ })).not.toBeVisible();
  await expect(page.getByRole('button', { name: 'Review & recycle', exact: true })).toBeDisabled();
  await page.getByRole('button', { name: 'Select extra copies', exact: true }).click();
  await page.getByRole('button', { name: 'Review & recycle', exact: true }).click();
  await expect
    .poll(() => page.evaluate(() => window.cleanupTest.removals.at(-1)))
    .toEqual({ scanId: 'scan-2', ids: ['2-2'] });
});

for (const kind of ['clean', 'duplicates'] as const) {
  test(`${kind} can stop recycling after the current item and refresh the partial result`, async ({
    page,
  }) => {
    await desktop(page, 'stop-after-current');
    if (kind === 'duplicates') await selectDuplicates(page);
    else {
      await page
        .getByRole('navigation')
        .getByRole('button', { name: 'Clean', exact: true })
        .click();
      await page.getByRole('button', { name: 'Scan temporary files', exact: true }).click();
      await page
        .getByRole('checkbox', { name: 'Select up to 200 filtered items', exact: true })
        .check();
    }
    await page.getByRole('button', { name: 'Review & recycle', exact: true }).click();
    await page.getByRole('button', { name: 'Stop after current item', exact: true }).click();
    await expect(
      page.getByText('Removal stopped. 1 item · 512 B moved to Recycle Bin.', { exact: true }),
    ).toBeVisible();
    expect(await page.evaluate(() => window.cleanupTest.cancellations)).toBe(1);
    await expect(page.getByText('0 selected', { exact: true })).toBeVisible();
    await expect(
      page.getByRole('button', { name: 'Review & recycle', exact: true }),
    ).toBeDisabled();
    await expect(
      page.getByRole('button', { name: 'Stop after current item', exact: true }),
    ).not.toBeVisible();
    expect(await page.evaluate(() => window.cleanupTest.scans.length)).toBe(2);
  });
}

test('failed refresh after recycling cannot leave old entries actionable', async ({ page }) => {
  await desktop(page, 'refresh-failure');
  await selectDuplicates(page);
  await page.getByRole('button', { name: 'Review & recycle', exact: true }).click();
  await expect(page.getByRole('alert')).toContainText('Folder could not be read.');
  await expect(page.getByRole('checkbox')).toHaveCount(0);
  await expect(
    page.getByRole('button', { name: 'Review & recycle', exact: true }),
  ).not.toBeVisible();
  await expect(page.getByRole('button', { name: 'Find duplicates', exact: true })).toBeEnabled();
});

test('temporary cleanup and its automatic refresh never send a custom folder', async ({ page }) => {
  await desktop(page, 'clean');
  await page.getByRole('navigation').getByRole('button', { name: 'Clean', exact: true }).click();
  await page.getByRole('button', { name: 'Scan temporary files', exact: true }).click();
  await page.getByRole('checkbox', { name: 'Select copy-a.pdf', exact: true }).check();
  await page.getByRole('button', { name: 'Review & recycle', exact: true }).click();
  await expect
    .poll(() => page.evaluate(() => window.cleanupTest.scans))
    .toEqual([
      { kind: 'clean', root: null },
      { kind: 'clean', root: null },
    ]);
  expect(await page.evaluate(() => window.cleanupTest.removals)).toEqual([
    { scanId: 'scan-1', ids: ['1-1'] },
  ]);
  await expect(
    page.getByRole('checkbox', { name: 'Select copy-a.pdf', exact: true }),
  ).not.toBeVisible();
});

test('network transfer lines stop at samples with missing rates', async ({ page }) => {
  await desktop(page, 'clean');
  await page.getByRole('navigation').getByRole('button', { name: 'Network', exact: true }).click();
  await expect(
    page.getByRole('heading', { name: 'Network interfaces', exact: true }),
  ).toBeVisible();
  for (const [rx, tx] of [
    [15, 25],
    [null, null],
    [20, 30],
    [25, 35],
  ]) {
    await page.evaluate(([rx, tx]) => window.cleanupTest.receive(rx, tx), [rx, tx]);
  }
  await expect(page.locator('polyline.tool-chart-rx')).toHaveCount(2);
  await expect(page.locator('polyline.tool-chart-tx')).toHaveCount(2);
  const segments = await page
    .locator('polyline.tool-chart-rx')
    .evaluateAll((lines) => lines.map((line) => line.getAttribute('points')));
  expect(segments.map((line) => line!.trim().split(' ').length)).toEqual([2, 2]);
});

test('history clears a previous loading error after a successful refresh', async ({ page }) => {
  await desktop(page, 'clean');
  await page.evaluate(() => {
    window.cleanupTest.historyFails = true;
    window.burrow!.getHistory = async () => {
      if (window.cleanupTest.historyFails) {
        throw new Error('History temporarily unavailable.');
      }
      const snapshot = await window.burrow!.getSnapshot();
      return [{ ...snapshot, timestamp: Date.now() - 3000 }, snapshot];
    };
  });
  await page.getByRole('tab', { name: 'History', exact: true }).click();
  await expect(page.getByRole('alert')).toContainText('History temporarily unavailable.');
  await page.evaluate(() => {
    window.cleanupTest.historyFails = false;
  });
  await page.getByRole('button', { name: '5m', exact: true }).click();
  await expect(page.getByText(/2 samples · stored locally/)).toBeVisible();
  await expect(page.getByRole('alert')).not.toBeVisible();
});
