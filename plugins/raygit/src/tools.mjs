import { z } from 'zod';
import { repository, status, history, branches, diff, mutate } from './git.mjs';

const repo = z.string().min(1).describe('Absolute path to the user-selected local Git repository.');
const snapshot = z.string().regex(/^[a-f0-9]{64}$/).describe('Snapshot returned by the most recent status. Reject writes if stale.');
const paths = z.array(z.string().min(1)).min(1).max(500).describe('Exact repository-relative paths selected by the user.');
const read = { readOnlyHint: true, destructiveHint: false, openWorldHint: false };
const write = { readOnlyHint: false, destructiveHint: false, openWorldHint: false, idempotentHint: false };
export const resourceUri = 'ui://raygit/workspace.html';

export const tools = {
  raygit_open: {
    title: 'Git 工作区', description: 'Open the RayGit interactive Git workspace in Codex. Supply the current project repository path. Empty arguments open a repository picker.',
    schema: z.object({ repo: repo.optional() }), annotations: read,
    async run(args) {
      if (!args.repo) return { needsRepository: true };
      const root = await repository(args.repo);
      const [state, log, refs] = await Promise.all([status(root), history(root), branches(root)]);
      return { ...state, ...log, ...refs };
    },
  },
  raygit_status: { title: '仓库状态', description: 'Read exact file status, current branch and optimistic-concurrency snapshot.', schema: z.object({ repo }), annotations: read,
    run: async args => status(await repository(args.repo)) },
  raygit_history: { title: '提交历史', description: 'Read a page of topologically ordered commits from all refs, including graph parents.', schema: z.object({ repo, offset: z.number().int().min(0).max(100000).default(0), limit: z.number().int().min(1).max(200).default(60) }), annotations: read,
    run: async args => history(await repository(args.repo), args) },
  raygit_branches: { title: '分支列表', description: 'List local and remote branches.', schema: z.object({ repo }), annotations: read,
    run: async args => branches(await repository(args.repo)) },
  raygit_diff: { title: '文件差异', description: 'Read working-tree, staged, or commit diff. Commit must be a SHA. Disable external diff and text conversion.', schema: z.object({ repo, scope: z.enum(['working', 'staged', 'commit']).default('working'), file: z.string().optional(), commit: z.string().optional() }), annotations: read,
    run: async args => diff(await repository(args.repo), args) },
};
for (const [operation, title, description, fields] of [
  ['stage', '暂存文件', 'Stage only explicitly selected changed files after checking the snapshot.', { paths }],
  ['unstage', '取消暂存', 'Unstage only explicitly selected files, preserving working copies.', { paths }],
  ['commit', '创建提交', 'Commit the current index only. Requires user intent. Does not auto-stage, amend or push. Repository commit hooks run normally.', { message: z.string().min(1).max(20000) }],
  ['create_branch', '创建分支', 'Create a local branch at HEAD without switching to it. Requires user intent.', { name: z.string().min(1).max(240) }],
  ['switch_branch', '切换分支', 'Switch to an existing local branch only when working tree and index are clean. Requires user intent.', { name: z.string().min(1).max(240) }],
]) {
  tools['raygit_' + operation] = { title, description, schema: z.object({ repo, snapshot, ...fields }), annotations: write,
    run: async args => mutate(await repository(args.repo), operation, args) };
}

export async function invoke(name, args) {
  try {
    const tool = tools[name];
    if (!tool) throw new Error('未知工具。');
    const data = await tool.run(tool.schema.parse(args));
    return { content: [{ type: 'text', text: JSON.stringify(data) }], structuredContent: data };
  } catch (error) {
    return { isError: true, content: [{ type: 'text', text: error.message }] };
  }
}
