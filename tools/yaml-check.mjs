#!/usr/bin/env node
/**
 * yaml-check.mjs —— 校验 cordis.patch.yml 是否仍可被 DSH 解析
 *
 * DSH 的补丁文件里会出现自定义标签（如 `disabled: !!js 'process.platform === ''win32'''`），
 * 标准 js-yaml 不认识 `!!js`，直接用默认 schema 解析会误报失败。
 * 这里先按原样解析，失败再剥离自定义标签重试，避免把「正常文件」判成「坏文件」。
 *
 * 用法: node tools/yaml-check.mjs <patch.yml> <profileDir> [必须包含的id]
 * 退出码: 0 通过 / 1 失败 / 2 无法校验（profile 内没有 js-yaml）
 */

import { createRequire } from "node:module"
import { readFileSync } from "node:fs"
import path from "node:path"

const require = createRequire(import.meta.url)
const [, , patchFile, profileDir, requiredId] = process.argv

if (!patchFile || !profileDir) {
  console.error("用法: node tools/yaml-check.mjs <patch.yml> <profileDir> [必须包含的id]")
  process.exit(2)
}

let yaml
try {
  yaml = require(path.join(profileDir, "node_modules", "js-yaml"))
} catch {
  process.exit(2)
}

const text = readFileSync(patchFile, "utf8")

function collectIds(document) {
  const ids = []
  const walk = (entry) => {
    if (!entry || typeof entry !== "object") return
    if (Array.isArray(entry.insert)) {
      for (const item of entry.insert) if (item?.id) ids.push(String(item.id))
      return
    }
    if (entry.id) ids.push(String(entry.id))
  }
  if (Array.isArray(document)) document.forEach(walk)
  return ids
}

const attempts = [
  { label: "原始", source: text },
  // 剥离自定义标签后再试一次（!!js / !js 这类宿主扩展类型）
  { label: "剥离自定义标签", source: text.replace(/!!js\s+/g, "").replace(/!js\s+/g, "") },
]

let lastError
for (const attempt of attempts) {
  try {
    const document = yaml.load(attempt.source)
    const ids = collectIds(document)
    if (!Array.isArray(document)) {
      console.error("顶层结构不是数组")
      process.exit(1)
    }
    if (requiredId && !ids.includes(requiredId)) {
      console.error(`解析成功但没找到条目 ${requiredId}（共 ${ids.length} 个）`)
      process.exit(1)
    }
    const dupes = ids.filter((id, index) => ids.indexOf(id) !== index)
    if (dupes.length) console.log(`  警告：存在重复条目 ${[...new Set(dupes)].join(", ")}`)
    console.log(`  ${attempt.label}解析通过：${ids.length} 个条目${requiredId ? `，含 ${requiredId}` : ""}`)
    process.exit(0)
  } catch (error) {
    lastError = error
  }
}

console.error(`YAML 无法解析：${lastError?.message ?? lastError}`)
if (lastError?.mark) {
  console.error(`  位置：第 ${lastError.mark.line + 1} 行第 ${lastError.mark.column + 1} 列`)
}
process.exit(1)
