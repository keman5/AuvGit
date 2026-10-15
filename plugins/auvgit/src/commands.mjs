import { spawn } from 'node:child_process';
import { createHash, randomUUID } from 'node:crypto';
import { mkdir, readFile, writeFile, rename } from 'node:fs/promises';
import { homedir } from 'node:os';
import path from 'node:path';
import { exclusive, status } from './git.mjs';

const defaults = [
  { id: 'fetch', label: 'Fetch', command: 'git fetch --prune', clean: false, builtin: true },
  { id: 'pull', label: 'Pull', command: 'git pull --ff-only', clean: true, builtin: true },
  { id: 'push', label: 'Push', command: 'git push', clean: false, builtin: true },
];
const jobs = new Map();
const pending = new Set();
const digest = value => createHash('sha256').update(value).digest('hex');
const configFile = repo => path.join(process.env.AUVGIT_CONFIG_DIR || path.join(homedir(), '.config', 'auvgit'), digest(repo) + '.json');
export async function commands(repo) {
  let raw = '[]';
  try { raw = await readFile(configFile(repo), 'utf8'); } catch (error) { if (error.code !== 'ENOENT') throw error; }
  const custom = JSON.parse(raw);
  if (!Array.isArray(custom)) throw new Error('命令配置损坏，请检查 AuvGit 用户配置。');
  return { commands: [...defaults, ...custom], revision: digest(raw) };
}
export async function configureCommand(repo, { revision, id, label, command, remove = false }) {
  return exclusive(repo, async () => {
    const current = await commands(repo);
    if (revision !== current.revision) throw new Error('命令配置已变化，请刷新。');
    if (defaults.some(item => item.id === id)) throw new Error('内置按钮不可覆盖，请创建自定义按钮。');
    const custom = current.commands.filter(item => !item.builtin);
    if (remove) {
      if (!custom.some(item => item.id === id)) throw new Error('没有此自定义按钮。');
      custom.splice(custom.findIndex(item => item.id === id), 1);
    } else {
      if (!label?.trim() || !command?.trim() || command.includes('\0')) throw new Error('请填写按钮名称和有效命令。');
      if (id && !custom.some(item => item.id === id)) throw new Error('没有此自定义按钮。');
      const item = { id: id || randomUUID(), label: label.trim(), command: command.trim(), clean: false, builtin: false };
      if (id) custom[custom.findIndex(item => item.id === id)] = item; else custom.push(item);
      if (custom.length > 20) throw new Error('每个仓库最多 20 个自定义按钮。');
    }
    const file = configFile(repo); await mkdir(path.dirname(file), { recursive: true, mode: 0o700 });
    const temp = file + '.' + randomUUID();
    await writeFile(temp, JSON.stringify(custom, null, 2) + '\n', { mode: 0o600 }); await rename(temp, file);
    return commands(repo);
  });
}

export async function startCommand(repo, { id, revision, snapshot }) {
  if (pending.has(repo) || [...jobs.values()].some(job => job.repo === repo && job.state === 'running')) throw new Error('此仓库已有命令正在执行。');
  for (const [key, job] of jobs) if (job.state !== 'running' && Date.now() - job.ended > 3600000) jobs.delete(key);
  if (jobs.size >= 100) throw new Error('命令任务过多，请稍后再试。');
  pending.add(repo);
  return new Promise((resolve, reject) => {
    exclusive(repo, async () => {
      const config = await commands(repo), before = await status(repo);
      if (config.revision !== revision) throw new Error('命令配置已变化，请重新确认。');
      if (before.snapshot !== snapshot) throw new Error('仓库已变化，请刷新后再执行。');
      const definition = config.commands.find(item => item.id === id);
      if (!definition) throw new Error('找不到此按钮。');
      if (definition.clean && !before.clean) throw new Error('Pull 前请提交或另行保存工作区改动。');
      const job = { id: randomUUID(), repo, label: definition.label, command: definition.command, state: 'running', output: '', truncated: false, started: Date.now(), exitCode: null };
      jobs.set(job.id, job);
      const env = Object.fromEntries(Object.entries(process.env).filter(([key]) => !key.startsWith('GIT_')));
      Object.assign(env, { GIT_TERMINAL_PROMPT: '0', GIT_SSH_COMMAND: 'ssh -o BatchMode=yes', LC_ALL: 'C' });
      // Commands are explicitly authored in the user's plugin settings; repository text is never executed as configuration.
      const child = spawn('/bin/sh', ['-c', definition.command], { cwd: repo, env, stdio: ['ignore', 'pipe', 'pipe'], detached: true });
      job.stop = () => { try { process.kill(-child.pid, 'SIGTERM'); } catch {};
        const force = setTimeout(() => { try { process.kill(-child.pid, 'SIGKILL'); } catch {} }, 1000); force.unref(); };
      const append = text => { text = String(text); const remaining = 200000 - job.output.length; if (text.length > remaining) job.truncated = true; job.output += text.slice(0, remaining); };
      child.stdout.setEncoding('utf8'); child.stderr.setEncoding('utf8');
      child.stdout.on('data', append); child.stderr.on('data', append);
      const timer = setTimeout(() => { job.timedOut = true; job.stop(); }, 120000);
      resolve(publicJob(job));
      await new Promise(done => {
        let settled = false;
        const finish = (code, error) => {
          if (settled) return; settled = true; clearTimeout(timer);
          job.exitCode = code; job.state = job.cancelRequested ? 'cancelled' : job.timedOut ? 'timed_out' : code === 0 ? 'succeeded' : 'failed';
          if (error) append(error.message); job.ended = Date.now(); delete job.stop; done();
        };
        child.on('error', error => finish(null, error)); child.on('close', code => finish(code));
      });
    }).catch(reject).finally(() => pending.delete(repo));
  });
}
function publicJob(job) { const { stop, cancelRequested, ...result } = job; return result; }
export function commandStatus(repo, id) {
  const job = jobs.get(id); if (!job || job.repo !== repo) throw new Error('命令任务不存在或不属于此仓库。');
  return publicJob(job);
}
export function cancelCommand(repo, id) {
  const job = jobs.get(id); if (!job || job.repo !== repo) throw new Error('命令任务不存在。');
  if (job.state === 'running') { job.cancelRequested = true; job.stop(); }
  return publicJob(job);
}

export function stopCommands() {
  for (const job of jobs.values()) if (job.state === 'running') { job.cancelRequested = true; job.stop(); }
}
