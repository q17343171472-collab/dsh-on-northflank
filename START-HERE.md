# 从哪开始

**要部署这件事，只看现在这个文件就够了。**

## 现状（2026-11）

- 镜像、入口脚本、nginx 配置、DSH profile 补丁、凭证合并脚本 —— 全部写好并且本地验证过
  （DSH 能正常启动并打印 `?token=` 登录链接）。
- ~~Northflank Sandbox~~ **走不通**：这个账号创建任何服务都被拒：
  `409 Please complete your account by adding a default payment method.`
  （换成 `nf-compute-10`、加不加 buildPlan、连只部署不构建的 `services/deployment` 都一样；
  Northflank 官网写着 Sandbox「No card needed」，但这台账号的实际行为是必须绑卡。）
- 亚洲区域还额外报 `409 Region does not support free projects.` —— 免费项目只能在
  `us-central` / `europe-west` 建。

## 现在走这条路

👉 **[`deploy/render.md`](deploy/render.md) —— Render 免费 Web Service（不要信用卡）**

或者 `deploy/` 下的其它方案（ClawCloud Run 等，见同一篇文档最后一节）。

## 文件说明

| 文件 | 作用 |
| --- | --- |
| `Dockerfile` | node:24 + `npm i -g @deepseek-ai/dsh`，构建期把 DSH profile（含 IM 机器人插件）烤进 `/opt/dsh-template` |
| `entrypoint.sh` | 首次运行把模板 profile 落到 `$DSH_HOME`、合并凭证、起 DSH（只听 127.0.0.1）+ 起 nginx 对外；自动适配平台注入的 `PORT` |
| `nginx.conf` | 对外反代，**原样透传 Host / Origin**（DSH 的浏览器信任栅栏要求），支持 WebSocket/SSE |
| `profile/cordis.patch.yml` | DSH 的 profile 补丁层：权限预设、默认模型、两个 provider、工具集、压缩策略 |
| `scripts/merge-credentials.mjs` | 把平台注入的环境变量写进 `$DSH_HOME/.credentials.yaml`（`refs:` + 浏览器会话密钥） |
| `deploy/render.md` | **当前主推**：Render 免费方案，含环境变量清单、拿登录链接、防休眠 |
| `deploy/deploy.mjs` | Northflank 自动化脚本（账号绑卡后才用得上） |

## 安全提醒

API key 只以环境变量形式注入，仓库里**没有任何密钥**。部署完建议把用过的 key 轮换一遍。
