import type { ActivityEntry, AppDetails, AppUninstallResult } from '../../src/shared/contracts';

interface UninstallDependencies {
  applications: {
    validateReview: (reviewId: string) => Promise<AppDetails>;
    launchReviewed: (reviewId: string, shouldStop?: () => boolean) => Promise<AppUninstallResult>;
  };
  confirm: (details: AppDetails) => Promise<boolean>;
  record: (entry: Omit<ActivityEntry, 'id' | 'timestamp'>) => unknown;
  flush: () => Promise<void>;
  shouldStop: () => boolean;
}

const cancelled = (): AppUninstallResult => ({
  status: 'cancelled',
  message: 'Cancelled. No uninstaller was started.',
});

/** Saves consent before dispatch, then records the launch outcome without inferring removal. */
export async function runAppUninstall(
  reviewId: string,
  { applications, confirm, record, flush, shouldStop }: UninstallDependencies,
): Promise<AppUninstallResult> {
  let details: AppDetails;
  try {
    details = await applications.validateReview(reviewId);
    if (shouldStop() || !(await confirm(details)) || shouldStop()) return cancelled();
  } catch (error) {
    if (shouldStop()) return cancelled();
    return {
      status: 'failed',
      message: error instanceof Error ? error.message : 'The app could not be reviewed.',
    };
  }
  try {
    record({
      title: 'Uninstaller launch requested',
      detail: `${details.app.name} · confirmation accepted; launch outcome pending.`,
      status: 'partial',
      bytes: 0,
    });
    await flush();
  } catch {
    // If persistence recovers later, the in-memory activity must still show no dispatch.
    try {
      record({
        title: 'Uninstaller could not start',
        detail: `${details.app.name} · Activity could not be saved; no uninstaller was started.`,
        status: 'error',
        bytes: 0,
      });
    } catch {
      // The UI still receives the definite pre-launch failure below.
    }
    return {
      status: 'failed',
      message:
        'Activity could not be saved. No uninstaller was started. Refresh details before retrying.',
    };
  }

  let result: AppUninstallResult;
  if (shouldStop()) result = cancelled();
  else {
    try {
      result = await applications.launchReviewed(reviewId, shouldStop);
    } catch {
      // The launcher normally classifies failures. An unexpected rejection cannot prove no dispatch.
      result = {
        status: 'unknown',
        message: 'The launch outcome could not be confirmed. Check Windows before trying again.',
      };
    }
  }
  const outcomes = {
    launched: { title: 'Uninstaller started', status: 'success' },
    cancelled: { title: 'Uninstaller launch cancelled', status: 'cancelled' },
    failed: { title: 'Uninstaller could not start', status: 'error' },
    unknown: { title: 'Uninstaller launch unconfirmed', status: 'partial' },
  } as const;
  try {
    record({
      ...outcomes[result.status],
      detail: `${details.app.name} · ${result.message}`,
      bytes: 0,
    });
    await flush();
  } catch {
    return {
      ...result,
      message: `${result.message} Activity could not be saved. Check Windows before trying again.`,
    };
  }
  return result;
}
