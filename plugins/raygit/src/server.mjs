import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { registerAppTool, registerAppResource, RESOURCE_MIME_TYPE } from '@modelcontextprotocol/ext-apps/server';
import { tools, invoke, resourceUri } from './tools.mjs';

export function createServer(html = typeof RAYGIT_HTML === 'undefined' ? '<p>Build the plugin first.</p>' : RAYGIT_HTML) {
  const server = new McpServer({ name: 'raygit', version: '0.1.0' });
  for (const [name, tool] of Object.entries(tools)) {
    const config = { title: tool.title, description: tool.description, inputSchema: tool.schema.shape, annotations: tool.annotations };
    if (name === 'raygit_open') {
      config._meta = { ui: { resourceUri }, 'openai/ui': { entrypoints: [{ type: 'thread' }] } };
      registerAppTool(server, name, config, args => invoke(name, args));
    } else server.registerTool(name, config, args => invoke(name, args));
  }
  registerAppResource(server, 'RayGit workspace', resourceUri, { mimeType: RESOURCE_MIME_TYPE }, async () => ({
    contents: [{ uri: resourceUri, mimeType: RESOURCE_MIME_TYPE, text: html,
      _meta: { ui: { csp: { connectDomains: [], resourceDomains: [] } }, 'openai/ui': { availableDisplayModes: ['fullscreen'], preferredDisplayMode: 'fullscreen' } },
    }],
  }));
  return server;
}
