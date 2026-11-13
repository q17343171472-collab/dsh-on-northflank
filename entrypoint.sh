#!/usr/bin/env bash
# DSH (DeepSeek Harness) 容器入口
#
# 流程：
#   1. 首次运行时把镜像内烘焙好的 profile 拷到可写目录
#   2. 把平台注入的环境变量合并进 credentials.yaml（密钥只走环境变量，不进镜像/仓库）
#   2.5 从 DSH_REMOTE_STATE_B64 还原手机配对状态（免费层文件系统是临时的，不还原就每次重新配对）
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

# ds-harness-remote 的全部身份/配对状态都在这里。
# 目录名 servers/<scope> 是对中继 origin 的 sha256 前 24 位，
# 中继固定为 https://dsh.r2049.cn ⇒ scope 恒为 e9988d504cda7c1541adafcc，
# 所以整棵树可以原样备份/还原，位置不会漂。
REMOTE_ROOT="$DSH_HOME/ds-harness-remote"

mkdir -p /var/log/nginx /var/lib/nginx /run

log() { printf '[entrypoint] %s\n' "$*"; }

# 平台差异：有的平台不允许环境变量名带下划线，所以两种写法都兼容
env_get() {
  local v
  v="$(printenv "$1" 2>/dev/null || true)"
  if [ -z "$v" ]; then v="$(printenv "$2" 2>/dev/null || true)"; fi
  printf '%s' "$v"
}

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
log "  磁盘: $(df -h / /data 2>/dev/null | tr -s ' \t' '  ' | tr '\n' '|' || true)"
log "  内存: $(grep -E '^(MemTotal|MemAvailable)' /proc/meminfo 2>/dev/null | tr -s ' ' | tr '\n' ' ')"
log "  CPU: $(nproc 2>/dev/null || echo '?') 核   node: $(node -v 2>/dev/null || echo '?')   pnpm: $(pnpm -v 2>/dev/null || echo '?')"
log "  DSH_HOME 已用: $(du -sh "$DSH_HOME" 2>/dev/null | cut -f1 || echo '?')"
log "────────────────────────────────────────────"

# ── 2. 凭证注入：环境变量 → credentials.yaml ──────────────────────────────
if [ -f /app/scripts/merge-credentials.mjs ]; then
  NODE_PATH="$(npm root -g)" node /app/scripts/merge-credentials.mjs || log "WARNING: credential merge failed"
fi

# ── 2.5 还原手机配对状态（关键：免费层每次 deploy/restart/spin-down 都清空磁盘） ──
# 首次配对后由 watchdog 把 tar.gz 的 base64 打进日志，粘进 Render 环境变量
# DSH_REMOTE_STATE_B64（Render 不允许下划线时用 DSH-REMOTE-STATE-B64）。
# 之后每次冷启动在这里还原，手机端不需要重新扫码。
remote_state_restore() {
  local b64 tmp
  b64="$(env_get DSH_REMOTE_STATE_B64 DSH-REMOTE-STATE-B64)"
  if [ -z "$b64" ]; then
    log "remote state: 环境变量未设置（首次启用此功能，或还没配对过）→ 走全新身份"
    return 0
  fi
  if [ -d "$REMOTE_ROOT/servers" ] && [ -n "$(ls -A "$REMOTE_ROOT/servers" 2>/dev/null || true)" ]; then
    log "remote state: 磁盘上已有身份，跳过还原"
    return 0
  fi
  log "remote state: 从环境变量还原（${#b64} 字符 base64）"
  tmp="$(mktemp -d)"
  if printf '%s' "$b64" | base64 -d > "$tmp/state.tar.gz" 2>/dev/null && [ -s "$tmp/state.tar.gz" ]; then
    if tar -xzf "$tmp/state.tar.gz" -C "$DSH_HOME" 2>/dev/null; then
      # identity-store 在 linux 上强制校验 device.key / pairing 文件必须是 0600，否则启动直接抛 IDENTITY_INVALID
      find "$REMOTE_ROOT" -type f \( -name '*.key' -o -name 'host-pairing.json' -o -name 'pairing-host-only.json' \) -exec chmod 600 {} + 2>/dev/null || true
      chmod 700 "$REMOTE_ROOT" 2>/dev/null || true
      log "remote state: 还原完成（$(du -sh "$REMOTE_ROOT" 2>/dev/null | cut -f1)）"
    else
      log "WARNING: remote state 解包失败，按全新身份启动（手机端需要再配一次）"
    fi
  else
    log "WARNING: DSH_REMOTE_STATE_B64 不是合法 base64，忽略"
  fi
  rm -rf "$tmp"
}
remote_state_restore

# ── 3. 组装 dsh 启动参数 ────────────────────────────────────────────────
# --trusted-host 可重复，用逗号分隔多个域名。
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

# ── 4.5 配对状态导出 watchdog ────────────────────────────────────────────
# 免费层没有 shell、没有持久磁盘，所以把「导出」做成日志通道：
# 状态一变（= 手机刚配对成功 / 中继重新注册），就把整棵 ds-harness-remote 打成
# tar.gz 再 base64，按 1000 字符一块打到日志里。把 [rs-XXXofYYY] 后面的内容
# 按顺序拼起来，就是 DSH_REMOTE_STATE_B64 的完整值。只在变化时打，不刷屏。
remote_state_dump() {
  [ -d "$REMOTE_ROOT/servers" ] || return 0
  local blob chunk i total
  blob="$( cd "$DSH_HOME" && tar -czf - ds-harness-remote 2>/dev/null | base64 -w0 )"
  [ -n "$blob" ] || return 0
  total=$(( (${#blob} + 999) / 1000 ))
  log "remote state snapshot: ${#blob} 字符 / $total 块 —— 拼起来即为 DSH_REMOTE_STATE_B64"
  i=0
  while [ $i -lt $total ]; do
    chunk="$(printf '%s' "$blob" | cut -c$((i*1000+1))-$(((i+1)*1000)))"
    log "[rs-$(printf '%03d' $((i+1)))of$(printf '%03d' $total)] $chunk"
    i=$((i+1))
  done
}

remote_state_watch() {
  local sig prev="__init__" last=0 now
  while true; do
    sleep 15
    # 整棵树取指纹：配对、中继注册、凭证续期都会改文件，不能只盯一个
    sig="$( (find "$REMOTE_ROOT" -type f -print0 2>/dev/null | xargs -0 -r md5sum 2>/dev/null | sort) | md5sum 2>/dev/null | cut -d' ' -f1 || true)"
    if [ -z "$sig" ]; then continue; fi
    now="$(date +%s)"
    if [ "$sig" != "$prev" ] && [ $((now - last)) -ge 60 ]; then
      prev="$sig"
      last="$now"
      log "remote state: 检测到状态变化，导出快照"
      remote_state_dump || true
    fi
  done
}
remote_state_watch &

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
