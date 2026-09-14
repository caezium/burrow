import { describe, expect, it, vi } from 'vitest';
import { runAppUninstall } from '../electron/services/uninstall-operation';
import type { AppDetails, AppUninstallResult } from '../src/shared/contracts';

const details: AppDetails = {
  app: {
    id: 'app',
    name: 'Example Studio',
    version: '1.0',
    publisher: 'Example',
    size: 500,
    installDate: '',
  },
  scope: 'user',
  installLocation: 'C:\\Users\\Tester\\AppData\\Local\\Programs\\Example',
  canReveal: true,
  reviewId: 'review',
  uninstall: {
    available: true,
    kind: 'exe',
    target: 'C:\\Example\\uninstall.exe',
    reason: 'Registered uninstaller',
  },
};
const launched: AppUninstallResult = {
  status: 'launched',
  message: 'The uninstaller started. Refresh apps when it finishes.',
  pid: 1234,
};
function dependencies() {
  return {
    applications: {
      validateReview: vi.fn(async () => details),
      launchReviewed: vi.fn(async (): Promise<AppUninstallResult> => launched),
    },
    confirm: vi.fn(async (_details: AppDetails) => true),
    record: vi.fn(),
    flush: vi.fn(async () => {}),
    shouldStop: vi.fn(() => false),
  };
}

describe('reviewed application uninstall', () => {
  it('persists accepted confirmation before native dispatch and reports only launch', async () => {
    const deps = dependencies();
    const order: string[] = [];
    deps.confirm.mockImplementation(async (value) => {
      expect(value).toBe(details);
      order.push('confirm');
      return true;
    });
    deps.flush.mockImplementation(async () => {
      order.push('flush');
    });
    deps.applications.launchReviewed.mockImplementation(async () => {
      order.push('launch');
      return launched;
    });
    expect(await runAppUninstall('review', deps)).toEqual(launched);
    expect(order).toEqual(['confirm', 'flush', 'launch', 'flush']);
    expect(deps.applications.launchReviewed).toHaveBeenCalledWith('review', deps.shouldStop);
    expect(
      deps.record.mock.calls.map(([entry]) => [entry.title, entry.status, entry.bytes]),
    ).toEqual([
      ['Uninstaller launch requested', 'partial', 0],
      ['Uninstaller started', 'success', 0],
    ]);
  });

  it('does not dispatch when native confirmation is cancelled', async () => {
    const deps = dependencies();
    deps.confirm.mockResolvedValue(false);
    expect((await runAppUninstall('review', deps)).status).toBe('cancelled');
    expect(deps.applications.launchReviewed).not.toHaveBeenCalled();
    expect(deps.record).not.toHaveBeenCalled();
  });

  it('does not confirm or launch a stale review', async () => {
    const deps = dependencies();
    deps.applications.validateReview.mockRejectedValue(new Error('App changed. Refresh details.'));
    expect(await runAppUninstall('review', deps)).toEqual({
      status: 'failed',
      message: 'App changed. Refresh details.',
    });
    expect(deps.confirm).not.toHaveBeenCalled();
    expect(deps.applications.launchReviewed).not.toHaveBeenCalled();
  });

  it('stops before confirmation when Burrow is quitting', async () => {
    const deps = dependencies();
    deps.shouldStop.mockReturnValue(true);
    expect((await runAppUninstall('review', deps)).status).toBe('cancelled');
    expect(deps.confirm).not.toHaveBeenCalled();
    expect(deps.applications.launchReviewed).not.toHaveBeenCalled();
  });

  it('stops when shutdown begins while consent is being saved', async () => {
    const deps = dependencies();
    deps.flush.mockImplementationOnce(async () => {
      deps.shouldStop.mockReturnValue(true);
    });
    expect((await runAppUninstall('review', deps)).status).toBe('cancelled');
    expect(deps.applications.launchReviewed).not.toHaveBeenCalled();
    expect(deps.record.mock.calls.at(-1)?.[0]).toMatchObject({ status: 'cancelled', bytes: 0 });
  });

  it('blocks native dispatch if the consent record cannot be saved', async () => {
    const deps = dependencies();
    deps.flush.mockRejectedValueOnce(new Error('disk full'));
    const result = await runAppUninstall('review', deps);
    expect(result.status).toBe('failed');
    expect(result.message).toContain('No uninstaller was started');
    expect(deps.applications.launchReviewed).not.toHaveBeenCalled();
    expect(deps.record.mock.calls.at(-1)?.[0]).toMatchObject({
      status: 'error',
      bytes: 0,
      detail: expect.stringContaining('no uninstaller was started'),
    });
  });

  it.each([
    ['cancelled', 'cancelled'],
    ['failed', 'error'],
    ['unknown', 'partial'],
  ] as const)('records %s as %s with no reclaimed space', async (status, activityStatus) => {
    const deps = dependencies();
    const result: AppUninstallResult = { status, message: `Launch ${status}` };
    deps.applications.launchReviewed.mockResolvedValue(result);
    expect(await runAppUninstall('review', deps)).toEqual(result);
    expect(deps.record.mock.calls.at(-1)?.[0]).toMatchObject({ status: activityStatus, bytes: 0 });
    expect(deps.applications.launchReviewed).toHaveBeenCalledTimes(1);
  });

  it('keeps a confirmed native launch outcome when its receipt cannot be saved', async () => {
    const deps = dependencies();
    deps.flush.mockResolvedValueOnce().mockRejectedValueOnce(new Error('disk full'));
    const result = await runAppUninstall('review', deps);
    expect(result).toMatchObject({ status: 'launched', pid: 1234 });
    expect(result.message).toContain('Activity could not be saved');
    expect(deps.applications.launchReviewed).toHaveBeenCalledTimes(1);
  });

  it('does not retry or claim no dispatch after an unexpected launcher rejection', async () => {
    const deps = dependencies();
    deps.applications.launchReviewed.mockRejectedValue(new Error('response lost'));
    const result = await runAppUninstall('review', deps);
    expect(result.status).toBe('unknown');
    expect(result.message).toContain('Check Windows');
    expect(deps.applications.launchReviewed).toHaveBeenCalledTimes(1);
  });
});
