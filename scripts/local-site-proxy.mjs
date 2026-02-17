import http from 'node:http';
import https from 'node:https';
import { URL } from 'node:url';

const target = process.env.LOCAL_SITE_PROXY_TARGET || 'https://iqii.cn';
const port = Number(process.env.LOCAL_SITE_PROXY_PORT || 4321);
const targetUrl = new URL(target);
const adminAuthInject = `<script>(function(){try{const hash=new URLSearchParams(window.location.hash.replace(/^#\\/?/,''));const token=hash.get('access_token');if(!token)return;let currentUser={};try{const raw=window.localStorage.getItem('static-cms-user');if(raw){const parsed=JSON.parse(raw);if(parsed&&typeof parsed==='object')currentUser=parsed;}}catch(_){}const nextUser=Object.assign({},currentUser,{backendName:'github',token:token});window.localStorage.setItem('static-cms-user',JSON.stringify(nextUser));hash.delete('access_token');hash.delete('token_type');hash.delete('error');const nextHash=hash.toString();const nextUrl=nextHash?window.location.pathname+'#'+nextHash:window.location.pathname;window.history.replaceState(null,'',nextUrl);}catch(_){}})();</script>`;

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
      'accept-encoding': 'identity',
    },
  };

  const client = upstream.protocol === 'https:' ? https : http;
  const proxyReq = client.request(options, (proxyRes) => {
    const isAdminPath = upstream.pathname === '/admin';
    const contentType = String(proxyRes.headers['content-type'] || '');
    const shouldInject = isAdminPath && contentType.includes('text/html');

    if (!shouldInject) {
      res.writeHead(proxyRes.statusCode || 502, proxyRes.headers);
      proxyRes.pipe(res);
      return;
    }

    const chunks = [];
    proxyRes.on('data', (chunk) => chunks.push(chunk));
    proxyRes.on('end', () => {
      const rawHtml = Buffer.concat(chunks).toString('utf8');
      const patchedHtml = rawHtml.includes('static-cms-user')
        ? rawHtml
        : /<body[^>]*>/i.test(rawHtml)
          ? rawHtml.replace(/<body[^>]*>/i, (match) => `${match}${adminAuthInject}`)
          : `${adminAuthInject}${rawHtml}`;

      const headers = { ...proxyRes.headers };
      delete headers['content-length'];
      delete headers['content-encoding'];
      delete headers['transfer-encoding'];
      res.writeHead(proxyRes.statusCode || 502, headers);
      res.end(patchedHtml);
    });
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
