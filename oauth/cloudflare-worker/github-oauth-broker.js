function json(status, data) {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store",
    },
  });
}

function redirect(location) {
  return new Response(null, {
    status: 302,
    headers: {
      location,
      "cache-control": "no-store",
    },
  });
}

function html(status, body) {
  return new Response(body, {
    status,
    headers: {
      "content-type": "text/html; charset=utf-8",
      "cache-control": "no-store",
    },
  });
}

function toBase64Url(input) {
  return btoa(input).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}

function fromBase64Url(input) {
  const normalized = input.replace(/-/g, "+").replace(/_/g, "/");
  const padded = normalized + "=".repeat((4 - (normalized.length % 4)) % 4);
  return atob(padded);
}

async function sign(payload, secret) {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sigBuffer = await crypto.subtle.sign(
    "HMAC",
    key,
    new TextEncoder().encode(payload),
  );
  return Array.from(new Uint8Array(sigBuffer))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

function normalizeOrigin(origin) {
  if (!origin) return "*";
  try {
    const url = new URL(origin);
    return `${url.protocol}//${url.host}`;
  } catch {
    return "*";
  }
}

function isAllowedOrigin(origin, allowList) {
  if (!origin) return false;
  if (allowList.length === 0) return true;
  return allowList.includes(origin);
}

function buildResultPage({ ok, origin, payload, message }) {
  const targetOrigin = JSON.stringify(origin || "*");
  const status = ok ? "success" : "error";
  const body = ok
    ? `authorization:github:${status}:${JSON.stringify(payload)}`
    : `authorization:github:${status}:${message}`;

  return `<!doctype html>
<html>
  <head><meta charset="utf-8" /><title>CMS Auth</title></head>
  <body>
    <script>
      (function () {
        var targetOrigin = ${targetOrigin};
        var message = ${JSON.stringify(body)};
        if (window.opener) {
          window.opener.postMessage(message, targetOrigin);
        }
        window.close();
      })();
    </script>
    <p>${ok ? "Authentication successful. You can close this window." : "Authentication failed."}</p>
  </body>
</html>`;
}

async function createState(origin, secret) {
  const payloadObj = {
    nonce: crypto.randomUUID().replace(/-/g, ""),
    origin,
    ts: Date.now(),
  };
  const payload = toBase64Url(JSON.stringify(payloadObj));
  const sig = await sign(payload, secret);
  return `${payload}.${sig}`;
}

async function parseState(rawState, secret) {
  if (!rawState || !rawState.includes(".")) return null;
  const [payload, sig] = rawState.split(".");
  if (!payload || !sig) return null;
  const expectSig = await sign(payload, secret);
  if (expectSig !== sig) return null;

  try {
    const data = JSON.parse(fromBase64Url(payload));
    if (!data?.nonce || !data?.ts) return null;
    if (Date.now() - data.ts > 10 * 60 * 1000) return null;
    return data;
  } catch {
    return null;
  }
}

async function exchangeCodeForToken(code, redirectUri, env) {
  const body = new URLSearchParams({
    client_id: env.GITHUB_CLIENT_ID,
    client_secret: env.GITHUB_CLIENT_SECRET,
    code,
    redirect_uri: redirectUri,
  });

  const response = await fetch("https://github.com/login/oauth/access_token", {
    method: "POST",
    headers: {
      accept: "application/json",
      "content-type": "application/x-www-form-urlencoded",
      "user-agent": "iq1-cms-oauth-broker-cf",
    },
    body,
  });

  const data = await response.json();
  if (!response.ok || !data?.access_token) {
    throw new Error(data?.error_description || data?.error || "Token exchange failed");
  }
  return data.access_token;
}

export default {
  async fetch(request, env) {
    const baseUrl = (env.PUBLIC_BASE_URL || "").replace(/\/$/, "");
    const stateSecret = env.OAUTH_STATE_SECRET || "change-me";
    const allowList = (env.ALLOWED_ORIGINS || "")
      .split(",")
      .map((item) => item.trim())
      .filter(Boolean);

    if (!env.GITHUB_CLIENT_ID || !env.GITHUB_CLIENT_SECRET || !baseUrl) {
      return json(500, {
        error:
          "Missing required env: GITHUB_CLIENT_ID, GITHUB_CLIENT_SECRET, PUBLIC_BASE_URL",
      });
    }

    if (request.method !== "GET") {
      return json(405, { error: "Method not allowed" });
    }

    const url = new URL(request.url);
    const path = url.pathname.toLowerCase();

    if (path === "/" || path.endsWith("/health")) {
      return json(200, { ok: true, service: "github-oauth-broker-cf" });
    }

    if (path.endsWith("/auth")) {
      const origin = normalizeOrigin(url.searchParams.get("origin") || url.searchParams.get("site_url") || "");
      if (origin !== "*" && !isAllowedOrigin(origin, allowList)) {
        return json(400, { error: "Origin not allowed" });
      }

      const state = await createState(origin, stateSecret);
      const redirectUri = `${baseUrl}/callback`;
      const authUrl =
        `https://github.com/login/oauth/authorize?` +
        new URLSearchParams({
          client_id: env.GITHUB_CLIENT_ID,
          redirect_uri: redirectUri,
          scope: "repo,user",
          state,
        }).toString();

      return redirect(authUrl);
    }

    if (path.endsWith("/callback")) {
      const code = url.searchParams.get("code") || "";
      const state = url.searchParams.get("state") || "";
      const oauthError = url.searchParams.get("error") || "";
      const stateData = await parseState(state, stateSecret);
      const origin = stateData?.origin || "*";

      if (oauthError) {
        return html(
          400,
          buildResultPage({ ok: false, origin, message: `GitHub OAuth error: ${oauthError}` }),
        );
      }

      if (!code || !stateData) {
        return html(
          400,
          buildResultPage({ ok: false, origin, message: "Invalid OAuth callback params" }),
        );
      }

      try {
        const redirectUri = `${baseUrl}/callback`;
        const token = await exchangeCodeForToken(code, redirectUri, env);
        return html(200, buildResultPage({ ok: true, origin, payload: { token, provider: "github" } }));
      } catch (err) {
        return html(
          500,
          buildResultPage({
            ok: false,
            origin,
            message: err instanceof Error ? err.message : "OAuth failed",
          }),
        );
      }
    }

    return json(404, { error: "Not found" });
  },
};