# DSH (DeepSeek Harness) — 24/7 always-on agent container
#
# 架构：
#   nginx :8080 (公网入口，平台边缘把公网域名转到这里)
#     └── proxy_pass → dsh web 127.0.0.1:3080
#
# 注意：dsh web 拒绝 --host 0.0.0.0（通配符），只能绑定具体 IP 或回环地址，
# 所以公网暴露一律由 nginx 反代完成，DSH 本体只监听 127.0.0.1:3080。

FROM node:24-bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    NODE_ENV=production \
    DSH_HOME=/data/dsh \
    DSH_TEMPLATE_HOME=/opt/dsh-template \
    DSH_PORT=3080 \
    PORT=8080

RUN apt-get update && apt-get install -y --no-install-recommends \
      nginx \
      ca-certificates \
      curl \
      git \
      python3 \
      make \
      g++ \
      tini \
    && rm -rf /var/lib/apt/lists/*

# DSH 本体 + pnpm + js-yaml（脚本需要用 js-yaml 读写 credentials.yaml）
RUN npm install -g \
      @deepseek-ai/dsh@0.2.2-rc.1 \
      pnpm@11 \
      js-yaml@4 \
    && npm cache clean --force

# 目录选择器（browse）绝对不要自己装，两种装法都会坏：
#  1) `npm i -g @deepseek-ai/dsh-host-directory-picker-browse` → 构建直接失败：
#     peer 依赖指向未发布的 @deepseek-ai/dsh-paths@^0.0.1-rc.1，npm 报 404。
#  2) 在 profile 里 `pnpm add` 这两个包（不写版本）→ pnpm 装的是 npm 上的 dist-tag latest，
#     而这两个包的 latest 还停在远古的 0.0.1-rc.1 / 0.0.1-rc.3；它们的客户端半边会
#     require('@deepseek-ai/dsh-client-runtime/client')，那个包在 npm 上只发到 0.1.1-rc.2，
#     模块表对不上 ⇒ 网页起来后直接 “Failed to load plugins / web boot: 2 entries did not activate”。
# 正确做法：什么都不装。@deepseek-ai/dsh-web-app@0.2.2-rc.1 已经依赖了同版本的
# dsh-host-directory-picker-{auto,browse,native} 与 dsh-client-ui-directory-picker-{browse,native}，
# 它们就在全局安装树 /usr/local/lib/node_modules 里，profile 的 directory-picker 行会自动解析到
# dsh-host-directory-picker-auto；headless 容器里 auto 会自己选 browse 后端。

# 构建期就生成好 profile（bundles + ds-harness-remote）
# ds-harness-remote 0.6.4 = 手机远程接入插件（P2P + 端到端加密，手机端用 DSH Go / Remote App 配对）
# 注：`dsh plugin --profile <name> <pnpm-args...>` 会把参数原样交给 pnpm，
# 所以这里等价于 `pnpm add -w <包名>`（-w 只能出现一次，包名跟在后面）。
#
# 2026-11-13：已移除 @xmanrui/dsh-im（IM 机器人插件，11 个 IM 平台 SDK）。
#   本机单一配置实测：im 占稳态内存 ≈56 MB（B 配置 215 MB vs A 配置 156 MB），
#   Render 免费层 512 MB 上限下常驻已用 ≈430 MB，去掉 im 可回收这部分留白。
#   需要 IM 遥控时再加回来：`-w @xmanrui/dsh-im` 或用 `dsh plugin --profile web add -w @xmanrui/dsh-im`。
RUN DSH_HOME=/opt/dsh-template dsh plugin --profile web add -w \
        ds-harness-remote@0.6.4

WORKDIR /app
COPY profile/cordis.patch.yml   /opt/dsh-template/profiles/web/cordis.patch.yml
COPY nginx.conf                 /etc/nginx/nginx.conf
COPY scripts/merge-credentials.mjs /app/scripts/merge-credentials.mjs
COPY entrypoint.sh              /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

RUN mkdir -p /data/dsh /data/workspace
VOLUME ["/data"]

EXPOSE 8080
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
