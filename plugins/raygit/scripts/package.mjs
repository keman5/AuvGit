import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { cp, mkdir, readFile, writeFile, readdir, chmod, rm, mkdtemp } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const output = path.resolve(root, '../../.artifacts/raygit-plugin');
const destination = path.join(output, 'plugins/raygit');
process.chdir(root);
if (process.platform !== 'darwin' || process.arch !== 'arm64') throw new Error('This packaged runtime targets macOS Apple Silicon. Add a verified runtime/checksum for another platform before packaging.');
await mkdir(destination, { recursive: true });
for (const entry of ['plugin.json', 'mcp.json', '.mcp.json', '.codex-plugin', 'assets', 'skills', 'README.md', 'RELEASE_REVIEW.md']) await cp(entry, path.join(destination, entry), { recursive: true });
await mkdir(path.join(destination, 'scripts'), { recursive: true });
await cp('scripts/start.sh', path.join(destination, 'scripts/start.sh'));
await chmod(path.join(destination, 'scripts/start.sh'), 0o755);
await mkdir(path.join(destination, 'dist'), { recursive: true });
await cp('dist/server.cjs', path.join(destination, 'dist/server.cjs'));

// node-pty loads its N-API addon relative to its package, so preserve that layout.
const ptyDestination = path.join(destination, 'node_modules/node-pty');
await rm(ptyDestination, { recursive: true, force: true });
await mkdir(path.join(ptyDestination, 'prebuilds'), { recursive: true });
for (const entry of ['package.json', 'LICENSE', 'lib']) await cp(path.join(root, 'node_modules/node-pty', entry), path.join(ptyDestination, entry), { recursive: true });
await cp(path.join(root, 'node_modules/node-pty/prebuilds/darwin-arm64'), path.join(ptyDestination, 'prebuilds/darwin-arm64'), { recursive: true });
await chmod(path.join(ptyDestination, 'prebuilds/darwin-arm64/spawn-helper'), 0o755);

// A verified, standalone runtime lives inside the plugin, not /Applications or PATH.
const version = 'v24.21.0', archive = `node-${version}-darwin-arm64.tar.gz`;
const expected = 'bed7eea5325e1108f32ce5228ddd6a5f0f08a499ee42aa7442aea583702f6057';
const download = path.join(tmpdir(), `raygit-${archive}`);
try { await readFile(download); }
catch { execFileSync('curl', ['-fsSL', `https://nodejs.org/dist/${version}/${archive}`, '-o', download], { stdio: 'inherit' }); }
if (createHash('sha256').update(await readFile(download)).digest('hex') !== expected) throw new Error('Node runtime checksum mismatch.');
const unpack = await mkdtemp(path.join(tmpdir(), 'raygit-node-unpack-'));
try {
  execFileSync('tar', ['-xzf', download, '-C', unpack, `node-${version}-darwin-arm64/bin/node`, `node-${version}-darwin-arm64/LICENSE`]);
  await mkdir(path.join(destination, 'runtime'), { recursive: true });
  await cp(path.join(unpack, `node-${version}-darwin-arm64/bin/node`), path.join(destination, 'runtime/node'));
  await cp(path.join(unpack, `node-${version}-darwin-arm64/LICENSE`), path.join(destination, 'runtime/LICENSE'));
  await chmod(path.join(destination, 'runtime/node'), 0o755);
} finally { await rm(unpack, { recursive: true, force: true }); }

let notices = 'RayGit bundled JavaScript dependency notices\n\n';
async function licenseDirectory(directory) {
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    if (!entry.isDirectory() || entry.name.startsWith('.')) continue;
    const pkg = path.join(directory, entry.name);
    if (entry.name.startsWith('@')) { await licenseDirectory(pkg); continue; }
    try {
      const meta = JSON.parse(await readFile(path.join(pkg, 'package.json'), 'utf8'));
      notices += `\n--- ${meta.name} ${meta.version} (${meta.license || 'see license'}) ---\n`;
      for (const file of await readdir(pkg)) if (/^(license|licence|copying)(\.|$)/i.test(file)) notices += '\n' + await readFile(path.join(pkg, file), 'utf8') + '\n';
    } catch (error) { if (error.code !== 'ENOENT') throw error; }
  }
}
await licenseDirectory(path.join(root, 'node_modules'));
await writeFile(path.join(destination, 'THIRD_PARTY_NOTICES.txt'), notices);
await mkdir(path.join(output, '.agents/plugins'), { recursive: true });
await writeFile(path.join(output, '.agents/plugins/marketplace.json'), JSON.stringify({ name: 'raygit-local', interface: { displayName: 'RayGit Local' }, plugins: [{ name: 'raygit', source: { source: 'local', path: './plugins/raygit' }, policy: { installation: 'AVAILABLE', authentication: 'ON_INSTALL' }, category: 'Developer Tools' }] }, null, 2) + '\n');
const zip = path.resolve(output, '../raygit-codex-plugin-0.3.2-macos-arm64.zip');
await rm(zip, { force: true });
execFileSync('/usr/bin/zip', ['-q', '-r', zip, 'raygit'], { cwd: path.dirname(destination) });
const nodeVersion = execFileSync(path.join(destination, 'runtime/node'), ['--version'], { encoding: 'utf8' }).trim();
await writeFile(path.join(output, 'BUILD.json'), JSON.stringify({ plugin: 'raygit', version: '0.3.2', platform: 'darwin-arm64', nodeVersion, runtimeSHA256: expected, archiveSHA256: createHash('sha256').update(await readFile(zip)).digest('hex') }, null, 2) + '\n');
const marketplaceZip = path.resolve(output, '../raygit-codex-marketplace-0.3.2-macos-arm64.zip');
await rm(marketplaceZip, { force: true });
execFileSync('/usr/bin/zip', ['-q', '-r', marketplaceZip, path.basename(output)], { cwd: path.dirname(output) });
console.log(JSON.stringify({ marketplace: output, plugin: destination, archive: zip, marketplaceArchive: marketplaceZip, nodeVersion }, null, 2));
