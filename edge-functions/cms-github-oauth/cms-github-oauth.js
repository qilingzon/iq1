const {
  GITHUB_CLIENT_ID,
  GITHUB_CLIENT_SECRET,
  PUBLIC_BASE_URL,
  OAUTH_STATE_SECRET,
  ALLOWED_ORIGINS,
} = Deno.env.toObject();

const BASE_URL = (PUBLIC_BASE_URL || "").replace(/\/$/, "");
const STATE_SECRET = OAUTH_STATE_SECRET || "change-me";
const ALLOW_LIST = (ALLOWED_ORIGINS || "")
  .split(",")
  .map((item) => item.trim())
  .filter(Boolean);

function json(statusCode, data) {
  return new Response(JSON.stringify(data), {
    status: statusCode,
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

function html(statusCode, body) {
  return new Response(body, {
    status: statusCode,
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

async function sign(payload) {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(STATE_SECRET),
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

async function createState(origin) {
  const payloadObj = {
    nonce: crypto.randomUUID().replace(/-/g, ""),
    origin,
    ts: Date.now(),
  };
  const payload = toBase64Url(JSON.stringify(payloadObj));
  const sig = await sign(payload);
  return `${payload}.${sig}`;
}

async function parseState(rawState) {
  if (!rawState || !rawState.includes(".")) return null;
  const [payload, sig] = rawState.split(".");
  if (!payload || !sig) return null;
  const expectSig = await sign(payload);
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

function normalizeOrigin(origin) {
  if (!origin) return "*";
  try {
    const url = new URL(origin);
    return `${url.protocol}//${url.host}`;
  } catch {
    return "*";
  }
}

function isAllowedOrigin(origin) {
  if (!origin) return false;
  if (ALLOW_LIST.length === 0) return true;
  return ALLOW_LIST.includes(origin);
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

async function exchangeCodeForToken(code, redirectUri) {
  const body = new URLSearchParams({
    client_id: GITHUB_CLIENT_ID,
    client_secret: GITHUB_CLIENT_SECRET,
    code,
    redirect_uri: redirectUri,
  });

  const response = await fetch("https://github.com/login/oauth/access_token", {
    method: "POST",
    headers: {
      accept: "application/json",
      "content-type": "application/x-www-form-urlencoded",
      "user-agent": "iq1-cms-oauth-broker-edgeone",
    },
    body,
  });

  const data = await response.json();
  if (!response.ok || !data?.access_token) {
    throw new Error(data?.error_description || data?.error || "Token exchange failed");
  }
  return data.access_token;
}

function getPath(url) {
  return url.pathname.toLowerCase();
}

export default async (request) => {
  if (!GITHUB_CLIENT_ID || !GITHUB_CLIENT_SECRET || !BASE_URL) {
    return json(500, {
      error:
        "Missing required env: GITHUB_CLIENT_ID, GITHUB_CLIENT_SECRET, PUBLIC_BASE_URL",
    });
  }

  if (request.method !== "GET") {
    return json(405, { error: "Method not allowed" });
  }

  const url = new URL(request.url);
  const path = getPath(url);

  if (path.endsWith("/health") || path === "/") {
    return json(200, { ok: true, service: "github-oauth-broker-edgeone" });
  }

  if (path.endsWith("/auth")) {
    const origin = normalizeOrigin(url.searchParams.get("origin") || url.searchParams.get("site_url") || "");
    if (origin !== "*" && !isAllowedOrigin(origin)) {
      return json(400, { error: "Origin not allowed" });
    }

    const state = await createState(origin);
    const redirectUri = `${BASE_URL}/callback`;
    const authUrl =
      `https://github.com/login/oauth/authorize?` +
      new URLSearchParams({
        client_id: GITHUB_CLIENT_ID,
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

    const stateData = await parseState(state);
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
      const redirectUri = `${BASE_URL}/callback`;
      const token = await exchangeCodeForToken(code, redirectUri);
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
};