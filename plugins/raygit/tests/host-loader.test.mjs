import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { once } from 'node:events';
import { createInterface } from 'node:readline';
import { cp, mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';

const hasCodex = spawnSync('codex', ['--version']).status === 0;

test('Codex loads the portable MCP config and rejects the former unsupported fields', {
  skip: hasCodex ? false : 'Codex CLI is required for host loader verification',
  timeout: 60_000,
}, async t => {
  const root = await mkdtemp(path.join(tmpdir(), 'raygit-host-loader-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const config = JSON.parse(await readFile('mcp.json', 'utf8'));
  async function fixture(name, mcp) {
    const market = path.join(root, name);
    const plugin = path.join(market, 'plugins/raygit');
    await mkdir(plugin, { recursive: true });
    for (const entry of ['plugin.json', '.codex-plugin', '.mcp.json', 'assets', 'skills']) {
      await cp(entry, path.join(plugin, entry), { recursive: true });
    }
    await writeFile(path.join(plugin, 'mcp.json'), JSON.stringify(mcp));
    await mkdir(path.join(market, '.agents/plugins'), { recursive: true });
    const marketplacePath = path.join(market, '.agents/plugins/marketplace.json');
    await writeFile(marketplacePath, JSON.stringify({ name: `raygit-test-${name}`, plugins: [{
      name: 'raygit', source: { source: 'local', path: './plugins/raygit' },
    }] }));
    return marketplacePath;
  }
  const validPath = await fixture('valid', config);
  const formerConfig = structuredClone(config);
  Object.assign(formerConfig.mcpServers.raygit, { env_vars: ['PATH'], tool_timeout_sec: 90 });
  const invalidPath = await fixture('invalid', formerConfig);
  const absoluteCommand = structuredClone(config);
  absoluteCommand.mcpServers.raygit.command = '/bin/sh';
  const absolutePath = await fixture('absolute-command', absoluteCommand);
  const child = spawn('codex', ['app-server', '--stdio'], {
    stdio: ['pipe', 'pipe', 'pipe'], env: { ...process.env, RUST_LOG: 'warn' },
  });
  let diagnostics = '';
  child.stderr.on('data', chunk => { diagnostics = (diagnostics + chunk).slice(-16_000); });
  const lines = createInterface({ input: child.stdout });
  const pending = new Map();
  let nextId = 0;
  lines.on('line', line => {
    const message = JSON.parse(line);
    const request = pending.get(message.id);
    if (!request) return;
    pending.delete(message.id);
    clearTimeout(request.timer);
    if (message.error) request.reject(new Error(JSON.stringify(message.error)));
    else request.resolve(message.result);
  });
  t.after(async () => {
    for (const request of pending.values()) clearTimeout(request.timer);
    lines.close();
    if (child.exitCode === null && child.signalCode === null) {
      const exited = once(child, 'exit');
      child.kill();
      const timer = setTimeout(() => child.kill('SIGKILL'), 3000);
      await exited;
      clearTimeout(timer);
    }
  });
  function rpc(method, params) {
    return new Promise((resolve, reject) => {
      const id = ++nextId;
      const timer = setTimeout(() => { pending.delete(id); reject(new Error(`${method} timed out`)); }, 15_000);
      pending.set(id, { resolve, reject, timer });
      child.stdin.write(JSON.stringify({ id, method, params }) + '\n');
    });
  }
  await rpc('initialize', { clientInfo: { name: 'raygit-loader-test', version: '1' }, capabilities: { experimentalApi: true } });
  child.stdin.write('{"method":"initialized"}\n');
  const read = marketplacePath => rpc('plugin/read', { marketplacePath, pluginName: 'raygit' });
  assert.deepEqual((await read(validPath)).plugin.mcpServers, ['raygit'], diagnostics);
  assert.deepEqual((await read(invalidPath)).plugin.mcpServers, []);
  assert.deepEqual((await read(absolutePath)).plugin.mcpServers, []);
});
