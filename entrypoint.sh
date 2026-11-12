#!/usr/bin/env bash
# DSH 容器入口（Northflank / Render / 任何 Docker 平台通用）
set -euo pipefail

DSH_HOME="${DSH_HOME:-/data/dsh}"
DSH_TEMPLATE_HOME="${DSH_TEMPLATE_HOME:-/opt/dsh-template}"
DSH_PORT="${DSH_PORT:-3080}"
# 对外监听端口：Render / Railway 之类会注入 PORT，Northflank 走 8080 默认值
WEB_PORT="${PORT:-8080}"
export DSH_HOME

# nginx 需要写 pid/log 目录
mkdir -p /var/log/nginx /var/lib/nginx /run

log() { printf '[entrypoint] %s\n' "$*"; }

# ── 1. profile 初始化（模板 → 可写目录，只在首次执行时拷贝） ──────────────
mkdir -p "$DSH_HOME/profiles/web"
if [ ! -f "$DSH_HOME/profiles/web/package.json" ]; then
  log "seeding profile from $DSH_TEMPLATE_HOME"
  # 整个 profiles 树一起拷（web/ + 共享的 profiles/node_modules，pnpm 的 symlink 是相对路径，自洽）
  mkdir -p "$DSH_HOME/profiles"
  cp -a "$DSH_TEMPLATE_HOME/profiles/." "$DSH_HOME/profiles/"
fi
# patch 层始终以仓库内版本为准（幂等覆盖）
if [ -f "$DSH_TEMPLATE_HOME/profiles/web/cordis.patch.yml" ]; then
  cp -a "$DSH_TEMPLATE_HOME/profiles/web/cordis.patch.yml" "$DSH_HOME/profiles/web/cordis.patch.yml"
fi

# ── 2. 凭证注入：把平台注入的环境变量写进 credentials.yaml ──
if [ -f /app/scripts/merge-credentials.mjs ]; then
  NODE_PATH="$(npm root -g)" node /app/scripts/merge-credentials.mjs || log "WARNING: credential merge failed"
fi

# ── 3. 组装 dsh 启动参数 ────────────────────────────────────────────────
# --trusted-host 可重复，用逗号分隔多个域名。
# 有的平台（Northflank）变量名不允许下划线，注入的是 DSH-TRUSTED-HOST /
# DSH-PUBLIC-URL，这里用 printenv 兼容两种写法。
env_get() {
  local v
  v="$(printenv "$1" 2>/dev/null || true)"
  if [ -z "$v" ]; then v="$(printenv "$2" 2>/dev/null || true)"; fi
  printf '%s' "$v"
}
TRUSTED_HOSTS="$(env_get DSH_TRUSTED_HOST DSH-TRUSTED-HOST)"
PUBLIC_URL="$(env_get DSH_PUBLIC_URL DSH-PUBLIC-URL)"
: "${TRUSTED_HOSTS:=localhost}"
: "${PUBLIC_URL:=http://localhost:8080/}"
export DSH_TRUSTED_HOST="$TRUSTED_HOSTS"
export DSH_PUBLIC_URL="$PUBLIC_URL"
DSH_ARGS=(--profile web --no-open --port "$DSH_PORT" --host 127.0.0.1 --public-url "$PUBLIC_URL")
IFS=',' read -ra _hosts <<< "$TRUSTED_HOSTS"
for h in "${_hosts[@]}"; do
  h="$(echo "$h" | tr -d '[:space:]')"
  if [ -n "$h" ]; then
    DSH_ARGS+=(--trusted-host "$h")
  fi
done

log "launching: dsh ${DSH_ARGS[*]}"
log "public url: $PUBLIC_URL"

# ── 4. 启动 DSH（后台，日志同时落盘并回显） ─────────────────────────────
mkdir -p "$DSH_HOME"
: > "$DSH_HOME/dsh.log"
dsh "${DSH_ARGS[@]}" 2>&1 | tee -a "$DSH_HOME/dsh.log" &
DSH_PID=$!

term() {
  log "shutting down"
  kill "$DSH_PID" 2>/dev/null || true
  nginx -s quit 2>/dev/null || true
  wait "$DSH_PID" 2>/dev/null || true
  exit 0
}
trap term TERM INT

# 等待 DSH 打印启动 URL（里面带一次性 token）
for i in $(seq 1 60); do
  if grep -qE 'dsh web: https?://' "$DSH_HOME/dsh.log" 2>/dev/null; then
    break
  fi
  sleep 1
done
if grep -qE 'dsh web: https?://' "$DSH_HOME/dsh.log" 2>/dev/null; then
  URL="$(grep -oE 'dsh web: https?://[^ ]+' "$DSH_HOME/dsh.log" | tail -n1)"
  printf '%s\n' "$URL" > "$DSH_HOME/public-url.txt"
  log "launch url (含 token): $URL"
  log "把这一行保存下来，用手机打开即可进入：$URL"
fi

# ── 5. nginx 前台运行（PID 1 语义由 tini 承担） ─────────────────────────
# 平台注入的 PORT 不是 8080 时，生成一份改过端口的配置（Render 默认 10000）
NGINX_CONF=/etc/nginx/nginx.conf
if [ "$WEB_PORT" != "8080" ]; then
  NGINX_CONF=/tmp/nginx.conf
  log "rewriting nginx listen port 8080 -> $WEB_PORT"
  sed -e "s/listen 8080 default_server;/listen ${WEB_PORT} default_server;/" \
      -e "s/listen \[::\]:8080 default_server;/listen [::]:${WEB_PORT} default_server;/" \
      /etc/nginx/nginx.conf > "$NGINX_CONF"
fi
log "web port: $WEB_PORT"
nginx -t -c "$NGINX_CONF"
exec nginx -c "$NGINX_CONF" -g 'daemon off;'
