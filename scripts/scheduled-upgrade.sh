#!/bin/bash
# scheduled-upgrade.sh - 部署到目标机器的定时升级脚本
# 由 OpenClaw Cron Job 触发执行
# 用法: ~/.openclaw/scripts/scheduled-upgrade.sh [--force] [--version X.Y.Z]
# 
# 退出码:
#   0 - 升级成功 或 已是最新版
#   1 - 升级失败（不可修复）
#   2 - 有 Breaking Changes，需要用户确认（暂停自动升级）

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

# 确保日志目录
mkdir -p "$LOG_DIR"

# 日志函数
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

log "══════════════════════════════════════════════════"
log "  OpenClaw 定时升级检查"
log "══════════════════════════════════════════════════"

# ── 1. 获取版本信息 ──
log "[1/7] 获取版本信息..."

CURRENT_VER=$($OPENCLAW_BIN --version 2>/dev/null | grep -oP 'OpenClaw \K[\d.]+' | head -1 || echo "")
if [[ -z "$CURRENT_VER" ]]; then
    log "❌ 无法获取当前版本，openclaw 命令不可用"
    log "   建议使用 openclaw-remote-install 技能重新安装"
    exit 1
fi
log "  当前版本: $CURRENT_VER"

# 获取最新版本
LATEST_VER=$(npm view openclaw version 2>/dev/null || echo "")
if [[ -z "$LATEST_VER" ]]; then
    # 备用：从 GitHub API 获取
    LATEST_VER=$(curl -sf https://api.github.com/repos/openclaw/openclaw/releases/latest 2>/dev/null | grep -oP '"tag_name":\s*"v\K[^"]+' || echo "")
fi

if [[ -z "$LATEST_VER" ]]; then
    log "⚠️ 无法获取最新版本信息，跳过升级检查"
    exit 0
fi
log "  最新版本: $LATEST_VER"

# ── 2. 版本对比 ──
log "[2/7] 版本对比..."

if [[ "$CURRENT_VER" == "$LATEST_VER" ]]; then
    log "✅ 已是最新版本 (v$CURRENT_VER)，无需升级"
    exit 0
fi

if [[ "$TARGET_VERSION" != "latest" ]] && [[ "$CURRENT_VER" == "$TARGET_VERSION" ]]; then
    log "✅ 已是指定版本 (v$TARGET_VERSION)，无需升级"
    exit 0
fi

log "  📦 发现新版本: v$CURRENT_VER → v$LATEST_VER"

# ── 3. 获取变更日志并检查 Breaking Changes ──
log "[3/7] 检查 Breaking Changes..."

# 获取 GitHub releases 信息
RELEASE_INFO=$(curl -sf "https://api.github.com/repos/openclaw/openclaw/releases" 2>/dev/null || echo "")

# 提取当前版本到目标版本之间的变更
CHANGELOG=$(curl -sf "https://raw.githubusercontent.com/openclaw/openclaw/main/CHANGELOG.md" 2>/dev/null || echo "")

# 检查 Breaking Changes（简单关键词匹配）
BREAKING_KEYWORDS="BREAKING|破坏|不兼容|removed|deprecated|migration|迁移|breaking"
HAS_BREAKING=false
BREAKING_DETAILS=""

if [[ -n "$CHANGELOG" ]]; then
    # 提取当前版本到最新版本之间的 changelog
    CHANGELOG_SECTION=$(echo "$CHANGELOG" | sed -n "/^##.*${CURRENT_VER}/,/^## /p" | head -200)
    
    if echo "$CHANGELOG_SECTION" | grep -qiE "$BREAKING_KEYWORDS"; then
        HAS_BREAKING=true
        BREAKING_DETAILS=$(echo "$CHANGELOG_SECTION" | grep -iE "$BREAKING_KEYWORDS" | head -10)
    fi
fi

# 也从 release notes 检查
if [[ -n "$RELEASE_INFO" ]]; then
    if echo "$RELEASE_INFO" | grep -qiE "$BREAKING_KEYWORDS"; then
        HAS_BREAKING=true
        BREAKING_EXTRA=$(echo "$RELEASE_INFO" | grep -iE "$BREAKING_KEYWORDS" | head -5)
        BREAKING_DETAILS="${BREAKING_DETAILS}\n${BREAKING_EXTRA}"
    fi
fi

# ── 4. 输出升级摘要（供 AI agent 解析）──
log "[4/7] 生成升级摘要..."

echo ""
echo "=== UPGRADE_SUMMARY ==="
echo "CURRENT_VERSION=$CURRENT_VER"
echo "LATEST_VERSION=$LATEST_VER"
echo "HAS_BREAKING=$HAS_BREAKING"
echo "BREAKING_DETAILS=$BREAKING_DETAILS"
echo "=== END_SUMMARY ==="
echo ""

# 如果有 Breaking Changes 且非强制模式，暂停
if [[ "$HAS_BREAKING" == "true" ]] && [[ "$FORCE" != "true" ]]; then
    log "⚠️ 发现 Breaking Changes，自动升级已暂停"
    log "   Breaking Changes 详情:"
    echo "$BREAKING_DETAILS" | while read -r line; do
        log "   - $line"
    done
    log ""
    log "   请用户确认后手动执行升级，或使用 --force 参数强制升级"
    log ""
    log "   手动升级命令:"
    log "   $OPENCLAW_BIN cron run <JOB_ID>"
    log "   或直接: npm install -g openclaw@$LATEST_VER"
    exit 2
fi

# ── 5. 执行升级 ──
log "[5/7] 执行升级..."

# 确保使用国内源
npm config set registry https://registry.npmmirror.com 2>/dev/null

# 清理残留进程
pkill -f "npm install.*openclaw" 2>/dev/null || true
sleep 1

# 执行升级
log "  → npm install -g openclaw@$LATEST_VER"
if npm install -g "openclaw@$LATEST_VER" 2>&1 | tee -a "$LOG_FILE"; then
    log "  ✅ npm install 成功"
else
    log "  ❌ npm install 失败，尝试重试..."
    sleep 3
    if npm install -g "openclaw@$LATEST_VER" 2>&1 | tee -a "$LOG_FILE"; then
        log "  ✅ 重试成功"
    else
        log "  ❌ 升级失败（两次尝试均失败）"
        log "  可能原因：网络问题、npm registry 不可用、磁盘空间不足"
        exit 1
    fi
fi

# ── 6. 重启 Gateway + 验证 ──
log "[6/7] 重启 Gateway..."

# 验证新版本
NEW_VER=$($OPENCLAW_BIN --version 2>/dev/null | grep -oP 'OpenClaw \K[\d.]+' | head -1 || echo "")
if [[ "$NEW_VER" != "$LATEST_VER" ]]; then
    log "⚠️ 版本验证不一致: 期望 v$LATEST_VER, 实际 v$NEW_VER"
fi

# 重启 Gateway
$OPENCLAW_BIN gateway restart 2>&1 | tee -a "$LOG_FILE" || {
    log "  ⚠️ openclaw gateway restart 失败，尝试 systemctl..."
    systemctl --user restart openclaw-gateway.service 2>/dev/null || true
}

sleep 5

# 验证 Gateway 运行
GW_PID=$(pgrep -f "openclaw-gateway" 2>/dev/null || echo "")
if [[ -n "$GW_PID" ]]; then
    log "  🟢 Gateway: 运行中 (PID: $GW_PID)"
    GW_OK=true
else
    log "  🔴 Gateway: 未运行，尝试再次启动..."
    $OPENCLAW_BIN gateway restart 2>/dev/null || true
    sleep 5
    GW_PID=$(pgrep -f "openclaw-gateway" 2>/dev/null || echo "")
    if [[ -n "$GW_PID" ]]; then
        log "  🟢 Gateway: 已启动 (PID: $GW_PID)"
        GW_OK=true
    else
        log "  🔴 Gateway: 启动失败"
        GW_OK=false
    fi
fi

# 恢复 npm 国内源
npm config set registry https://registry.npmmirror.com 2>/dev/null

# ── 7. 输出最终结果 ──
log "[7/7] 升级完成"
log ""

echo ""
echo "=== UPGRADE_RESULT ==="
echo "SUCCESS=$GW_OK"
echo "OLD_VERSION=$CURRENT_VER"
echo "NEW_VERSION=${NEW_VER:-$LATEST_VER}"
echo "GATEWAY_PID=${GW_PID:-none}"
echo "HAS_BREAKING=$HAS_BREAKING"
echo "LOG_FILE=$LOG_FILE"
echo "=== END_RESULT ==="
echo ""

if [[ "$GW_OK" == "true" ]]; then
    log "🎉 升级成功! v$CURRENT_VER → v${NEW_VER:-$LATEST_VER}"
    log ""
    log "  版本: v${NEW_VER:-$LATEST_VER}"
    log "  Gateway: 🟢 运行中 (PID: $GW_PID)"
    log "  日志: $LOG_FILE"
    exit 0
else
    log "⚠️ 升级完成但 Gateway 启动失败"
    log "   请检查日志: $LOG_FILE"
    log "   手动回滚: npm install -g openclaw@$CURRENT_VER && $OPENCLAW_BIN gateway restart"
    exit 1
fi
