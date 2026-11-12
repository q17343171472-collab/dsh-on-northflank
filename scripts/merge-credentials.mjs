#!/usr/bin/env node
/**
 * 把 Northflank secret group 注入的环境变量写进 DSH 的本地凭证文件。
 *
 *   $DSH_HOME/.credentials.yaml
 *     version: 1
 *     records: { ... }      # kind: grant + payload
 *     refs:    { KEY: value }
 *
 * 环境变量 → refs 的映射由 DSH_SECRET_REFS 决定（逗号分隔，默认见下），
 * 这样不会把 NORTHFLANK_* / 平台内部变量误写进凭证文件。
 */
import { createRequire } from 'node:module'
import { execSync } from 'node:child_process'
import fs from 'node:fs'
import path from 'node:path'

const require = createRequire(import.meta.url)

function loadYaml() {
  try {
    return require('js-yaml')
  } catch {
    const root = execSync('npm root -g', { encoding: 'utf8' }).trim()
    return createRequire(path.join(root, 'index.js'))('js-yaml')
  }
}

const yaml = loadYaml()

const HOME = process.env.DSH_HOME || '/data/dsh'
const FILE = path.join(HOME, '.credentials.yaml')
const DEFAULT_REFS = [
  'DEEPSEEK_API_KEY',
  'AMD_API_KEY',
  'X5M5X_API_KEY',
  'OPENAI_API_KEY',
  'ANYSEARCH_API_KEY',
  'APIFY_TOKEN',
  'FIRECRAWL_API_KEY',
]

const refNames = (process.env.DSH_SECRET_REFS || DEFAULT_REFS.join(','))
  .split(',')
  .map((s) => s.trim())
  .filter(Boolean)

let doc = { version: 1, records: {}, refs: {} }
if (fs.existsSync(FILE)) {
  try {
    const parsed = yaml.load(fs.readFileSync(FILE, 'utf8'))
    if (parsed && typeof parsed === 'object') {
      doc = {
        version: parsed.version ?? 1,
        records: parsed.records ?? {},
        refs: parsed.refs ?? {},
      }
    }
  } catch (err) {
    console.error('[merge-credentials] 旧凭证文件解析失败，将重建：', err.message)
  }
}
doc.records ||= {}
doc.refs ||= {}

const written = []
for (const name of refNames) {
  // Northflank 的 secret group / runtimeEnvironment 变量名只允许
  // 字母、数字、连字符、斜杠和点 —— 下划线会被拒收，
  // 所以 DEEPSEEK_API_KEY 在平台上以 DEEPSEEK-API-KEY 的形式注入。
  // 两种写法都查一次，写进 refs 时统一还原成下划线形态。
  const candidates = [name, name.replace(/_/g, '-')]
  let value
  for (const key of candidates) {
    const v = process.env[key]
    if (v !== undefined && v !== '') {
      value = v
      break
    }
  }
  if (value === undefined) continue
  doc.refs[name] = value
  written.push(name)
}

// 可选：直接注入一整段 records（例如 deepseek 平台账号 token）
if (process.env.DSH_CREDENTIALS_RECORDS) {
  try {
    const extra = yaml.load(process.env.DSH_CREDENTIALS_RECORDS)
    Object.assign(doc.records, extra ?? {})
    written.push('DSH_CREDENTIALS_RECORDS')
  } catch (err) {
    console.error('[merge-credentials] DSH_CREDENTIALS_RECORDS 解析失败：', err.message)
  }
}

fs.mkdirSync(HOME, { recursive: true })
fs.writeFileSync(FILE, yaml.dump(doc, { lineWidth: 120, noRefs: true }), 'utf8')
try {
  fs.chmodSync(FILE, 0o600)
} catch {}

console.log(`[merge-credentials] ${FILE} 已更新，写入 ${written.length} 项：${written.join(', ') || '(无)'}`)