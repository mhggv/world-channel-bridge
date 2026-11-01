#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# world-channel-bridge 体检脚本
# 一条命令看清「插件到底有没有真的在跑」，不用翻源码。
#   ./doctor.sh [--profile ...] [--home ...] [--service ...]
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

PLUGIN_ID="world-channel-bridge"
PROFILE=""; DSH_HOME_ARG=""; SERVICE=""
PASS=0; FAIL=0; WARN=0

RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; DIM=$'\033[2m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
pass() { PASS=$((PASS+1)); printf '%s✔%s %s\n' "$GREEN" "$RESET" "$*"; }
fail() { FAIL=$((FAIL+1)); printf '%s✘%s %s\n' "$RED" "$RESET" "$*"; }
warn() { WARN=$((WARN+1)); printf '%s!%s %s\n' "$YELLOW" "$RESET" "$*"; }
section() { printf '\n%s%s%s\n' "$BOLD" "$*" "$RESET"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --profile) PROFILE="${2:?}"; shift 2 ;;
    --home) DSH_HOME_ARG="${2:?}"; shift 2 ;;
    --service) SERVICE="${2:?}"; shift 2 ;;
    -h|--help) sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "未知参数: $1"; exit 2 ;;
  esac
done

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -z "$SERVICE" ] && command -v systemctl >/dev/null 2>&1; then
  for candidate in dsh-web dsh dsh-server; do
    systemctl cat "${candidate}.service" >/dev/null 2>&1 && { SERVICE="$candidate"; break; }
  done
fi

DETECT_HOME=""
if [ -n "$DSH_HOME_ARG" ]; then DETECT_HOME="$DSH_HOME_ARG"
elif [ -n "${DSH_HOME:-}" ] && [ -d "${DSH_HOME}/profiles" ]; then DETECT_HOME="$DSH_HOME"
elif [ -n "$SERVICE" ]; then
  DETECT_HOME="$(systemctl show "$SERVICE" -p Environment --value 2>/dev/null | tr ' ' '\n' | sed -n 's/^DSH_HOME=//p' | head -1)"
fi
if [ -z "$DETECT_HOME" ] || [ ! -d "$DETECT_HOME" ]; then
  for guess in "$HOME/home" "$HOME/.dsh/home" "$HOME/dsh/home"; do
    [ -d "$guess/profiles" ] && { DETECT_HOME="$guess"; break; }
  done
fi
DSH_HOME="${DETECT_HOME:-<未找到>}"

if [ -z "$PROFILE" ] && [ "$DSH_HOME" != "<未找到>" ]; then
  if [ -f "$DSH_HOME/profiles/web/cordis.patch.yml" ]; then PROFILE="$DSH_HOME/profiles/web"
  else for dir in "$DSH_HOME"/profiles/*/; do [ -f "${dir}cordis.patch.yml" ] && { PROFILE="${dir%/}"; break; }; done; fi
fi

NODE_BIN="$(command -v node 2>/dev/null || true)"
[ -z "$NODE_BIN" ] && [ -x /opt/node/bin/node ] && NODE_BIN=/opt/node/bin/node

printf '%sworld-channel-bridge 体检%s\n' "$BOLD" "$RESET"
printf '%s  DSH_HOME : %s\n  profile  : %s\n  service  : %s\n%s' "$DIM" "$DSH_HOME" "${PROFILE:-<未找到>}" "${SERVICE:-<未探测到>}" "$RESET"

# ── 1. 定位 ─────────────────────────────────────────────────────────────────
section "1. 安装位置"
if [ "$PROFILE" = "" ] || [ ! -d "$PROFILE" ]; then
  fail "找不到 profile 目录（用 --profile 指定）"
else
  pass "profile 存在：$PROFILE"
fi

TARGET_DIR="$DSH_HOME/plugins/$PLUGIN_ID"
if [ -f "$TARGET_DIR/index.js" ]; then
  pass "插件文件就位：$TARGET_DIR/index.js"
else
  fail "插件文件缺失：$TARGET_DIR/index.js"
fi

# ── 2. 链接 ─────────────────────────────────────────────────────────────────
section "2. 模块链接"
LINK="$PROFILE/node_modules/$PLUGIN_ID"
if [ -L "$LINK" ] || [ -e "$LINK" ]; then
  REAL="$(readlink -f "$LINK" 2>/dev/null || true)"
  if [ -f "$REAL/index.js" ]; then
    pass "node_modules/$PLUGIN_ID -> $REAL"
  else
    fail "软链指向无效路径：$REAL"
  fi
else
  fail "缺少 node_modules/$PLUGIN_ID（宿主无法 import）"
fi

# ── 3. 代码 ─────────────────────────────────────────────────────────────────
section "3. 代码与导入"
if [ -n "$NODE_BIN" ] && [ -f "$TARGET_DIR/index.js" ]; then
  if "$NODE_BIN" --check "$TARGET_DIR/index.js" 2>/dev/null; then
    pass "语法检查通过"
  else
    fail "语法检查失败"
  fi
  if [ "$PROFILE" != "" ] && [ -d "$PROFILE" ]; then
    OUT="$(cd "$PROFILE" && "$NODE_BIN" -e "import('$PLUGIN_ID').then(m=>{ if(!m.apply) throw new Error('缺少 apply 导出'); console.log(Object.keys(m).join(',')) }).catch(e=>{ console.error(e.message); process.exit(1) })" 2>&1)"
    if [ $? -eq 0 ]; then
      pass "宿主导入成功（导出：$OUT）"
    else
      fail "导入失败：$OUT"
    fi
  fi
else
  warn "跳过（缺少 node 或插件文件）"
fi

# ── 4. 配置 ─────────────────────────────────────────────────────────────────
section "4. profile 配置"
PATCH_FILE="$PROFILE/cordis.patch.yml"
if [ -f "$PATCH_FILE" ]; then
  if grep -qE "^\s*-\s*id:\s*['\"]?$PLUGIN_ID['\"]?\s*$" "$PATCH_FILE"; then
    LINE=$(grep -nE "^\s*-\s*id:\s*['\"]?$PLUGIN_ID['\"]?\s*$" "$PATCH_FILE" | cut -d: -f1)
    pass "条目已登记（第 $LINE 行）"
  else
    fail "配置里没有 $PLUGIN_ID 条目"
  fi
  if [ -n "$NODE_BIN" ] && [ -d "$PROFILE/node_modules/js-yaml" ]; then
    RESULT="$("$NODE_BIN" "$SRC_DIR/tools/yaml-check.mjs" "$PATCH_FILE" "$PROFILE" "$PLUGIN_ID" 2>&1)"
    if [ $? -eq 0 ]; then
      pass "YAML 可解析：$(printf '%s' "$RESULT" | tr -d '\n' | sed 's/^ *//')"
    else
      fail "YAML 解析失败：$RESULT"
    fi
  else
    warn "profile 内无 js-yaml，跳过 YAML 解析校验"
  fi
else
  fail "找不到 $PATCH_FILE"
fi

# ── 5. 服务与运行日志 ───────────────────────────────────────────────────────
section "5. 服务运行状态"
if [ -n "$SERVICE" ] && command -v systemctl >/dev/null 2>&1; then
  STATE="$(systemctl is-active "$SERVICE" 2>/dev/null || true)"
  [ "$STATE" = "active" ] && pass "服务 $SERVICE 运行中" || fail "服务 $SERVICE 状态：$STATE"
  LOGS="$(journalctl -u "$SERVICE" --since "-24h" --no-pager 2>/dev/null | grep "world-channel-bridge" | tail -6)"
  if [ -n "$LOGS" ]; then
    pass "最近的插件日志："
    printf '%s\n' "$LOGS" | sed 's/^/      /'
  else
    warn "24 小时内没有任何插件日志（服务重启过吗？）"
  fi
else
  warn "未探测到 systemd 服务，跳过"
fi

# ── 6. 记忆归属对账 ─────────────────────────────────────────────────────────
section "6. 会话登记情况"
WS_FILE="$DSH_HOME/storages/workspace.json"
if [ -f "$WS_FILE" ] && [ -n "$NODE_BIN" ]; then
  "$NODE_BIN" -e "
    const fs=require('fs');
    const d=JSON.parse(fs.readFileSync('$WS_FILE','utf8'));
    const ws=d?.tables?.workspaces ?? {};
    let roomCount=0;
    for(const k of Object.keys(ws)){
      const w=ws[k];
      if(!/[\\/\\\\]worlds[\\/\\\\][^\\/\\\\]+[\\/\\\\]room[\\/]?\$/.test(w.path)) continue;
      roomCount++;
      console.log('      房间「'+w.title+'」'+w.path);
      console.log('        已登记会话: '+w.sessionIds.length+' 个');
    }
    if(!roomCount) console.log('      （没有形如 worlds/<名>/room 的工作区）');
  " || warn "读取 workspace.json 失败"
else
  warn "找不到 $WS_FILE"
fi

ARCHIVE="$DSH_HOME/worlds"
if command -v python3 >/dev/null 2>&1; then
  for db in "$ARCHIVE"/*/archive.sqlite; do
    [ -f "$db" ] || continue
    INFO="$(python3 - "$db" <<'PY' 2>/dev/null
import sqlite3, sys
db = sqlite3.connect("file:%s?mode=ro" % sys.argv[1], uri=True)
r = db.execute("SELECT COUNT(*) FROM records").fetchone()[0]
p = db.execute("SELECT COUNT(*) FROM progress").fetchone()[0]
print("%d 条记录 / %d 个已归档会话" % (r, p))
PY
)"
    [ -n "$INFO" ] && pass "记忆正本 $(basename "$(dirname "$db")")：$INFO"
  done
fi

# ── 汇总 ────────────────────────────────────────────────────────────────────
printf '\n%s────────────────────────────────%s\n' "$DIM" "$RESET"
printf '  通过 %s%d%s   警告 %s%d%s   失败 %s%d%s\n' "$GREEN" "$PASS" "$RESET" "$YELLOW" "$WARN" "$RESET" "$RED" "$FAIL" "$RESET"
if [ "$FAIL" -eq 0 ]; then
  printf '  %s结论：插件正常运行，渠道对话会进入记忆。%s\n\n' "$GREEN" "$RESET"
  exit 0
else
  printf '  %s结论：有问题，按上面标 ✘ 的项排查；日志用 journalctl -u %s -n 100%s\n\n' "$RED" "${SERVICE:-dsh-web}" "$RESET"
  exit 1
fi
