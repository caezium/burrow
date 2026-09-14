export function formatBytes(bytes: number, decimals = 1): string {
  if (!Number.isFinite(bytes) || bytes <= 0) return '0 B';
  const index = Math.min(Math.floor(Math.log(bytes) / Math.log(1024)), 4);
  return `${(bytes / 1024 ** index).toFixed(index ? decimals : 0)} ${['B', 'KB', 'MB', 'GB', 'TB'][index]}`;
}
export function formatUptime(seconds: number): string {
  const days = Math.floor(seconds / 86400);
  return days
    ? `${days}d ${Math.floor((seconds % 86400) / 3600)}h`
    : `${Math.floor(seconds / 3600)}h ${Math.floor((seconds % 3600) / 60)}m`;
}
export function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
