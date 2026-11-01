#!/usr/bin/env node
/**
 * self-test.mjs —— 不依赖 DSH 宿主，用假 ctx 验证插件核心逻辑。
 * 换机器后先跑这个：node tools/self-test.mjs
 */
import path from "node:path"
import { mkdtemp, mkdir, writeFile, rm } from "node:fs/promises"
import { tmpdir } from "node:os"

const { apply, name, inject } = await import("../index.js")

const results = []
const check = (label, condition, detail = "") => {
  results.push({ label, ok: Boolean(condition), detail })
  console.log(`${condition ? "✔" : "✘"} ${label}${detail ? `  ${detail}` : ""}`)
}

// ── 构造一个临时 DSH_HOME ────────────────────────────────────────────────────
const home = await mkdtemp(path.join(tmpdir(), "wcb-test-"))
const roomDir = path.join(home, "worlds", "default", "room")
await mkdir(roomDir, { recursive: true })
process.env.DSH_HOME = home

const attached = []
const room = {
  path: roomDir,
  record: { title: "测试的房间", sessionIds: ["session-already"] },
  attachSession: async (id) => {
    attached.push(id)
    room.record.sessionIds.push(id)
  },
}

const registry = {
  entities: new Map([[roomDir, room]]),
  async resolveByPath(p) {
    const target = path.resolve(p)
    return this.entities.get(target)
  },
}

const ctx = {
  get: (key) => (key === "workspaceRegistry" ? registry : undefined),
  logger: () => ({ info: () => {}, warn: () => {}, debug: () => {} }),
  on: () => {},
  sessionPersistence: {
    async list() {
      return [
        { header: { id: "session-already", cwd: roomDir } },   // 已在名单，不该重复登记
        { header: { id: "session-qq", cwd: roomDir } },        // 应登记
        { header: { id: "session-other", cwd: "/tmp/elsewhere" } }, // 不该登记
        { header: { id: "session-nocwd" } },                   // 缺 cwd，跳过
      ]
    },
  },
}

check("导出 name", name === "world-channel-bridge", name)
check("导出 inject 含 sessionPersistence", inject.includes("sessionPersistence"))

apply(ctx, { firstDelayMs: 0, intervalMs: 60_000 })
await new Promise((resolve) => setTimeout(resolve, 400))

check("登记了房间内的新会话", attached.includes("session-qq"), JSON.stringify(attached))
check("不重复登记已在名单的会话", !attached.includes("session-already"))
check("不登记房间外的会话", !attached.includes("session-other"))
check("跳过缺 cwd 的会话", !attached.includes("session-nocwd"))
check("暴露了调试入口", typeof ctx.worldChannelBridge?.runNow === "function")

// 幂等性：再跑一次不该新增
const before = attached.length
await ctx.worldChannelBridge.runNow()
await new Promise((resolve) => setTimeout(resolve, 100))
check("重复巡检幂等", attached.length === before, `新增 ${attached.length - before} 个`)

// 房间列表
const rooms = await ctx.worldChannelBridge.listRooms()
check("listRooms 能列出房间", rooms.length === 1 && rooms[0].path === roomDir, JSON.stringify(rooms))

// dryRun 模式不应真的登记
const dryAttached = []
const dryRoom = {
  path: path.join(home, "worlds", "default", "room"),
  record: { title: "dry", sessionIds: [] },
  attachSession: async (id) => dryAttached.push(id),
}
const dryCtx = {
  ...ctx,
  get: () => ({ entities: new Map([[dryRoom.path, dryRoom]]), resolveByPath: async () => dryRoom }),
  worldChannelBridge: undefined,
  on: () => {},
}
apply(dryCtx, { firstDelayMs: 0, intervalMs: 60_000, dryRun: true })
await new Promise((resolve) => setTimeout(resolve, 400))
check("dryRun 不写入", dryAttached.length === 0, `实际写入 ${dryAttached.length}`)

await rm(home, { recursive: true, force: true })

const failed = results.filter((r) => !r.ok)
console.log("")
console.log(`通过 ${results.length - failed.length}/${results.length}`)
process.exit(failed.length === 0 ? 0 : 1)
