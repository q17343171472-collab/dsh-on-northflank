# DSH on Northflank — 24/7 常驻的 DeepSeek Harness

把 DeepSeek Harness（DSH）跑在 **Northflank Sandbox 免费额度**里，电脑关机也能用手机随时连上聊天。

```
手机浏览器 ──https://<xxx>.code.run/?token=...──▶ Northflank 边缘
                                                    │
                                            nginx :8080 (容器内反代)
                                                    │
                                            dsh web 127.0.0.1:3080
```

## 为什么是 Northflank

| 平台 | 免费额度 | 是否睡觉/过期 | 要不要卡 |
|---|---|---|---|
| **Northflank Sandbox** | $20/月资源额度 | **Always on, no sleeping** | **不用卡** |
| Render Free | 15 分钟休眠 | 会睡 | 否 |
| Railway Free | $1/月 credit | 会睡 | 否 |
| Cloudflare Workers | 无常驻容器 | 无状态 | 否 |
| Koyeb Free | 有限 | 会睡 | **要卡** |
| Oracle Always Free | 有限 | 常驻 | **要卡** |

本项目用 `nf-compute-50`（0.5 vCPU / 1 GB，$12/月），落在 $20 额度内，剩下 $8 留给出网流量和磁盘。

## 目录结构

```
Dockerfile                    # node:24 + nginx + tini + dsh（npm 全局装）
entrypoint.sh                 # 容器入口：seed profile → 注入凭证 → 起 dsh → 起 nginx
nginx.conf                    # :8080 反代到 127.0.0.1:3080，保留 Host/Origin
profile/cordis.patch.yml      # 云端 profile 配置（模型、权限、工具、预设）
scripts/merge-credentials.mjs # 把环境变量里的 API key 写进 $DSH_HOME/.credentials.yaml
deploy/deploy.mjs             # 一键部署脚本（Northflank API）
```

## 一键部署

### 1. 拿 Northflank API token

登录 [app.northflank.com](https://app.northflank.com) → 右上头像 → **Account → API tokens** → New token。
token 需要这些权限：

```
Project > Projects > Manage > Create
Project > Secrets > SecretGroups > Create
Project > Services > General > Create
Project > Services > General > Update
```

### 2. 执行

```bash
export NORTHFLANK_API_TOKEN=nf_xxxxxxxx      # Windows PowerShell: $env:NORTHFLANK_API_TOKEN="nf_xxx"
node deploy/deploy.mjs
```

脚本按顺序做这些事：

1. `GET /v1/projects` → 没有就 `POST` 新建项目（`asia-east` 香港区）
2. `GET /v1/projects/{id}/secrets` → 没有就 `POST` 建项目级密钥组，把本地
   `D:\DeepSeek Harness\dsh-data\.credentials.yaml` 里 `refs:` 的各家 API key
   （`AMD_API_KEY`、`X5M5X_API_KEY` 等）上传成环境变量
   > Northflank 变量名不允许下划线，`DEEPSEEK_API_KEY` 会变成 `DEEPSEEK-API-KEY`，
   > 容器里的 `merge-credentials.mjs` 会把横线还原成下划线再写进 `credentials.yaml`
3. `PUT /v1/projects/{id}/services/combined` 建服务：
   - 镜像：`node:24-bookworm-slim` + `@deepseek-ai/dsh@0.2.2-rc.1` + `@xmanrui/dsh-im`
   - 端口：容器内 `8080`（nginx），公网 HTTP
   - 健康检查：TCP 8080（DSH 的 `/` 没有 token 会返回 401，用 HTTP 检查会误判不健康）
   - 构建来源默认走 GitHub 仓库；**如果账号没绑 GitHub，构建失败会自动切成内联 Dockerfile 重来一次**
4. 读端口上的 `*.code.run` 域名 → 写进 `DSH-TRUSTED-HOST` / `DSH-PUBLIC-URL` → 重启
5. 从运行日志里捞出 `dsh web: https://xxx.code.run/?token=...` 打印出来

### 3. 手机上打开

脚本最后会打印一行：

```
带 token  https://xxx.code.run/?token=35a_xxxxxxxx
```

手机浏览器打开它 → 换取成 30 天 cookie → 之后直接开 `https://xxx.code.run/` 即可，不用再带 token。

## 几个必须知道的实现细节

- **DSH 不能绑通配符**。`dsh web --host 0.0.0.0` 会被拒（只接受一个具体 IP 或回环地址），
  所以公网暴露靠 nginx，DSH 本体只听 `127.0.0.1:3080`。
- **浏览器信任栅栏**。DSH 会校验 `Host` / `Origin` / `sec-fetch-site`，
  所以 nginx 必须原样透传 `Host` 和 `Origin`（`proxy_set_header Host $host;`），
  同时 `--trusted-host` 必须包含真实域名，否则 403。
- **启动 token 只在根路径换 cookie**。`?token=` 走 `GET /` 换成一个 authority 绑定的签名 cookie
  （HttpOnly / SameSite=Strict / 30 天），所以必须用带 token 的完整 URL 打开一次。
- **凭证不进仓库**。所有 API key 只存在于 Northflank 的项目级密钥组（静态加密）里，
  容器启动时由 `merge-credentials.mjs` 合并进 `$DSH_HOME/.credentials.yaml`（0600）。
- **模型**。默认 provider `amd` / 模型 `DeepSeek-V4.1-Flash`
  （`https://developer.amd.com.cn/radeon/api/v1`）；`x5m5x` 作为备选。
  本地用的 `bendi`（127.0.0.1:3425）云端不可达，已从云端 patch 里删掉。
- **沙箱没有 GUI**。目录选择器 `auto` 会自动落到 `browse` 后端，Dockerfile 里也显式装了
  `@deepseek-ai/dsh-host-directory-picker-browse` 和 `@deepseek-ai/dsh-client-ui-directory-picker-browse`。

## IM 机器人（微信 / Telegram / 飞书 / 钉钉…）

`@xmanrui/dsh-im` 已经在镜像里装好。进 DSH 网页 → **设置 → IM机器人** → 填渠道配置即可。
机器人是**出站**连接公共 IM 网关，**不需要公网 IP**，所以容器在 Northflank 里也能用。

常用命令：`/menu` `/new` `/model` `/status` `/compact` `/workspace`。

## 运维

```bash
nf logs dsh-web --project <projectId>          # 看日志
nf restart dsh-web --project <projectId>       # 重启
nf scale dsh-web --project <projectId> --instances 1
```

数据都在 `/data`（Northflank ephemeral storage）。重建服务会丢会话记录，
需要长期留存可以在 `deployment.volumes` 里挂持久卷。