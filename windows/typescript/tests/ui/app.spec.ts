import { expect, test } from '@playwright/test';

test('current macOS navigation and real feature states render without errors', async ({
  page,
}, testInfo) => {
  const errors: string[] = [];
  page.on('pageerror', (error) => errors.push(error.message));
  await page.goto('/');
  await expect(page.getByText('UI preview · example data')).toBeVisible();
  await expect(page.getByRole('heading', { name: 'Looking good in here.' })).toBeVisible();
  await page.screenshot({ path: testInfo.outputPath('overview.png'), fullPage: false });
  for (const name of [
    'Clean',
    'Optimize',
    'Apps',
    'Analyze',
    'Duplicates',
    'Leftovers',
    'Similar Photos',
    'Ports',
    'Network',
    'Get Online',
    'Settings',
  ]) {
    await page.getByRole('navigation').getByRole('button', { name, exact: true }).click();
    await expect(page.getByRole('heading', { name, exact: true })).toBeVisible();
  }
  expect(errors).toEqual([]);
});

test('process filtering, sorting and pinning stay interactive', async ({ page }) => {
  await page.goto('/');
  await page.getByRole('textbox', { name: 'Filter processes' }).fill('Code.exe');
  await expect(page.getByRole('button', { name: 'Pin Code.exe', exact: true })).toBeVisible();
  await expect(page.getByRole('button', { name: 'Pin msedge.exe', exact: true })).not.toBeVisible();
  await page.getByRole('button', { name: 'Pin Code.exe', exact: true }).click();
  await expect(page.getByRole('button', { name: 'Unpin Code.exe', exact: true })).toBeVisible();
  await page.getByRole('textbox', { name: 'Filter processes' }).clear();
  await page.getByRole('button', { name: 'Memory', exact: true }).click();
  await expect(page.locator('tbody tr').first()).toContainText('Code.exe');
});

test('theme preferences and keyboard return work', async ({ page }) => {
  await page.goto('/');
  await page.getByRole('navigation').getByRole('button', { name: 'Settings' }).click();
  await page.getByRole('button', { name: 'Light', exact: true }).click();
  await expect(page.locator('html')).toHaveAttribute('data-theme', 'light');
  await expect(page.getByRole('status').filter({ hasText: 'Preferences saved' })).toBeVisible();
  await page.getByRole('button', { name: 'Dark', exact: true }).click();
  await expect(page.locator('html')).toHaveAttribute('data-theme', 'dark');
  await page.keyboard.press('Escape');
  await expect(page.getByRole('heading', { name: 'Looking good in here.' })).toBeVisible();
});

test('scan results and user selection survive navigation', async ({ page }) => {
  await page.goto('/');
  await page.getByRole('navigation').getByRole('button', { name: 'Clean', exact: true }).click();
  await page.getByRole('button', { name: /Project build artifacts/ }).click();
  await page.getByRole('button', { name: 'Choose folder', exact: true }).click();
  await page.getByRole('button', { name: 'Scan folder', exact: true }).click();
  const select = page.getByRole('checkbox', { name: 'Select website\\node_modules', exact: true });
  await expect(select).toBeVisible();
  await select.check();
  await page.getByRole('navigation').getByRole('button', { name: 'Analyze', exact: true }).click();
  await page.getByRole('navigation').getByRole('button', { name: 'Clean', exact: true }).click();
  await expect(select).toBeChecked();
  await expect(page.getByRole('button', { name: /Review.*recycle/i }).last()).toBeDisabled();
});

test('history ranges and honest missing sensors', async ({ page }) => {
  await page.goto('/');
  await expect(page.getByText('GPU metrics are awaiting Windows integration.')).toBeVisible();
  await page.getByRole('tab', { name: 'History', exact: true }).click();
  await expect(page.getByRole('heading', { name: 'History', exact: true })).toBeVisible();
  await page.getByRole('button', { name: '5m', exact: true }).click();
  await expect(page.getByText(/samples · stored locally/)).toBeVisible();
  await page.getByRole('tab', { name: 'Activity', exact: true }).click();
  await expect(page.getByRole('heading', { name: 'A fresh start.' })).toBeVisible();
});

test('small desktop layout keeps settings reachable without horizontal overflow', async ({
  page,
}) => {
  await page.setViewportSize({ width: 940, height: 760 });
  await page.goto('/');
  const settings = page.getByRole('navigation').getByRole('button', { name: 'Settings' });
  await expect(settings).toBeInViewport();
  const metrics = await page.evaluate(() => ({
    width: document.documentElement.clientWidth,
    scroll: document.documentElement.scrollWidth,
  }));
  expect(metrics.scroll).toBeLessThanOrEqual(metrics.width);
  await settings.click();
  await expect(page.getByRole('heading', { name: 'Settings', exact: true })).toBeVisible();
});

test('system cache preview has no removal action', async ({ page }) => {
  await page.goto('/');
  await page.getByRole('navigation').getByRole('button', { name: 'Clean', exact: true }).click();
  await page.getByRole('button', { name: 'Preview temporary files', exact: true }).click();
  await expect(page.getByText('Temporary files', { exact: true })).toBeVisible();
  await expect(page.getByRole('button', { name: /Review.*recycle/i })).not.toBeVisible();
});
