# DSH (DeepSeek Harness) on Northflank — 24/7 always-on agent
#
# 架构：
#   nginx :8080 (公网入口，Northflank 边缘把 *.code.run 转到这里)
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

# 目录选择器：headless 容器里 auto 会选 browse，这里把 browse 包也显式装上，
# 保证 @deepseek-ai/dsh-host-directory-picker-auto 的 peer 能解析到。
RUN npm install -g \
      @deepseek-ai/dsh-host-directory-picker-browse \
      @deepseek-ai/dsh-client-ui-directory-picker-browse \
    && npm cache clean --force

# 构建期就生成好 profile（bundles + dsh-im + browse picker），运行时只做拷贝
RUN DSH_HOME=/opt/dsh-template dsh plugin --profile web add -w @xmanrui/dsh-im \
    && cd /opt/dsh-template/profiles/web \
    && (pnpm add \
          @deepseek-ai/dsh-host-directory-picker-browse \
          @deepseek-ai/dsh-client-ui-directory-picker-browse || true)

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