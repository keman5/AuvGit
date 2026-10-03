import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { registerAppTool, registerAppResource, RESOURCE_MIME_TYPE } from '@modelcontextprotocol/ext-apps/server';
import { tools, invoke, resourceUri } from './tools.mjs';

export function createServer(html = typeof RAYGIT_HTML === 'undefined' ? '<p>Build the plugin first.</p>' : RAYGIT_HTML) {
  // This SDK's registerTool drops icons; initialize.serverInfo.icons is the
  // documented fallback used by the host for entrypoint navigation icons.
  const navigationIcon = '<svg xmlns="http://www.w3.org/2000/svg" width="20" height="20" viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.33"><path d="M6 5v10m0-5c0-4 8 0 8-5"/><circle cx="6" cy="4" r="2"/><circle cx="6" cy="16" r="2"/><circle cx="14" cy="4" r="2"/></svg>';
  const server = new McpServer({ name: 'raygit', title: 'RayGit', version: '0.3.2', icons: [{ src: 'data:image/svg+xml;base64,' + Buffer.from(navigationIcon).toString('base64'), mimeType: 'image/svg+xml', sizes: ['20x20'] }] });
  for (const [name, tool] of Object.entries(tools)) {
    const context = () => ({ listRoots: server.server.getClientCapabilities()?.roots ? () => server.server.listRoots({}, { timeout: 3000 }) : undefined });
    const config = { title: tool.title, description: tool.description, inputSchema: tool.schema.shape, annotations: tool.annotations };
    if (name === 'raygit_open') {
      config._meta = { ui: { resourceUri }, 'openai/ui': { entrypoints: [{ type: 'global' }, { type: 'thread' }] } };
      registerAppTool(server, name, config, args => invoke(name, args, context()));
    } else {
      if (tool.appOnly) config._meta = { ui: { visibility: ['app'] } };
      server.registerTool(name, config, args => invoke(name, args, context()));
    }
  }
  registerAppResource(server, 'RayGit workspace', resourceUri, { mimeType: RESOURCE_MIME_TYPE }, async () => ({
    contents: [{ uri: resourceUri, mimeType: RESOURCE_MIME_TYPE, text: html,
      _meta: { ui: { csp: { connectDomains: [], resourceDomains: [] } }, 'openai/ui': { availableDisplayModes: ['fullscreen'], preferredDisplayMode: 'fullscreen' } },
    }],
  }));
  return server;
}
