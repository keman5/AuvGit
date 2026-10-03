import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { readFile, writeFile, mkdir, rename, access } from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
import { homedir } from 'node:os';
import path from 'node:path';
import { repository, exclusive } from './git.mjs';

const workspaceFile = () => path.join(process.env.RAYGIT_CONFIG_DIR || path.join(homedir(), '.config/raygit'), 'workspace.json');
async function readWorkspace() {
  try {
    const data = JSON.parse(await readFile(workspaceFile(), 'utf8'));
    return { lastRepo: typeof data.lastRepo === 'string' ? data.lastRepo : null, recent: Array.isArray(data.recent) ? data.recent : [], catalog: Array.isArray(data.catalog) ? data.catalog : [] };
  } catch (error) { if (error.code === 'ENOENT') return { lastRepo: null, recent: [], catalog: [] }; throw new Error('无法读取 RayGit 项目记录。'); }
}
async function saveWorkspace(update) {
  const file = workspaceFile();
  return exclusive(file, async () => {
    const data = await update(await readWorkspace());
    await mkdir(path.dirname(file), { recursive: true, mode: 0o700 });
    const temp = file + '.' + randomUUID();
    await writeFile(temp, JSON.stringify(data) + '\n', { mode: 0o600 }); await rename(temp, file);
    return data;
  });
}

// Use Codex's read-only app-server API, not private desktop state or thread history.
export async function codexProjects(executable) {
  if (!executable) {
    executable = process.env.RAYGIT_CODEX_BIN;
    if (!executable) {
      for (const candidate of [path.join(homedir(), 'Library/pnpm/bin/codex'), '/opt/homebrew/bin/codex', '/usr/local/bin/codex']) {
        try { await access(candidate); executable = candidate; break; } catch {}
      }
    }
  }
  const child = spawn(executable || 'codex', ['app-server', '--stdio'], {
    cwd: homedir(), stdio: ['pipe', 'pipe', 'ignore'],
    env: { ...process.env, PATH: path.dirname(process.execPath) + path.delimiter + (process.env.PATH || ''), RUST_LOG: 'error' },
  });
  const lines = createInterface({ input: child.stdout });
  let next = 0, failure;
  const pending = new Map();
  const fail = error => { failure = error; for (const p of pending.values()) p.reject(error); pending.clear(); };
  child.on('error', fail); child.on('exit', () => fail(new Error('Codex 项目接口已退出。'))); child.stdin.on('error', fail);
  lines.on('line', line => {
    try {
      const msg = JSON.parse(line), request = pending.get(msg.id);
      if (!request) return;
      pending.delete(msg.id);
      if (msg.error) request.reject(new Error('Codex 项目接口暂不可用。')); else request.resolve(msg.result);
    } catch { fail(new Error('Codex 项目接口返回无效数据。')); }
  });
  const timer = setTimeout(() => { fail(new Error('读取 Codex 项目超时。')); child.kill('SIGKILL'); }, 8000);
  const rpc = (method, params) => new Promise((resolve, reject) => {
    if (failure) return reject(failure);
    const id = ++next; pending.set(id, { resolve, reject }); child.stdin.write(JSON.stringify({ id, method, params }) + '\n');
  });
  try {
    await rpc('initialize', { clientInfo: { name: 'raygit-project-picker', version: '1' }, capabilities: { experimentalApi: true } });
    child.stdin.write('{"method":"initialized"}\n');
    const result = [], cursors = new Set(); let cursor;
    do {
      const page = await rpc('project/list', { limit: 100, sortKey: 'position', ...(cursor ? { cursor } : {}) });
      if (!Array.isArray(page?.data)) throw new Error('Codex 项目列表格式不受支持。');
      for (const item of page.data) for (const root of item.roots || []) {
        if (typeof root.path !== 'string' || !path.isAbsolute(root.path) || root.path.includes('\0')) continue;
        result.push({ repo: root.path, name: typeof item.name === 'string' ? item.name : path.basename(root.path), origin: 'codex' });
      }
      cursor = page.nextCursor;
      if (cursor && cursors.has(cursor)) throw new Error('Codex 项目分页未前进。');
      cursors.add(cursor);
    } while (cursor);
    return result;
  } finally { clearTimeout(timer); lines.close(); child.stdin.end(); child.kill(); const force = setTimeout(() => { if (child.exitCode === null && child.signalCode === null) child.kill('SIGKILL'); }, 1000); force.unref(); }
}

export async function projectCatalog(hostProjects = [], { fetchProjects = codexProjects } = {}) {
  let saved, catalog, warning = null;
  try { saved = await readWorkspace(); } catch (error) { saved = { lastRepo: null, recent: [], catalog: [] }; warning = error.message; }
  try { catalog = await fetchProjects(); }
  catch { catalog = saved.catalog; warning = '暂时无法更新 Codex 项目列表，显示已保存的项目。'; }
  if (!warning) { try { await saveWorkspace(data => ({ ...data, catalog })); } catch (error) { warning = error.message; } }
  const unique = new Map();
  for (const item of [...catalog, ...hostProjects, ...saved.recent]) {
    if (typeof item?.repo !== 'string' || !path.isAbsolute(item.repo) || unique.has(item.repo)) continue;
    unique.set(item.repo, { repo: item.repo, name: item.name || path.basename(item.repo), origin: item.origin || 'recent' });
  }
  const projects = await Promise.all([...unique.values()].map(async item => {
    try { return { ...item, repo: await repository(item.repo), available: true }; }
    catch { return { ...item, available: false, reason: '目录不可用或不是 Git 仓库' }; }
  }));
  const canonical = [...new Map(projects.map(item => [item.repo, item])).values()];
  return { projects: canonical, lastRepo: saved.lastRepo, catalogWarning: warning };
}
export async function rememberProject(repo, name) {
  await saveWorkspace(data => ({ ...data, lastRepo: repo, recent: [{ repo, name, origin: 'recent' }, ...data.recent.filter(p => p.repo !== repo)].slice(0, 50) }));
}
export async function selectOpeningRepository(resolved, catalog) {
  if (resolved.source === 'roots' || resolved.source === 'explicit') return resolved;
  if (catalog.lastRepo) {
    try { return { repo: await repository(catalog.lastRepo), source: 'recent' }; } catch {}
  }
  return resolved;
}
