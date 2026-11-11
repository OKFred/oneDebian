// One bounded command to the owned loopback Chromium; transport close preserves it.
const request = JSON.parse(process.argv[2]);
if (!Number.isInteger(request.port) || request.port < 1024 || request.port > 65535)
  throw Error('Invalid CDP port');
const base = 'http://127.0.0.1:' + request.port;
const response = await fetch(base + '/json/version', {signal:AbortSignal.timeout(5000),redirect:'error'});
if (!response.ok) throw Error('CDP discovery failed');
const info = await response.json();
const address = new URL(request.endpoint || info.webSocketDebuggerUrl);
if (address.protocol !== 'ws:' || address.hostname !== '127.0.0.1' || address.port !== String(request.port)
    || !address.pathname.startsWith('/devtools/') || address.username || address.password || address.search || address.hash)
  throw Error('Unexpected CDP endpoint');
const ws = new WebSocket(address);
try {
  const result = await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(Error('CDP deadline exceeded')), 20000);
    const fail = error => {clearTimeout(timer); reject(error);};
    ws.addEventListener('error', () => fail(Error('CDP transport failed')));
    ws.addEventListener('open', () => ws.send(JSON.stringify({id:1,method:request.method,params:request.params || {}})));
    ws.addEventListener('message', event => {
      const message = JSON.parse(event.data);
      if (message.id !== 1) return;
      clearTimeout(timer);
      if (message.error) reject(Error(message.error.message)); else resolve(message.result);
    });
  });
  console.log(JSON.stringify(result));
} finally {ws.close();}
