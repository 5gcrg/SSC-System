'use strict';
// SSC System — Dashboard Server
// Zero external npm dependencies — pure Node.js built-ins only.
// Start via:  node scripts/dashboard-server.js
// Or use:     powershell -ExecutionPolicy Bypass -File scripts\dashboard.ps1

const http   = require('http');
const fs     = require('fs');
const path   = require('path');
const net    = require('net');
const { spawn } = require('child_process');
const crypto = require('crypto');

const DASHBOARD_PORT = 9999;
const REPO      = path.resolve(__dirname, '..');
const HTML_FILE = path.join(__dirname, 'dashboard.html');

// ── Service Definitions ────────────────────────────────────────────────────────
const SERVICES = {
  mysql: {
    id: 'mysql', name: 'MySQL', port: 3306, icon: '🗄️',
    color: '#3b82f6', isWindowsService: true,
    links: []
  },
  minio: {
    id: 'minio', name: 'MinIO', port: 9000, consolePort: 9001, icon: '🪣',
    color: '#ef4444',
    links: [{ label: 'Console', url: 'http://localhost:9001' }]
  },
  fileserver: {
    id: 'fileserver', name: 'File Server', port: 8080, icon: '📁',
    color: '#f59e0b',
    links: [{ label: 'Health', url: 'http://localhost:8080/actuator/health' }]
  },
  backend: {
    id: 'backend', name: 'Main API', port: 8081, icon: '⚙️',
    color: '#8b5cf6',
    links: [{ label: 'Ping', url: 'http://localhost:8081/api/v1/ping' }]
  },
  frontend: {
    id: 'frontend', name: 'Frontend', port: 3000, icon: '🌐',
    color: '#10b981',
    links: [{ label: 'Open App', url: 'http://localhost:3000/login' }]
  }
};

const SERVICE_ORDER = ['mysql', 'minio', 'fileserver', 'backend', 'frontend'];

// ── State ──────────────────────────────────────────────────────────────────────
const procs      = {};           // id -> ChildProcess
const logBuffers = {};           // id -> string[]  (capped ring buffer)
const wsClients  = new Set();   // Set<net.Socket>

SERVICE_ORDER.forEach(id => { logBuffers[id] = []; });

// ── Port Check ─────────────────────────────────────────────────────────────────
function checkPort(port) {
  return new Promise(resolve => {
    const sock = new net.Socket();
    sock.setTimeout(400);
    sock.once('connect', () => { sock.destroy(); resolve(true);  });
    sock.once('error',   () => resolve(false));
    sock.once('timeout', () => { sock.destroy(); resolve(false); });
    sock.connect(port, '127.0.0.1');
  });
}

function waitForPort(port, timeoutMs = 120000) {
  return new Promise(resolve => {
    const deadline = Date.now() + timeoutMs;
    (function poll() {
      checkPort(port).then(up => {
        if (up) return resolve(true);
        if (Date.now() >= deadline) return resolve(false);
        setTimeout(poll, 1500);
      });
    })();
  });
}

async function collectStatuses() {
  const result = {};
  for (const id of SERVICE_ORDER) {
    const up = await checkPort(SERVICES[id].port);
    if (up) {
      result[id] = 'online';
    } else if (procs[id] && !procs[id].killed) {
      result[id] = 'starting';
    } else {
      result[id] = 'stopped';
    }
  }
  return result;
}

// ── Logging ────────────────────────────────────────────────────────────────────
const LOG_CAP_CHARS = 60_000;

function appendLog(id, text) {
  logBuffers[id].push(text);
  // Trim oldest entries if buffer grows too large
  while (logBuffers[id].length > 1) {
    const total = logBuffers[id].reduce((s, l) => s + l.length, 0);
    if (total <= LOG_CAP_CHARS) break;
    logBuffers[id].shift();
  }
  broadcast({ type: 'log', service: id, data: text });
}

// ── WebSocket Helpers ──────────────────────────────────────────────────────────
function encodeWsFrame(text) {
  const payload = Buffer.from(text, 'utf8');
  const len = payload.length;
  let header;
  if (len < 126) {
    header = Buffer.alloc(2);
    header[0] = 0x81; // FIN + text opcode
    header[1] = len;
  } else if (len < 65536) {
    header = Buffer.alloc(4);
    header[0] = 0x81;
    header[1] = 126;
    header.writeUInt16BE(len, 2);
  } else {
    header = Buffer.alloc(10);
    header[0] = 0x81;
    header[1] = 127;
    header.writeBigUInt64BE(BigInt(len), 2);
  }
  return Buffer.concat([header, payload]);
}

function broadcast(obj) {
  const frame = encodeWsFrame(JSON.stringify(obj));
  for (const socket of wsClients) {
    try { socket.write(frame); } catch { wsClients.delete(socket); }
  }
}

function handleWsUpgrade(req, socket) {
  const key = req.headers['sec-websocket-key'];
  if (!key) { socket.destroy(); return; }

  const accept = crypto
    .createHash('sha1')
    .update(key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11')
    .digest('base64');

  socket.write(
    'HTTP/1.1 101 Switching Protocols\r\n' +
    'Upgrade: websocket\r\n' +
    'Connection: Upgrade\r\n' +
    `Sec-WebSocket-Accept: ${accept}\r\n\r\n`
  );

  wsClients.add(socket);

  // Replay buffered logs for this new client
  for (const id of SERVICE_ORDER) {
    if (logBuffers[id].length > 0) {
      const frame = encodeWsFrame(JSON.stringify({
        type: 'log', service: id, data: logBuffers[id].join('')
      }));
      try { socket.write(frame); } catch {}
    }
  }

  // Handle close frame (opcode 0x8) or errors
  socket.on('data', buf => {
    const opcode = buf.length > 0 ? (buf[0] & 0x0f) : -1;
    if (opcode === 0x8) { socket.destroy(); wsClients.delete(socket); }
  });
  socket.on('close', () => wsClients.delete(socket));
  socket.on('error', () => { wsClients.delete(socket); });
}

// ── Service Start ──────────────────────────────────────────────────────────────
async function startService(id) {
  const svc = SERVICES[id];
  const isUp = await checkPort(svc.port);
  if (isUp) {
    appendLog(id, `[dashboard] ${svc.name} is already running on port ${svc.port}.\n`);
    return;
  }
  if (procs[id] && !procs[id].killed) {
    appendLog(id, `[dashboard] ${svc.name} is already starting…\n`);
    return;
  }

  appendLog(id, `[dashboard] ▶ Starting ${svc.name}…\n`);
  let child;

  try {
    if (id === 'mysql') {
      // Start the MySQL Windows service — requires Administrator rights.
      // We use try/catch inside PowerShell so a permission error shows in the log
      // instead of silently crashing the child process.
      child = spawn('powershell', [
        '-NoProfile', '-Command',
        `$s = Get-Service -Name 'MySQL*' -EA SilentlyContinue | Select-Object -First 1; ` +
        `if ($s) { ` +
        `  if ($s.Status -ne 'Running') { ` +
        `    try { Start-Service $s.Name -EA Stop; Write-Host "MySQL service started." } ` +
        `    catch { Write-Host "ERROR: Cannot start MySQL service — please run the dashboard as Administrator, or start MySQL manually." } ` +
        `  } else { Write-Host "MySQL service is already running." } ` +
        `} else { Write-Host "No MySQL Windows service found — if mysqld is running standalone, it should appear online shortly." }`
      ], { windowsHide: true });

    } else if (id === 'minio') {
      const minioExe = path.join(REPO, 'minio', 'minio.exe');
      if (!fs.existsSync(minioExe)) {
        appendLog(id, '[dashboard] ✖ minio.exe not found — run scripts\\setup.ps1 first.\n');
        return;
      }
      const dataDir = path.join(REPO, 'minio', 'data');
      child = spawn(minioExe, ['server', dataDir, '--console-address', ':9001'], {
        windowsHide: true,
        env: {
          ...process.env,
          MINIO_ROOT_USER: 'sscadmin',
          MINIO_ROOT_PASSWORD: 'sscpassword123'
        }
      });

    } else if (id === 'fileserver') {
      const targetDir = path.join(REPO, 'ssc-booking-fileserver', 'target');
      if (!fs.existsSync(targetDir)) {
        appendLog(id, '[dashboard] ✖ target/ not found — run scripts\\setup.ps1 first.\n');
        return;
      }
      const jars = fs.readdirSync(targetDir)
        .filter(f => f.endsWith('.jar') && !f.includes('sources'));
      if (!jars.length) {
        appendLog(id, '[dashboard] ✖ No jar found — run scripts\\setup.ps1 first.\n');
        return;
      }
      const javaExeFs = process.env.JAVA_HOME
        ? path.join(process.env.JAVA_HOME, 'bin', 'java.exe')
        : 'java';
      child = spawn(javaExeFs, ['-jar', path.join(targetDir, jars[0])], {
        cwd: path.join(REPO, 'ssc-booking-fileserver'),
        windowsHide: true
      });

    } else if (id === 'backend') {
      const targetDir = path.join(REPO, 'ssc-booking-backend', 'target');
      if (!fs.existsSync(targetDir)) {
        appendLog(id, '[dashboard] ✖ target/ not found — run scripts\\setup.ps1 first.\n');
        return;
      }
      const jars = fs.readdirSync(targetDir)
        .filter(f => f.endsWith('.jar') && !f.includes('sources'));
      if (!jars.length) {
        appendLog(id, '[dashboard] ✖ No jar found — run scripts\\setup.ps1 first.\n');
        return;
      }
      const javaExeBe = process.env.JAVA_HOME
        ? path.join(process.env.JAVA_HOME, 'bin', 'java.exe')
        : 'java';
      child = spawn(javaExeBe, ['-jar', path.join(targetDir, jars[0])], {
        cwd: path.join(REPO, 'ssc-booking-backend'),
        windowsHide: true
      });

    } else if (id === 'frontend') {
      const frontendDir = path.join(REPO, 'ssc-booking-frontend');
      if (!fs.existsSync(path.join(frontendDir, '.next'))) {
        appendLog(id, '[dashboard] ✖ .next/ not found — run scripts\\setup.ps1 first.\n');
        return;
      }
      child = spawn('npm', ['run', 'start'], {
        cwd: frontendDir,
        windowsHide: true,
        shell: true   // needed on Windows for npm.cmd
      });
    }
  } catch (err) {
    appendLog(id, `[dashboard] ✖ Spawn error: ${err.message}\n`);
    return;
  }

  if (!child) return;
  procs[id] = child;

  child.stdout && child.stdout.on('data', d => appendLog(id, d.toString()));
  child.stderr && child.stderr.on('data', d => appendLog(id, d.toString()));
  child.on('error', err => appendLog(id, `[dashboard] Process error: ${err.message}\n`));
  child.on('exit', (code, signal) => {
    appendLog(id, `[dashboard] ${svc.name} process exited (code=${code} signal=${signal})\n`);
    delete procs[id];
  });
}

// ── Service Stop ───────────────────────────────────────────────────────────────
async function stopService(id) {
  const svc = SERVICES[id];
  appendLog(id, `[dashboard] ■ Stopping ${svc.name}…\n`);

  // Kill managed child if we have one
  if (procs[id] && !procs[id].killed) {
    procs[id].kill();
    await new Promise(r => setTimeout(r, 800));
    if (procs[id] && !procs[id].killed) procs[id].kill('SIGKILL');
    delete procs[id];
  }

  if (id === 'mysql') {
    // Try Windows service first, then fall back to port-kill on 3306
    spawn('powershell', [
      '-NoProfile', '-Command',
      `$s = Get-Service -Name 'MySQL*' -EA SilentlyContinue | Select -First 1; ` +
      `if ($s -and $s.Status -ne 'Stopped') { Stop-Service $s.Name -Force -EA SilentlyContinue; Write-Host "MySQL service stopped." } ` +
      `else { $pids = (Get-NetTCPConnection -LocalPort 3306 -State Listen -EA SilentlyContinue).OwningProcess | Sort-Object -Unique; ` +
      `foreach ($p in $pids) { Stop-Process -Id $p -Force -EA SilentlyContinue; Write-Host "Killed PID $p on port 3306" } }`
    ], { windowsHide: true });
  } else {
    // Kill by port (handles externally-started processes)
    const portsToKill = [svc.port];
    if (id === 'minio') portsToKill.push(9001);

    for (const port of portsToKill) {
      spawn('powershell', [
        '-NoProfile', '-Command',
        `$pids = (Get-NetTCPConnection -LocalPort ${port} -State Listen -EA SilentlyContinue).OwningProcess | ` +
        `Sort-Object -Unique; foreach ($p in $pids) { Stop-Process -Id $p -Force -EA SilentlyContinue }`
      ], { windowsHide: true });
    }
  }

  appendLog(id, `[dashboard] Stop signal sent to ${svc.name}.\n`);
}


// ── Start All (sequential, fire-and-forget) ────────────────────────────────────
async function startAll() {
  appendLog('mysql', '[dashboard] ═══ Starting all services in order… ═══\n');
  for (const id of SERVICE_ORDER) {
    await startService(id);
    const svc = SERVICES[id];
    appendLog(id, `[dashboard] Waiting for ${svc.name} on port ${svc.port}…\n`);
    const up = await waitForPort(svc.port, 120_000);
    if (up) {
      appendLog(id, `[dashboard] ✔ ${svc.name} is up.\n`);
    } else {
      appendLog(id, `[dashboard] ⚠ ${svc.name} did not become ready in time — continuing anyway.\n`);
    }
  }
  broadcast({ type: 'notify', level: 'success', message: 'All services started.' });
}

// ── HTTP Server ────────────────────────────────────────────────────────────────
const server = http.createServer(async (req, res) => {
  const url = (req.url || '/').split('?')[0];

  const json = (data, status = 200) => {
    res.setHeader('Content-Type', 'application/json');
    res.setHeader('Access-Control-Allow-Origin', '*');
    res.writeHead(status);
    res.end(JSON.stringify(data));
  };

  if (req.method === 'OPTIONS') {
    res.setHeader('Access-Control-Allow-Origin', '*');
    res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    res.writeHead(204); res.end(); return;
  }

  // Serve dashboard SPA
  if (url === '/' || url === '/index.html') {
    try {
      const html = fs.readFileSync(HTML_FILE, 'utf8');
      res.setHeader('Content-Type', 'text/html; charset=utf-8');
      res.writeHead(200); res.end(html);
    } catch {
      res.writeHead(500); res.end('dashboard.html not found next to dashboard-server.js');
    }
    return;
  }

  // GET /api/services — full service metadata + current statuses
  if (url === '/api/services' && req.method === 'GET') {
    const statuses = await collectStatuses();
    json({ services: SERVICES, order: SERVICE_ORDER, statuses });
    return;
  }

  // GET /api/status — lightweight status poll
  if (url === '/api/status' && req.method === 'GET') {
    json(await collectStatuses());
    return;
  }

  // POST /api/start/:id
  const startM = url.match(/^\/api\/start\/(\w+)$/);
  if (startM && req.method === 'POST') {
    const id = startM[1];
    if (!SERVICES[id]) { json({ error: 'unknown service' }, 404); return; }
    startService(id).catch(e => appendLog(id, `[dashboard] Error: ${e.message}\n`));
    json({ ok: true }); return;
  }

  // POST /api/stop/:id
  const stopM = url.match(/^\/api\/stop\/(\w+)$/);
  if (stopM && req.method === 'POST') {
    const id = stopM[1];
    if (!SERVICES[id]) { json({ error: 'unknown service' }, 404); return; }
    await stopService(id);
    json({ ok: true }); return;
  }

  // POST /api/start-all
  if (url === '/api/start-all' && req.method === 'POST') {
    startAll().catch(console.error); // fire and forget
    json({ ok: true, message: 'Starting all services sequentially — watch logs for progress.' });
    return;
  }

  // POST /api/stop-all
  if (url === '/api/stop-all' && req.method === 'POST') {
    const stopOrder = [...SERVICE_ORDER].reverse();
    for (const id of stopOrder) await stopService(id);
    json({ ok: true }); return;
  }

  res.writeHead(404); res.end('Not found');
});

// WebSocket upgrade
server.on('upgrade', (req, socket, _head) => {
  if ((req.headers['upgrade'] || '').toLowerCase() !== 'websocket') {
    socket.destroy(); return;
  }
  handleWsUpgrade(req, socket);
});

server.listen(DASHBOARD_PORT, '127.0.0.1', () => {
  console.log('');
  console.log('  ╔══════════════════════════════════════════╗');
  console.log('  ║     SSC System — Service Dashboard       ║');
  console.log(`  ║  http://localhost:${DASHBOARD_PORT}                  ║`);
  console.log('  ║  Ctrl+C to stop the dashboard server     ║');
  console.log('  ╚══════════════════════════════════════════╝');
  console.log('');
});

// Broadcast status every 3 seconds
setInterval(async () => {
  try {
    const statuses = await collectStatuses();
    broadcast({ type: 'status', statuses });
  } catch {}
}, 3000);

process.on('SIGINT', () => {
  console.log('\nDashboard server stopped.');
  process.exit(0);
});
