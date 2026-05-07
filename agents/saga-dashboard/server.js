#!/usr/bin/env node
/**
 * saga-dashboard server
 * Static file server + proxy to saga-mcp REST API (localhost:3851)
 * No direct DB access — single source of truth is saga-mcp.
 */

import http from 'http';
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const SAGA_API = 'http://localhost:3851';
const SERVE_DIR = __dirname;
const PORT = 7902;

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript',
  '.css': 'text/css',
  '.json': 'application/json',
  '.ico': 'image/x-icon',
};

function proxy(targetUrl, res) {
  http.get(targetUrl, (upstream) => {
    let body = '';
    upstream.on('data', (chunk) => body += chunk);
    upstream.on('end', () => {
      res.writeHead(upstream.statusCode || 200, {
        'Content-Type': 'application/json',
        'Access-Control-Allow-Origin': '*',
      });
      res.end(body);
    });
  }).on('error', (e) => {
    res.writeHead(502, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'saga-mcp unavailable: ' + e.message }));
  });
}

const server = http.createServer((req, res) => {
  res.setHeader('Access-Control-Allow-Origin', '*');

  // Proxy /api/* to saga-mcp
  if (req.url.startsWith('/api/')) {
    proxy(SAGA_API + req.url, res);
    return;
  }

  // Static files
  let filePath = path.join(SERVE_DIR, req.url === '/' ? 'index.html' : req.url);
  if (!filePath.startsWith(SERVE_DIR)) {
    res.writeHead(403); res.end('Forbidden'); return;
  }

  fs.readFile(filePath, (err, data) => {
    if (err) {
      res.writeHead(404); res.end('Not found'); return;
    }
    const ext = path.extname(filePath);
    res.writeHead(200, { 'Content-Type': MIME[ext] || 'application/octet-stream' });
    res.end(data);
  });
});

server.listen(PORT, '0.0.0.0', () => {
  console.log(`saga-dashboard listening on http://localhost:${PORT}`);
  console.log(`Proxying /api/* → ${SAGA_API}`);
});

server.on('error', (e) => {
  console.error('Server error:', e.message);
  process.exit(1);
});
