#!/usr/bin/env node
/**
 * @deprecated This local MCP proxy server is no longer used.
 * ediProd access is now handled via the `edi` CLI tool.
 * Install: bun link (from mcp-ediprod repo)
 * Usage: edi --help
 *
 * This file is kept for reference only and can be safely deleted.
 */

const http = require('http');
const https = require('https');
const url = require('url');

const EDIPROD_API_BASE = 'https://ediprod.mcp.wtg.zone';

// Tools exposed by this MCP server
const TOOLS = {
  'get-staff-tickets': {
    description: 'Get tickets assigned to a staff member on a buffer board',
    inputSchema: {
      type: 'object',
      properties: {
        boardName: { type: 'string', description: 'Name of the buffer board' },
        staffCode: { type: 'string', description: 'Staff code (2-3 characters)' }
      },
      required: ['boardName', 'staffCode']
    }
  }
};

async function makeRequest(method, path, body = null) {
  return new Promise((resolve, reject) => {
    const urlObj = new URL(`${EDIPROD_API_BASE}${path}`);
    const options = {
      hostname: urlObj.hostname,
      port: urlObj.port || 443,
      path: urlObj.pathname + urlObj.search,
      method: method,
      headers: {
        'Content-Type': 'application/json',
        'User-Agent': 'ediProd-MCP-Server'
      }
    };

    const req = https.request(options, (res) => {
      let data = '';
      res.on('data', chunk => data += chunk);
      res.on('end', () => {
        try {
          resolve({ status: res.statusCode, data: JSON.parse(data) });
        } catch (e) {
          resolve({ status: res.statusCode, data: data });
        }
      });
    });

    req.on('error', reject);
    if (body) req.write(JSON.stringify(body));
    req.end();
  });
}

async function callTool(toolName, args) {
  if (toolName === 'get-staff-tickets') {
    try {
      const response = await makeRequest('POST', '/api/get-staff-tickets', args);
      return response.data;
    } catch (error) {
      throw new Error(`ediProd API error: ${error.message}`);
    }
  }
  throw new Error(`Unknown tool: ${toolName}`);
}

// MCP Protocol handler
function handleJsonRpc(message) {
  const { jsonrpc, id, method, params } = message;
  
  if (method === 'initialize') {
    return {
      jsonrpc: '2.0',
      id,
      result: {
        protocolVersion: '2024-11-05',
        capabilities: {},
        serverInfo: {
          name: 'ediProd MCP Server',
          version: '1.0.0'
        }
      }
    };
  }

  if (method === 'tools/list') {
    return {
      jsonrpc: '2.0',
      id,
      result: {
        tools: Object.entries(TOOLS).map(([name, spec]) => ({
          name,
          description: spec.description,
          inputSchema: spec.inputSchema
        }))
      }
    };
  }

  if (method === 'tools/call') {
    const { name, arguments: args } = params;
    callTool(name, args).then(result => {
      process.stdout.write(JSON.stringify({
        jsonrpc: '2.0',
        id,
        result
      }) + '\n');
    }).catch(error => {
      process.stdout.write(JSON.stringify({
        jsonrpc: '2.0',
        id,
        error: { code: -32000, message: error.message }
      }) + '\n');
    });
    return; // Don't send response yet, async
  }

  return {
    jsonrpc: '2.0',
    id,
    error: { code: -32601, message: 'Method not found' }
  };
}

// Start server
const server = http.createServer((req, res) => {
  if (req.method === 'POST') {
    let body = '';
    req.on('data', chunk => body += chunk);
    req.on('end', () => {
      try {
        const message = JSON.parse(body);
        const response = handleJsonRpc(message);
        if (response) {
          res.writeHead(200, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify(response));
        }
      } catch (error) {
        res.writeHead(400);
        res.end(JSON.stringify({ error: error.message }));
      }
    });
  } else {
    res.writeHead(404);
    res.end();
  }
});

const PORT = 3000;
server.listen(PORT, () => {
  console.error(`ediProd MCP Server listening on port ${PORT}`);
});

// Handle stdin for MCP protocol
process.stdin.setEncoding('utf8');
let buffer = '';

process.stdin.on('data', (chunk) => {
  buffer += chunk;
  const lines = buffer.split('\n');
  buffer = lines.pop();
  
  for (const line of lines) {
    if (line.trim()) {
      try {
        const message = JSON.parse(line);
        const response = handleJsonRpc(message);
        if (response) {
          process.stdout.write(JSON.stringify(response) + '\n');
        }
      } catch (error) {
        process.stdout.write(JSON.stringify({
          error: { code: -32700, message: 'Parse error', data: error.message }
        }) + '\n');
      }
    }
  }
});
