#!/usr/bin/env bash
# DSH (DeepSeek Harness) 容器入口
#
# 流程：
#   1. 首次运行时把镜像内烘焙好的 profile 拷到可写目录
#   2. 把平台注入的环境变量合并进 credentials.yaml（密钥只走环境变量，不进镜像/仓库）
#   3. 启动 dsh web（只监听 127.0.0.1），等它打印带 token 的登录 URL
#   4. nginx 监听平台指定端口并反代到 dsh（动态端口：平台注入 PORT，Render 默认 10000）
#   5. dsh 一旦退出就退出容器，让平台重启，避免 nginx 对着死上游返回 502
set -euo pipefail

DSH_HOME="${DSH_HOME:-/data/dsh}"
DSH_TEMPLATE_HOME="${DSH_TEMPLATE_HOME:-/opt/dsh-template}"
DSH_PORT="${DSH_PORT:-3080}"
# 对外监听端口：Render / Railway 之类会注入 PORT，本地默认 8080
WEB_PORT="${PORT:-8080}"
export DSH_HOME

mkdir -p /var/log/nginx /var/lib/nginx /run

log() { printf '[entrypoint] %s\n' "$*"; }

# ── 1. profile 初始化（模板 → 可写目录，只在首次执行时拷贝） ──────────────
mkdir -p "$DSH_HOME/profiles/web"
if [ ! -f "$DSH_HOME/profiles/web/package.json" ]; then
  log "seeding profile from $DSH_TEMPLATE_HOME"
  mkdir -p "$DSH_HOME/profiles"
  # 整个 profiles 树一起拷（web/ + 共享的 profiles/node_modules，pnpm 的 symlink 是相对路径，自洽）
  cp -a "$DSH_TEMPLATE_HOME/profiles/." "$DSH_HOME/profiles/"
fi
# patch 层始终以仓库内版本为准（幂等覆盖）
if [ -f "$DSH_TEMPLATE_HOME/profiles/web/cordis.patch.yml" ]; then
  cp -a "$DSH_TEMPLATE_HOME/profiles/web/cordis.patch.yml" "$DSH_HOME/profiles/web/cordis.patch.yml"
fi

# ── 1.5 启动自检：把磁盘 / 内存 / CPU 的真实数字打进日志 ──────────────────
# 免费实例资源很少（Render Free = 512 MB / 0.1 CPU / 临时文件系统），先看清家底，
# 以后再装 skill / MCP / 插件时就知道还剩多少空间。
log "── 资源自检 ─────────────────────────────────"
while IFS= read -r line; do log "  $line"; done < <(df -h / /data 2>/dev/null || true)
log "  内存: $(grep -E '^(MemTotal|MemAvailable)' /proc/meminfo 2>/dev/null | tr -s ' ' | tr '\n' ' ')"
log "  CPU: $(nproc 2>/dev/null || echo '?') 核   node: $(node -v 2>/dev/null || echo '?')   pnpm: $(pnpm -v 2>/dev/null || echo '?')"
log "  DSH_HOME 已用: $(du -sh "$DSH_HOME" 2>/dev/null | cut -f1 || echo '?')"
log "────────────────────────────────────────────"

# ── 2. 凭证注入：环境变量 → credentials.yaml ──────────────────────────────
if [ -f /app/scripts/merge-credentials.mjs ]; then
  NODE_PATH="$(npm root -g)" node /app/scripts/merge-credentials.mjs || log "WARNING: credential merge failed"
fi

# ── 3. 组装 dsh 启动参数 ────────────────────────────────────────────────
# --trusted-host 可重复，用逗号分隔多个域名。
# 有的平台不允许环境变量名带下划线，所以两种写法都兼容。
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

# 等 DSH 打印启动 URL（里面带 token）；最多等 150 秒
for _ in $(seq 1 150); do
  if grep -qE 'dsh web: https?://' "$DSH_HOME/dsh.log" 2>/dev/null; then break; fi
  if grep -q 'startup failed' "$DSH_HOME/dsh.log" 2>/dev/null; then break; fi
  sleep 1
done

if grep -q 'startup failed' "$DSH_HOME/dsh.log" 2>/dev/null; then
  log "!! DSH 启动失败，下面是失败原因（完整诊断见 \$DSH_HOME/logs/）"
  grep -A 20 'startup failed' "$DSH_HOME/dsh.log" || true
  exit 1
fi

if grep -qE 'dsh web: https?://' "$DSH_HOME/dsh.log" 2>/dev/null; then
  URL="$(grep -oE 'dsh web: https?://[^ ]+' "$DSH_HOME/dsh.log" | tail -n1)"
  printf '%s\n' "$URL" > "$DSH_HOME/public-url.txt"
  log "launch url (含 token): $URL"
  log "★ 用手机打开这一行的网址即可登录（令牌可重复使用，登录后换成 30 天 cookie）"
else
  log "!! 等不到 dsh web 的启动 URL（150 秒超时），日志尾部："
  tail -n 30 "$DSH_HOME/dsh.log" || true
  exit 1
fi

# ── 5. nginx 反代（动态端口） ───────────────────────────────────────────
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
nginx -c "$NGINX_CONF" -g 'daemon off;' &
NGINX_PID=$!

sleep 2
CODE="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${WEB_PORT}/" || echo 000)"
log "self-check http://127.0.0.1:${WEB_PORT}/ -> $CODE （401 属于正常：nginx 已通，只是请求没带 token）"

# DSH 退出就退出容器（平台会重启），不要让 nginx 对着死上游一直 502
wait "$DSH_PID" || true
log "dsh 进程已退出，容器退出让平台重启"
kill "$NGINX_PID" 2>/dev/null || true
exit 1
