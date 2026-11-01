#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# world-channel-bridge 卸载脚本
#
#   ./uninstall.sh                # 移除插件与配置条目，重启服务
#   ./uninstall.sh --keep-files   # 只摘配置，保留插件文件
#   ./uninstall.sh --no-restart
#
# 说明：已登记进工作区的会话不会被撤销，她的记忆不受影响；
#       卸载后新产生的渠道对话将不再进入记忆归档。
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

PLUGIN_ID="world-channel-bridge"
LEGACY_ID="world-qq-bridge"
PROFILE=""; DSH_HOME_ARG=""; SERVICE=""; DO_RESTART=1; KEEP_FILES=0

RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; DIM=$'\033[2m'; RESET=$'\033[0m'
ok()   { printf '%s✔%s %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '%s!%s %s\n' "$YELLOW" "$RESET" "$*"; }
die()  { printf '%s✘ %s%s\n' "$RED" "$*" "$RESET" >&2; exit 1; }
step() { printf '\n%s▸ %s%s\n' "$DIM" "$*" "$RESET"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --profile) PROFILE="${2:?}"; shift 2 ;;
    --home) DSH_HOME_ARG="${2:?}"; shift 2 ;;
    --service) SERVICE="${2:?}"; shift 2 ;;
    --no-restart) DO_RESTART=0; shift ;;
    --keep-files) KEEP_FILES=1; shift ;;
    -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "未知参数: $1" ;;
  esac
done

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -z "$SERVICE" ] && command -v systemctl >/dev/null 2>&1; then
  for candidate in dsh-web dsh dsh-server; do
    if systemctl cat "${candidate}.service" >/dev/null 2>&1; then SERVICE="$candidate"; break; fi
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
[ -n "$DETECT_HOME" ] && [ -d "$DETECT_HOME" ] || die "找不到 DSH_HOME，请用 --home 指定"
DSH_HOME="$(cd "$DETECT_HOME" && pwd)"

if [ -z "$PROFILE" ]; then
  if [ -f "$DSH_HOME/profiles/web/cordis.patch.yml" ]; then PROFILE="$DSH_HOME/profiles/web"
  else for dir in "$DSH_HOME"/profiles/*/; do [ -f "${dir}cordis.patch.yml" ] && { PROFILE="${dir%/}"; break; }; done; fi
fi
[ -n "$PROFILE" ] && [ -d "$PROFILE" ] || die "找不到 profile，请用 --profile 指定"
PROFILE="$(cd "$PROFILE" && pwd)"

NODE_BIN="$(command -v node 2>/dev/null || true)"
[ -z "$NODE_BIN" ] && [ -x /opt/node/bin/node ] && NODE_BIN=/opt/node/bin/node
[ -n "$NODE_BIN" ] || die "找不到 node"

RUN_USER=""
if [ -n "$SERVICE" ]; then RUN_USER="$(systemctl show "$SERVICE" -p User --value 2>/dev/null || true)"; fi

step "移除配置条目"
for id in "$PLUGIN_ID" "$LEGACY_ID"; do
  if "$NODE_BIN" "$SRC_DIR/tools/patch-edit.mjs" has "$PROFILE/cordis.patch.yml" "$id" >/dev/null 2>&1; then
    "$NODE_BIN" "$SRC_DIR/tools/patch-edit.mjs" remove "$PROFILE/cordis.patch.yml" "$id"
    ok "已移除 $id"
  else
    warn "配置里没有 $id，跳过"
  fi
done

step "移除软链"
for id in "$PLUGIN_ID" "$LEGACY_ID"; do
  if [ -L "$PROFILE/node_modules/$id" ] || [ -e "$PROFILE/node_modules/$id" ]; then
    rm -rf "$PROFILE/node_modules/$id"
    ok "已删除 node_modules/$id"
  fi
done

step "清理 package.json 里的依赖登记"
PKG="$PROFILE/package.json"
if [ -f "$PKG" ]; then
  "$NODE_BIN" -e "
    const fs = require('fs');
    const p = '$PKG';
    const pkg = JSON.parse(fs.readFileSync(p, 'utf8'));
    const deps = pkg.dependencies || {};
    let changed = false;
    for (const id of ['$PLUGIN_ID', '$LEGACY_ID']) {
      if (deps[id]) { delete deps[id]; changed = true; }
    }
    if (changed) { pkg.dependencies = deps; fs.writeFileSync(p, JSON.stringify(pkg, null, 2) + '\n'); }
    console.log(changed ? '  已移除依赖登记' : '  无需清理');
  " 2>/dev/null || warn "package.json 清理跳过"
fi

if [ "$KEEP_FILES" = "0" ]; then
  step "删除插件文件"
  for id in "$PLUGIN_ID" "$LEGACY_ID"; do
    if [ -d "$DSH_HOME/plugins/$id" ]; then
      rm -rf "$DSH_HOME/plugins/$id"
      ok "已删除 $DSH_HOME/plugins/$id"
    fi
  done
else
  warn "已保留插件文件（--keep-files）"
fi

if [ "$DO_RESTART" = "1" ] && [ -n "$SERVICE" ]; then
  step "重启 $SERVICE"
  systemctl restart "$SERVICE" && ok "已重启"
else
  warn "未重启服务，改动将在下次重启后生效"
fi

printf '\n%s卸载完成%s。已归档的记忆不受影响；后续渠道对话不再进入记忆。\n' "$GREEN" "$RESET"
