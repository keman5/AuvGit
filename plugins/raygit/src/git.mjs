import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { createReadStream } from 'node:fs';
import { lstat, readlink, realpath } from 'node:fs/promises';
import path from 'node:path';

const MAX_OUTPUT = 16 * 1024 * 1024;
const locks = new Map();

export function git(repo, args, { allowFailure = false, timeout = 30000 } = {}) {
  return new Promise((resolve, reject) => {
    const env = Object.fromEntries(Object.entries(process.env).filter(([key]) => !key.startsWith('GIT_')));
    Object.assign(env, { GIT_TERMINAL_PROMPT: '0', GIT_OPTIONAL_LOCKS: '0', LC_ALL: 'C', GIT_LITERAL_PATHSPECS: '1' });
    const child = spawn('git', ['--no-pager', '-c', 'color.ui=false', '-c', 'core.quotepath=false', '-C', repo, ...args], {
      env, stdio: ['ignore', 'pipe', 'pipe'], detached: process.platform !== 'win32',
    });
    const out = [], err = [];
    let bytes = 0, failure;
    const stop = message => {
      failure = new Error(message);
      try { process.platform === 'win32' ? child.kill('SIGKILL') : process.kill(-child.pid, 'SIGKILL'); } catch {}
    };
    const timer = setTimeout(() => stop('Git 操作超时。请刷新仓库确认实际结果，再决定是否重试。'), timeout);
    for (const [stream, chunks] of [[child.stdout, out], [child.stderr, err]]) {
      stream.on('data', chunk => {
        bytes += chunk.length;
        if (bytes > MAX_OUTPUT) stop('Git 输出超过 16 MiB；请选择单个文件或更小的历史范围。');
        else chunks.push(chunk);
      });
    }
    child.on('error', error => { clearTimeout(timer); reject(error); });
    child.on('close', code => {
      clearTimeout(timer);
      const result = { code, stdout: Buffer.concat(out).toString('utf8'), stderr: Buffer.concat(err).toString('utf8') };
      if (failure) reject(failure);
      else if (code !== 0 && !allowFailure) reject(new Error(result.stderr.trim() || `Git 操作失败 (${code})`));
      else resolve(result);
    });
  });
}

export async function repository(input) {
  if (typeof input !== 'string' || !path.isAbsolute(input) || input.includes('\0')) throw new Error('请提供仓库的绝对路径。');
  const requested = await realpath(input);
  const check = await git(requested, ['rev-parse', '--is-inside-work-tree']);
  if (check.stdout.trim() !== 'true') throw new Error('需要包含工作区的 Git 仓库；暂不支持裸仓库。');
  const root = (await git(requested, ['rev-parse', '--show-toplevel'])).stdout.replace(/\r?\n$/, '');
  return realpath(root);
}

export function parseStatus(raw) {
  const records = raw.split('\0'), files = [];
  for (let i = 0; i < records.length && records[i]; i++) {
    const entry = records[i], x = entry[0], y = entry[1];
    const file = { path: entry.slice(3), index: x, worktree: y, untracked: x === '?', conflict: x === 'U' || y === 'U' || ['AA', 'DD'].includes(x + y) };
    if (x === 'R' || x === 'C' || y === 'R' || y === 'C') file.originalPath = records[++i];
    file.staged = ![' ', '?', '!'].includes(x);
    file.unstaged = ![' ', '!'].includes(y);
    files.push(file);
  }
  return files;
}

async function digestFile(hash, filename) {
  try {
    const stat = await lstat(filename);
    hash.update(String(stat.mode));
    if (stat.isSymbolicLink()) hash.update(await readlink(filename));
    else if (stat.isFile()) for await (const chunk of createReadStream(filename)) hash.update(chunk);
    else hash.update(`directory:${stat.mtimeMs}`);
  } catch (error) { if (error.code === 'ENOENT') hash.update('missing'); else throw error; }
}

export async function status(repo) {
  const [raw, head, branch, indexPath, tracking] = await Promise.all([
    git(repo, ['status', '--porcelain=v1', '-z', '--untracked-files=all']),
    git(repo, ['rev-parse', '--verify', 'HEAD'], { allowFailure: true }),
    git(repo, ['symbolic-ref', '--quiet', '--short', 'HEAD'], { allowFailure: true }),
    git(repo, ['rev-parse', '--git-path', 'index']),
    git(repo, ['rev-list', '--left-right', '--count', 'HEAD...@{upstream}'], { allowFailure: true }),
  ]);
  const files = parseStatus(raw.stdout);
  const hash = createHash('sha256').update(raw.stdout).update(head.stdout).update(branch.stdout);
  await digestFile(hash, path.resolve(repo, indexPath.stdout.replace(/\r?\n$/, '')));
  for (const name of [...new Set(files.flatMap(file => [file.path, file.originalPath].filter(Boolean)))].sort()) {
    hash.update('\0' + name + '\0');
    await digestFile(hash, path.join(repo, name));
  }
  const [ahead, behind] = tracking.code === 0 ? tracking.stdout.trim().split(/\s+/).map(Number) : [null, null];
  return { repo, name: path.basename(repo), branch: branch.code === 0 ? branch.stdout.trim() : 'detached HEAD', head: head.code === 0 ? head.stdout.trim() : null,
    snapshot: hash.digest('hex'), files, ahead, behind, clean: files.length === 0 };
}

export async function history(repo, { offset = 0, limit = 60 } = {}) {
  const head = await git(repo, ['rev-parse', '--verify', 'HEAD'], { allowFailure: true });
  if (head.code !== 0) return { commits: [], offset, hasMore: false };
  const output = await git(repo, ['log', '--all', '--topo-order', `--skip=${offset}`, `--max-count=${limit + 1}`, '-z', '--format=%H%x00%P%x00%an%x00%aI%x00%D%x00%s']);
  const fields = output.stdout.split('\0');
  if (fields.at(-1) === '') fields.pop();
  const commits = [];
  for (let i = 0; i + 5 < fields.length; i += 6) commits.push({ oid: fields[i], parents: fields[i + 1].split(' ').filter(Boolean), author: fields[i + 2], date: fields[i + 3], refs: fields[i + 4], subject: fields[i + 5] });
  return { commits: commits.slice(0, limit), offset, hasMore: commits.length > limit };
}

export async function branches(repo) {
  const result = await git(repo, ['for-each-ref', '--sort=-committerdate', '--format=%(refname)%00%(refname:short)%00%(objectname)%00%(HEAD)%00%(upstream:short)', 'refs/heads', 'refs/remotes']);
  return { branches: result.stdout.split('\n').filter(Boolean).map(line => {
    const [ref, name, oid, current, upstream] = line.split('\0');
    return { ref, name, oid, current: current === '*', upstream, remote: ref.startsWith('refs/remotes/') };
  }) };
}

function filePath(value) {
  if (typeof value !== 'string' || !value || path.isAbsolute(value) || value.includes('\0') || value.split(/[\\/]/).some(part => part === '..' || part.toLowerCase() === '.git')) throw new Error('文件路径必须位于仓库内，不能包含 .. 或 .git。');
  return value;
}

async function oid(repo, value) {
  if (!/^[0-9a-f]{7,64}$/i.test(value || '')) throw new Error('请选择有效的提交 SHA。');
  return (await git(repo, ['rev-parse', '--verify', `${value}^{commit}`])).stdout.trim();
}

export async function diff(repo, { scope = 'working', file, commit } = {}) {
  if (file !== undefined) filePath(file);
  let result;
  if (scope === 'commit') {
    const revision = await oid(repo, commit);
    result = await git(repo, ['show', '--format=fuller', '--no-ext-diff', '--no-textconv', '--find-renames', '--stat', '--patch', revision, '--', ...(file ? [file] : [])]);
  } else {
    if (scope === 'working' && file) {
      const raw = await git(repo, ['status', '--porcelain=v1', '-z', '--untracked-files=all', '--', file]);
      const entry = parseStatus(raw.stdout).find(item => item.path === file);
      if (entry?.untracked) {
        // --no-index can follow symlinks. Display the target text instead of reading outside the repo.
        const stat = await lstat(path.join(repo, file));
        if (stat.isSymbolicLink()) return { repo, scope, file, text: `新符号链接 ${file}\n+${await readlink(path.join(repo, file))}`, truncated: false };
        result = await git(repo, ['diff', '--no-index', '--no-ext-diff', '--no-textconv', '--', '/dev/null', file], { allowFailure: true });
        if (![0, 1].includes(result.code)) throw new Error(result.stderr || '无法读取新文件。');
      }
    }
    result ??= await git(repo, ['diff', '--no-ext-diff', '--no-textconv', '--find-renames', ...(scope === 'staged' ? ['--cached'] : []), '--', ...(file ? [file] : [])]);
  }
  const max = 300000;
  return { repo, scope, file: file ?? null, commit: commit ?? null, text: result.stdout.slice(0, max), truncated: result.stdout.length > max };
}

async function exclusive(repo, action) {
  const previous = locks.get(repo) ?? Promise.resolve();
  let release;
  const current = new Promise(resolve => { release = resolve; });
  const queued = previous.catch(() => {}).then(() => current);
  locks.set(repo, queued);
  await previous.catch(() => {});
  try { return await action(); }
  finally { release(); if (locks.get(repo) === queued) locks.delete(repo); }
}

export async function mutate(repo, operation, args) {
  return exclusive(repo, async () => {
    const before = await status(repo);
    if (before.snapshot !== args.snapshot) throw new Error('仓库已被外部修改。请刷新后检查改动，再重试。');
    let result;
    if (operation === 'stage' || operation === 'unstage') {
      const paths = [...new Set((args.paths ?? []).map(filePath))];
      if (!paths.length) throw new Error('请至少选择一个文件。');
      const eligible = before.files.filter(file => operation === 'stage' ? file.unstaged : file.staged);
      const allowed = new Set(eligible.flatMap(file => [file.path, file.originalPath].filter(Boolean)));
      if (paths.some(name => !allowed.has(name))) throw new Error('所选文件状态已变化或不属于当前操作。请刷新。');
      for (const file of eligible) if (file.originalPath && (paths.includes(file.path) || paths.includes(file.originalPath))) {
        if (!paths.includes(file.path)) paths.push(file.path);
        if (!paths.includes(file.originalPath)) paths.push(file.originalPath);
      }
      result = operation === 'stage'
        ? await git(repo, ['add', '--', ...paths])
        : before.head
          ? await git(repo, ['reset', '-q', 'HEAD', '--', ...paths])
          : await git(repo, ['rm', '--cached', '-q', '--', ...paths]);
    } else if (operation === 'commit') {
      if (!args.message?.trim()) throw new Error('提交说明不能为空。');
      if (before.files.some(file => file.conflict)) throw new Error('存在未解决的冲突。');
      if (!before.files.some(file => file.staged)) throw new Error('没有已暂存的改动。');
      result = await git(repo, ['commit', '-m', args.message], { timeout: 60000 });
    } else if (operation === 'create_branch') {
      if (!args.name || args.name.startsWith('-')) throw new Error('无效分支名称。');
      await git(repo, ['check-ref-format', '--branch', args.name]);
      result = await git(repo, ['branch', '--', args.name]);
    } else if (operation === 'switch_branch') {
      if (!before.clean) throw new Error('切换分支前请提交或另行保存工作区改动。');
      const available = await branches(repo);
      if (!available.branches.some(branch => !branch.remote && branch.name === args.name)) throw new Error('请选择已有的本地分支。');
      result = await git(repo, ['switch', '--no-guess', '--', args.name]);
    } else throw new Error('不支持的操作。');
    return { ...(await status(repo)), notice: result.stdout.trim() || result.stderr.trim() || '操作已完成。' };
  });
}
