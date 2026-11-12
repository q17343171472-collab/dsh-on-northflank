#!/usr/bin/env node
/**
 * DSH → Northflank 一键部署脚本
 *
 *   node deploy/deploy.mjs            # 建项目 → 建密钥组 → 建服务 → 写域名 → 重启 → 取 token
 *   node deploy/deploy.mjs --dry-run  # 只打印将要发起的请求，不真正调用
 *   node deploy/deploy.mjs --inline   # 不依赖 GitHub，直接把 Dockerfile 内联进构建请求
 *
 * 环境变量
 *   NORTHFLANK_API_TOKEN   必填，个人 API token（Northflank App → Account → API tokens）
 *   NF_REGION              默认 asia-east（香港）
 *   NF_PROJECT_NAME        默认 "DSH 24x7"
 *   NF_SERVICE_NAME        默认 "dsh-web"
 *   NF_SECRET_NAME         默认 "dsh-secrets"
 *   NF_PLAN                默认 nf-compute-50（$12/月，落在 Sandbox $20/月额度内）
 *   NF_REPO_URL            默认 https://github.com/q17343171472-collab/dsh-on-northflank
 *   NF_REPO_BRANCH         默认 main
 *   DSH_LOCAL_CREDENTIALS  本地凭证文件路径（读 refs: 里的各家 API key）
 *   NF_SECRET_KEYS         要上传的 key 列表，逗号分隔
 *   NF_PUBLIC_HOST         手动指定公网域名（不给就自动读端口 DNS）
 */

import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = path.dirname(fileURLToPath(import.meta.url))
const ROOT = path.resolve(HERE, '..')

const API = 'https://api.northflank.com/v1'
const TOKEN = process.env.NORTHFLANK_API_TOKEN || ''
const DRY = process.argv.includes('--dry-run')
const INLINE = process.argv.includes('--inline')

const REGION = process.env.NF_REGION || 'asia-east'
const PROJECT_NAME = process.env.NF_PROJECT_NAME || 'DSH 24x7'
const SERVICE_NAME = process.env.NF_SERVICE_NAME || 'dsh-web'
const SECRET_NAME = process.env.NF_SECRET_NAME || 'dsh-secrets'
const PLAN = process.env.NF_PLAN || 'nf-compute-50'
const REPO_URL = process.env.NF_REPO_URL || 'https://github.com/q17343171472-collab/dsh-on-northflank'
const REPO_BRANCH = process.env.NF_REPO_BRANCH || 'main'
const CREDS_FILE =
  process.env.DSH_LOCAL_CREDENTIALS || 'D:\\DeepSeek Harness\\dsh-data\\.credentials.yaml'
// 构建来源：repo = 从 GitHub 仓库构建（需要 Northflank 能访问该仓库）
//          inline = 把 Dockerfile 内联进 API 请求（不依赖任何仓库访问）
let MODE = INLINE ? 'inline' : 'repo'
const SECRET_KEYS = (
  process.env.NF_SECRET_KEYS ||
  'DEEPSEEK_API_KEY,AMD_API_KEY,X5M5X_API_KEY,OPENAI_API_KEY,ANYSEARCH_API_KEY,APIFY_TOKEN,FIRECRAWL_API_KEY'
)
  .split(',')
  .map((s) => s.trim())
  .filter(Boolean)

const t0 = Date.now()
const log = (...a) => console.log(`[${String((Date.now() - t0) / 1000).padStart(6)}s]`, ...a)

async function api(method, p, body) {
  if (DRY) {
    log(`DRY-RUN ${method} ${p}`)
    if (body) console.log(JSON.stringify(body, null, 2).slice(0, 4000))
    return { __dry: true, data: {} }
  }
  const res = await fetch(`${API}${p}`, {
    method,
    headers: {
      Authorization: `Bearer ${TOKEN}`,
      'Content-Type': 'application/json',
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  })
  const text = await res.text()
  let json
  try {
    json = text ? JSON.parse(text) : {}
  } catch {
    json = { raw: text }
  }
  if (!res.ok) {
    throw new Error(`${method} ${p} → HTTP ${res.status}\n${text.slice(0, 2000)}`)
  }
  log(`${method} ${p} → ${res.status}`)
  return json
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

/* ── 本地凭证：只解析 refs: 这个扁平键值块 ──────────────────────────────── */
function parseRefs(text) {
  const out = {}
  let inRefs = false
  for (const line of text.split(/\r?\n/)) {
    if (/^refs:\s*$/.test(line)) {
      inRefs = true
      continue
    }
    if (!inRefs) continue
    if (/^\S/.test(line)) break // 下一个顶层键，refs 结束
    const m = line.match(/^\s+([A-Za-z0-9_.-]+):\s*(.*)$/)
    if (!m) continue
    let v = m[2].trim()
    if ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'"))) {
      v = v.slice(1, -1)
    }
    if (v === '' || v === '|' || v === '>') continue
    out[m[1]] = v
  }
  return out
}

function loadLocalRefs() {
  if (!fs.existsSync(CREDS_FILE)) {
    log(`本地凭证文件不存在，跳过密钥上传：${CREDS_FILE}`)
    return {}
  }
  const refs = parseRefs(fs.readFileSync(CREDS_FILE, 'utf8'))
  const picked = {}
  for (const k of SECRET_KEYS) {
    if (refs[k]) picked[k] = refs[k]
  }
  log(`本地凭证命中 ${Object.keys(picked).length} 项：${Object.keys(picked).join(', ') || '(无)'}`)
  return picked
}

/* ── Dockerfile：仓库模式直接用文件；inline 模式把附属文件内联进去 ───────── */
const INLINE_FILES = {
  'profile/cordis.patch.yml': '/opt/dsh-template/profiles/web/cordis.patch.yml',
  'nginx.conf': '/etc/nginx/nginx.conf',
  'scripts/merge-credentials.mjs': '/app/scripts/merge-credentials.mjs',
  'entrypoint.sh': '/usr/local/bin/entrypoint.sh',
}

function buildInlineDockerfile() {
  let df = fs.readFileSync(path.join(ROOT, 'Dockerfile'), 'utf8')
  for (const [src, dst] of Object.entries(INLINE_FILES)) {
    const file = path.join(ROOT, src)
    if (!fs.existsSync(file)) continue
    const b64 = fs.readFileSync(file).toString('base64')
    const copyLine = new RegExp(
      `^COPY\\s+${src.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\s+${dst.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\s*$`,
      'm'
    )
    if (!copyLine.test(df)) {
      log(`警告：Dockerfile 里没找到 COPY ${src} ${dst}，内联模式跳过该文件`)
      continue
    }
    // 用 base64 单行写回：Dockerfile 里不出现 heredoc，classic builder / kaniko 都能解析
    const replacement = `RUN mkdir -p ${path.posix.dirname(dst)} && echo '${b64}' | base64 -d > ${dst}`
    df = df.replace(copyLine, replacement)
  }
  return df
}

/* ── 组装服务规格 ───────────────────────────────────────────────────────── */
function serviceSpec(runtimeEnvironment) {
  const spec = {
    name: SERVICE_NAME,
    description: 'DSH web — 24/7 online, reachable from phone',
    tags: ['dsh'],
    billing: { deploymentPlan: PLAN },
    deployment: {
      instances: 1,
      docker: { configType: 'default' },
      storage: { ephemeralStorage: { storageSize: 4096 }, shmSize: 512 },
      strategy: { type: 'rollout-steady' },
      zonalRedundancy: { type: 'disabled' },
    },
    ports: [
      { name: 'http', internalPort: 8080, protocol: 'HTTP', public: true, vpcAccessible: false },
    ],
    healthChecks: [
      {
        protocol: 'TCP',
        type: 'livenessProbe',
        port: 8080,
        initialDelaySeconds: 30,
        periodSeconds: 15,
        timeoutSeconds: 5,
        failureThreshold: 6,
      },
      {
        protocol: 'TCP',
        type: 'readinessProbe',
        port: 8080,
        initialDelaySeconds: 20,
        periodSeconds: 10,
        timeoutSeconds: 5,
        failureThreshold: 6,
      },
    ],
    runtimeEnvironment,
  }
  if (MODE === 'inline') {
    spec.buildSettings = {
      dockerfile: {
        dockerFilePath: '/Dockerfile',
        dockerWorkDir: '/',
        buildEngine: 'kaniko',
        dockerfileContents: buildInlineDockerfile(),
      },
    }
  } else {
    spec.vcsData = { projectUrl: REPO_URL, projectType: 'github', projectBranch: REPO_BRANCH }
    spec.buildSettings = {
      dockerfile: { dockerFilePath: '/Dockerfile', dockerWorkDir: '/', buildEngine: 'kaniko' },
    }
  }
  return spec
}

/* ── 等构建结束，失败就把构建日志打出来 ─────────────────────────────────── */
async function waitForBuild(projectId, serviceId, minutes = 12) {
  const deadline = Date.now() + minutes * 60 * 1000
  let last = ''
  while (Date.now() < deadline) {
    const res = await api('GET', `/v1/projects/${projectId}/services/${serviceId}`)
    const st = res?.data?.status?.build?.status || res?.data?.status?.deployment?.status || ''
    const dep = res?.data?.status?.deployment?.status || ''
    if (st !== last) {
      log(`构建状态：${st || '(未知)'} 部署状态：${dep || '(未知)'}`)
      last = st
    }
    if (['SUCCESS', 'CRASHED', 'IN_PROGRESS'].includes(st) && dep === 'COMPLETED') return 'ok'
    if (['FAILURE', 'SUBMISSION_FAILURE', 'ABORTED', 'UNSCHEDULABLE'].includes(st)) return 'failed'
    if (st === 'SUCCESS' && dep === 'COMPLETED') return 'ok'
    await sleep(10000)
  }
  return 'timeout'
}

async function dumpBuildLogs(projectId, serviceId) {
  const res = await api(
    'GET',
    `/v1/projects/${projectId}/services/${serviceId}/logs?type=build&lineLimit=200&direction=backward`
  )
  const txt = JSON.stringify(res)
  console.log('\n----- 构建日志（尾部） -----')
  console.log(txt.slice(-4000))
  console.log('---------------------------\n')
}

/* ── 主流程 ─────────────────────────────────────────────────────────────── */
async function main() {
  if (!TOKEN && !DRY) {
    console.error('缺少环境变量 NORTHFLANK_API_TOKEN。')
    console.error('Northflank App → Account → API tokens → 新建 token → 复制后执行：')
    console.error('  $env:NORTHFLANK_API_TOKEN = "nf_xxx"   (PowerShell)')
    process.exit(1)
  }

  /* 1) 项目 */
  const projectsRes = await api('GET', '/v1/projects')
  const projects = projectsRes?.data?.projects || []
  let project = projects.find((p) => (p.name || '').toLowerCase() === PROJECT_NAME.toLowerCase())
  if (project) {
    log(`复用项目 ${project.name} (${project.id})`)
  } else {
    const created = await api('POST', '/v1/projects', {
      name: PROJECT_NAME,
      description: 'DeepSeek Harness — always-on web deployment',
      color: '#2F6FEB',
      region: REGION,
    })
    project = created?.data
    log(`新建项目 ${project?.name} (${project?.id}) @ ${REGION}`)
  }
  const projectId = project?.id
  if (!projectId) throw new Error('拿不到 projectId')

  /* 2) 密钥组（项目级 → 自动注入到该项目所有资源） */
  const refs = loadLocalRefs()
  const variables = {}
  for (const [k, v] of Object.entries(refs)) {
    variables[k.replace(/_/g, '-')] = v // Northflank 变量名不允许下划线
  }
  const secretBody = {
    name: SECRET_NAME,
    description: 'DSH provider credentials (injected as environment variables)',
    secretType: 'environment',
    priority: 50,
    type: 'secret',
    restrictions: { restricted: false },
    secrets: { variables },
  }
  const secretsRes = await api('GET', `/v1/projects/${projectId}/secrets`)
  const secrets = secretsRes?.data?.secrets || []
  const existing = secrets.find((s) => (s.name || '').toLowerCase() === SECRET_NAME.toLowerCase())
  if (existing) {
    await api('PATCH', `/v1/projects/${projectId}/secrets/${existing.id}`, {
      ...secretBody,
      name: undefined,
    })
    log(`更新密钥组 ${SECRET_NAME} (${existing.id})，${Object.keys(variables).length} 个变量`)
  } else {
    const created = await api('POST', `/v1/projects/${projectId}/secrets`, secretBody)
    log(`新建密钥组 ${SECRET_NAME} (${created?.data?.id})，${Object.keys(variables).length} 个变量`)
  }

  /* 3) 服务（PUT = create-or-update） */
  const bootEnv = {
    'DSH-TRUSTED-HOST': 'bootstrap.invalid',
    'DSH-PUBLIC-URL': 'https://bootstrap.invalid/',
  }
  let spec = serviceSpec(bootEnv)
  let svcRes = await api('PUT', `/v1/projects/${projectId}/services/combined`, spec)
  let service = svcRes?.data
  const serviceId = service?.id
  log(`服务就位 ${service?.name} (${serviceId})｜构建来源：${MODE}`)
  if (!serviceId) {
    log('拿不到 serviceId，把服务端返回原文贴出来看：')
    console.log(JSON.stringify(svcRes).slice(0, 2000))
    process.exit(2)
  }

  /* 3.5) 等构建；仓库构建失败（多半是没绑 GitHub 账号）→ 自动改内联构建重来 */
  const buildResult = await waitForBuild(projectId, serviceId)
  if (buildResult === 'failed' && MODE === 'repo') {
    log('仓库构建失败，改用内联 Dockerfile 重试…')
    await dumpBuildLogs(projectId, serviceId)
    MODE = 'inline'
    spec = serviceSpec(bootEnv)
    svcRes = await api('PUT', `/v1/projects/${projectId}/services/combined`, spec)
    const again = await waitForBuild(projectId, serviceId)
    if (again !== 'ok') {
      await dumpBuildLogs(projectId, serviceId)
      log('内联构建也没成功，日志在上面。')
      process.exit(4)
    }
  } else if (buildResult !== 'ok') {
    await dumpBuildLogs(projectId, serviceId)
    log(`构建未成功（${buildResult}），日志在上面。`)
    process.exit(4)
  }

  /* 4) 等端口 DNS（code.run 域名） */
  let dns = process.env.NF_PUBLIC_HOST || ''
  if (!dns) {
    for (let i = 0; i < 40; i++) {
      const portsRes = await api('GET', `/v1/projects/${projectId}/services/${serviceId}/ports`)
      const ports = portsRes?.data?.ports || []
      const hit = ports.find((p) => p.dns) || ports.find((p) => (p.domains || []).length)
      if (hit) {
        dns = hit.dns || hit.domains[0]
        break
      }
      log('等待端口 DNS 分配…')
      await sleep(6000)
    }
  }
  if (!dns) {
    log('没拿到 code.run 域名。两种办法：')
    log('  1) 在 Northflank 控制台打开这个服务，复制它的公开 URL，再执行：')
    log('     $env:NF_PUBLIC_HOST = "xxxx.code.run"; node deploy/deploy.mjs')
    process.exit(3)
  }
  dns = String(dns).replace(/^https?:\/\//, '').replace(/\/$/, '')
  log(`公网域名：${dns}`)

  /* 5) 写运行时环境（真实域名 → 浏览器信任栅栏放行）并重启 */
  const realEnv = {
    'DSH-TRUSTED-HOST': dns,
    'DSH-PUBLIC-URL': `https://${dns}/`,
  }
  await api('PATCH', `/v1/projects/${projectId}/services/combined/${serviceId}`, {
    runtimeEnvironment: realEnv,
  })
  log('runtimeEnvironment 已写入，准备重启')
  await api('POST', `/v1/projects/${projectId}/services/${serviceId}/restart`)

  /* 6) 从运行日志里捞一次性启动 token */
  let launchUrl = ''
  for (let i = 0; i < 60; i++) {
    await sleep(5000)
    const logsRes = await api(
      'GET',
      `/v1/projects/${projectId}/services/${serviceId}/logs?type=runtime&lineLimit=400&direction=backward`
    )
    const blob = JSON.stringify(logsRes)
    const m = blob.match(/dsh web: (https?:\\?\/\\?\/[^"\\ ]+)/)
    if (m) {
      launchUrl = m[1].replace(/\\?\//g, '/')
      if (launchUrl.includes('token=')) break
    }
    if (i % 4 === 0) log('等待服务启动日志…')
  }

  console.log('\n' + '='.repeat(66))
  console.log('部署完成')
  console.log('='.repeat(66))
  console.log(`项目      ${PROJECT_NAME} (${projectId}) @ ${REGION}`)
  console.log(`服务      ${SERVICE_NAME} (${serviceId})  套餐 ${PLAN}`)
  console.log(`公网地址  https://${dns}/`)
  if (launchUrl) {
    const token = (launchUrl.match(/token=([A-Za-z0-9_-]+)/) || [])[1]
    console.log(`带 token  https://${dns}/?token=${token}`)
    console.log('\n手机浏览器直接打开上面这行 → 会写入 cookie，之后直接开 https://' + dns + '/ 即可。')
  } else {
    console.log('\n启动日志里还没抓到 token，去 Northflank 控制台看这个服务的 runtime 日志，')
    console.log(`找 "dsh web: https://${dns}/?token=..." 那一行，或者执行：`)
    console.log(`  nf logs ${SERVICE_NAME} --project ${projectId}`)
  }
  console.log('\n下一步（可选）：在 DSH 里开 IM 机器人')
  console.log('  设置 → IM机器人 → 填渠道配置（微信 iLink / Telegram / 飞书 / 钉钉 …）')
  console.log('  机器人是出站连接，不需要公网 IP。')
  console.log('='.repeat(66))
}

main().catch((err) => {
  console.error('\n部署失败：', err.message)
  process.exit(1)
})