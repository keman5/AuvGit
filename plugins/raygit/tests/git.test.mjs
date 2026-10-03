import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile, readFile, rm, rename, symlink, realpath } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { git, repository, status, history, branches, diff, mutate } from '../src/git.mjs';

async function fixture(t, initial = true) {
  const directory = await realpath(await mkdtemp(path.join(tmpdir(), 'raygit-plugin-test-')));
  t.after(() => rm(directory, { recursive: true, force: true }));
  await git(directory, ['init', '-b', 'main']);
  await git(directory, ['config', 'user.name', 'RayGit Test']);
  await git(directory, ['config', 'user.email', 'raygit-test@example.invalid']);
  await git(directory, ['config', 'commit.gpgsign', 'false']);
  await git(directory, ['config', 'core.hooksPath', '/dev/null']);
  if (initial) {
    await writeFile(path.join(directory, 'tracked.txt'), 'original\n');
    await git(directory, ['add', '--', 'tracked.txt']);
    await git(directory, ['commit', '-m', 'Initial commit']);
  }
  return directory;
}
const update = async (repo, operation, extra) => mutate(repo, operation, { snapshot: (await status(repo)).snapshot, ...extra });

test('exact paths, spaces/newlines/pathspec metacharacters, and commit only the index', async t => {
  const repo = await fixture(t);
  const names = ['space name.txt', 'line\nbreak.txt', '-option.txt', ':(glob)*', 'untouched.txt'];
  for (const name of names) await writeFile(path.join(repo, name), 'new\n');
  const initial = await status(repo);
  assert.equal(initial.files.length, 5);
  await update(repo, 'stage', { paths: [':(glob)*', 'space name.txt', 'line\nbreak.txt', '-option.txt'] });
  assert.equal((await status(repo)).files.filter(file => file.staged).length, 4);
  await update(repo, 'commit', { message: 'Selected changes\n\nKeep unrelated work.' });
  assert.deepEqual((await status(repo)).files.map(file => file.path), ['untouched.txt']);
  assert.equal((await history(repo)).commits[0].subject, 'Selected changes');
  assert.match((await diff(repo, { scope: 'commit', commit: (await status(repo)).head })).text, /Selected changes/);
});

test('stale snapshot rejects content changes even when status stays identical', async t => {
  const repo = await fixture(t);
  await writeFile(path.join(repo, 'tracked.txt'), 'first\n');
  const first = await status(repo);
  await writeFile(path.join(repo, 'tracked.txt'), 'other\n');
  assert.deepEqual(first.files, (await status(repo)).files);
  await assert.rejects(mutate(repo, 'stage', { paths: ['tracked.txt'], snapshot: first.snapshot }), /外部修改/);
  assert.equal((await status(repo)).files[0].staged, false);
});

test('unstage works before first commit and preserves later working edits', async t => {
  const repo = await fixture(t, false);
  assert.equal((await history(repo)).commits.length, 0);
  await writeFile(path.join(repo, 'new.txt'), 'one\n');
  await update(repo, 'stage', { paths: ['new.txt'] });
  await writeFile(path.join(repo, 'new.txt'), 'two\n');
  await update(repo, 'unstage', { paths: ['new.txt'] });
  assert.equal(await readFile(path.join(repo, 'new.txt'), 'utf8'), 'two\n');
  assert.equal((await status(repo)).files[0].untracked, true);
  await update(repo, 'stage', { paths: ['new.txt'] });
  await update(repo, 'commit', { message: 'First' });
  assert.equal((await status(repo)).clean, true);
});

test('tracked modifications retain both staged and unstaged contents', async t => {
  const repo = await fixture(t);
  await writeFile(path.join(repo, 'tracked.txt'), 'staged\n');
  await update(repo, 'stage', { paths: ['tracked.txt'] });
  await writeFile(path.join(repo, 'tracked.txt'), 'working\n');
  const state = await status(repo);
  assert.ok(state.files[0].staged && state.files[0].unstaged);
  assert.match((await diff(repo, { scope: 'staged', file: 'tracked.txt' })).text, /\+staged/);
  assert.match((await diff(repo, { file: 'tracked.txt' })).text, /\+working/);
  await update(repo, 'unstage', { paths: ['tracked.txt'] });
  assert.equal(await readFile(path.join(repo, 'tracked.txt'), 'utf8'), 'working\n');
});

test('staged rename is unstaged as a pair; deletion is staged without file reads failing', async t => {
  const repo = await fixture(t);
  await rename(path.join(repo, 'tracked.txt'), path.join(repo, 'renamed.txt'));
  await update(repo, 'stage', { paths: ['tracked.txt', 'renamed.txt'] });
  const state = await status(repo);
  assert.equal(state.files[0].originalPath, 'tracked.txt');
  await update(repo, 'unstage', { paths: ['renamed.txt'] });
  assert.ok((await status(repo)).files.every(file => !file.staged));
});

test('branch creation and clean-only switching', async t => {
  const repo = await fixture(t);
  await update(repo, 'create_branch', { name: 'feature/demo' });
  assert.equal((await status(repo)).branch, 'main');
  assert.ok((await branches(repo)).branches.some(branch => branch.name === 'feature/demo'));
  await writeFile(path.join(repo, 'tracked.txt'), 'dirty\n');
  await assert.rejects(update(repo, 'switch_branch', { name: 'feature/demo' }), /保存工作区/);
  await writeFile(path.join(repo, 'tracked.txt'), 'original\n');
  await update(repo, 'switch_branch', { name: 'feature/demo' });
  assert.equal((await status(repo)).branch, 'feature/demo');
  await assert.rejects(update(repo, 'create_branch', { name: '--delete' }), /无效分支/);
});

test('a staged rename can be edited and staged again', async t => {
  const repo = await fixture(t);
  await rename(path.join(repo, 'tracked.txt'), path.join(repo, 'renamed.txt'));
  await update(repo, 'stage', { paths: ['tracked.txt', 'renamed.txt'] });
  await writeFile(path.join(repo, 'renamed.txt'), 'original\nmore\n');
  await update(repo, 'stage', { paths: ['renamed.txt'] });
  assert.ok((await status(repo)).files.every(file => !file.unstaged));
  assert.equal((await git(repo, ['show', ':renamed.txt'])).stdout, 'original\nmore\n');
});

test('pagination does not skip or duplicate commits, includes parent links', async t => {
  const repo = await fixture(t);
  for (let i = 1; i <= 4; i++) await git(repo, ['commit', '--allow-empty', '-m', `Commit ${i}`]);
  const first = await history(repo, { offset: 0, limit: 2 });
  const next = await history(repo, { offset: 2, limit: 3 });
  assert.equal(first.hasMore, true); assert.equal(next.hasMore, false);
  assert.equal(new Set([...first.commits, ...next.commits].map(commit => commit.oid)).size, 5);
  assert.equal(first.commits[0].parents[0], first.commits[1].oid);
});

test('invalid paths/revisions rejected and symlink targets are not followed', async t => {
  const repo = await fixture(t);
  await assert.rejects(diff(repo, { file: '../outside' }), /仓库内/);
  await assert.rejects(diff(repo, { scope: 'commit', commit: '--all' }), /SHA/);
  await assert.rejects(repository('relative/path'), /绝对路径/);
  await assert.rejects(update(repo, 'stage', { paths: ['.git/config'] }), /仓库内/);
  await symlink('/etc/passwd', path.join(repo, 'link'));
  const result = await diff(repo, { file: 'link' });
  assert.match(result.text, /\/etc\/passwd/);
  assert.doesNotMatch(result.text, /root:/);
});

test('binary diff is reported without decoding file as text', async t => {
  const repo = await fixture(t);
  await writeFile(path.join(repo, 'binary.bin'), Buffer.from([0, 1, 2, 3, 255]));
  assert.match((await diff(repo, { file: 'binary.bin' })).text, /Binary files/);
});

test('parallel writes serialize and reject the second stale snapshot', async t => {
  const repo = await fixture(t);
  await writeFile(path.join(repo, 'a.txt'), 'a'); await writeFile(path.join(repo, 'b.txt'), 'b');
  const { snapshot } = await status(repo);
  const results = await Promise.allSettled(['a.txt', 'b.txt'].map(name => mutate(repo, 'stage', { snapshot, paths: [name] })));
  assert.equal(results.filter(result => result.status === 'fulfilled').length, 1);
  assert.equal((await status(repo)).files.filter(file => file.staged).length, 1);
});
