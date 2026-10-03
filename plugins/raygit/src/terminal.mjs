import pty from 'node-pty';
import { randomUUID } from 'node:crypto';
import { existsSync } from 'node:fs';
import path from 'node:path';

const sessions = new Map();
const LIMIT = 256 * 1024;
const IDLE = 30 * 60 * 1000;
function session(repo, id) {
  const item = sessions.get(id);
  if (!item || item.repo !== repo) throw new Error('终端已关闭，或不属于当前仓库。请重新打开。');
  item.touched = Date.now();
  return item;
}
function stop(item) {
  if (item.exitCode !== null) return;
  try { item.pty.kill('SIGHUP'); } catch {}
  // forkpty creates a session leader. Closing also stops same-group foreground jobs.
  try { process.kill(-item.pty.pid, 'SIGHUP'); } catch {}
}
const sweep = setInterval(() => {
  for (const [id, item] of sessions) if (Date.now() - item.touched > IDLE) { stop(item); sessions.delete(id); }
}, 60_000);
sweep.unref();

export function openTerminal(repo, { cols = 100, rows = 24 } = {}) {
  if (sessions.size >= 8) throw new Error('最多同时打开 8 个终端，请先关闭不需要的终端。');
  const shell = process.env.SHELL && path.isAbsolute(process.env.SHELL) && existsSync(process.env.SHELL) ? process.env.SHELL : '/bin/sh';
  const env = Object.fromEntries(Object.entries(process.env).filter(([key, value]) => value !== undefined && !key.startsWith('GIT_') && !key.startsWith('CODEX_')));
  Object.assign(env, { TERM: 'xterm-256color', COLORTERM: 'truecolor', PWD: repo });
  const terminal = pty.spawn(shell, ['-i'], { name: 'xterm-256color', cols, rows, cwd: repo, env });
  const item = { id: randomUUID(), repo, shell, pty: terminal, output: '', start: 0, exitCode: null, touched: Date.now() };
  sessions.set(item.id, item);
  terminal.onData(data => {
    item.output += data;
    if (item.output.length > LIMIT) { const drop = item.output.length - LIMIT; item.output = item.output.slice(drop); item.start += drop; }
  });
  terminal.onExit(({ exitCode }) => { item.exitCode = exitCode; });
  return { id: item.id, repo, shell, cols, rows };
}
export function readTerminal(repo, { id, cursor = 0 }) {
  const item = session(repo, id);
  return { id, repo, output: item.output.slice(Math.max(0, cursor - item.start)), cursor: item.start + item.output.length, truncated: cursor < item.start, exitCode: item.exitCode };
}
export function inputTerminal(repo, { id, data }) {
  const item = session(repo, id);
  if (item.exitCode !== null) throw new Error('终端进程已退出。');
  item.pty.write(data);
  return { accepted: true };
}
export function resizeTerminal(repo, { id, cols, rows }) {
  const item = session(repo, id);
  if (item.exitCode === null) item.pty.resize(cols, rows);
  return { cols, rows };
}
export function closeTerminal(repo, { id }) {
  const item = session(repo, id); stop(item); sessions.delete(id);
  return { closed: true };
}
export function stopTerminals() {
  for (const item of sessions.values()) stop(item);
  sessions.clear();
}
