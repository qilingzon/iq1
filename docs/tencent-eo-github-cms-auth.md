# 腾讯云 EO：Static CMS GitHub 登录部署指南

本指南用于给网站后台 `/admin` 增加 GitHub 登录能力，适用于腾讯云 EO 场景。

## 1) 在 GitHub 创建 OAuth App

可先执行一键参数生成命令：

```bash
npm run cms:auth:setup
```

命令会生成文件：

- `docs/cms-auth.generated.txt`

里面包含 GitHub OAuth 回调地址、SCF 环境变量、EO 环境变量，可直接复制粘贴。

进入 GitHub Developer Settings -> OAuth Apps -> New OAuth App：

- Application name: `iq1-cms-auth`
- Homepage URL: `https://你的站点域名`
- Authorization callback URL: `https://你的认证服务域名/callback`

创建后记录：

- `Client ID`
- `Client Secret`

## 2) 部署腾讯云 SCF 函数

代码文件：

- `oauth/tencent-scf/github-oauth-broker.mjs`

在腾讯云函数（SCF）中新建 Node.js 18+ 函数，入口设置为：

- `index.main_handler`

把 `github-oauth-broker.mjs` 重命名为 `index.mjs` 后上传。

## 3) 配置 SCF 环境变量

在函数环境变量中添加：

- `GITHUB_CLIENT_ID=你的ClientID`
- `GITHUB_CLIENT_SECRET=你的ClientSecret`
- `PUBLIC_BASE_URL=https://你的认证服务域名`
- `OAUTH_STATE_SECRET=随机长字符串`
- `ALLOWED_ORIGINS=https://你的站点域名`

说明：

- `PUBLIC_BASE_URL` 必须与你给函数绑定的公网域名一致。
- `ALLOWED_ORIGINS` 可配置多个，逗号分隔。

## 4) 绑定 API 网关路由

为函数添加 API 网关触发器，保证至少以下路径可访问：

- `GET /auth`
- `GET /callback`
- `GET /health`

部署后先验证：

- 访问 `https://你的认证服务域名/health`
- 返回 `{"ok":true,...}` 即正常。

## 5) 配置站点后台使用认证服务

在网站部署环境（EO）中设置：

- `CMS_BASE_URL=https://你的认证服务域名`
- `CMS_AUTH_ENDPOINT=/auth`

然后重新部署网站。

## 6) 登录验证

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