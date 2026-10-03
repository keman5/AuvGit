// Development-only MCP App host. It exposes only a disposable demo repository.
import http from 'node:http';
import { randomBytes } from 'node:crypto';
import { mkdtemp, mkdir, writeFile, readFile, realpath } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { build } from 'esbuild';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';
import { ListRootsRequestSchema } from '@modelcontextprotocol/sdk/types.js';
import { pathToFileURL } from 'node:url';
import { projectFixture } from '../tests/helpers/project-fixture.mjs';
import { git } from '../src/git.mjs';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const entrypointMode = process.argv.includes('--entrypoint');
const repo = await realpath(await mkdtemp(path.join(tmpdir(), 'raygit-ui-demo-')));
await git(repo, ['init', '-b', 'main']);
for (const [key, value] of [['user.name', 'RayGit Demo'], ['user.email', 'demo@example.invalid'], ['commit.gpgsign', 'false'], ['core.hooksPath', '/dev/null']]) await git(repo, ['config', key, value]);
await mkdir(path.join(repo, 'src'));
await writeFile(path.join(repo, 'README.md'), '# Atlas\n\nA quieter place for your projects.\n');
await writeFile(path.join(repo, 'src/workspace.ts'), 'export function openWorkspace(name: string) {\n  return { name, ready: false };\n}\n');
await git(repo, ['add', '.']); await git(repo, ['commit', '-m', 'Set up the workspace']);
await git(repo, ['switch', '-c', 'feature/history']);
await writeFile(path.join(repo, 'src/history.ts'), 'export const pageSize = 60;\n');
await git(repo, ['add', '.']); await git(repo, ['commit', '-m', 'Add paginated commit history']);
await git(repo, ['switch', 'main']);
await writeFile(path.join(repo, 'src/theme.ts'), 'export const accent = "#197b65";\n');
await git(repo, ['add', '.']); await git(repo, ['commit', '-m', 'Introduce the forest theme']);
await git(repo, ['merge', '--no-ff', 'feature/history', '-m', 'Merge history into workspace']);
await git(repo, ['branch', 'release/0.1']);
await writeFile(path.join(repo, 'src/workspace.ts'), 'export function openWorkspace(name: string) {\n  if (!name.trim()) throw new Error("Choose a repository");\n  return { name, ready: true, local: true };\n}\n');
await writeFile(path.join(repo, 'README.md'), '# Atlas\n\nA quieter place for your projects.\n\n## Getting started\nOpen a local repository to begin.\n');
await git(repo, ['add', 'README.md']);
await writeFile(path.join(repo, 'src/shortcuts.ts'), 'export const refresh = "Command+R";\n');
const secondRepo = await realpath(await mkdtemp(path.join(tmpdir(), 'raygit-second-project-')));
await git(secondRepo, ['init', '-b', 'develop']);
await writeFile(path.join(secondRepo, 'project-two.txt'), 'A separate project\n');
const fixtureCli = await projectFixture(path.join(repo, '.git'), [{ name: 'Atlas', roots: [{ path: repo }] }, { name: '第二个项目', roots: [{ path: secondRepo }] }]);
let currentRepo = repo;
const token = randomBytes(24).toString('hex');
const client = new Client({ name: 'raygit-preview-host', version: '0.1.0' }, { capabilities: { roots: { listChanged: true } } });
client.setRequestHandler(ListRootsRequestSchema, async () => ({ roots: [{ uri: pathToFileURL(currentRepo).href }] }));
await client.connect(new StdioClientTransport({ command: '/bin/sh', args: [path.join(root, 'scripts/start.sh')], stderr: 'inherit', env: { ...process.env, RAYGIT_CONFIG_DIR: path.join(repo, '.git/raygit-preview-config'), RAYGIT_CODEX_BIN: fixtureCli } }));
const initial = await client.callTool({ name: 'raygit_open', arguments: entrypointMode ? {} : { repo } });
const resource = await client.readResource({ uri: 'ui://raygit/workspace.html' });
const ui = resource.contents[0].text;
const host = await build({ stdin: { contents: `
import { AppBridge, PostMessageTransport } from '@modelcontextprotocol/ext-apps/app-bridge';
const iframe = document.querySelector('iframe');
const hostContext = {theme:'light',displayMode:'fullscreen',availableDisplayModes:['fullscreen']};

const bridge = new AppBridge(null, {name:'RayGit development host',version:'0.1.0'}, {serverTools:{}, updateModelContext:{}}, {hostContext});
bridge.oncalltool = async params => (await fetch('/tool', {method:'POST',headers:{'content-type':'application/json','x-raygit-token':TOKEN},body:JSON.stringify(params)})).json();
bridge.onupdatemodelcontext = async params => {document.querySelector('#context').textContent = 'Context attached: ' + params.content[0].text.length + ' characters';return {}};
bridge.onrequestdisplaymode = async ({mode}) => ({mode});
bridge.oninitialized = async () => {await bridge.sendToolInput({arguments:ENTRYPOINT_MODE ? {} : {repo:REPO}});await bridge.sendToolResult(INITIAL)};
await bridge.connect(new PostMessageTransport(iframe.contentWindow,iframe.contentWindow));
document.querySelector('#switch-project').onclick = async () => { const next = await (await fetch('/switch', {method:'POST',headers:{'x-raygit-token':TOKEN}})).json(); await bridge.sendToolInput({arguments:{}}); await bridge.sendToolResult(next); };
iframe.src='/app';
`, resolveDir: root, sourcefile: 'preview-host.mjs' }, bundle: true, format: 'esm', platform: 'browser', write: false,
  define: { TOKEN: JSON.stringify(token), INITIAL: JSON.stringify(initial), REPO: JSON.stringify(repo), ENTRYPOINT_MODE: JSON.stringify(entrypointMode) } });
const server = http.createServer(async (req, res) => {
  const send = (code, type, body) => { res.writeHead(code, { 'Content-Type': type, 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' }); res.end(body); };
  if (req.headers.host !== `127.0.0.1:${server.address().port}`) return send(403, 'text/plain', 'Forbidden host');
  if (req.method === 'GET' && req.url === '/') return send(200, 'text/html', '<!doctype html><meta charset="UTF-8"><title>RayGit · Development verification</title><style>body{margin:0;background:#f6f8f7}iframe{border:0;width:100%;height:calc(100vh - 60px)}#context{font:11px system-ui;padding:4px 12px;color:#718380}</style><iframe title="RayGit" sandbox="allow-scripts allow-same-origin allow-forms allow-modals"></iframe><div id="context">Development host · disposable repository only</div><button id="switch-project">切换宿主项目并点击入口（测试）</button><script type="module" src="/host.js"></script>');
  if (req.method === 'GET' && req.url === '/app') return send(200, 'text/html', ui);
  if (req.method === 'GET' && req.url === '/host.js') return send(200, 'text/javascript', host.outputFiles[0].text);
  if (req.method === 'POST' && req.url === '/switch' && req.headers['x-raygit-token'] === token) {
    currentRepo = currentRepo === repo ? secondRepo : repo;
    return send(200, 'application/json', JSON.stringify(await client.callTool({ name: 'raygit_open', arguments: {} })));
  }
  if (req.method === 'POST' && req.url === '/tool' && req.headers['x-raygit-token'] === token) {
    try {
      let body = ''; for await (const chunk of req) { body += chunk; if (body.length > 100000) throw new Error('Request too large'); }
      const params = JSON.parse(body);
      if (params.arguments?.repo && ![repo, secondRepo].includes(await realpath(params.arguments.repo))) throw new Error('Development preview is restricted to its disposable repository.');
      send(200, 'application/json', JSON.stringify(await client.callTool(params)));
    } catch (error) { send(200, 'application/json', JSON.stringify({ isError: true, content: [{ type: 'text', text: error.message }] })); }
    return;
  }
  send(404, 'text/plain', 'Not found');
});
server.listen(0, '127.0.0.1', async () => {
  const info = { url: `http://127.0.0.1:${server.address().port}`, repo, pid: process.pid };
  await mkdir(path.join(root, 'artifacts'), { recursive: true });
  await writeFile(path.join(root, 'artifacts/preview.json'), JSON.stringify(info, null, 2));
  console.log(JSON.stringify(info));
});
for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, async () => { server.close(); await client.close(); process.exit(0); });
