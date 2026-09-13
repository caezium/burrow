import { afterEach, describe, expect, it, vi } from 'vitest';
import { drainWithin } from '../electron/services/lifecycle';

afterEach(() => vi.useRealTimers());

describe('bounded shutdown draining', () => {
  it('waits for the OS operation and its receipt before allowing shutdown', async () => {
    let finishMove!: () => void;
    let finishSave!: () => void;
    const move = new Promise<void>((resolve) => {
      finishMove = resolve;
    });
    const save = new Promise<void>((resolve) => {
      finishSave = resolve;
    });
    const order: string[] = [];
    const pending = (async () => {
      await move;
      order.push('moved');
      await save;
      order.push('receipt saved');
    })();
    const drain = drainWithin(pending, 1_000).then((result) => {
      order.push('drained');
      return result;
    });
    finishMove();
    await Promise.resolve();
    expect(order).toEqual(['moved']);
    finishSave();
    expect(await drain).toEqual({ status: 'complete' });
    expect(order).toEqual(['moved', 'receipt saved', 'drained']);
  });
  it('times out without pretending a pending native move was cancelled or finished', async () => {
    vi.useFakeTimers();
    let finish!: () => void;
    const pending = new Promise<void>((resolve) => {
      finish = resolve;
    });
    const firstAttempt = drainWithin(pending, 15_000);
    await vi.advanceTimersByTimeAsync(15_000);
    expect(await firstAttempt).toEqual({ status: 'timeout' });
    finish();
    expect(await drainWithin(pending, 15_000)).toEqual({ status: 'complete' });
  });
  it('surfaces failed receipt persistence instead of permitting shutdown', async () => {
    const error = new Error('Disk is full');
    expect(await drainWithin(Promise.reject(error), 15_000)).toEqual({ status: 'error', error });
  });
});
