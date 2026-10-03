import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, realpath, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { git, status } from '../src/git.mjs';
import { commands, configureCommand, startCommand, commandStatus, cancelCommand } from '../src/commands.mjs';
const delay=ms=>new Promise(resolve=>setTimeout(resolve,ms));
async function finished(repo,id){for(let i=0;i<200;i++){const job=commandStatus(repo,id);if(job.state!=='running')return job;await delay(20);}throw new Error('Command did not finish');}
test('custom commands, stale config, cancellation and local remote pull/push',async t=>{
 const root=await realpath(await mkdtemp(path.join(tmpdir(),'raygit-command-'))); process.env.RAYGIT_CONFIG_DIR=path.join(root,'config');t.after(()=>rm(root,{recursive:true,force:true}));
 await git(root,['init','--bare','remote.git']); await git(root,['clone',path.join(root,'remote.git'),'repo']);const repo=path.join(root,'repo');
 for(const [k,v] of [['user.name','Test'],['user.email','test@example.invalid'],['commit.gpgsign','false'],['core.hooksPath','/dev/null']])await git(repo,['config',k,v]);
 await writeFile(path.join(repo,'file'),'one');await git(repo,['add','.']);await git(repo,['commit','-m','Initial']);await git(repo,['push','-u','origin','HEAD']);
 let config=await commands(repo);const first=config;
 config=await configureCommand(repo,{revision:config.revision,label:'Status',command:'git status --short'});
 await assert.rejects(configureCommand(repo,{revision:first.revision,label:'Old',command:'true'}),/已变化/);
 const run=async id=>startCommand(repo,{id,revision:config.revision,snapshot:(await status(repo)).snapshot});
 const job=await run(config.commands.at(-1).id); assert.equal((await finished(repo,job.id)).state,'succeeded');
 for(const id of ['fetch','pull','push'])assert.equal((await finished(repo,(await run(id)).id)).state,'succeeded');
 config=await configureCommand(repo,{revision:config.revision,label:'Fail',command:'echo output; exit 7'});
 const fail=await finished(repo,(await run(config.commands.at(-1).id)).id);assert.equal(fail.exitCode,7);assert.match(fail.output,/output/);
 config=await configureCommand(repo,{revision:config.revision,label:'Wait',command:'sleep 30'});
 const wait=await run(config.commands.at(-1).id);await assert.rejects(run('fetch'),/已有命令/);cancelCommand(repo,wait.id);assert.equal((await finished(repo,wait.id)).state,'cancelled');
 await writeFile(path.join(repo,'dirty'),'dirty');await assert.rejects(run('pull'),/保存工作区/);
 const stale=(await status(repo)).snapshot;await writeFile(path.join(repo,'dirty'),'changed');await assert.rejects(startCommand(repo,{id:'push',revision:config.revision,snapshot:stale}),/已变化/);
});
