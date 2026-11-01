# world-channel-bridge

[![CI](https://github.com/mhggv/world-channel-bridge/actions/workflows/ci.yml/badge.svg)](https://github.com/mhggv/world-channel-bridge/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Node](https://img.shields.io/badge/node-%3E%3D20-brightgreen.svg)](https://nodejs.org)

让**官方 QQ 机器人**（以及任何走会话的外部渠道）说的话，真正进入「世界控制台」里那个人格的记忆。

零依赖、零硬编码路径、可跨机器复用。装完即忘，不需要再改任何代码。

> A zero-dependency DSH/Cordis plugin that registers external-channel sessions
> (official QQ bot, WeChat, …) into the world room workspace, so their conversations
> actually reach `dsh-world`'s memory archive.

---

## 它解决什么问题

DSH 的世界插件（`dsh-world`）只归档**某个工作区名单里的会话**：

```
归档范围 = 工作区「她/他的房间」的 sessionIds 名单
```

而官方 QQ 插件（`@tencent-connect/dsh-qqbot`）创建会话时，只设置了 cwd 和 agent preset，**没有**把会话登记进工作区名单。于是出现一个很隐蔽的现象：

| 层面 | 状态 |
|---|---|
| QQ 能收消息、能回话 | ✅ 正常 |
| 会话确实建在她的房间目录下 | ✅ 正常 |
| 会话进入记忆归档 | ❌ 被过滤器跳过 |

结果就是「数据通、记忆不通」：QQ 上聊得再多，网页端的她也不知道；日记里也没有 QQ 的痕迹；会话一压缩，那些对话就永久消失。

**本插件补的就是这一步登记动作。**

```
QQ 消息 ──► im-qqbot 建会话（cwd = worlds/default/room）
                       │
                       ▼
        ✗ 缺少 attachSession()  ← 断点在这里
                       │
          world-channel-bridge（本插件）
                       │  发现「cwd 在房间目录、但不在名单」的会话
                       ▼
        ✓ workspace.attachSession(sessionId)
                       │
                       ▼
        dsh-world 归档钩子接管 ──► archive.sqlite（记忆正本）
                                 └► 日记 / 活动 / 长期记忆
```

---

## 为什么它是安全的

- 只调用宿主公开 API（`workspaceRegistry`、`sessionPersistence`），不直接改任何数据文件；
- 宿主 `attachSession()` 自带硬校验：**会话的 cwd 必须等于工作区路径**，否则抛错。所以插件不可能把无关会话塞进她的记忆；
- 幂等：已在名单里的会话直接跳过，重复巡检不会产生重复记录；
- 失败只告警，不会拖垮 DSH 服务。

---

## 快速安装

**方式一：git clone（推荐）**

```bash
git clone https://github.com/mhggv/world-channel-bridge.git
cd world-channel-bridge
sudo ./install.sh
```

**方式二：下载 Release 包**

```bash
curl -L -o wcb.tar.gz https://github.com/mhggv/world-channel-bridge/releases/latest/download/world-channel-bridge-1.0.0.tar.gz
tar xzf wcb.tar.gz && cd world-channel-bridge
sudo ./install.sh
```

脚本会自动完成：

1. 探测 `DSH_HOME`、profile 目录、node、systemd 服务名和运行用户（都可用参数覆盖）；
2. 把插件放到 `$DSH_HOME/plugins/world-channel-bridge`；
3. 在 profile 的 `node_modules` 建软链（**绝对路径**，不会因目录层级算错）；
4. 在 `cordis.patch.yml` 追加 `- insert:` 条目（幂等，自动备份原文件）；
5. 校验 YAML 仍可解析、模块可被宿主导入；
6. 重启服务并回读日志确认插件真的加载了。

常用参数：

```bash
./install.sh --home /path/to/dsh-home --profile /path/to/dsh-home/profiles/web
./install.sh --no-restart      # 只装不重启
./install.sh --link            # 不复制文件，直接软链到当前目录（便于反复调试）
./install.sh --dry-run         # 只打印将要做什么
```

### 非 systemd 环境（Windows / macOS / 前台启动）

```bash
./install.sh --home <DSH_HOME> --profile <profile目录> --no-restart
```

然后手动重启你的 DSH 进程即可。Windows 下请用 Git Bash 或 WSL 执行。

---

## 配置

全部可选。想调就改 profile 的 `cordis.patch.yml` 里这个条目：

```yaml
- insert:
  - id: world-channel-bridge
    name: 'world-channel-bridge'
    config:
      intervalMs: 30000       # 巡检间隔（毫秒），新会话最多延迟这么久被登记
      worlds: ['default']     # 只处理这些世界；留空 = 全部
      roomDirs: []            # 显式指定房间目录；留空 = 自动发现
      worldNamePattern: ''    # 自定义房间目录识别正则；留空 = .../worlds/<名>/room
      dshHome: ''             # 显式指定 DSH_HOME；留空 = 环境变量 / 自动探测
      dryRun: false           # true = 只写日志不登记（排障用）
      verbose: false          # true = 每轮巡检都打日志
```

改完重启服务生效。

> 大多数情况下**一个都不用配**：房间目录是从工作区注册表里按 `.../worlds/<名>/room` 自动识别的，换机器、加世界、改目录都不用动代码。

---

## 验证

```bash
./doctor.sh
```

一条命令体检 6 项：插件文件、模块链接、代码可导入、配置条目与 YAML、服务状态与运行日志、**各房间已登记的会话数 + 记忆正本记录数**。全绿就是真的在跑。

单看日志：

```bash
journalctl -u dsh-web -n 200 | grep world-channel-bridge
```

正常长这样：

```
[world-channel-bridge] v1.0.0 已就绪：监控 1 个世界房间、3 个渠道会话
[world-channel-bridge] 已登记会话 session-xxxx →「房间标题」，该渠道的对话将进入记忆归档
```

**双向验收**（最有说服力）：

1. 在 QQ 上告诉她一件新鲜事 → 去网页端问她，她应该记得；
2. 在网页端告诉她一件事 → 去 QQ 上问她，她也应该记得。

---

## 换机器怎么用

1. 新机器装好 DSH、跑起 `dsh-world` 和 QQ 插件，确认两边都能聊；
2. 把本目录拷过去，`sudo ./install.sh`；
3. `./doctor.sh` 看到房间和会话数就成。

**不需要**改代码、不需要记路径、不需要手动改 YAML。如果新机器的目录结构特殊，用 `--home` / `--profile` 指定即可。

> 若要连历史记忆一起搬，另行迁移 `worlds/<名>/archive.sqlite`、`worlds/<名>/room`、`sessions/` 等数据，
> 并保证路径与旧机一致（会话 header 里钉的是绝对路径）。本插件只负责「新对话进得来」。

---

## 排障

| 现象 | 原因 | 处理 |
|---|---|---|
| 日志里完全没有 `world-channel-bridge` | 插件没被加载 | `doctor.sh` 看「配置条目」和「模块链接」；注意 patch 条目必须是 `- insert:` 形式，直接用顶层 `- id:` 只能覆盖已有插件，新插件会被静默跳过 |
| 有加载日志但会话数一直是 0 | 渠道会话的 cwd 不是房间目录 | 看 `doctor.sh` 里房间 path，对比 QQ 会话的 cwd；必要时在 QQ 插件配置里把 cwd 指到 `worlds/<名>/room` |
| 登记失败：`its cwd resolves to '...'` | 路径不一致（软链/尾斜杠） | 插件已做 realpath 兜底；仍失败则说明该会话 cwd 确实不是房间目录 |
| 已登记但旧对话没进记忆 | 归档器只增量扫 | 重启服务触发一次全量回扫（catchUp） |
| 换了 Node 版本后报语法错 | Node < 20 | 插件用了较新的语法，升级 Node 到 20+ |

---

## 卸载

```bash
sudo ./uninstall.sh              # 摘配置 + 删文件 + 重启
sudo ./uninstall.sh --keep-files # 只摘配置，保留文件
```

已归档的记忆**不会**被撤销；只是之后新产生的渠道对话不再进入记忆。

---

## 目录结构

```
world-channel-bridge/
├── index.js                     # 插件本体（唯一的运行时文件，零依赖）
├── package.json
├── install.sh                   # 一键安装（自动探测 + 幂等）
├── uninstall.sh                 # 一键卸载
├── doctor.sh                    # 体检
├── tools/
│   ├── patch-edit.mjs           # 安全增删 cordis.patch.yml 条目（块级编辑，不动其它配置）
│   ├── yaml-check.mjs           # 校验配置可解析（兼容宿主自定义的 !!js 标签）
│   └── self-test.mjs            # 无宿主自测：node tools/self-test.mjs
├── .github/workflows/ci.yml     # CI：语法 + 自测 + 脚本检查（Node 20/22）
├── LICENSE                      # MIT
└── README.md
```

---

## 附：兼容范围

依赖宿主两个 API，自 DSH 0.2.x 起稳定：

- `workspaceRegistry.resolveByPath(path)` / `workspaceRegistry.entities`
- `workspace.attachSession(sessionId)`
- `sessionPersistence.list()`（返回项含 `header.cwd`、`header.id`）

任一 API 缺失时插件只告警、不崩溃，服务照常启动。

版本 1.0.0

---

## 许可证

[MIT](LICENSE) © 2026 mhggv

欢迎提 Issue / PR。如果这个插件省了你几个小时，给个 Star 就行。
