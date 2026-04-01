#!/usr/bin/env node
// NextTrace Agent — connects to central server via WebSocket
// Usage: node nt-agent.js --server wss://HOST/path --id <id> [--label X] [--region X] [--emoji X] [--key X]
const { spawn } = require('child_process');
const WebSocket = require('ws');

const args = process.argv.slice(2);
function arg(name, def) {
  const i = args.indexOf('--' + name);
  return i >= 0 && args[i + 1] ? args[i + 1] : def;
}

const SERVER  = arg('server', '');
const HOST_ID = arg('id', '');
const SECRET  = arg('key', '');
const LABEL   = arg('label', '');
const REGION  = arg('region', '');
const EMOJI   = arg('emoji', '');
const NT_BIN  = '/usr/local/bin/nexttrace';

if (!SERVER || !HOST_ID) {
  console.error('Usage: node nt-agent.js --server wss://... --id <id> [--label X] [--region X] [--emoji X] [--key X]');
  process.exit(1);
}

let ws = null;
let reconnectTimer = null;
const activeJobs = new Map();

function connect() {
  if (ws) try { ws.terminate(); } catch {}
  console.log(`[agent:${HOST_ID}] connecting to ${SERVER}...`);

  ws = new WebSocket(SERVER, {
    headers: { 'X-Host-Id': HOST_ID, 'X-Key': SECRET },
    handshakeTimeout: 10000,
  });

  ws.on('open', () => {
    console.log(`[agent:${HOST_ID}] connected`);
    // Auto-register with metadata — server writes hosts.json if hostId is new
    send({ type: 'register', hostId: HOST_ID, label: LABEL, region: REGION, emoji: EMOJI });
    heartbeat();
  });

  ws.on('message', (raw) => {
    let msg;
    try { msg = JSON.parse(raw); } catch { return; }
    if (msg.type === 'trace')  handleTrace(msg);
    else if (msg.type === 'cancel') handleCancel(msg);
    else if (msg.type === 'pong')   { /* ok */ }
  });

  ws.on('close', (code) => {
    console.log(`[agent:${HOST_ID}] disconnected (${code}), reconnecting in 3s...`);
    scheduleReconnect();
  });

  ws.on('error', (err) => {
    console.error(`[agent:${HOST_ID}] ws error: ${err.message}`);
  });
}

function send(obj) {
  if (ws && ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify(obj));
}

function scheduleReconnect() {
  if (reconnectTimer) return;
  reconnectTimer = setTimeout(() => { reconnectTimer = null; connect(); }, 3000);
}

let hbInterval = null;
function heartbeat() {
  if (hbInterval) clearInterval(hbInterval);
  hbInterval = setInterval(() => {
    if (ws && ws.readyState === WebSocket.OPEN)
      send({ type: 'ping', hostId: HOST_ID, active: activeJobs.size });
  }, 15000);
}

function stripAnsi(s) {
  return String(s)
    .replace(/\u001b\[[0-9;]*[A-Za-z]/g, '')
    .replace(/\x1b\[[0-9;]*[A-Za-z]/g, '')
    .replace(/\[[0-9;]*m/g, '')
    .replace(/\r/g, '');
}

function handleTrace(msg) {
  const { jobId, args: ntArgs, stdin } = msg;
  if (!jobId || !ntArgs) return;
  const stdio = stdin ? ['pipe', 'pipe', 'pipe'] : ['ignore', 'pipe', 'pipe'];
  let child;
  try { child = spawn(NT_BIN, ntArgs, { stdio, timeout: 90000 }); }
  catch (e) { send({ type: 'error', jobId, error: e.message }); return; }
  activeJobs.set(jobId, child);
  if (stdin) { child.stdin.write(stdin); child.stdin.end(); }
  child.stdout.on('data', d => send({ type: 'data', jobId, data: stripAnsi(d.toString()) }));
  child.stderr.on('data', d => send({ type: 'data', jobId, data: stripAnsi(d.toString()) }));
  child.on('error', e => { send({ type: 'error', jobId, error: e.message }); activeJobs.delete(jobId); });
  child.on('close', code => { send({ type: 'end', jobId, code }); activeJobs.delete(jobId); });
}

function handleCancel(msg) {
  const child = activeJobs.get(msg.jobId);
  if (child) { child.kill('SIGKILL'); activeJobs.delete(msg.jobId); }
}

process.on('SIGTERM', () => {
  console.log(`[agent:${HOST_ID}] shutting down...`);
  for (const [, child] of activeJobs) child.kill('SIGKILL');
  if (ws) ws.close();
  process.exit(0);
});
process.on('SIGINT', () => process.emit('SIGTERM'));

connect();
