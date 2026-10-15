import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { createServer } from './server.mjs';
import { stopCommands } from './commands.mjs';
import { stopTerminals } from './terminal.mjs';
const stop = () => { stopCommands(); stopTerminals(); };
const server = createServer();
server.server.onclose = stop;
for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => { stop(); server.close().finally(() => { process.exitCode = 0; }); });
server.connect(new StdioServerTransport()).catch(error => {
  console.error(error.message);
  process.exitCode = 1;
});
