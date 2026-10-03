import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm, realpath } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { setTimeout as sleep } from 'node:timers/promises';
import { openTerminal, readTerminal, inputTerminal, resizeTerminal, closeTerminal, stopTerminals } from '../src/terminal.mjs';

test('interactive PTYs preserve cwd, isolate input, resize, interrupt, exit and close', async t => {
  const root = await realpath(await mkdtemp(path.join(tmpdir(), 'raygit-terminal-')));
  t.after(() => { stopTerminals(); return rm(root, { recursive: true, force: true }); });
  const oldShell = process.env.SHELL; process.env.SHELL = '/bin/sh';
  const a = openTerminal(root), b = openTerminal(tmpdir());
  process.env.SHELL = oldShell;
  async function until(item, check) {
    for (let n = 0; n < 100; n++) { const data = readTerminal(item.repo, { id: item.id }); if (check(data)) return data; await sleep(30); }
    assert.fail('Terminal output timeout');
  }
  inputTerminal(root, { id: a.id, data: 'printf "\\nROOT:%s\\n" "$PWD"\r' });
  await until(a, data => data.output.includes('ROOT:' + root));
  assert.throws(() => inputTerminal(tmpdir(), { id: a.id, data: 'echo wrong\r' }), /不属于/);
  resizeTerminal(root, { id: a.id, cols: 91, rows: 27 });
  inputTerminal(root, { id: a.id, data: 'stty size\r' });
  const sized = await until(a, data => data.output.includes('27 91'));
  assert.equal(readTerminal(root, { id: a.id, cursor: sized.cursor }).output, '');
  inputTerminal(root, { id: a.id, data: 'sleep 10\r' }); await sleep(80);
  inputTerminal(root, { id: a.id, data: '\x03' }); await sleep(80);
  inputTerminal(root, { id: a.id, data: 'printf "\\n%s\\n" alive-after-interrupt\r' });
  await until(a, data => /\r?\nalive-after-interrupt\r?\n/.test(data.output));
  assert.equal(readTerminal(b.repo, { id: b.id }).output.includes('alive-after-interrupt'), false);
  inputTerminal(root, { id: a.id, data: 'exit 7\r' });
  await until(a, data => data.exitCode === 7);
  assert.throws(() => inputTerminal(root, { id: a.id, data: 'x' }), /退出/);
  closeTerminal(root, { id: a.id }); closeTerminal(b.repo, { id: b.id });
  assert.throws(() => readTerminal(root, { id: a.id }), /已关闭/);
});
