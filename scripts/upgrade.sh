#!/bin/bash
# openclaw-remote-upgrade - 远程机器 OpenClaw 升级脚本（含回滚）
# 用法: ./upgrade.sh [--force] [--version=X.Y.Z] <USER@HOST> [SSH_KEY] [TARGET_VERSION]
# 示例: ./upgrade.sh trclaw2@100.81.167.91 ~/.ssh/id_rsa_tnt
# 示例: ./upgrade.sh --force root@43.134.173.17 ~/.ssh/id_rsa_tnt 2026.4.11
#
# 升级方式：使用 openclaw update --yes（官方内置命令）
# - 自带 self-update 处理（不会出现 MODULE_NOT_FOUND）
# - 自动处理包管理器差异（npm/pnpm/yarn）
# - 自带 Breaking Changes 检查
# - 自动重启 Gateway
#
# 退出码：
#   0 - 升级成功
#   1 - 升级失败
#   2 - 有 Breaking Changes 需要用户确认（暂停）

set -e

# ── 参数解析 ──
FORCE=false
TARGET_VERSION="latest"
SSH_KEY="$HOME/.ssh/id_rsa_tnt"
POSITIONAL=()

for arg in "$@"; do
    case $arg in
        --force) FORCE=true ;;
        --version=*) TARGET_VERSION="${arg#*=}" ;;
        *) POSITIONAL+=("$arg") ;;
    esac
done

USER_HOST="${POSITIONAL[0]:?用法: $0 [--force] <USER@HOST> [SSH_KEY] [TARGET_VERSION]}"
SSH_KEY="${POSITIONAL[1]:-$SSH_KEY}"
[[ "$TARGET_VERSION" == "latest" ]] && TARGET_VERSION="${POSITIONAL[2]:-latest}"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"

# 支持 root@HOST 和 user@HOST 格式
if [[ "$USER_HOST" == *@* ]]; then
    SSH_USER="${USER_HOST%%@*}"
    HOST="${USER_HOST##*@}"
else
    SSH_USER="root"
    HOST="$USER_HOST"
fi

# ── 远程 shell 检测 ──
REMOTE_SHELL=$(ssh $SSH_OPTS ${SSH_USER}@${HOST} 'echo $SHELL' 2>/dev/null | xargs basename || echo "bash")
if [[ "$REMOTE_SHELL" == "zsh" ]]; then
    SHELL_CMD="zsh -l -c"
else
    SHELL_CMD="bash -l -c"
fi

echo "════════════════════════════════════════════════════════════"
echo "  OpenClaw 远程升级（含回滚）"
echo "════════════════════════════════════════════════════════════"
echo "目标: ${SSH_USER}@${HOST}"
echo "目标版本: $TARGET_VERSION"
echo "远程 Shell: $REMOTE_SHELL"
echo "升级方式: openclaw update --yes"
echo ""

# ── 1. SSH 连接测试 ──
echo "[1/8] SSH 连接测试..."
if ! ssh $SSH_OPTS ${SSH_USER}@${HOST} 'echo "SSH OK"' 2>/dev/null; then
    echo "❌ SSH 连接失败，请检查："
    echo "  - SSH 私钥是否正确: $SSH_KEY"
    echo "  - 目标机器是否可达: $HOST"
    echo "  - 用户是否有权限: $SSH_USER"
    exit 1
fi
echo "✅ SSH 连接正常"

# ── 2. 版本检测与对比 ──
echo ""
echo "[2/8] 版本检测与对比..."

CURRENT_VER=$(ssh $SSH_OPTS ${SSH_USER}@${HOST} "$SHELL_CMD 'openclaw --version 2>/dev/null'" 2>/dev/null | grep -oP 'OpenClaw \K[\d.]+' | head -1 || echo "")
if [[ -z "$CURRENT_VER" ]]; then
    echo "❌ 目标机器未安装 OpenClaw，或 openclaw 命令不可用"
    echo "   请使用 install.sh 进行全新安装"
    exit 1
fi

GATEWAY_VER=$(ssh $SSH_OPTS ${SSH_USER}@${HOST} "$SHELL_CMD 'openclaw --version 2>/dev/null'" 2>/dev/null | head -1)
echo "  当前版本: $GATEWAY_VER"

if [[ "$TARGET_VERSION" == "latest" ]]; then
    LATEST_VER=$(ssh $SSH_OPTS ${SSH_USER}@${HOST} "$SHELL_CMD 'openclaw update --dry-run --json 2>/dev/null'" 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('targetVersion',''))" 2>/dev/null || echo "")
    if [[ -z "$LATEST_VER" ]]; then
        LATEST_VER=$(ssh $SSH_OPTS ${SSH_USER}@${HOST} "$SHELL_CMD 'npm view openclaw version 2>/dev/null'" 2>/dev/null || echo "")
    fi
    TARGET_VERSION="${LATEST_VER}"
    echo "  最新版本: $TARGET_VERSION"
else
    echo "  指定版本: $TARGET_VERSION"
fi

if [[ "$CURRENT_VER" == "$TARGET_VERSION" ]]; then
    echo ""
    echo "⚠️  当前版本 ($CURRENT_VER) 已是目标版本"
    echo ""
    echo "选择："
    echo "  1. 覆盖安装（重新安装）"
    echo "  2. 跳过，保持现有版本"
    echo ""
    read -p "请选择 [1/2]: " choice
    if [[ "$choice" != "1" ]]; then
        echo "✅ 保持现有版本，升级终止"
        exit 0
    fi
    echo "→ 用户选择覆盖安装"
fi

# ── 3. 获取并分析变更日志（含 Breaking Changes 分类）──
echo ""
echo "[3/8] 获取变更日志..."

CHANGELOG_RAW=$(curl -s https://raw.githubusercontent.com/openclaw/openclaw/main/CHANGELOG.md 2>/dev/null || echo "")

if [[ -z "$CHANGELOG_RAW" ]]; then
    echo "⚠️  无法从 GitHub 获取 CHANGELOG，尝试从 releases 页面获取..."
    CHANGELOG_RAW=$(curl -s "https://api.github.com/repos/openclaw/openclaw/releases" 2>/dev/null | head -5000)
fi

CHANGELOG_SECTION=$(echo "$CHANGELOG_RAW" | sed -n "/^## ${CURRENT_VER}/,/^## /p" | head -100)

BREAKING_FOUND="no"

if [[ -n "$CHANGELOG_SECTION" ]]; then
    echo "📝 变更摘要（从 v${CURRENT_VER} 到 v${TARGET_VERSION}）："
    echo ""

    # 提取 breaking changes
    BREAKING=$(echo "$CHANGELOG_SECTION" | grep -iE "(BREAKING|破坏|不兼容|removed|deprecated|migration|迁移|config.*change|配置.*变更|field.*rename|字段.*重命名)" | head -20)

    if [[ -n "$BREAKING" ]]; then
        echo "⚠️  Breaking Changes 检测到:"
        echo "$BREAKING" | sed 's/^/    /'
        echo ""
        BREAKING_FOUND="yes"

        # ── 分类 Breaking Changes ──
        BC_AUTO=$(echo "$BREAKING" | grep -iE "(config.*rename|字段.*重命名|field.*rename|deprecated.*use|废弃.*使用|rename.*to|改名为|migrate.*config|配置.*迁移|移除.*请使用|removed.*use|switch.*to|切换到)" | head -10 || true)

        if [[ -n "$BC_AUTO" ]]; then
            BC_MANUAL=$(echo "$BREAKING" | grep -vFxf <(echo "$BC_AUTO") | head -10 || true)
        else
            BC_MANUAL="$BREAKING"
        fi

        if [[ -n "$BC_AUTO" ]]; then
            echo "🤖 Agent 可自动处理的变更:"
            echo "$BC_AUTO" | sed 's/^/    /'
            echo ""
        fi

        if [[ -n "$BC_MANUAL" ]]; then
            echo "👤 需要人工确认的变更:"
            echo "$BC_MANUAL" | sed 's/^/    /'
            echo ""
        fi

        # ── 决策逻辑 ──
        if [[ "$FORCE" == "true" ]]; then
            echo "🔑 --force 已设置，跳过 Breaking Changes 检查，直接升级"
            echo ""
        elif [[ -n "$BC_AUTO" ]] && [[ -z "$BC_MANUAL" ]]; then
            echo "✅ 所有 Breaking Changes 均可由 Agent 自动处理，继续升级"
            echo ""
        elif [[ -n "$BC_MANUAL" ]]; then
            echo "⚠️  检测到需要人工确认的 Breaking Changes"
            echo ""

            echo "=== BC_REPORT ==="
            echo "STATUS=NEEDS_CONFIRMATION"
            echo "AUTO_HANDLEABLE=$(echo "$BC_AUTO" | grep -c . 2>/dev/null || echo 0)"
            echo "NEEDS_CONFIRMATION=$(echo "$BC_MANUAL" | grep -c . 2>/dev/null || echo 0)"
            echo "AUTO_DETAILS=$BC_AUTO"
            echo "MANUAL_DETAILS=$BC_MANUAL"
            echo "=== END_BC_REPORT ==="
            echo ""

            if [[ ! -t 0 ]]; then
                echo "⏸️  非交互模式，升级已暂停（exit 2）"
                exit 2
            fi

            echo "请选择:"
            echo "  1. 确认继续升级（接受 Breaking Changes）"
            echo "  2. 取消升级"
            read -p "请选择 [1/2]: " bc_choice
            case "$bc_choice" in
                1) echo "→ 用户确认继续升级" ;;
                *) echo "→ 取消升级"; exit 2 ;;
            esac
        fi
    else
        echo "✅ 未发现明显的 Breaking Changes"
    fi

    # 提取新功能和 bug 修复摘要
    FEATURES=$(echo "$CHANGELOG_SECTION" | grep -iE "^[#]+\s+(feat|feature|new|add)" | head -10 || true)
    FIXES=$(echo "$CHANGELOG_SECTION" | grep -iE "^[#]+\s+(fix|bug)" | head -10 || true)
else
    echo "⚠️  无法获取详细变更日志，将直接执行升级"
fi

echo "=== CHANGELOG_SUMMARY ==="
echo "CURRENT=$CURRENT_VER"
echo "TARGET=$TARGET_VERSION"
echo "HAS_BREAKING=$BREAKING_FOUND"
echo "=== END_SUMMARY ==="

# ── 4. 规划回滚步骤 ──
echo ""
echo "[4/8] 规划回滚步骤..."

BACKUP_DIR="/tmp/openclaw-rollback-$(date +%Y%m%d%H%M%S)"
mkdir -p "$BACKUP_DIR"

echo "  📦 备份当前状态到: $BACKUP_DIR"
ssh $SSH_OPTS ${SSH_USER}@${HOST} "$SHELL_CMD 'openclaw --version 2>/dev/null'" > "$BACKUP_DIR/current-version.txt" 2>/dev/null || true
ssh $SSH_OPTS ${SSH_USER}@${HOST} "$SHELL_CMD 'cat ~/.openclaw/openclaw.json 2>/dev/null'" > "$BACKUP_DIR/openclaw-config.json" 2>/dev/null || true

cat > "$BACKUP_DIR/rollback.sh" << 'ROLLBACK_EOF'
#!/bin/bash
# OpenClaw 回滚脚本（自动生成）
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET_VER="$(cat "$SCRIPT_DIR/current-version.txt" 2>/dev/null | grep -oP '[\d.]+' | head -1 || echo "unknown")"
USER_HOST="$(head -1 "$SCRIPT_DIR/target-host.txt" 2>/dev/null)"
SSH_KEY="$(head -1 "$SCRIPT_DIR/ssh-key.txt" 2>/dev/null)"

if [[ -z "$USER_HOST" ]]; then
    echo "❌ 无法确定回滚目标"
    exit 1
fi

SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"

echo "=== OpenClaw 回滚 ==="
echo "目标: $USER_HOST → v${TARGET_VER}"
echo ""

echo "[1/3] 回滚 openclaw..."
# 使用 openclaw update --tag 指定旧版本回滚
ssh $SSH_OPTS $USER_HOST "bash -l -c 'openclaw update --yes --tag $TARGET_VER'" 2>&1
echo "✅ 版本已回滚"

echo "[2/3] 恢复配置..."
scp $SSH_OPTS "$SCRIPT_DIR/openclaw-config.json" $USER_HOST:~/.openclaw/openclaw.json 2>/dev/null || echo "⚠️ 配置恢复失败"

echo "[3/3] 重启 Gateway..."
ssh $SSH_OPTS $USER_HOST "bash -l -c 'openclaw gateway restart'" 2>&1
sleep 3

echo ""
echo "=== 回滚验证 ==="
ssh $SSH_OPTS $USER_HOST "bash -l -c 'openclaw --version'" 2>&1
echo "✅ 回滚完成"
ROLLBACK_EOF

echo "${SSH_USER}@${HOST}" > "$BACKUP_DIR/target-host.txt"
echo "${SSH_KEY:-}" > "$BACKUP_DIR/ssh-key.txt"
chmod +x "$BACKUP_DIR/rollback.sh"

echo "  📝 回滚脚本已生成: $BACKUP_DIR/rollback.sh"
echo ""

# ── 5. 执行升级（使用 openclaw update）──
echo "[5/8] 执行升级（openclaw update）..."

# 构建 openclaw update 命令
UPDATE_CMD="openclaw update --yes --timeout 600"
if [[ "$TARGET_VERSION" != "latest" ]]; then
    UPDATE_CMD="openclaw update --yes --timeout 600 --tag $TARGET_VERSION"
fi

echo "  → 执行: $UPDATE_CMD"
UPDATE_OUTPUT=$(ssh $SSH_OPTS ${SSH_USER}@${HOST} "$SHELL_CMD '$UPDATE_CMD'" 2>&1) || {
    UPDATE_EXIT=$?
    echo "  ⚠️ openclaw update 退出码: $UPDATE_EXIT"
}
echo "$UPDATE_OUTPUT" | tail -20 | sed 's/^/    /'

# 验证升级结果
NEW_VER=$(ssh $SSH_OPTS ${SSH_USER}@${HOST} "$SHELL_CMD 'openclaw --version 2>/dev/null'" 2>/dev/null | grep -oP 'OpenClaw \K[\d.]+' | head -1 || echo "")

if [[ "$NEW_VER" == "$TARGET_VERSION" ]] || [[ "$TARGET_VERSION" == "latest" && -n "$NEW_VER" ]]; then
    echo "  ✅ 升级成功: v${CURRENT_VER} → v${NEW_VER}"
    UPGRADE_SUCCESS="yes"
else
    echo "  ❌ 升级可能失败"
    echo "     期望版本: $TARGET_VERSION"
    echo "     实际版本: ${NEW_VER:-未检测到}"
    echo ""
    echo "  完整升级输出:"
    echo "$UPDATE_OUTPUT" | tail -30 | sed 's/^/    /'

    # 重试一次
    echo ""
    echo "  → 重试升级..."
    ssh $SSH_OPTS ${SSH_USER}@${HOST} "$SHELL_CMD '$UPDATE_CMD'" 2>&1 | tail -10
    sleep 2
    NEW_VER=$(ssh $SSH_OPTS ${SSH_USER}@${HOST} "$SHELL_CMD 'openclaw --version 2>/dev/null'" 2>/dev/null | grep -oP 'OpenClaw \K[\d.]+' | head -1 || echo "")

    if [[ -n "$NEW_VER" ]]; then
        echo "  ✅ 重试成功: v${NEW_VER}"
        UPGRADE_SUCCESS="yes"
    else
        echo "  ❌ 重试仍然失败"
        UPGRADE_SUCCESS="no"
        if [[ -t 0 ]]; then
            echo ""
            read -p "  是否回滚到 v${CURRENT_VER}？[y/N]: " rollback_choice
            if [[ "$rollback_choice" =~ ^[Yy]$ ]]; then
                bash "$BACKUP_DIR/rollback.sh"
                exit 1
            fi
        fi
    fi
fi

# ── 6. 更新飞书官方插件 ──
echo ""
echo "[6/8] 更新飞书官方插件..."
ssh $SSH_OPTS ${SSH_USER}@${HOST} "$SHELL_CMD 'npx -y @larksuite/openclaw-lark install 2>&1'" 2>/dev/null | tail -3
echo "  ✅ 飞书插件更新完成"

# ── 7. 验证结果 ──
echo ""
echo "[7/8] 验证升级结果..."

VERIFY_VER=$(ssh $SSH_OPTS ${SSH_USER}@${HOST} "$SHELL_CMD 'openclaw --version 2>/dev/null'" 2>/dev/null || echo "未知")
echo "  📦 版本: $VERIFY_VER"

GW_STATUS=$(ssh $SSH_OPTS ${SSH_USER}@${HOST} "ps aux | grep openclaw-gateway | grep -v grep | head -1" 2>/dev/null || echo "")
if [[ -n "$GW_STATUS" ]]; then
    GW_PID=$(echo "$GW_STATUS" | awk '{print $2}')
    echo "  🟢 Gateway: 运行中 (PID: $GW_PID)"
else
    echo "  🔴 Gateway: 未运行，尝试启动..."
    ssh $SSH_OPTS ${SSH_USER}@${HOST} "$SHELL_CMD 'openclaw gateway restart'" 2>/dev/null || true
    sleep 5
    GW_STATUS=$(ssh $SSH_OPTS ${SSH_USER}@${HOST} "ps aux | grep openclaw-gateway | grep -v grep | head -1" 2>/dev/null || echo "")
    if [[ -n "$GW_STATUS" ]]; then
        echo "  🟢 Gateway: 已启动"
    else
        echo "  🔴 Gateway: 启动失败"
    fi
fi

# ── 8. 汇总报告 ──
echo ""
echo "[8/8] 汇总报告"
echo ""
echo "════════════════════════════════════════════════════════════"
echo "  升级报告"
echo "════════════════════════════════════════════════════════════"
echo ""
echo "  目标机器: ${SSH_USER}@${HOST}"
echo "  升级路径: v${CURRENT_VER} → v${NEW_VER}"
echo "  升级结果: $([ "$UPGRADE_SUCCESS" = "yes" ] && echo "✅ 成功" || echo "❌ 失败")"
echo "  Gateway: $([ -n "$GW_STATUS" ] && echo "🟢 运行中" || echo "🔴 未运行")"
echo ""
echo "  📦 回滚信息:"
echo "     回滚脚本: $BACKUP_DIR/rollback.sh"
echo "     回滚命令: bash $BACKUP_DIR/rollback.sh"
echo ""

if [[ "$UPGRADE_SUCCESS" == "yes" ]]; then
    echo "🎉 升级完成！v${CURRENT_VER} → v${NEW_VER}"
else
    echo "⚠️ 升级未完全成功，请检查上述验证结果"
    echo "   如需回滚: bash $BACKUP_DIR/rollback.sh"
fi

echo ""
echo "═ END ═"
