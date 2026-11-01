#!/usr/bin/env node
/**
 * patch-edit.mjs —— 安全地增删 cordis.patch.yml 里的插件条目
 *
 * 只做「块级文本编辑」，不重新序列化 YAML —— 不动用户其它配置的注释与格式。
 * 用法：
 *   node tools/patch-edit.mjs has    <patch.yml> <id>
 *   node tools/patch-edit.mjs list   <patch.yml>
 *   node tools/patch-edit.mjs add    <patch.yml> <id> <module> [--config key=value ...]
 *   node tools/patch-edit.mjs remove <patch.yml> <id>
 * 退出码：has 存在=0 不存在=1；其余 0=成功 1=失败
 */

import { readFileSync, writeFileSync, existsSync, copyFileSync } from "node:fs"

const [, , command, file, ...rest] = process.argv

if (!command || !file) {
  console.error("用法: node tools/patch-edit.mjs <has|list|add|remove> <patch.yml> [参数]")
  process.exit(2)
}
if (!existsSync(file)) {
  console.error(`找不到文件: ${file}`)
  process.exit(1)
}

const raw = readFileSync(file, "utf8")
const lines = raw.split("\n")

const indentOf = (line) => line.length - line.replace(/^\s*/, "").length
const isBlockStart = (line) => /^\s*-\s/.test(line)

/** 找到 `- id: <id>` 所在行 */
function findEntry(id) {
  const re = new RegExp(`^(\\s*)-\\s*id:\\s*['"]?${escapeRe(id)}['"]?\\s*$`)
  for (let i = 0; i < lines.length; i += 1) {
    const m = re.exec(lines[i])
    if (m) return { index: i, indent: m[1].length }
  }
  return null
}

/** 条目结束位置（不含） */
function entryEnd(start, indent) {
  let i = start + 1
  while (i < lines.length) {
    const line = lines[i]
    if (line.trim() === "") {
      i += 1
      continue
    }
    if (indentOf(line) <= indent) break
    i += 1
  }
  return i
}

/** 向上找所属的 `- insert:` 行 */
function enclosingInsert(startIndex) {
  for (let i = startIndex - 1; i >= 0; i -= 1) {
    const line = lines[i]
    if (!line.trim()) continue
    if (/^\s*-\s*insert:\s*$/.test(line)) return i
    if (indentOf(line) === 0 && !isBlockStart(line)) return -1
  }
  return -1
}

/** insert 块结束位置（不含） */
function insertBlockEnd(insertIndex) {
  const indent = indentOf(lines[insertIndex])
  let i = insertIndex + 1
  while (i < lines.length) {
    const line = lines[i]
    if (line.trim() === "") {
      i += 1
      continue
    }
    if (indentOf(line) <= indent && isBlockStart(line)) break
    i += 1
  }
  return i
}

function escapeRe(text) {
  return String(text).replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
}

function serializeConfig(pairs) {
  if (!pairs.length) return []
  const out = ["      config:"]
  for (const pair of pairs) {
    const eq = pair.indexOf("=")
    if (eq < 0) continue
    const key = pair.slice(0, eq).trim()
    let value = pair.slice(eq + 1).trim()
    if (value === "true" || value === "false" || /^-?\d+$/.test(value)) {
      // 原样输出布尔/数字
    } else if (value.startsWith("[") && value.endsWith("]")) {
      // 数组字面量原样
    } else {
      value = `'${value.replace(/'/g, "''")}'`
    }
    out.push(`        ${key}: ${value}`)
  }
  return out
}

function commit(nextLines) {
  const backup = `${file}.bak-${stamp()}`
  copyFileSync(file, backup)
  let text = nextLines.join("\n")
  if (!text.endsWith("\n")) text += "\n"
  writeFileSync(file, text, "utf8")
  console.log(`已写入 ${file}（备份：${backup}）`)
}

function stamp() {
  const d = new Date()
  const p = (n) => String(n).padStart(2, "0")
  return `${d.getFullYear()}${p(d.getMonth() + 1)}${p(d.getDate())}-${p(d.getHours())}${p(d.getMinutes())}${p(d.getSeconds())}`
}

switch (command) {
  case "has": {
    const id = rest[0]
    const hit = findEntry(id)
    console.log(hit ? `存在（第 ${hit.index + 1} 行）` : "不存在")
    process.exit(hit ? 0 : 1)
    break
  }

  case "list": {
    const re = /^\s*-\s*id:\s*['"]?([^'"\s]+)['"]?\s*$/
    lines.forEach((line, i) => {
      const m = re.exec(line)
      if (m) console.log(`${String(i + 1).padStart(4)}  ${m[1]}`)
    })
    break
  }

  case "add": {
    const [id, moduleName] = rest
    if (!id || !moduleName) {
      console.error("用法: add <patch.yml> <id> <module> [--config k=v ...]")
      process.exit(2)
    }
    if (findEntry(id)) {
      console.log(`条目 ${id} 已存在，跳过（幂等）`)
      break
    }
    const configPairs = []
    const args = rest.slice(2)
    for (let i = 0; i < args.length; i += 1) {
      if (args[i] === "--config" && args[i + 1]) configPairs.push(args[++i])
    }
    const block = ["- insert:", `  - id: ${id}`, `    name: '${moduleName}'`, ...serializeConfig(configPairs)]
    // 去掉文件末尾多余空行，保证块之间只隔一个空行
    while (lines.length && lines[lines.length - 1].trim() === "") lines.pop()
    lines.push("", ...block)
    commit(lines)
    break
  }

  case "remove": {
    const id = rest[0]
    const hit = findEntry(id)
    if (!hit) {
      console.log(`条目 ${id} 不存在，无需删除`)
      break
    }
    const stop = entryEnd(hit.index, hit.indent)
    const insertIdx = enclosingInsert(hit.index)
    let from = hit.index
    let to = stop
    if (insertIdx >= 0) {
      const blockEnd = insertBlockEnd(insertIdx)
      const siblings = lines
        .slice(insertIdx + 1, blockEnd)
        .filter((line) => new RegExp(`^\\s{${hit.indent}}-\\s*id:`).test(line))
      if (siblings.length <= 1) {
        from = insertIdx
        to = blockEnd
      }
    }
    // 吞掉块后紧跟的空行，避免留下连续空行
    if (to < lines.length && lines[to]?.trim() === "") to += 1
    lines.splice(from, to - from)
    commit(lines)
    break
  }

  default:
    console.error(`未知命令: ${command}`)
    process.exit(2)
}
