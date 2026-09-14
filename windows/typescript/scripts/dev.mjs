import { createServer } from 'vite';
import { spawn } from 'node:child_process';
import electron from 'electron';
await import('./build-electron.mjs');
const server = await createServer();
await server.listen();
const child = spawn(electron, ['.'], {
  stdio: 'inherit',
  env: { ...process.env, BURROW_DEV_URL: 'http://127.0.0.1:5173' },
});
async function close() {
  child.kill();
  await server.close();
}
process.on('SIGINT', close);
process.on('SIGTERM', close);
child.on('exit', async (code) => {
  await server.close();
  process.exit(code ?? 0);
});
