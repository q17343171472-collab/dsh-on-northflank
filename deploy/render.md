# 无卡方案：Render 免费 Web Service（Docker）

Northflank 免费 Sandbox 在这个账号上被卡在 `409 Please complete your account by adding a default payment method.`
（账号级限制，换套餐 / 换区域都不行）。所以同一套镜像改挂到 **Render 免费 Web Service** ——
注册不要信用卡、Docker 构建、免费 HTTPS 域名、新加坡节点。

代价：免费实例 **15 分钟无入站流量就休眠**，所以配一个免费探活把它叫醒 / 保住。下面第 6 步。

---

## 1. 注册

<https://dashboard.render.com/register> → 用 GitHub 登录（**不需要填卡**）。

## 2. 建服务（Public Git Repository，不用授权 GitHub）

New + → **Web Service** → 选 **Public Git Repository** → 填：

```
https://github.com/q17343171472-collab/dsh-on-northflank
```

然后按下面填：

| 字段 | 值 |
| --- | --- |
| Name | `dsh-web`（决定域名，重名就换一个） |
| Region | **Singapore**（离国内最近） |
| Branch | `main` |
| Runtime | **Docker** |
| Dockerfile Path | `./Dockerfile` |
| Docker Context Directory | `.`（留空） |
| Instance Type | **Free** |

> 实际域名以创建后页面顶部显示的 "Your service is live at …" 为准 —— 第 3 步要用它。

## 3. 环境变量（Environment → Add Environment Variable）

服务创建页往下拉就是 Environment Variables，逐条加（名字区分大小写，Render 允许下划线）：

```
DSH_TRUSTED_HOST=<你的域名，如 dsh-web.onrender.com>
DSH_PUBLIC_URL=https://<你的域名>/
DSH_BROWSER_SESSION_SECRET=<64 位随机串>
AMD_API_KEY=<你的 AMD_API_KEY>
X5M5X_API_KEY=<你的 X5M5X_API_KEY>
OPENAI_API_KEY=<你的 OPENAI_API_KEY>
ANYSEARCH_API_KEY=<你的 ANYSEARCH_API_KEY>
APIFY_TOKEN=<你的 APIFY_TOKEN>
FIRECRAWL_API_KEY=<你的 FIRECRAWL_API_KEY>
```

- `DSH_TRUSTED_HOST` / `DSH_PUBLIC_URL` 必须先知道域名，所以顺序是：先 Create（域名定下来）→
  再去 Environment 补这两个 → Save（会自动重新部署）。
- `DSH_BROWSER_SESSION_SECRET` 随便生成一串固定的随机值（`node -e "console.log(require('crypto').randomBytes(32).toString('hex'))"`），
  作用是把 cookie 签名密钥钉死：以后重新部署，手机上原来的登录 cookie 还有效，不用重新找 token。
- 不填也能跑，只是每次重启都要重新拿一次 `?token=` 链接。
- 默认模型是 `amd / DeepSeek-V4.1-Flash`（见 `profile/cordis.patch.yml`），所以 `AMD_API_KEY` 是必须的。

## 4. 部署

点 **Create Web Service** → 等 Build（拉 node:24 镜像 + `npm i -g @deepseek-ai/dsh`，大约 5～10 分钟）→ 状态变成 **Live**。

## 5. 拿手机登录链接

Logs 面板里找这一行（entrypoint 会打印）：

```
[entrypoint] launch url (含 token): https://<域名>/?token=xxxxxxxx
```

把整条 URL 发到手机，浏览器打开 → 换到 30 天 cookie，之后就只记域名即可。
（这个 token 只在一个 `GET /` 上有效，用过一次即写入 cookie；页面刷新不需要再带 token。）

## 6. 防休眠（必须做）

任选一个免费的定时请求服务，每 **5 分钟** GET 一次 `https://<域名>/`：

- <https://cron-job.org>（免费，注册只要邮箱，不要卡）：Create cronjob → URL 填 `https://<域名>/` → Every 5 minutes → 保存。
- 或 <https://uptimerobot.com>（免费版 5 分钟间隔）：New Monitor → HTTP(s) → 同上 URL。

> `/` 在没 cookie 时返回 **401**，这也算「入站流量」，足够阻止休眠，不用管状态码。

免费额度：每个 workspace 每月 750 小时实例时长，一个月 730 小时 —— 刚好够一个常驻服务。
别开第二个常驻服务，否则会超额被挂起。

## 7. 已知取舍

| 项 | Render Free | 说明 |
| --- | --- | --- |
| 内存 / CPU | 512 MB / 0.1 CPU | DSH 是 IO 型（等模型 API），够用；同时开很多工具子进程会慢 |
| 磁盘 | **不持久** | `/data/dsh` 重启即空，但镜像里已经烤好 profile 模板，启动自动重建，半分钟内可用 |
| 休眠 | 15 分钟无流量 | 用第 6 步的探活解决；冷启动约 1 分钟 |
| 自定义域名 | 免费版不支持 | 用 `*.onrender.com` 就行 |
| 卡 | 不要 | 免费实例不验证支付方式 |

## 8. 备选：ClawCloud Run（无卡，$5/月额度）

同一份 `Dockerfile` 可以直接用：ClawCloud Run → App Launchpad → Image 填一个自己推的公开镜像
（`node:24` 裸镜像起不来），端口 `8080`，挂存储到 `/data`，环境变量同上。

好处是额度按 `$5/月` 折算（1 vCPU / 1 GB 常驻约 $3/月，够），**不按小时限制、不休眠**；
代价是要先自己推一个镜像（本机没有 docker，得走 GitHub Actions 或别的构建机）。
