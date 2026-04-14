#!/bin/bash
# scheduled-upgrade.sh - 部署到目标机器的定时升级脚本
# 由 OpenClaw Cron Job 触发执行
# 用法: ~/.openclaw/scripts/scheduled-upgrade.sh [--force] [--version X.Y.Z]
#
# 升级方式：使用 openclaw update --yes（官方内置命令）
# - 自带 self-update 处理
# - 自动处理包管理器差异（npm/pnpm/yarn）
# - 自带 Breaking Changes 检查
# - 自动重启 Gateway
#
# 退出码:
#   0 - 升级成功 或 已是最新版
#   1 - 升级失败
#   2 - 有 Breaking Changes，需要用户确认

set -e

# ── 参数解析 ──
FORCE=false
TARGET_VERSION="latest"
LOG_DIR="$HOME/.openclaw/logs"
LOG_FILE="$LOG_DIR/upgrade-$(date +%Y%m%d-%H%M%S).log"
OPENCLAW_BIN=$(which openclaw 2>/dev/null || echo "$HOME/.local/node/bin/openclaw")

for arg in "$@"; do
    case $arg in
        --force) FORCE=true ;;
        --version=*) TARGET_VERSION="${arg#*=}" ;;
        --version) shift; TARGET_VERSION="$1" ;;
    esac
done

mkdir -p "$LOG_DIR"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

log "════════════════════════════════════════════════════════════"
log "  OpenClaw 定时升级检查（使用 openclaw update）"
log "════════════════════════════════════════════════════════════"

# ── 1. 获取版本信息 ──
log "[1/5] 获取版本信息..."

CURRENT_VER=$($OPENCLAW_BIN --version 2>/dev/null | grep -oP 'OpenClaw \K[\d.]+' | head -1 || echo "")
if [[ -z "$CURRENT_VER" ]]; then
    log "❌ 无法获取当前版本，openclaw 命令不可用"
    exit 1
fi
log "  当前版本: $CURRENT_VER"

# 使用 openclaw update --dry-run 获取目标版本
DRY_RUN_OUTPUT=$($OPENCLAW_BIN update --dry-run --json 2>/dev/null || echo "")
LATEST_VER=$(echo "$DRY_RUN_OUTPUT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('targetVersion',''))" 2>/dev/null || echo "")

if [[ -z "$LATEST_VER" ]]; then
    LATEST_VER=$(npm view openclaw version 2>/dev/null || echo "")
fi

if [[ -z "$LATEST_VER" ]]; then
    log "⚠️ 无法获取最新版本信息，跳过升级检查"
    exit 0
fi
log "  最新版本: $LATEST_VER"

# ── 2. 版本对比 ──
log "[2/5] 版本对比..."

if [[ "$CURRENT_VER" == "$LATEST_VER" ]]; then
    log "✅ 已是最新版本 (v$CURRENT_VER)，无需升级"
    exit 0
fi

log "  📦 发现新版本: v$CURRENT_VER → v$LATEST_VER"

# ── 3. 检查 Breaking Changes（仅在非 --force 模式）──
if [[ "$FORCE" != "true" ]]; then
    log "[3/5] 检查 Breaking Changes..."

    CHANGELOG_RAW=$(curl -sf "https://raw.githubusercontent.com/openclaw/openclaw/main/CHANGELOG.md" 2>/dev/null || echo "")
    BREAKING_FOUND=false

    if [[ -n "$CHANGELOG_RAW" ]]; then
        CHANGELOG_SECTION=$(echo "$CHANGELOG_RAW" | sed -n "/^##.*${CURRENT_VER}/,/^## /p" | head -200)
        BREAKING_KEYWORDS="BREAKING|破坏|不兼容|removed|deprecated|migration|迁移|breaking"

        if echo "$CHANGELOG_SECTION" | grep -qiE "$BREAKING_KEYWORDS"; then
            BREAKING_FOUND=true
            BREAKING_DETAILS=$(echo "$CHANGELOG_SECTION" | grep -iE "$BREAKING_KEYWORDS" | head -10)
        fi
    fi

    if [[ "$BREAKING_FOUND" == "true" ]]; then
        log "⚠️ 发现 Breaking Changes，自动升级已暂停"
        log "   Breaking Changes 详情:"
        echo "$BREAKING_DETAILS" | while read -r line; do
            log "   - $line"
        done
        log ""
        log "   手动升级命令:"
        log "   $OPENCLAW_BIN update --yes --tag $LATEST_VER"
        log "   或强制: bash ~/.openclaw/scripts/scheduled-upgrade.sh --force"
        exit 2
    fi
else
    log "[3/5] --force 模式，跳过 Breaking Changes 检查"
fi

# ── 4. 执行升级（使用 openclaw update）──
log "[4/5] 执行升级（openclaw update --yes）..."

UPDATE_CMD="$OPENCLAW_BIN update --yes --timeout 600"
if [[ "$TARGET_VERSION" != "latest" ]]; then
    UPDATE_CMD="$OPENCLAW_BIN update --yes --timeout 600 --tag $TARGET_VERSION"
fi

log "  → 执行: $UPDATE_CMD"
if $UPDATE_CMD 2>&1 | tee -a "$LOG_FILE"; then
    log "  ✅ openclaw update 执行完成"
else
    log "  ⚠️ openclaw update 退出码非零，检查结果..."
fi

# ── 5. 验证结果 ──
log "[5/5] 验证结果..."

NEW_VER=$($OPENCLAW_BIN --version 2>/dev/null | grep -oP 'OpenClaw \K[\d.]+' | head -1 || echo "")

GW_PID=$(pgrep -f "openclaw-gateway" 2>/dev/null || echo "")
GW_OK=false
if [[ -n "$GW_PID" ]]; then
    log "  🟢 Gateway: 运行中 (PID: $GW_PID)"
    GW_OK=true
else
    log "  🔴 Gateway: 未运行，尝试启动..."
    $OPENCLAW_BIN gateway restart 2>/dev/null || true
    sleep 5
    GW_PID=$(pgrep -f "openclaw-gateway" 2>/dev/null || echo "")
    if [[ -n "$GW_PID" ]]; then
        log "  🟢 Gateway: 已启动 (PID: $GW_PID)"
        GW_OK=true
    else
        log "  🔴 Gateway: 启动失败"
    fi
fi

echo ""
echo "=== UPGRADE_RESULT ==="
echo "SUCCESS=$GW_OK"
echo "OLD_VERSION=$CURRENT_VER"
echo "NEW_VERSION=${NEW_VER:-$LATEST_VER}"
echo "GATEWAY_PID=${GW_PID:-none}"
echo "HAS_BREAKING=$BREAKING_FOUND"
echo "LOG_FILE=$LOG_FILE"
echo "=== END_RESULT ==="
echo ""

if [[ "$GW_OK" == "true" ]]; then
    log "🎉 升级成功! v$CURRENT_VER → v${NEW_VER:-$LATEST_VER}"
    exit 0
else
    log "⚠️ 升级完成但 Gateway 启动失败"
    log "   回滚命令: $OPENCLAW_BIN update --yes --tag $CURRENT_VER"
    exit 1
fi
