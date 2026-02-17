import http from 'node:http';
import https from 'node:https';
import { URL } from 'node:url';

const target = process.env.LOCAL_SITE_PROXY_TARGET || 'https://iqii.cn';
const port = Number(process.env.LOCAL_SITE_PROXY_PORT || 4321);
const targetUrl = new URL(target);

const server = http.createServer((req, res) => {
  const upstream = new URL(req.url || '/', targetUrl);

  const options = {
    protocol: upstream.protocol,
    hostname: upstream.hostname,
    port: upstream.port || (upstream.protocol === 'https:' ? 443 : 80),
    method: req.method,
    path: `${upstream.pathname}${upstream.search}`,
    headers: {
      ...req.headers,
      host: upstream.host,
    },
  };

  const client = upstream.protocol === 'https:' ? https : http;
  const proxyReq = client.request(options, (proxyRes) => {
    res.writeHead(proxyRes.statusCode || 502, proxyRes.headers);
    proxyRes.pipe(res);
  });

  proxyReq.on('error', (error) => {
    res.writeHead(502, { 'content-type': 'text/plain; charset=utf-8' });
    res.end(`Proxy error: ${error.message}`);
  });

  req.pipe(proxyReq);
});

server.listen(port, () => {
  console.log(`Local site proxy running at http://localhost:${port}`);
  console.log(`Proxy target: ${target}`);
});
