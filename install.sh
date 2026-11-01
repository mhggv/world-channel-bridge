#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# world-channel-bridge 安装脚本
#
#   ./install.sh                     # 自动探测 DSH 安装位置并安装
#   ./install.sh --profile /path/to/profile
#   ./install.sh --home /path/to/dsh-home
#   ./install.sh --no-restart        # 装完不重启服务
#   ./install.sh --link              # 不复制，直接软链到当前目录（开发用）
#   ./install.sh --dry-run           # 只打印将要做什么
#
# 幂等：重复执行不会重复写配置、不会破坏已有条目。
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

PLUGIN_ID="world-channel-bridge"
SERVICE=""
PROFILE=""
DSH_HOME_ARG=""
DO_RESTART=1
USE_LINK=0
DRY_RUN=0

RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; DIM=$'\033[2m'; RESET=$'\033[0m'
say()  { printf '%s\n' "$*"; }
ok()   { printf '%s✔%s %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '%s!%s %s\n' "$YELLOW" "$RESET" "$*"; }
die()  { printf '%s✘ %s%s\n' "$RED" "$*" "$RESET" >&2; exit 1; }
step() { printf '\n%s▸ %s%s\n' "$DIM" "$*" "$RESET"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --profile) PROFILE="${2:?}"; shift 2 ;;
    --home)    DSH_HOME_ARG="${2:?}"; shift 2 ;;
    --service) SERVICE="${2:?}"; shift 2 ;;
    --no-restart) DO_RESTART=0; shift ;;
    --link) USE_LINK=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "未知参数: $1（--help 查看用法）" ;;
  esac
done

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$SRC_DIR/index.js" ] || die "安装包不完整：缺少 index.js（请在解压后的插件目录内运行）"

ROOT=0
[ "$(id -u)" = "0" ] || ROOT=1

# ── 探测 systemd 服务 ────────────────────────────────────────────────────────
if [ -z "$SERVICE" ] && command -v systemctl >/dev/null 2>&1; then
  for candidate in dsh-web dsh dsh-server; do
    if systemctl list-unit-files "${candidate}.service" >/dev/null 2>&1 \
       && systemctl cat "${candidate}.service" >/dev/null 2>&1; then
      SERVICE="$candidate"; break
    fi
  done
  # 兜底：列出所有含 dsh 的服务名
  if [ -z "$SERVICE" ]; then
    SERVICE="$(systemctl list-unit-files --no-legend 2>/dev/null | awk '{print $1}' \
      | grep -E '^dsh.*\.service$' | head -1 | sed 's/\.service$//')"
  fi
fi

# ── 探测 DSH_HOME ───────────────────────────────────────────────────────────
DETECT_HOME=""
if [ -n "$DSH_HOME_ARG" ]; then
  DETECT_HOME="$DSH_HOME_ARG"
elif [ -n "${DSH_HOME:-}" ] && [ -d "${DSH_HOME}/profiles" ]; then
  DETECT_HOME="$DSH_HOME"
elif [ -n "$SERVICE" ]; then
  ENV_LINE="$(systemctl show "$SERVICE" -p Environment --value 2>/dev/null || true)"
  DETECT_HOME="$(printf '%s\n' "$ENV_LINE" | tr ' ' '\n' | sed -n 's/^DSH_HOME=//p' | head -1)"
fi
if [ -z "$DETECT_HOME" ] || [ ! -d "$DETECT_HOME" ]; then
  # 常见默认位置
  for guess in "$HOME/home" "$HOME/.dsh/home" "$HOME/dsh/home" /opt/dsh/home; do
    if [ -d "$guess/profiles" ]; then DETECT_HOME="$guess"; break; fi
  done
fi
[ -n "$DETECT_HOME" ] && [ -d "$DETECT_HOME" ] || die "找不到 DSH_HOME，请用 --home 指定（通常含 profiles/ 与 worlds/ 的目录）"
DSH_HOME="$(cd "$DETECT_HOME" && pwd)"

# ── 探测 profile ────────────────────────────────────────────────────────────
if [ -z "$PROFILE" ]; then
  if [ -f "$DSH_HOME/profiles/web/cordis.patch.yml" ]; then
    PROFILE="$DSH_HOME/profiles/web"
  else
    for dir in "$DSH_HOME"/profiles/*/; do
      [ -f "${dir}cordis.patch.yml" ] && { PROFILE="${dir%/}"; break; }
    done
  fi
fi
[ -n "$PROFILE" ] && [ -d "$PROFILE" ] || die "找不到 profile 目录（含 cordis.patch.yml），请用 --profile 指定"
PROFILE="$(cd "$PROFILE" && pwd)"
PATCH_FILE="$PROFILE/cordis.patch.yml"

[ -f "$PATCH_FILE" ] || die "缺少 $PATCH_FILE"

# ── 探测 node ───────────────────────────────────────────────────────────────
NODE_BIN=""
if command -v node >/dev/null 2>&1; then
  NODE_BIN="$(command -v node)"
elif [ -x /opt/node/bin/node ]; then
  NODE_BIN=/opt/node/bin/node
elif [ -n "$SERVICE" ]; then
  NODE_BIN="$(systemctl cat "$SERVICE" 2>/dev/null | sed -n 's/^ExecStart=\([^ ]*node\).*/\1/p' | head -1)"
fi
[ -n "$NODE_BIN" ] && [ -x "$NODE_BIN" ] || die "找不到 node，请安装或加 --service 指定服务"
NODE_VER="$("$NODE_BIN" -v)"
NODE_MAJOR="$(printf '%s' "$NODE_VER" | sed 's/^v//' | cut -d. -f1)"
[ "$NODE_MAJOR" -ge 20 ] 2>/dev/null || warn "Node 版本 $NODE_VER 低于 20，可能有兼容问题"

# ── 探测运行用户 ────────────────────────────────────────────────────────────
RUN_USER=""
if [ -n "$SERVICE" ]; then
  RUN_USER="$(systemctl show "$SERVICE" -p User --value 2>/dev/null || true)"
fi
if [ -z "$RUN_USER" ] && [ "$ROOT" = "1" ]; then
  # 非 root 时用当前用户
  RUN_USER="$(id -un)"
fi
if [ -z "$RUN_USER" ] && [ "$ROOT" = "0" ]; then
  if id dsh >/dev/null 2>&1; then RUN_USER=dsh; else RUN_USER=root; fi
fi
RUN_GROUP=""
if [ -n "$SERVICE" ]; then
  RUN_GROUP="$(systemctl show "$SERVICE" -p Group --value 2>/dev/null || true)"
fi
[ -n "$RUN_GROUP" ] || RUN_GROUP="$RUN_USER"

say ""
say "  安装目录   $DSH_HOME/plugins/$PLUGIN_ID"
say "  profile    $PROFILE"
say "  配置文件   $PATCH_FILE"
say "  node       $NODE_BIN ($NODE_VER)"
say "  服务       ${SERVICE:-<未探测到>}"
say "  运行用户   $RUN_USER"

run() {
  if [ "$DRY_RUN" = "1" ]; then
    printf '    %s[dry-run]%s %s\n' "$DIM" "$RESET" "$*"
  else
    eval "$@"
  fi
}

# ── 1. 落盘插件 ─────────────────────────────────────────────────────────────
step "部署插件文件"
TARGET_DIR="$DSH_HOME/plugins/$PLUGIN_ID"
if [ "$USE_LINK" = "1" ]; then
  run "mkdir -p '$DSH_HOME/plugins'"
  run "rm -rf '$TARGET_DIR'"
  run "ln -sfn '$SRC_DIR' '$TARGET_DIR'"
  ok "已软链：$TARGET_DIR -> $SRC_DIR"
elif [ "$(cd "$SRC_DIR" 2>/dev/null && pwd -P)" = "$(cd "$TARGET_DIR" 2>/dev/null && pwd -P)" ]; then
  ok "已在安装目录内运行，跳过复制"
else
  run "mkdir -p '$TARGET_DIR'"
  run "find '$TARGET_DIR' -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true"
  # 整包复制（含 install/uninstall/doctor 脚本，装完可以在服务器上直接跑）
  run "cp -R '$SRC_DIR'/. '$TARGET_DIR'/"
  run "chmod +x '$TARGET_DIR'/*.sh 2>/dev/null || true"
  ok "已复制到 $TARGET_DIR"
fi

if [ "$RUN_USER" != "" ] && [ "$ROOT" = "0" ] && [ "$(id -un)" != "$RUN_USER" ]; then
  run "chown -R '$RUN_USER:$RUN_GROUP' '$TARGET_DIR' 2>/dev/null || true"
fi

# ── 2. 建立 node_modules 软链（绝对路径，避免相对层级算错）─────────────────
step "链接到 profile 的 node_modules"
if [ ! -d "$PROFILE/node_modules" ]; then
  run "mkdir -p '$PROFILE/node_modules'"
fi
run "ln -sfn '$TARGET_DIR' '$PROFILE/node_modules/$PLUGIN_ID'"
ok "node_modules/$PLUGIN_ID -> $TARGET_DIR"

# ── 3. 语法与可导入性自检 ───────────────────────────────────────────────────
step "自检"
if [ "$DRY_RUN" = "0" ]; then
  "$NODE_BIN" --check "$TARGET_DIR/index.js" || die "index.js 语法检查失败"
  ok "语法检查通过"
  ( cd "$PROFILE" && "$NODE_BIN" -e "import('$PLUGIN_ID').then(m=>{ if(!m.apply) throw new Error('缺少 apply 导出'); console.log('  exports: '+Object.keys(m).join(', ')) }).catch(e=>{ console.error(e.message); process.exit(1) })" ) \
    || die "无法从 profile 导入该插件，检查 node_modules 软链"
  ok "模块可被宿主导入"
fi

# ── 4. 登记到 profile/package.json ─────────────────────────────────────────
# DSH 的「插件管理 → 已安装」只读 profile/package.json 的两处登记：
#   dependencies         → 算「已安装」
#   dsh.profile.bundles  → 算「已启用」
# 只塞 node_modules 软链 + loader 条目的话，插件能跑但列表里永远看不到。
step "登记为 profile 插件"
MANIFEST="$PROFILE/package.json"
[ -f "$MANIFEST" ] || die "缺少 $MANIFEST（这个 profile 不完整）"
LINK_SPEC="link:$TARGET_DIR"

if [ "$DRY_RUN" = "1" ]; then
  run "'$NODE_BIN' '$SRC_DIR/tools/manifest-edit.mjs' add '$MANIFEST' '$PLUGIN_ID' '$LINK_SPEC'"
else
  cp -a "$MANIFEST" "$MANIFEST.bak-$(date +%Y%m%d-%H%M%S)"
  "$NODE_BIN" "$SRC_DIR/tools/manifest-edit.mjs" add "$MANIFEST" "$PLUGIN_ID" "$LINK_SPEC" \
    || die "写入 $MANIFEST 失败（原文件已备份为 $MANIFEST.bak-*）"
  ok "$PLUGIN_ID 已登记（dependencies + dsh.profile.bundles）"
fi

# 迁移：清掉旧版本写在 cordis.patch.yml 里的手动条目。
# 现在由插件自带的 cordis.patch.yml（dsh.bundle.patch）提供同一条 entry，
# 两处都留会让插件被挂载两次。
if [ "$DRY_RUN" = "1" ]; then
  run "'$NODE_BIN' '$SRC_DIR/tools/patch-edit.mjs' remove '$PATCH_FILE' '$PLUGIN_ID'"
else
  set +e
  "$NODE_BIN" "$SRC_DIR/tools/patch-edit.mjs" has "$PATCH_FILE" "$PLUGIN_ID" >/dev/null 2>&1
  LEGACY_RC=$?
  set -e
  if [ "$LEGACY_RC" -eq 0 ]; then
    cp -a "$PATCH_FILE" "$PATCH_FILE.bak-$(date +%Y%m%d-%H%M%S)"
    "$NODE_BIN" "$SRC_DIR/tools/patch-edit.mjs" remove "$PATCH_FILE" "$PLUGIN_ID"
    ok "已移除 cordis.patch.yml 中的旧条目（改由 bundle patch 提供，避免重复加载）"
  fi
  # 校验 profile 的 patch 文件仍然可解析（文件里可能含 !!js 自定义标签）。
  # 注意：条目现在由插件自带的 cordis.patch.yml 提供，profile 里没有它是正常的。
  set +e
  YAML_OUT="$("$NODE_BIN" "$SRC_DIR/tools/yaml-check.mjs" "$PATCH_FILE" "$PROFILE" "$PLUGIN_ID" 2>&1)"
  YAML_RC=$?
  set -e
  if [ "$YAML_RC" -eq 2 ]; then
    warn "profile 内没有 js-yaml，跳过 YAML 解析校验"
  elif [ "$YAML_RC" -eq 0 ]; then
    ok "cordis.patch.yml 可解析"
  elif printf '%s' "$YAML_OUT" | grep -q "没找到条目"; then
    ok "cordis.patch.yml 可解析（条目由插件自带的 bundle patch 提供）"
  else
    printf '%s\n' "$YAML_OUT"
    warn "cordis.patch.yml 解析校验未通过，请人工确认"
  fi
fi

if [ "$RUN_USER" != "" ] && [ "$ROOT" = "0" ] && [ "$(id -un)" != "$RUN_USER" ]; then
  run "chown '$RUN_USER:$RUN_GROUP' '$MANIFEST' 2>/dev/null || true"
  run "chown '$RUN_USER:$RUN_GROUP' '$PATCH_FILE' 2>/dev/null || true"
fi

# ── 5. 重启服务 ─────────────────────────────────────────────────────────────
if [ "$DO_RESTART" = "1" ] && [ -n "$SERVICE" ]; then
  step "重启 $SERVICE"
  if [ "$DRY_RUN" = "1" ]; then
    run "systemctl restart '$SERVICE'"
  else
    systemctl restart "$SERVICE" || die "重启失败，查看：journalctl -u $SERVICE -n 50"
    ok "已重启"
    step "等待插件就绪（约 12 秒）"
    sleep 12
    if journalctl -u "$SERVICE" --since "-1min" --no-pager 2>/dev/null | grep -q "world-channel-bridge"; then
      journalctl -u "$SERVICE" --since "-1min" --no-pager 2>/dev/null | grep "world-channel-bridge" | tail -5 | sed 's/^/    /'
      ok "插件已加载"
    else
      warn "日志里没看到插件输出，用 doctor.sh 排查（可能宿主未重载配置）"
    fi
  fi
else
  warn "未重启服务，改动将在下次重启后生效"
fi

say ""
ok "安装完成"
say ""
say "  验证： ./doctor.sh"
say "  卸载： ./uninstall.sh"
say ""
