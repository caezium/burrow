import type { ActivityEntry, RecycleResult, ScanEntry } from '../../src/shared/contracts';
import type { ScanService } from './scanner';

interface RecycleDependencies {
  scanner: Pick<ScanService, 'validateRecycle' | 'revalidateEntry' | 'markRecycled' | 'getResult'>;
  confirm: (selected: ScanEntry[]) => Promise<boolean>;
  trash: (file: string) => Promise<void>;
  record: (entry: Omit<ActivityEntry, 'id' | 'timestamp'>) => unknown;
  flush: () => Promise<void>;
  shouldStop: () => boolean;
}

/** Runs the reviewed operation in order, persisting each receipt before moving another item. */
export async function recycleReviewed(
  scanId: string,
  ids: string[],
  { scanner, confirm, trash, record, flush, shouldStop }: RecycleDependencies,
): Promise<RecycleResult> {
  let recycled = 0;
  const recycledIds: string[] = [];
  let bytes = 0;
  const failures: string[] = [];
  let selected: ScanEntry[];
  try {
    selected = await scanner.validateRecycle(scanId, ids);
  } catch (error) {
    if (shouldStop()) return { recycled, recycledIds, bytes, failures, cancelled: true };
    throw error;
  }
  if (shouldStop() || !(await confirm(selected)) || shouldStop())
    return { recycled, recycledIds, bytes, failures, cancelled: true };

  record({
    title: 'Recycle operation started',
    detail: `${selected.length} selected items in ${scanner.getResult(scanId)?.root ?? 'the scanned folder'}`,
    status: 'partial',
    bytes: 0,
  });
  await flush();
  for (const item of selected) {
    if (shouldStop()) break;
    try {
      const checked = await scanner.revalidateEntry(scanId, item.id);
      if (shouldStop()) break;
      await trash(checked.path);
      scanner.markRecycled(scanId, item.id);
      recycled++;
      recycledIds.push(item.id);
      bytes += checked.bytes;
      record({
        title: 'Moved to Recycle Bin',
        detail: checked.path,
        status: 'success',
        bytes: checked.bytes,
      });
    } catch (error) {
      if (shouldStop()) break;
      failures.push(`${item.name}: ${error instanceof Error ? error.message : 'Recycle failed'}`);
      record({
        title: 'Item could not be recycled',
        detail: failures.at(-1)!,
        status: 'error',
        bytes: 0,
      });
    }
    // Stop on a save failure, but still return exact native outcomes to the interface.
    try {
      await flush();
    } catch {
      failures.push(
        'Activity could not be saved. The operation stopped; review the moved items before retrying.',
      );
      break;
    }
  }
  const cancelled = shouldStop();
  record({
    title: 'Moved items to Recycle Bin',
    detail: `${recycled} moved · ${failures.length} failed${cancelled ? ' · stopped' : ''}${failures.length ? `\n${failures.join('\n')}` : ''}`,
    status: cancelled ? 'cancelled' : failures.length ? 'partial' : 'success',
    bytes,
  });
  try {
    await flush();
  } catch {
    if (!failures.some((failure) => failure.startsWith('Activity could not be saved.')))
      failures.push('Activity could not be saved. The moved items are listed in this result.');
  }
  return { recycled, recycledIds, bytes, failures, cancelled };
}
