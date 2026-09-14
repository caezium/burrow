export type DrainResult =
  { status: 'complete' } | { status: 'timeout' } | { status: 'error'; error: unknown };

/** A timeout never cancels the underlying OS operation or treats it as completed. */
export async function drainWithin(work: Promise<unknown>, timeoutMs: number): Promise<DrainResult> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    return await Promise.race<DrainResult>([
      work.then(
        () => ({ status: 'complete' as const }),
        (error) => ({ status: 'error' as const, error }),
      ),
      new Promise<DrainResult>((resolve) => {
        timer = setTimeout(() => resolve({ status: 'timeout' }), timeoutMs);
      }),
    ]);
  } finally {
    if (timer) clearTimeout(timer);
  }
}
