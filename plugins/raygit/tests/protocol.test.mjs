import test from 'node:test';
import assert from 'node:assert/strict';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';
import { mkdtemp, rm, readFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { projectFixture } from './helpers/project-fixture.mjs';
import { invoke } from '../src/tools.mjs';

test('built artifact speaks real MCP over stdio and advertises an interactive resource', async t => {
  const directory = await mkdtemp(path.join(tmpdir(), 'raygit-protocol-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const executable = await projectFixture(directory, []);
  const client = new Client({ name: 'raygit-verifier', version: '1.0.0' });
  const transport = new StdioClientTransport({ command: '/bin/sh', args: ['scripts/start.sh'], stderr: 'pipe', env: { RAYGIT_CONFIG_DIR: directory, RAYGIT_CODEX_BIN: executable } });
  await client.connect(transport); t.after(() => client.close());
  const { tools } = await client.listTools();
  assert.equal(tools.length, 23);
  const open = tools.find(tool => tool.name === 'raygit_open');
  assert.equal(open._meta.ui.resourceUri, 'ui://raygit/workspace.html');
  assert.deepEqual(open._meta['openai/ui'].entrypoints, [{ type: 'global' }, { type: 'thread' }]);
  assert.equal(open.title, 'RayGit');
  const icon = client.getServerVersion().icons[0];
  assert.equal(icon.mimeType, 'image/svg+xml');
  assert.match(Buffer.from(icon.src.split(',')[1], 'base64').toString(), /currentColor/);
  assert.equal(tools.find(tool => tool.name === 'raygit_commit').annotations.readOnlyHint, false);
  const result = await client.callTool({ name: 'raygit_open', arguments: {} });
  assert.equal(result.structuredContent.needsRepository, true);
  const resource = await client.readResource({ uri: open._meta.ui.resourceUri });
  assert.equal(resource.contents[0].mimeType, 'text/html;profile=mcp-app');
  assert.deepEqual(resource.contents[0]._meta['openai/ui'].availableDisplayModes, ['fullscreen']);
  assert.ok(resource.contents[0].text.includes('创建提交'));
  assert.ok(!resource.contents[0].text.includes('/* RAYGIT_SCRIPT */'));
});

test('invalid requests return visible errors without a server crash', async () => {
  assert.equal((await invoke('raygit_stage', { repo: '/tmp', paths: [] })).isError, true);
  assert.equal((await invoke('raygit_status', { repo: 'relative' })).isError, true);
  assert.equal((await invoke('raygit_no_such_tool', {})).isError, true);
});

test('portable and compatibility manifests agree', async () => {
  const portable = JSON.parse(await readFile('plugin.json', 'utf8'));
  const compat = JSON.parse(await readFile('.codex-plugin/plugin.json', 'utf8'));
  assert.equal(portable.name, compat.name); assert.equal(portable.version, compat.version);
  assert.deepEqual(portable.extensions['com.openai'].interface, compat.interface);
  assert.ok(portable.extensions['com.openai'].interface.shortDescription.length <= 30);
});
