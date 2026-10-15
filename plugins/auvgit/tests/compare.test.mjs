import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, realpath, writeFile, readFile, rm, chmod, stat, symlink, rename, mkdir } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { git } from '../src/git.mjs';
import { comparison, saveComparison } from '../src/compare.mjs';
async function fixture(t, content = 'first\nsecond\n') {
  const repo = await realpath(await mkdtemp(path.join(tmpdir(), 'auvgit-compare-')));
  t.after(() => rm(repo, { recursive: true, force: true }));
  await git(repo, ['init', '-b', 'main']);
  for (const [k,v] of [['user.name','Test'],['user.email','test@example.invalid'],['commit.gpgsign','false'],['core.hooksPath','/dev/null']]) await git(repo,['config',k,v]);
  await writeFile(path.join(repo,'file.txt'),content); await git(repo,['add','.']); await git(repo,['commit','-m','Initial']); return repo;
}
async function save(repo, text, extra = {}) { return saveComparison(repo, { file:'file.txt', token:(await comparison(repo,'file.txt')).token, text, ...extra }); }
test('worktree and partial index edits remain isolated', async t => {
  const repo = await fixture(t);
  await save(repo,'work\nsecond\n');
  assert.equal((await git(repo,['show',':file.txt'])).stdout,'first\nsecond\n');
  await save(repo,'index\nsecond\n',{target:'index'});
  assert.equal(await readFile(path.join(repo,'file.txt'),'utf8'),'work\nsecond\n');
  assert.equal((await git(repo,['show',':file.txt'])).stdout,'index\nsecond\n');
});
test('same-size external edit and index mode changes invalidate comparison token', async t => {
  const repo=await fixture(t); const old=await comparison(repo,'file.txt');
  await writeFile(path.join(repo,'file.txt'),'other\nsecond\n');
  await assert.rejects(saveComparison(repo,{file:'file.txt',token:old.token,text:'overwrite'}),/外部修改/);
  const next=await comparison(repo,'file.txt'); await git(repo,['update-index','--chmod=+x','file.txt']);
  await assert.rejects(saveComparison(repo,{file:'file.txt',token:next.token,text:'overwrite'}),/外部修改/);
});
test('UTF-8 BOM, CRLF and executable mode survive save', async t => {
  const repo=await fixture(t,'\ufeffone\r\ntwo\r\n'); await chmod(path.join(repo,'file.txt'),0o755);
  await save(repo,'one\nnew\n');
  assert.equal(await readFile(path.join(repo,'file.txt'),'utf8'),'\ufeffone\r\nnew\r\n');
  assert.equal((await stat(path.join(repo,'file.txt'))).mode & 0o777,0o755);
});
test('binary, oversized, mixed EOL and symbolic links cannot be overwritten', async t => {
  const repo=await fixture(t);
  for(const bytes of [Buffer.from([0,255]),Buffer.alloc(2100000,65),Buffer.from('a\r\nb\n')]) {
    await writeFile(path.join(repo,'file.txt'),bytes); const data=await comparison(repo,'file.txt'); assert.equal(data.versions.worktree.editable,false);
    await assert.rejects(saveComparison(repo,{file:'file.txt',token:data.token,text:'oops'})); assert.deepEqual(await readFile(path.join(repo,'file.txt')),bytes);
  }
  await symlink('/etc/passwd',path.join(repo,'link'));
  await assert.rejects(comparison(repo,'link'),/符号链接/);
  await assert.rejects(comparison(repo,'../outside'),/仓库内/);
});
test('renamed file uses original HEAD and new executable index preserves mode', async t => {
  const repo=await fixture(t); await rename(path.join(repo,'file.txt'),path.join(repo,'renamed.txt')); await git(repo,['add','-A']);
  assert.equal((await comparison(repo,'renamed.txt')).versions.head.text,'first\nsecond\n');
  await writeFile(path.join(repo,'new.sh'),'echo hello\n'); await chmod(path.join(repo,'new.sh'),0o755);
  const data=await comparison(repo,'new.sh'); await saveComparison(repo,{file:'new.sh',token:data.token,target:'index',text:'echo partial\n'});
  assert.match((await git(repo,['ls-files','--stage','new.sh'])).stdout,/100755/);
});
test('conflict versions and explicit resolution; unresolved marker save is atomic', async t => {
  const repo=await fixture(t); await git(repo,['switch','-c','other']); await writeFile(path.join(repo,'file.txt'),'theirs\n'); await git(repo,['commit','-am','theirs']);
  await git(repo,['switch','main']); await writeFile(path.join(repo,'file.txt'),'ours\n'); await git(repo,['commit','-am','ours']); await git(repo,['merge','other'],{allowFailure:true});
  const data=await comparison(repo,'file.txt'); assert.equal(data.conflict,true); assert.equal(data.versions.ours.text,'ours\n'); assert.equal(data.versions.theirs.text,'theirs\n');
  const before=await readFile(path.join(repo,'file.txt'));
  await assert.rejects(save(repo,'<<<<<<< unresolved\n',{stage:true}),/冲突标记/); assert.deepEqual(await readFile(path.join(repo,'file.txt')),before);
  await save(repo,'resolved\n',{stage:true}); assert.equal((await comparison(repo,'file.txt')).conflict,false); assert.equal((await git(repo,['show',':file.txt'])).stdout,'resolved\n');
});

test('deleted directories remain comparable and a saved draft restores the file', async t => {
  const repo=await fixture(t);await mkdir(path.join(repo,'nested'));await writeFile(path.join(repo,'nested/deleted.txt'),'before\n');await git(repo,['add','.']);await git(repo,['commit','-m','Nested']);await rm(path.join(repo,'nested'),{recursive:true});
  const data=await comparison(repo,'nested/deleted.txt');assert.equal(data.versions.worktree.exists,false);assert.equal(data.versions.index.text,'before\n');
  await saveComparison(repo,{file:'nested/deleted.txt',token:data.token,text:'restored\n'});assert.equal(await readFile(path.join(repo,'nested/deleted.txt'),'utf8'),'restored\n');
});
