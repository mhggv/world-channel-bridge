#!/usr/bin/env node
/**
 * 读写 profile 的 package.json —— 让插件以「正式依赖 + bundle 层」的身份存在。
 *
 *   node tools/manifest-edit.mjs has    <profile/package.json> <name>
 *   node tools/manifest-edit.mjs add    <profile/package.json> <name> [spec]
 *   node tools/manifest-edit.mjs remove <profile/package.json> <name>
 *
 * 为什么需要它
 * ────────────────────────────────────────────────────────────────────────────
 * DSH 的「插件管理 → 已安装」列表（@deepseek-ai/dsh-plugin-manager 的
 * listBundles()）只认 profile package.json 里的两处登记：
 *
 *   dependencies          —— 这个包算「已安装」
 *   dsh.profile.bundles   —— 这个包算「已启用」
 *
 * 只在 node_modules 里塞一个软链、只在 cordis.patch.yml 里插一条 loader 条目，
 * 插件照样能跑，但永远不会出现在那个列表里 —— 这正是「装上了却看不见」的原因。
 *
 * 本脚本只改这两个字段，其余内容（含键顺序）原样保留；写入前由调用方负责备份。
 */
import { readFileSync, writeFileSync } from "node:fs"

const [, , command, file, name, spec] = process.argv

if (!command || !file || !name) {
  console.error("用法: node tools/manifest-edit.mjs <has|add|remove> <profile/package.json> <name> [spec]")
  process.exit(2)
}

function readManifest() {
  let raw
  try {
    raw = readFileSync(file, "utf8")
  } catch (error) {
    console.error(`读取失败 ${file}: ${error.message}`)
    process.exit(2)
  }
  try {
    return { raw, data: JSON.parse(raw) }
  } catch (error) {
    console.error(`${file} 不是合法 JSON：${error.message}`)
    process.exit(2)
  }
}

function writeManifest(data) {
  const text = JSON.stringify(data, void 0, 2) + "\n"
  writeFileSync(file, text, "utf8")
}

function states(data) {
  const dependency = data.dependencies?.[name]
  const bundles = Array.isArray(data.dsh?.profile?.bundles) ? data.dsh.profile.bundles : []
  return {
    dependency: dependency ?? null,
    dependencyDeclared: dependency !== void 0,
    bundleSelected: bundles.includes(name),
    bundles,
  }
}

const { data } = readManifest()

switch (command) {
  case "has": {
    const s = states(data)
    if (s.dependencyDeclared && s.bundleSelected) console.log(`registered ${s.dependency}`)
    else if (s.dependencyDeclared) console.log(`dependency-only ${s.dependency}`)
    else if (s.bundleSelected) console.log("bundle-only")
    else console.log("absent")
    process.exit(0)
  }

  case "add": {
    const target = spec && spec !== "" ? spec : `link:${process.cwd()}`
    data.dependencies ??= {}
    data.dependencies[name] = target
    data.dsh ??= {}
    data.dsh.profile ??= {}
    const bundles = Array.isArray(data.dsh.profile.bundles) ? data.dsh.profile.bundles : []
    if (!bundles.includes(name)) bundles.push(name)
    data.dsh.profile.bundles = bundles
    writeManifest(data)
    console.log(`dependencies["${name}"] = ${target}`)
    console.log(`dsh.profile.bundles += ${name}（共 ${bundles.length} 项）`)
    process.exit(0)
  }

  case "remove": {
    let changed = false
    if (data.dependencies && name in data.dependencies) {
      delete data.dependencies[name]
      changed = true
    }
    const bundles = Array.isArray(data.dsh?.profile?.bundles) ? data.dsh.profile.bundles : null
    if (bundles && bundles.includes(name)) {
      data.dsh.profile.bundles = bundles.filter((item) => item !== name)
      changed = true
    }
    if (changed) {
      writeManifest(data)
      console.log(`已从 dependencies 与 dsh.profile.bundles 移除 ${name}`)
    } else {
      console.log(`${name} 未登记，无需移除`)
    }
    process.exit(0)
  }

  default:
    console.error(`未知命令: ${command}`)
    process.exit(2)
}
