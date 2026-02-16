import crypto from "node:crypto";

const CLIENT_ID = process.env.GITHUB_CLIENT_ID;
const CLIENT_SECRET = process.env.GITHUB_CLIENT_SECRET;
const PUBLIC_BASE_URL = (process.env.PUBLIC_BASE_URL || "").replace(/\/$/, "");
const STATE_SECRET = process.env.OAUTH_STATE_SECRET || "change-me";
const ALLOWED_ORIGINS = (process.env.ALLOWED_ORIGINS || "")
  .split(",")
  .map((item) => item.trim())
  .filter(Boolean);

function json(statusCode, data) {
  return {
    statusCode,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store",
    },
    body: JSON.stringify(data),
  };
}

function redirect(location) {
  return {
    statusCode: 302,
    headers: {
      location,
      "cache-control": "no-store",
    },
    body: "",
  };
}

function html(statusCode, body) {
  return {
    statusCode,
    headers: {
      "content-type": "text/html; charset=utf-8",
      "cache-control": "no-store",
    },
    body,
  };
}

function toBase64Url(input) {
  return Buffer.from(input).toString("base64url");
}

function fromBase64Url(input) {
  return Buffer.from(input, "base64url").toString("utf8");
}

function sign(payload) {
  return crypto.createHmac("sha256", STATE_SECRET).update(payload).digest("hex");
}

function createState(origin) {
  const payloadObj = {
    nonce: crypto.randomBytes(16).toString("hex"),
    origin,
    ts: Date.now(),
  };
  const payload = toBase64Url(JSON.stringify(payloadObj));
  const sig = sign(payload);
  return `${payload}.${sig}`;
}

function parseState(rawState) {
  if (!rawState || !rawState.includes(".")) return null;
  const [payload, sig] = rawState.split(".");
  if (!payload || !sig) return null;
  if (sign(payload) !== sig) return null;
  try {
    const data = JSON.parse(fromBase64Url(payload));
    if (!data?.nonce || !data?.ts) return null;
    if (Date.now() - data.ts > 10 * 60 * 1000) return null;
    return data;
  } catch {
    return null;
  }
}

function getMethod(event) {
  return (
    event?.httpMethod ||
    event?.requestContext?.http?.method ||
    event?.requestContext?.httpMethod ||
    "GET"
  ).toUpperCase();
}

function getPath(event) {
  const rawPath =
    event?.path ||
    event?.rawPath ||
    event?.requestContext?.http?.path ||
    "/";
  return rawPath.toLowerCase();
}

function getQuery(event) {
  if (event?.queryStringParameters) return event.queryStringParameters;
  if (event?.rawQueryString) {
    const entries = new URLSearchParams(event.rawQueryString);
    return Object.fromEntries(entries);
  }
  return {};
}

function isAllowedOrigin(origin) {
  if (!origin) return false;
  if (ALLOWED_ORIGINS.length === 0) return true;
  return ALLOWED_ORIGINS.includes(origin);
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
    client_id: CLIENT_ID,
    client_secret: CLIENT_SECRET,
    code,
    redirect_uri: redirectUri,
  });

  const response = await fetch("https://github.com/login/oauth/access_token", {
    method: "POST",
    headers: {
      accept: "application/json",
      "content-type": "application/x-www-form-urlencoded",
      "user-agent": "iq1-cms-oauth-broker",
    },
    body,
  });

  const data = await response.json();
  if (!response.ok || !data?.access_token) {
    throw new Error(data?.error_description || data?.error || "Token exchange failed");
  }
  return data.access_token;
}

export const main_handler = async (event) => {
  if (!CLIENT_ID || !CLIENT_SECRET || !PUBLIC_BASE_URL) {
    return json(500, {
      error:
        "Missing required env: GITHUB_CLIENT_ID, GITHUB_CLIENT_SECRET, PUBLIC_BASE_URL",
    });
  }

  const method = getMethod(event);
  const path = getPath(event);
  const query = getQuery(event);

  if (method !== "GET") {
    return json(405, { error: "Method not allowed" });
  }

  if (path.endsWith("/health") || path === "/") {
    return json(200, { ok: true, service: "github-oauth-broker" });
  }

  if (path.endsWith("/auth")) {
    const origin = normalizeOrigin(query.origin || query.site_url || "");
    if (origin !== "*" && !isAllowedOrigin(origin)) {
      return json(400, { error: "Origin not allowed" });
    }

    const state = createState(origin);
    const redirectUri = `${PUBLIC_BASE_URL}/callback`;
    const authUrl =
      `https://github.com/login/oauth/authorize?` +
      new URLSearchParams({
        client_id: CLIENT_ID,
        redirect_uri: redirectUri,
        scope: "repo,user",
        state,
      }).toString();

    return redirect(authUrl);
  }

  if (path.endsWith("/callback")) {
    const { code, state, error } = query;
    const stateData = parseState(state);
    const origin = stateData?.origin || "*";

    if (error) {
      const page = buildResultPage({
        ok: false,
        origin,
        message: `GitHub OAuth error: ${error}`,
      });
      return html(400, page);
    }

    if (!code || !stateData) {
      const page = buildResultPage({
        ok: false,
        origin,
        message: "Invalid OAuth callback params",
      });
      return html(400, page);
    }

    try {
      const redirectUri = `${PUBLIC_BASE_URL}/callback`;
      const token = await exchangeCodeForToken(code, redirectUri);
      const page = buildResultPage({
        ok: true,
        origin,
        payload: { token, provider: "github" },
      });
      return html(200, page);
    } catch (err) {
      const page = buildResultPage({
        ok: false,
        origin,
        message: err instanceof Error ? err.message : "OAuth failed",
      });
      return html(500, page);
    }
  }

  return json(404, { error: "Not found" });
};