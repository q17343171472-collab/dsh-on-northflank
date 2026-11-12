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

# 目录选择器（browse）不要用 `npm i -g` 装：
# peer 依赖指向未发布的 @deepseek-ai/dsh-paths@^0.0.1-rc.1，npm 会直接 404（实测构建失败）。
# 正确做法是在 profile 里用 pnpm 装（见下面的 RUN），因为 pnpm-workspace.yaml 设了
# autoInstallPeers: false，不会去解析那些未发布的 peer。
# headless 容器里 auto 选择器会自动选 browse 后端。

# 构建期就生成好 profile（bundles + dsh-im + ds-harness-remote + browse picker），运行时只做拷贝
# ds-harness-remote 0.6.4 = 手机远程接入插件（P2P + 端到端加密，手机端用 DSH Go / Remote App 配对）
# 注：`dsh plugin --profile <name> <pnpm-args...>` 会把参数原样交给 pnpm，
# 所以这里等价于 `pnpm add -w <两个包>`（-w 只能出现一次，两个包名跟在后面）。
RUN DSH_HOME=/opt/dsh-template dsh plugin --profile web add -w \
        @xmanrui/dsh-im \
        ds-harness-remote@0.6.4 \
    && cd /opt/dsh-template/profiles/web \
    && pnpm add \
          @deepseek-ai/dsh-host-directory-picker-browse \
          @deepseek-ai/dsh-client-ui-directory-picker-browse

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
