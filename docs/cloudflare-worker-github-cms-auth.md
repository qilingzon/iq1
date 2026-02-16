# Cloudflare Worker：Static CMS GitHub 登录（免费方案）

本方案用于在不依赖腾讯云 API 网关的情况下，为 `/admin` 提供 GitHub OAuth 登录能力。

## 1) GitHub OAuth App

在 GitHub Developer Settings -> OAuth Apps -> New OAuth App：

- Application name: `iq1-cms-auth`
- Homepage URL: `https://iqii.cn`
- Authorization callback URL: `https://auth.iqii.cn/callback`

保存后记录：

- `Client ID`
- `Client Secret`

## 2) 创建 Cloudflare Worker

代码文件：

- `oauth/cloudflare-worker/github-oauth-broker.js`

在 Cloudflare Dashboard -> Workers & Pages：

1. 创建 Worker（例如命名 `iq1-cms-oauth`）
2. 粘贴 `oauth/cloudflare-worker/github-oauth-broker.js` 代码并部署

## 3) 设置 Worker 环境变量

在 Worker Settings -> Variables 添加：

- `GITHUB_CLIENT_ID=你的ClientID`
- `GITHUB_CLIENT_SECRET=你的ClientSecret`
- `PUBLIC_BASE_URL=https://auth.iqii.cn`
- `OAUTH_STATE_SECRET=随机长字符串`
- `ALLOWED_ORIGINS=https://iqii.cn`

## 4) 绑定自定义域名

给 Worker 绑定域名：

- `auth.iqii.cn`

DNS 推荐在 Cloudflare 中托管该子域（或用 CNAME 接入）。

如果当前账号暂时无法完成自定义域名绑定，可先使用 Workers 子域：

- 形如 `https://iq1-cms-oauth.<your-subdomain>.workers.dev`
- 此时 GitHub OAuth App 的 callback 也要改成该地址的 `/callback`

## 5) 站点环境变量（EO）

在你的站点部署环境中设置：

- `CMS_BASE_URL=https://auth.iqii.cn`
- `CMS_AUTH_ENDPOINT=/auth`

若使用 Workers 子域临时方案，则将 `CMS_BASE_URL` 改为对应 `workers.dev` 地址。

如果你使用本仓库默认配置（已内置 `https://iq1-cms-oauth.qizo.workers.dev`），这两个站点变量可以不填。

然后重新部署站点。

## 6) 验证

- `https://auth.iqii.cn/health` 应返回 `{"ok":true,...}`
- `https://iqii.cn/admin` 点击登录应跳 GitHub 授权并返回后台

## 7) 1 分钟排错表

- 点登录没反应或空白页：先 `Ctrl+F5` 强刷，再用无痕窗口打开 `/admin`。
- 跳 GitHub 后回不来：GitHub OAuth App 的回调地址必须是 `https://iq1-cms-oauth.qizo.workers.dev/callback`。
- `bad_verification_code` 或 `incorrect_client_credentials`：检查 Worker 的 `GITHUB_CLIENT_ID` / `GITHUB_CLIENT_SECRET` 是否与 GitHub OAuth App 一致。
- `Origin not allowed`：Worker 的 `ALLOWED_ORIGINS` 需包含 `https://iqii.cn`（多域名用英文逗号分隔）。
- `Invalid OAuth callback params`：通常是回调地址不一致或 state 过期，返回 `/admin` 重新发起登录。
- 能进后台但无法写入：登录账号需对仓库 `qilingzon/iq1` 具备写权限。

快速自检命令：

- `npx wrangler secret list --name iq1-cms-oauth`
- `npx wrangler versions list --name iq1-cms-oauth`