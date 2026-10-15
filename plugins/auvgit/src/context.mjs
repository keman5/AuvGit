import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { repository } from './git.mjs';

// Resolve on every invocation. Never treat the last opened repository as host context.
export async function currentRepository({ listRoots, cwd = process.cwd(), pluginRoot = process.env.AUVGIT_PLUGIN_ROOT } = {}) {
  if (listRoots) {
    try {
      const { roots } = await listRoots();
      const projects = [];
      for (const root of roots) {
        try {
          if (!root.uri.startsWith('file:')) continue;
          const repo = await repository(fileURLToPath(root.uri));
          if (!projects.some(project => project.repo === repo)) projects.push({ repo, name: path.basename(repo) });
        } catch { /* A workspace root may be a non-Git artifact directory. */ }
      }
      if (projects.length === 1) return { repo: projects[0].repo, source: 'roots', projects };
      return { needsRepository: true, projects, reason: projects.length ? '宿主提供了多个仓库，请在左侧选择项目。' : '当前工作区没有可用的 Git 仓库。' };
    } catch {
      return { needsRepository: true, projects: [], reason: '未能读取当前工作区，请重试或从项目列表选择。' };
    }
  }
  // Some hosts launch a separate stdio server per project and communicate cwd.
  // This is startup context, not proof that a reused host has switched projects.
  if (!pluginRoot || (cwd !== pluginRoot && !cwd.startsWith(pluginRoot + path.sep))) {
    try { return { repo: await repository(cwd), source: 'cwd', projects: [] }; } catch {}
  }
  return { needsRepository: true, projects: [], reason: '宿主未提供当前项目路径。请从项目列表选择，或在当前 Codex 对话中说“打开当前项目的 AuvGit”。' };
}
