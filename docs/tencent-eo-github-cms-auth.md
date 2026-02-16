# 腾讯云 EO：Static CMS GitHub 登录部署指南

本指南用于给网站后台 `/admin` 增加 GitHub 登录能力，适用于腾讯云 EO 场景。

若你的腾讯云账号无法新建 API 网关资源，可直接使用免费替代方案：

- `docs/cloudflare-worker-github-cms-auth.md`

## 1) 在 GitHub 创建 OAuth App

可先执行一键参数生成命令：

```bash
npm run cms:auth:setup
```

命令会生成文件：

- `docs/cms-auth.generated.txt`
- `.secrets/cms-auth.local.json`（本地密钥存储，不会提交到 git）

里面包含 GitHub OAuth 回调地址、SCF 环境变量、EO 环境变量，可直接复制粘贴。
并且会保存你后续部署要用的本地参数（包括自动生成的 `OAUTH_STATE_SECRET`）。

进入 GitHub Developer Settings -> OAuth Apps -> New OAuth App：

- Application name: `iq1-cms-auth`
- Homepage URL: `https://你的站点域名`
- Authorization callback URL: `https://你的认证服务域名/callback`

创建后记录：

- `Client ID`
- `Client Secret`

## 2) 部署认证服务（EdgeOne 边缘函数，推荐）

当你的账号无法新建 API 网关资源时（提示 `apigw:CreateService` 无权限或产品限制），请直接使用 EO 边缘函数方案。

代码文件：

- `edge-functions/cms-github-oauth/cms-github-oauth.js`

### 2.1 在 EdgeOne 创建边缘函数

在 EO 控制台中：

1. 创建边缘函数，代码粘贴 `edge-functions/cms-github-oauth/cms-github-oauth.js`
2. 配置环境变量：
   - `GITHUB_CLIENT_ID=你的ClientID`
   - `GITHUB_CLIENT_SECRET=你的ClientSecret`
   - `PUBLIC_BASE_URL=https://你的认证服务域名`
   - `OAUTH_STATE_SECRET=随机长字符串`
   - `ALLOWED_ORIGINS=https://你的站点域名`
3. 绑定路由：
   - `GET /auth`
   - `GET /callback`
   - `GET /health`

### 2.2 绑定认证域名

将边缘函数发布到 `auth.iqii.cn`（或你的认证域名）。

发布后先验证：

- 访问 `https://你的认证服务域名/health`
- 返回 `{"ok":true,...}` 即正常。

## 3) （可选）部署腾讯云 SCF 函数

如果你的账号可正常创建 API 网关资源，也可以继续用 SCF 方案。

代码文件：

- `oauth/tencent-scf/github-oauth-broker.mjs`


### 2.1 半自动部署（推荐）

先确保本机已安装并配置 `tccli`（已完成 `tccli configure`）。

如果你本机只有基础版 `tccli.exe`（没有 `scf` 子命令），先安装插件：

```bash
pip install tccli tencentcloud-cli-plugin-scf tencentcloud-cli-plugin-apigateway
```

然后执行：

```bash
npm run cms:auth:deploy -- \
   -FunctionName iq1-cms-github-oauth \
   -Region ap-guangzhou
```

> 如果你已运行过 `npm run cms:auth:setup` 并填写过参数，`cms:auth:deploy` 会优先自动读取 `.secrets/cms-auth.local.json`，可不再重复输入 GitHub Client ID/Secret、PublicBaseUrl、AllowedOrigins、OAUTH_STATE_SECRET。

该命令会自动：
- 打包 `oauth/tencent-scf/github-oauth-broker.mjs`
- 创建或更新 SCF 函数
- 写入所需环境变量

命令执行完成后，只需要在 API 网关绑定 3 个 GET 路由到该函数：
- `/auth`
- `/callback`
- `/health`

也可以直接执行自动绑定命令：

```bash
npm run cms:auth:bind
```

该命令会尝试自动创建/更新上述 3 个路由触发器。

> 如果你不传 `-OauthStateSecret`，脚本会自动生成一个随机值。

### 2.2 腾讯云函数部署建议（手动方式）

在腾讯云函数（SCF）中新建 Node.js 18+ 函数，入口设置为：

- `index.main_handler`

把 `github-oauth-broker.mjs` 重命名为 `index.mjs` 后上传。

## 4) 配置 SCF 环境变量

在函数环境变量中添加：

- `GITHUB_CLIENT_ID=你的ClientID`
- `GITHUB_CLIENT_SECRET=你的ClientSecret`
- `PUBLIC_BASE_URL=https://你的认证服务域名`
- `OAUTH_STATE_SECRET=随机长字符串`
- `ALLOWED_ORIGINS=https://你的站点域名`

说明：

- `PUBLIC_BASE_URL` 必须与你给函数绑定的公网域名一致。
- `ALLOWED_ORIGINS` 可配置多个，逗号分隔。

## 5) 绑定 API 网关路由

为函数添加 API 网关触发器，保证至少以下路径可访问：

- `GET /auth`
- `GET /callback`
- `GET /health`

部署后先验证：

- 访问 `https://你的认证服务域名/health`
- 返回 `{"ok":true,...}` 即正常。

## 6) 配置站点后台使用认证服务

在网站部署环境（EO）中设置：

- `CMS_BASE_URL=https://你的认证服务域名`
- `CMS_AUTH_ENDPOINT=/auth`

然后重新部署网站。

## 7) 登录验证

访问：

- `https://你的站点域名/admin`

点击登录后应跳转 GitHub 授权，授权完成自动返回 CMS。

## 常见问题

1. 后台空白或登录失败：
   - 检查 `CMS_BASE_URL` 是否正确。
   - 检查 OAuth App 的 callback URL 是否与 `PUBLIC_BASE_URL/callback` 完全一致。

2. 提示 Origin not allowed：
   - 把站点域名加入 `ALLOWED_ORIGINS`。

3. 本地调试：
   - 本地继续使用 `npm run dev` + `npm run cms-proxy-server`。
   - 线上再使用 OAuth 认证服务。