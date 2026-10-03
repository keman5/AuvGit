import { createHash, randomBytes } from 'node:crypto';
import { lstat, open, rename, unlink, realpath, mkdir } from 'node:fs/promises';
import { constants } from 'node:fs';
import path from 'node:path';
import { git, filePath, status, exclusive } from './git.mjs';

const MAX_TEXT = 2 * 1024 * 1024;
const hash = bytes => createHash('sha256').update(bytes).digest('hex');

async function safePath(repo, file) {
  filePath(file);
  const absolute = path.join(repo, file);
  let cursor = repo;
  for (const part of path.relative(repo, absolute).split(path.sep)) {
    cursor = path.join(cursor, part);
    try { if ((await lstat(cursor)).isSymbolicLink()) throw new Error('符号链接仅支持查看差异，不能打开编辑器。'); }
    catch (error) { if (error.code !== 'ENOENT') throw error; }
  }
  let parentPath = path.dirname(absolute), parent;
  while (true) {
    try { parent = await realpath(parentPath); break; }
    catch (error) { if (error.code !== 'ENOENT' || parentPath === repo) throw error; parentPath = path.dirname(parentPath); }
  }
  if (parent !== repo && !parent.startsWith(repo + path.sep)) throw new Error('文件必须位于仓库内。');
  return absolute;
}

function decode(bytes, metadata = {}) {
  const result = { exists: true, bytes: bytes.length, token: hash(bytes), editable: false, ...metadata };
  if (bytes.length > MAX_TEXT) return { ...result, reason: '超过 2 MiB，保留只读文件信息；请使用外部编辑器处理大文件。' };
  if (bytes.includes(0)) return { ...result, reason: '二进制或非 UTF-8 文件，不能按文本编辑。' };
  const bom = bytes.subarray(0, 3).equals(Buffer.from([0xef, 0xbb, 0xbf]));
  let text;
  try { text = new TextDecoder('utf-8', { fatal: true }).decode(bom ? bytes.subarray(3) : bytes); }
  catch { return { ...result, reason: '非 UTF-8 文件，不能按文本编辑。' }; }
  const crlf = (text.match(/\r\n/g) || []).length;
  const bare = text.replace(/\r\n/g, '');
  const mixed = (crlf > 0 && bare.includes('\n')) || bare.includes('\r');
  return { ...result, text: text.replace(/\r\n/g, '\n'), bom, eol: crlf ? 'CRLF' : 'LF', editable: !mixed,
    ...(mixed ? { reason: '文件含混合换行；为保留字节格式，只读显示。' } : {}) };
}

async function working(repo, file) {
  const absolute = await safePath(repo, file);
  let stat;
  try { stat = await lstat(absolute); }
  catch (error) { if (error.code === 'ENOENT') return { exists: false, text: '', token: 'missing', mode: 0o644, editable: true, bom: false, eol: 'LF', bytes: 0 }; throw error; }
  if (!stat.isFile()) throw new Error('只支持普通文件，不支持目录或子模块编辑。');
  const handle = await open(absolute, constants.O_RDONLY | constants.O_NOFOLLOW);
  try {
    const opened = await handle.stat();
    if (stat.ino !== opened.ino || stat.dev !== opened.dev) throw new Error('文件正在被替换，请重新加载。');
    if (stat.size > MAX_TEXT) return { exists: true, bytes: stat.size, mode: stat.mode & 0o777, editable: false, reason: '超过 2 MiB，保留只读文件信息。' };
    const bytes = await handle.readFile();
    return decode(bytes, { mode: stat.mode & 0o777 });
  } finally { await handle.close(); }
}

async function blob(repo, spec, mode) {
  const result = await git(repo, ['rev-parse', '--verify', spec], { allowFailure: true });
  if (result.code !== 0) return { exists: false, text: '', token: 'missing', editable: true, bom: false, eol: 'LF', bytes: 0, mode: mode || '100644' };
  const oid = result.stdout.trim();
  const type = (await git(repo, ['cat-file', '-t', oid])).stdout.trim();
  if (type !== 'blob') return { exists: true, editable: false, reason: '此版本不是普通文件。', oid };
  const size = Number((await git(repo, ['cat-file', '-s', oid])).stdout.trim());
  if (size > MAX_TEXT) return { exists: true, bytes: size, editable: false, reason: '超过 2 MiB，保留只读文件信息。', oid };
  const bytes = (await git(repo, ['cat-file', 'blob', oid], { binary: true })).stdout;
  return decode(bytes, { oid, mode: mode || '100644' });
}

export async function comparison(repo, file) {
  filePath(file);
  const state = await status(repo);
  const headPath = state.files.find(item => item.path === file)?.originalPath || file;
  const entries = (await git(repo, ['ls-files', '--stage', '-z', '--', file])).stdout.split('\0').filter(Boolean).map(entry => {
    const tab = entry.indexOf('\t'); const [mode, oid, stage] = entry.slice(0, tab).split(' ');
    return { mode, oid, stage, path: entry.slice(tab + 1) };
  });
  if (entries.some(entry => ['120000', '160000'].includes(entry.mode))) throw new Error('符号链接和子模块不支持文本编辑。');
  const conflicts = entries.some(entry => entry.stage !== '0');
  const versions = {};
  const definitions = [['head', 'HEAD:' + headPath], ['index', ':' + file], ...(conflicts ? [['base', ':1:' + file], ['ours', ':2:' + file], ['theirs', ':3:' + file]] : [])];
  await Promise.all(definitions.map(async ([name, spec]) => { versions[name] = await blob(repo, spec, entries.find(entry => entry.stage === ({ index: '0', base: '1', ours: '2', theirs: '3' }[name]))?.mode); }));
  versions.worktree = await working(repo, file);
  return { repo, file, versions, conflict: conflicts, snapshot: state.snapshot,
    token: hash(JSON.stringify({ head: versions.head.oid, index: versions.index.oid, indexMode: versions.index.mode, conflict: entries.filter(entry => entry.stage !== '0'), worktree: versions.worktree.token, mode: versions.worktree.mode })) };
}

function encode(text, original) {
  if (text.includes('\0')) throw new Error('不能保存含 NUL 的文本。');
  const normalized = text.replace(/\r\n/g, '\n');
  if (normalized.includes('\r')) throw new Error('不支持独立 CR 换行。');
  const bytes = Buffer.from((original.bom ? '\ufeff' : '') + (original.eol === 'CRLF' ? normalized.replace(/\n/g, '\r\n') : normalized), 'utf8');
  if (bytes.length > MAX_TEXT) throw new Error('编辑结果超过 2 MiB。');
  return bytes;
}

export async function saveComparison(repo, { file, token, target = 'worktree', text, stage = false }) {
  return exclusive(repo, async () => {
    const current = await comparison(repo, file);
    if (current.token !== token) throw new Error('文件、索引或 HEAD 已被外部修改。草稿已保留，请重新加载后比较。');
    const original = current.versions[target];
    if (!original?.editable) throw new Error(original?.reason || '此版本不能编辑。');
    if (target === 'index' && current.conflict) throw new Error('请编辑工作区合并结果，保存后显式标记解决。');
    if (stage && /^(<<<<<<< |=======|>>>>>>> )/m.test(text)) throw new Error('仍有冲突标记，尚未保存或暂存。');
    const bytes = encode(text, original);
    if (target === 'index') {
      const blobId = (await git(repo, ['hash-object', '-w', '--stdin'], { input: bytes })).stdout.trim();
      const mode = original.exists ? original.mode : ((current.versions.worktree.mode & 0o111) ? '100755' : '100644');
      await git(repo, ['update-index', '-z', '--index-info'], { input: `${mode} ${blobId}\t${file}\0` });
    } else {
      const absolute = await safePath(repo, file);
      await mkdir(path.dirname(absolute), { recursive: true });
      await safePath(repo, file);
      const temporary = path.join(path.dirname(absolute), `.raygit-save-${randomBytes(12).toString('hex')}`);
      const handle = await open(temporary, 'wx', original.mode || 0o644);
      try {
        await handle.writeFile(bytes); await handle.chmod(original.mode || 0o644); await handle.sync(); await handle.close();
        // Recheck immediately before replacing; never write through a symlink.
        await safePath(repo, file);
        if ((await working(repo, file)).token !== original.token) throw new Error('保存前文件已变化，草稿保留。');
        await rename(temporary, absolute);
      } catch (error) { await handle.close().catch(() => {}); throw error; }
      finally { await unlink(temporary).catch(() => {}); }
      if (stage) {
        await git(repo, ['add', '--', file]);
      }
    }
    return { ...(await comparison(repo, file)), notice: target === 'index' ? '已保存到索引，工作区未改变。' : stage ? '已保存并暂存。' : '已保存工作区，索引未改变。' };
  });
}
