/**
 * world-channel-bridge v1.0.0
 * ────────────────────────────────────────────────────────────────────────────
 * 让「世界控制台」之外的渠道（官方 QQ 机器人、微信、未来的任何接入端）
 * 在发起对话时，自动进入她的记忆体系。
 *
 * ## 要解决什么问题
 *
 * DSH 的 dsh-world 插件把「记忆」（archive.sqlite 里的对话正本、日记、活动）
 * 归档范围限定为「某个工作区（worlds/<名字>/room）的 sessionIds 名单」。
 *
 * 而第三方渠道插件（如 @tencent-connect/dsh-qqbot）创建会话时只设置了
 * cwd 与 agent preset，**不会**调用宿主的 workspaceRegistry.attachSession()
 * 把会话登记进工作区。于是：
 *
 *   QQ 能聊天（会话能建、模型能回） → 但会话不在名单里 → 归档器跳过它
 *   → 记忆正本里没有 QQ 的内容 → 「网页端的她不记得 QQ 聊过什么」
 *
 * 这不是协议问题，是**工作区成员登记**问题。本插件补上这一步：
 * 周期性发现「cwd 落在某个世界房间目录、但尚未登记」的会话，把它们登记进去。
 * 登记后 dsh-world 的归档钩子会自动接管，新消息实时入库。
 *
 * ## 为什么安全
 *
 * 只调用宿主公开 API，不直接改任何文件。
 * 且 workspace.attachSession() 自身会校验「会话的 cwd 必须等于工作区路径」，
 * 不匹配会抛错而不是误登记 —— 插件不可能把无关会话塞进她的记忆。
 *
 * ## 为什么可移植
 *
 * - 零第三方依赖，只用 Node 内置模块；
 * - 不写死任何绝对路径：房间目录从「工作区注册表」里按 .../worlds/<名字>/room 自动识别，
 *   换机器、改目录、加世界都不用改代码；
 * - 所有宿主 API 调用都有防御性判断，宿主版本差异不会导致服务起不来。
 *
 * ## 配置（都可选，写在 profile 的 cordis.patch.yml 条目里）
 *
 * - id: world-channel-bridge
 *   name: world-channel-bridge
 *   config:
 *     intervalMs: 30000        # 巡检间隔（毫秒），新会话最多延迟这么久被登记
 *     worlds: [default]        # 只处理这些世界；留空 = 全部
 *     roomDirs: []             # 显式指定房间目录；留空 = 自动发现
 *     worldNamePattern: ''     # 自定义房间目录识别正则；留空 = 默认 .../worlds/<名>/room
 *     dryRun: false            # true = 只写日志不实际登记（排障用）
 *     verbose: false           # true = 每次巡检都打日志
 * ────────────────────────────────────────────────────────────────────────────
 */

import path from "node:path"
import os from "node:os"
import { existsSync } from "node:fs"
import { readdir, realpath } from "node:fs/promises"

export const name = "world-channel-bridge"

// sessionPersistence 用于读取全部会话的 header（拿到 cwd）；这是插件唯一强依赖。
export const inject = ["sessionPersistence"]

const VERSION = "1.0.0"

const DEFAULTS = {
  intervalMs: 30_000,
  firstDelayMs: 2_000,
  worlds: [],
  roomDirs: [],
  worldNamePattern: "",
  dshHome: "",
  dryRun: false,
  verbose: false,
}

// .../worlds/<世界名>/room  （同时兼容 Windows 反斜杠与结尾斜杠）
const DEFAULT_ROOM_RE = /[\\/]worlds[\\/]([^\\/]+?)[\\/]room[\\/]?$/

export function apply(ctx, config = {}) {
  const options = normalizeConfig(config)
  const log = makeLogger(ctx)
  const roomRe = options.worldNamePattern ? safeRegExp(options.worldNamePattern, DEFAULT_ROOM_RE) : DEFAULT_ROOM_RE

  // 同一条失败信息只报一次，避免每 30 秒刷屏
  const reported = new Set()
  let timer
  let firstRun = true
  let running = false

  const registry = () => {
    try {
      return ctx.get?.("workspaceRegistry") ?? ctx.workspaceRegistry
    } catch {
      return undefined
    }
  }

  // ── 发现世界房间 ──────────────────────────────────────────────────────────
  async function discoverRooms() {
    const reg = registry()
    if (!reg) return []

    const rooms = new Map() // 规范化路径 -> { path, world, entity }

    // 来源 1：工作区注册表里所有形如 .../worlds/<名>/room 的工作区
    for (const entity of await listWorkspaceEntities(reg)) {
      const roomPath = entity?.path
      if (typeof roomPath !== "string") continue
      const match = roomRe.exec(roomPath)
      if (!match) continue
      const world = match[1]
      if (options.worlds.length && !options.worlds.includes(world)) continue
      rooms.set(roomPath, { path: roomPath, world, entity })
    }

    // 来源 2：显式配置的房间目录（哪怕注册表里匹配不到，也尝试解析一次）
    for (const dir of options.roomDirs) {
      const entity = await safe(() => reg.resolveByPath(dir))
      if (!entity) continue
      const match = roomRe.exec(entity.path)
      const world = match?.[1] ?? path.basename(path.dirname(entity.path))
      if (options.worlds.length && !options.worlds.includes(world)) continue
      rooms.set(entity.path, { path: entity.path, world, entity })
    }

    // 来源 3：文件系统兜底（注册表还没建起来 / 世界刚创建时）
    if (rooms.size === 0) {
      for (const dir of await scanWorldsDir()) {
        const entity = await safe(() => reg.resolveByPath(dir))
        if (!entity) continue
        const match = roomRe.exec(entity.path)
        const world = match?.[1] ?? path.basename(path.dirname(entity.path))
        if (options.worlds.length && !options.worlds.includes(world)) continue
        rooms.set(entity.path, { path: entity.path, world, entity })
      }
    }

    return [...rooms.values()]
  }

  async function scanWorldsDir() {
    const home = options.dshHome || process.env.DSH_HOME || path.join(os.homedir(), "home")
    const worldsRoot = path.join(home, "worlds")
    const dirs = []
    try {
      for (const entry of await readdir(worldsRoot, { withFileTypes: true })) {
        if (!entry.isDirectory()) continue
        const roomDir = path.join(worldsRoot, entry.name, "room")
        if (existsSync(roomDir)) dirs.push(roomDir)
      }
    } catch {
      /* 目录不存在：不是错误，注册表来源已覆盖 */
    }
    return dirs
  }

  // ── 收集候选会话 ──────────────────────────────────────────────────────────
  async function listSessionHeaders() {
    let raw
    try {
      raw = await ctx.sessionPersistence.list()
    } catch (error) {
      warnOnce(`读取会话列表失败: ${errorText(error)}`)
      return []
    }
    // 兼容多种返回形态：数组 / Map / { sessions: [] }
    if (Array.isArray(raw)) return raw
    if (raw instanceof Map) return [...raw.values()]
    if (Array.isArray(raw?.sessions)) return raw.sessions
    if (typeof raw?.[Symbol.iterator] === "function") return [...raw]
    return []
  }

  // ── 一次巡检 ──────────────────────────────────────────────────────────────
  async function tick() {
    if (running) return
    running = true
    try {
      const rooms = await discoverRooms()
      if (rooms.length === 0) {
        warnOnce(
          registry()
            ? "已连上工作区服务，但没找到形如 worlds/<名>/room 的工作区；若你确实没建世界可忽略，否则用 doctor.sh 看房间路径"
            : "工作区服务 workspaceRegistry 尚未就绪，下个周期重试（若持续出现，说明 DSH 版本不兼容）",
        )
        return
      }

      // roomPath -> [sessionId]
      const buckets = new Map(rooms.map((room) => [room.path, []]))
      const headers = await listSessionHeaders()

      for (const item of headers) {
        const header = item?.header ?? item
        if (!header?.id || typeof header.cwd !== "string") continue
        const key = await matchRoom(header.cwd, buckets)
        if (key) buckets.get(key).push(header.id)
      }

      let attachedTotal = 0
      for (const room of rooms) {
        const ids = buckets.get(room.path) ?? []
        const members = new Set(room.entity?.record?.sessionIds ?? [])
        for (const id of ids) {
          if (members.has(id)) continue
          if (options.dryRun) {
            log.info?.(`[dry-run] 会话 ${id} 应登记进「${room.entity?.record?.title ?? room.world}」(cwd=${room.path})`)
            members.add(id)
            attachedTotal += 1
            continue
          }
          try {
            await room.entity.attachSession(id)
            members.add(id)
            attachedTotal += 1
            log.info?.(`已登记会话 ${id} →「${room.entity?.record?.title ?? room.world}」，该渠道的对话将进入记忆归档`)
          } catch (error) {
            warnOnce(`登记会话 ${id} 失败: ${errorText(error)}`)
          }
        }
      }

      if (firstRun) {
        const tracked = [...buckets.values()].reduce((sum, ids) => sum + ids.length, 0)
        log.info?.(
          `v${VERSION} 已就绪：监控 ${rooms.length} 个世界房间、${tracked} 个渠道会话` +
            (attachedTotal ? `，本次登记 ${attachedTotal} 个` : ""),
        )
        firstRun = false
      } else if (attachedTotal > 0) {
        log.info?.(`本轮新增登记 ${attachedTotal} 个会话`)
      } else if (options.verbose) {
        log.debug?.(`巡检完成：${rooms.length} 个房间，无需改动`)
      }
    } catch (error) {
      warnOnce(`巡检异常: ${errorText(error)}`)
    } finally {
      running = false
    }
  }

  // cwd 与房间路径比较（先按字面归一化；仅在必要时走 realpath，避免频繁 IO）
  async function matchRoom(cwd, buckets) {
    const normalized = normalizePath(cwd)
    if (buckets.has(normalized)) return normalized
    for (const roomPath of buckets.keys()) {
      if (roomPath === normalized) return roomPath
    }
    // realpath 兜底（符号链接 / 大小写差异等）
    const resolved = await safe(() => realpath(cwd))
    if (resolved) {
      const hit = [...buckets.keys()].find((p) => normalizePath(p) === normalizePath(resolved))
      if (hit) return hit
    }
    return undefined
  }

  function warnOnce(message) {
    if (reported.has(message)) return
    reported.add(message)
    log.warn?.(message)
  }

  // ── 启动 ──────────────────────────────────────────────────────────────────
  const kick = () => {
    // 宿主服务可能还在装配，首次延迟一点点再扫
    setTimeout(() => void tick(), options.firstDelayMs)?.unref?.()
  }

  kick()
  timer = setInterval(() => void tick(), options.intervalMs)
  timer?.unref?.()

  ctx.on?.("dispose", () => {
    if (timer) clearInterval(timer)
  })

  // 暴露给宿主/调试用（有 UI 面板时可以直接点一下）
  try {
    ctx.worldChannelBridge = {
      version: VERSION,
      options,
      runNow: tick,
      listRooms: async () =>
        (await discoverRooms()).map((room) => ({
          world: room.world,
          path: room.path,
          title: room.entity?.record?.title,
          sessions: room.entity?.record?.sessionIds?.length ?? 0,
        })),
    }
  } catch {
    /* 只读上下文时忽略 */
  }
}

// ── 工具函数 ────────────────────────────────────────────────────────────────

async function listWorkspaceEntities(registry) {
  try {
    if (registry.entities instanceof Map) return [...registry.entities.values()]
    if (typeof registry.list === "function") {
      const result = await registry.list()
      if (Array.isArray(result)) return result
      if (result instanceof Map) return [...result.values()]
      if (Array.isArray(result?.workspaces)) return result.workspaces
    }
    if (Array.isArray(registry.entities)) return registry.entities
  } catch {
    /* 宿主版本差异时静默降级到文件系统兜底 */
  }
  return []
}

function normalizeConfig(config) {
  const merged = { ...DEFAULTS, ...(config ?? {}) }
  const int = (value, fallback, min) => {
    const n = Number(value)
    return Number.isFinite(n) && n >= min ? n : fallback
  }
  return {
    ...merged,
    intervalMs: int(merged.intervalMs, DEFAULTS.intervalMs, 1_000),
    firstDelayMs: int(merged.firstDelayMs, DEFAULTS.firstDelayMs, 0),
    worlds: toArray(merged.worlds),
    roomDirs: toArray(merged.roomDirs),
    worldNamePattern: String(merged.worldNamePattern ?? ""),
    dshHome: String(merged.dshHome ?? ""),
    dryRun: Boolean(merged.dryRun),
    verbose: Boolean(merged.verbose),
  }
}

function toArray(value) {
  if (Array.isArray(value)) return value.map(String).filter(Boolean)
  if (typeof value === "string" && value.trim()) return [value.trim()]
  return []
}

function normalizePath(value) {
  return path.resolve(String(value)).replace(/[\\/]+$/, "")
}

function safeRegExp(pattern, fallback) {
  try {
    return new RegExp(pattern)
  } catch {
    return fallback
  }
}

async function safe(fn) {
  try {
    return await fn()
  } catch {
    return undefined
  }
}

function errorText(error) {
  return error instanceof Error ? error.message : String(error)
}

function makeLogger(ctx) {
  // 直接用 console：DSH 会把子进程 stdout/stderr 收进 journald，
  // 而 ctx.logger 在部分版本/日志级别下不落到系统日志里（会导致「插件明明在跑却像没加载」）。
  // 前缀固定，方便 `journalctl | grep world-channel-bridge` 检索。
  const prefix = "[world-channel-bridge]"
  const line = (message) => `${prefix} ${message}`
  return {
    info: (message) => console.log(line(message)),
    warn: (message) => console.warn(line(message)),
    debug: (message) => console.log(line(message)),
  }
}
