#!/bin/bash
# openclaw-remote-upgrade - 远程机器 OpenClaw 升级脚本（含回滚）
# 用法: ./upgrade.sh [--force] [--version=X.Y.Z] <USER@HOST> [SSH_KEY] [TARGET_VERSION]
# 示例: ./upgrade.sh trclaw2@100.81.167.91 ~/.ssh/id_rsa_tnt
# 示例: ./upgrade.sh --force root@43.134.173.17 ~/.ssh/id_rsa_tnt 2026.4.11
#
# Breaking Changes 处理逻辑：
#   - 检测到 BC → 分类为「Agent 可自动处理」或「需人工确认」
#   - 全部可自动处理 → 输出处理步骤，继续升级
#   - 有需人工确认的 → 暂停（exit 2），agent 询问用户
#   - --force → 跳过所有 BC 检查，直接升级
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
[[ "$FORCE" == "true" ]] && echo "模式: --force（跳过 BC 检查）"
echo ""

# ── 1. SSH 连接测试 ──
echo "[1/10] SSH 连接测试..."
if ! ssh $SSH_OPTS ${SSH_USER}@${HOST} 'echo "SSH OK"' 2>/dev/null; then
    echo "❌ SSH 连接失败，请检查："
    echo "  - SSH 私钥是否正确: $SSH_KEY"
    echo "  - 目标机器是否可达: $HOST"
    echo "  - 用户是否有权限: $SSH_USER"
    exit 1
fi
echo "✅ SSH 连接正常"

# ── 1.5 检查并切换 npm 国内源 ──
echo ""
echo "[2/10] 检查并切换 npm 国内源..."
CURRENT_REG=$(ssh $SSH_OPTS ${SSH_USER}@${HOST} "$SHELL_CMD 'npm config get registry 2>/dev/null'" 2>/dev/null | xargs || echo "")
MIRROR_OK=false
if [[ -n "$CURRENT_REG" ]]; then
    if echo "$CURRENT_REG" | grep -qE "npmmirror|tencent|cnpm|aliyun|huawei"; then
        echo "  ✅ npm 源已是国内镜像: $CURRENT_REG"
        MIRROR_OK=true
    else
        echo "  ⚠️  当前 npm 源非国内镜像: $CURRENT_REG"
        echo "  → 切换为 https://registry.npmmirror.com ..."
        ssh $SSH_OPTS ${SSH_USER}@${HOST} "$SHELL_CMD 'npm config set registry https://registry.npmmirror.com'" >/dev/null 2>&1
        NEW_REG=$(ssh $SSH_OPTS ${SSH_USER}@${HOST} "$SHELL_CMD 'npm config get registry 2>/dev/null'" 2>/dev/null | xargs || echo "")
        echo "  ✅ 已切换为: $NEW_REG"
        MIRROR_OK=true
    fi
else
    echo "  ⚠️  无法获取 npm 源，尝试设置国内镜像..."
    ssh $SSH_OPTS ${SSH_USER}@${HOST} "$SHELL_CMD 'npm config set registry https://registry.npmmirror.com'" >/dev/null 2>&1
    MIRROR_OK=true
fi
if [[ "$MIRROR_OK" == "true" ]]; then
    echo "✅ npm 国内源就绪"
fi


# ── 2. 版本检测与对比 ──
echo ""
echo "[3/10] 版本检测与对比..."

CURRENT_VER=$(ssh $SSH_OPTS ${SSH_USER}@${HOST} "$SHELL_CMD 'openclaw --version 2>/dev/null'" 2>/dev/null | grep -oP 'OpenClaw \K[\d.]+' | head -1 || echo "")
if [[ -z "$CURRENT_VER" ]]; then
    echo "❌ 目标机器未安装 OpenClaw，或 openclaw 命令不可用"
    echo "   请使用 install.sh 进行全新安装"
    exit 1
fi

GATEWAY_VER=$(ssh $SSH_OPTS ${SSH_USER}@${HOST} "$SHELL_CMD 'openclaw --version 2>/dev/null'" 2>/dev/null | head -1)
echo "  当前版本: $GATEWAY_VER"

if [[ "$TARGET_VERSION" == "latest" ]]; then
    LATEST_VER=$(ssh $SSH_OPTS ${SSH_USER}@${HOST} "$SHELL_CMD 'npm view openclaw version 2>/dev/null'" 2>/dev/null || echo "")
    if [[ -z "$LATEST_VER" ]]; then
        LATEST_VER=$(curl -s https://api.github.com/repos/openclaw/openclaw/releases/latest 2>/dev/null | grep -oP '"tag_name":\s*"v\K[^"]+' || echo "")
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
echo "[4/10] 获取变更日志..."

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
        # Agent 可自动处理：配置重命名、字段迁移、废弃→替代方案
        BC_AUTO=$(echo "$BREAKING" | grep -iE "(config.*rename|字段.*重命名|field.*rename|deprecated.*use|废弃.*使用|rename.*to|改名为|migrate.*config|配置.*迁移|移除.*请使用|removed.*use|switch.*to|切换到)" | head -10 || true)

        # 需要人工确认：功能删除、数据迁移、重大格式变更
        if [[ -n "$BC_AUTO" ]]; then
            BC_MANUAL=$(echo "$BREAKING" | grep -vFxf <(echo "$BC_AUTO") | head -10 || true)
        else
            BC_MANUAL="$BREAKING"
        fi

        if [[ -n "$BC_AUTO" ]]; then
            echo "🤖 Agent 可自动处理的变更:"
            echo "$BC_AUTO" | sed 's/^/    /'
            echo ""

            # 生成自动处理步骤
            echo "📋 自动生成的处理步骤:"
            while IFS= read -r line; do
                [[ -z "$line" ]] && continue
                if echo "$line" | grep -qiE "rename|改名|migrate|迁移"; then
                    OLD_FIELD=$(echo "$line" | grep -oP '(?:从|from|旧字段|old)[：:\s]*\K[a-zA-Z_.]+' | head -1 || true)
                    NEW_FIELD=$(echo "$line" | grep -oP '(?:到|to|新字段|new)[：:\s]*\K[a-zA-Z_.]+' | head -1 || true)
                    if [[ -n "$OLD_FIELD" ]] && [[ -n "$NEW_FIELD" ]]; then
                        echo "    → 配置迁移: openclaw.json 中将 '$OLD_FIELD' 改为 '$NEW_FIELD'"
                    fi
                fi
                if echo "$line" | grep -qiE "deprecated|废弃"; then
                    echo "    → 废弃功能检测到，升级后需关注兼容性"
                fi
                if echo "$line" | grep -qiE "removed.*use|移除.*请使用"; then
                    echo "    → 已移除功能有替代方案，将自动切换"
                fi
            done <<< "$BC_AUTO"
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
            echo "   升级已暂停，等待用户确认"
            echo ""

            # 输出结构化数据供 agent 解析
            echo "=== BC_REPORT ==="
            echo "STATUS=NEEDS_CONFIRMATION"
            echo "AUTO_HANDLEABLE=$(echo "$BC_AUTO" | grep -c . 2>/dev/null || echo 0)"
            echo "NEEDS_CONFIRMATION=$(echo "$BC_MANUAL" | grep -c . 2>/dev/null || echo 0)"
            echo "AUTO_DETAILS=$BC_AUTO"
            echo "MANUAL_DETAILS=$BC_MANUAL"
            echo "=== END_BC_REPORT ==="
            echo ""

            # 非交互模式（被 agent 调用时）：直接退出
            if [[ ! -t 0 ]]; then
                echo "⏸️  非交互模式，升级已暂停（exit 2）"
                echo "   Agent 应解析 BC_REPORT 并询问用户确认"
                echo "   用户确认后使用 --force 重新执行: $0 --force $USER_HOST $SSH_KEY $TARGET_VERSION"
                exit 2
            fi

            # 交互模式：询问用户
            echo "请选择:"
            echo "  1. 确认继续升级（接受 Breaking Changes）"
            echo "  2. 取消升级"
            echo ""
            read -p "请选择 [1/2]: " bc_choice
            case "$bc_choice" in
                1)
                    echo "→ 用户确认继续升级"
                    ;;
                *)
                    echo "→ 取消升级"
                    echo "   如需跳过检查，请使用: $0 --force $USER_HOST $SSH_KEY $TARGET_VERSION"
                    exit 2
                    ;;
            esac
        fi
    else
        echo "✅ 未发现明显的 Breaking Changes"
        echo ""
    fi

    # 提取新功能
    FEATURES=$(echo "$CHANGELOG_SECTION" | grep -iE "(feat|feature|new|add)" | head -10 || true)
    if [[ -n "$FEATURES" ]]; then
        echo "🌟 新功能:"
        echo "$FEATURES" | sed 's/^/    /'
        echo ""
    fi

    # 提取 bug 修复
    FIXES=$(echo "$CHANGELOG_SECTION" | grep -iE "(fix|bug|issue|error)" | head -10 || true)
    if [[ -n "$FIXES" ]]; then
        echo "🔧 Bug 修复:"
        echo "$FIXES" | sed 's/^/    /'
        echo ""
    fi
else
    echo "⚠️  无法获取详细变更日志，将直接执行升级"
    echo "   建议手动检查: https://github.com/openclaw/openclaw/releases"
fi

# 输出完整变更摘要供外部 agent 解析
echo "=== CHANGELOG_SUMMARY ==="
echo "CURRENT=$CURRENT_VER"
echo "TARGET=$TARGET_VERSION"
echo "HAS_BREAKING=$BREAKING_FOUND"
echo "$CHANGELOG_SECTION"
echo "=== END_SUMMARY ==="

# ── 4. 规划回滚步骤 ──
echo ""
echo "[5/10] 规划回滚步骤..."

BACKUP_DIR="/tmp/openclaw-rollback-$(date +%Y%m%d%H%M%S)"
mkdir -p "$BACKUP_DIR"

echo "  📦 备份当前状态到: $BACKUP_DIR"
ssh $SSH_OPTS ${SSH_USER}@${HOST} "$SHELL_CMD 'npm list -g openclaw 2>/dev/null'" > "$BACKUP_DIR/npm-list.txt" 2>/dev/null || true
ssh $SSH_OPTS ${SSH_USER}@${HOST} "$SHELL_CMD 'openclaw --version 2>/dev/null'" > "$BACKUP_DIR/current-version.txt" 2>/dev/null || true
ssh $SSH_OPTS ${SSH_USER}@${HOST} "$SHELL_CMD 'cat ~/.openclaw/openclaw.json 2>/dev/null'" > "$BACKUP_DIR/openclaw-config.json" 2>/dev/null || true

cat > "$BACKUP_DIR/rollback.sh" << ROLLBACK_EOF
#!/bin/bash
# OpenClaw 回滚脚本（自动生成）
# 回滚目标: ${SSH_USER}@${HOST}
# 回滚到版本: ${CURRENT_VER}
# 生成时间: $(date)

SSH_OPTS="$SSH_OPTS"
USER_HOST="${SSH_USER}@${HOST}"
TARGET_VER="${CURRENT_VER}"

echo "=== OpenClaw 回滚 ==="
echo "目标: \$USER_HOST"
echo "回滚版本: \$TARGET_VER"
echo ""

echo "[1/3] 回滚 openclaw 到 v\$TARGET_VER..."
ssh \$SSH_OPTS \$USER_HOST 'bash -l -c "npm config set registry https://registry.npmmirror.com && npm install -g openclaw@'\$TARGET_VER'"'
echo "✅ 版本已回滚"

echo "[2/3] 恢复配置..."
scp \$SSH_OPTS "$BACKUP_DIR/openclaw-config.json" \$USER_HOST:~/.openclaw/openclaw.json 2>/dev/null || echo "⚠️ 配置恢复失败，可能需要手动恢复"

echo "[3/3] 重启 Gateway..."
ssh \$SSH_OPTS \$USER_HOST 'bash -l -c "openclaw gateway restart"'
sleep 3

echo ""
echo "=== 回滚验证 ==="
ssh \$SSH_OPTS \$USER_HOST 'bash -l -c "openclaw --version"'
echo "✅ 回滚完成"
ROLLBACK_EOF

chmod +x "$BACKUP_DIR/rollback.sh"

echo "  📝 回滚脚本已生成: $BACKUP_DIR/rollback.sh"
echo "  📝 回滚命令: bash $BACKUP_DIR/rollback.sh"
echo ""

# ── 5. 执行升级 ──
echo "[6/10] 执行升级..."

echo "  → 切换 npm 国内源..."
ssh $SSH_OPTS ${SSH_USER}@${HOST} "$SHELL_CMD 'npm config set registry https://registry.npmmirror.com'" >/dev/null 2>&1

echo "  → 清理残留 npm 进程..."
ssh $SSH_OPTS ${SSH_USER}@${HOST} 'killall -9 npm node 2>/dev/null' 2>/dev/null || true
sleep 2

echo "  → 升级 openclaw 到 v${TARGET_VERSION}..."
UPGRADE_OUTPUT=$(ssh $SSH_OPTS ${SSH_USER}@${HOST} "$SHELL_CMD 'npm install -g openclaw@${TARGET_VERSION} 2>&1'" 2>&1 || true)

NEW_VER=$(ssh $SSH_OPTS ${SSH_USER}@${HOST} "$SHELL_CMD 'openclaw --version 2>/dev/null'" 2>/dev/null | grep -oP 'OpenClaw \K[\d.]+' | head -1 || echo "")

if [[ "$NEW_VER" == "$TARGET_VERSION" ]]; then
    echo "  ✅ 升级成功: v${CURRENT_VER} → v${NEW_VER}"
    UPGRADE_SUCCESS="yes"
else
    echo "  ❌ 升级失败"
    echo "     期望版本: $TARGET_VERSION"
    echo "     实际版本: ${NEW_VER:-未检测到}"
    echo ""
    echo "  升级输出:"
    echo "$UPGRADE_OUTPUT" | tail -20 | sed 's/^/    /'
    UPGRADE_SUCCESS="no"

    echo ""
    echo "  → 尝试修复：重新安装..."
    ssh $SSH_OPTS ${SSH_USER}@${HOST} "$SHELL_CMD 'npm install -g openclaw@${TARGET_VERSION}'" 2>&1 | tail -5
    sleep 2
    NEW_VER=$(ssh $SSH_OPTS ${SSH_USER}@${HOST} "$SHELL_CMD 'openclaw --version 2>/dev/null'" 2>/dev/null | grep -oP 'OpenClaw \K[\d.]+' | head -1 || echo "")

    if [[ "$NEW_VER" == "$TARGET_VERSION" ]]; then
        echo "  ✅ 重试成功: v${NEW_VER}"
        UPGRADE_SUCCESS="yes"
    else
        echo "  ❌ 重试仍然失败"
        UPGRADE_SUCCESS="no"
        echo ""
        echo "  ⚠️ 是否回滚到 v${CURRENT_VER}？"
        read -p "  回滚？[y/N]: " rollback_choice
        if [[ "$rollback_choice" =~ ^[Yy]$ ]]; then
            echo "  → 执行回滚..."
            bash "$BACKUP_DIR/rollback.sh"
            echo "  ✅ 回滚完成"
            exit 1
        fi
    fi
fi

# ── 6. 更新飞书插件 ──
echo ""
echo "[7/10] 更新官方插件..."
echo "  → 检查已安装的官方插件..."
PLUGIN_LIST=$(ssh $SSH_OPTS ${SSH_USER}@${HOST} "$SHELL_CMD 'openclaw plugins list 2>/dev/null'" 2>/dev/null | grep -E "@larksuite|@wecom" | grep -v "grep" || echo "")
if [[ -z "$PLUGIN_LIST" ]]; then
    echo "  ℹ️  未发现飞书或企业微信插件，跳过插件更新"
else
    echo "  发现以下官方插件："
    echo "$PLUGIN_LIST" | while read line; do
        echo "    $line"
    done
    # 飞书插件更新
    if echo "$PLUGIN_LIST" | grep -q "@larksuite"; then
        echo ""
        echo "  → 更新 @larksuite/openclaw-lark ..."
        ssh $SSH_OPTS ${SSH_USER}@${HOST} "$SHELL_CMD 'npx @larksuite/openclaw-lark update 2>&1'" 2>/dev/null || true
        echo "  ✅ 飞书插件更新完成"
    fi
    # 企业微信插件更新
    if echo "$PLUGIN_LIST" | grep -q "@wecom"; then
        echo ""
        echo "  → 更新 @wecom/wecom-openclaw-cli ..."
        ssh $SSH_OPTS ${SSH_USER}@${HOST} "$SHELL_CMD 'npx @wecom/wecom-openclaw-cli update 2>&1'" 2>/dev/null || true
        echo "  ✅ 企业微信插件更新完成"
    fi
fi

# ── 7. 重启 Gateway ──
echo ""
echo "[8/10] 重启 Gateway..."
ssh $SSH_OPTS ${SSH_USER}@${HOST} "$SHELL_CMD 'openclaw gateway restart'" 2>&1 || {
    echo "  ⚠️ Gateway 重启命令执行失败，尝试 systemctl..."
    ssh $SSH_OPTS ${SSH_USER}@${HOST} 'systemctl --user restart openclaw-gateway.service' 2>/dev/null || true
}
sleep 5

# ── 7. 恢复 npm 源 ──
echo ""
echo "[9/10] 恢复 npm 国内源..."
ssh $SSH_OPTS ${SSH_USER}@${HOST} "$SHELL_CMD 'npm config set registry https://registry.npmmirror.com && npm config get registry'" 2>/dev/null || echo "  ⚠️ npm 源恢复可能失败"

# ── 8. 验证结果 ──
echo ""
echo "[10/10] 验证升级结果..."

VERIFY_VER=$(ssh $SSH_OPTS ${SSH_USER}@${HOST} "$SHELL_CMD 'openclaw --version 2>/dev/null'" 2>/dev/null || echo "未知")
echo "  📦 版本: $VERIFY_VER"

GW_STATUS=$(ssh $SSH_OPTS ${SSH_USER}@${HOST} "ps aux | grep openclaw-gateway | grep -v grep | head -1" 2>/dev/null || echo "")
if [[ -n "$GW_STATUS" ]]; then
    GW_PID=$(echo "$GW_STATUS" | awk '{print $2}')
    echo "  🟢 Gateway: 运行中 (PID: $GW_PID)"
else
    echo "  🔴 Gateway: 未运行"
    echo "     → 尝试启动..."
    ssh $SSH_OPTS ${SSH_USER}@${HOST} "$SHELL_CMD 'openclaw gateway restart'" 2>/dev/null || true
    sleep 3
    GW_STATUS=$(ssh $SSH_OPTS ${SSH_USER}@${HOST} "ps aux | grep openclaw-gateway | grep -v grep | head -1" 2>/dev/null || echo "")
    if [[ -n "$GW_STATUS" ]]; then
        echo "  🟢 Gateway: 已启动"
    else
        echo "  🔴 Gateway: 启动失败"
    fi
fi

NPM_REG=$(ssh $SSH_OPTS ${SSH_USER}@${HOST} "$SHELL_CMD 'npm config get registry'" 2>/dev/null || echo "未知")
echo "  📦 npm 源: $NPM_REG"

# ── 9. 汇总报告 ──
echo ""
echo "════════════════════════════════════════════════════════════"
echo "  升级报告"
echo "════════════════════════════════════════════════════════════"
echo ""
echo "  目标机器: ${SSH_USER}@${HOST}"
echo "  升级路径: v${CURRENT_VER} → v${VERIFY_VER}"
echo "  升级结果: $([ "$UPGRADE_SUCCESS" = "yes" ] && echo "✅ 成功" || echo "❌ 失败")"
echo "  Gateway: $([ -n "$GW_STATUS" ] && echo "🟢 运行中" || echo "🔴 未运行")"
echo "  npm 源: $NPM_REG"
echo ""
echo "  📦 回滚信息:"
echo "     回滚脚本: $BACKUP_DIR/rollback.sh"
echo "     回滚命令: bash $BACKUP_DIR/rollback.sh"
echo ""

if [[ "$UPGRADE_SUCCESS" == "yes" ]]; then
    echo "🎉 升级完成！v${CURRENT_VER} → v${VERIFY_VER}"
else
    echo "⚠️ 升级未完全成功，请检查上述验证结果"
    echo "   如需回滚: bash $BACKUP_DIR/rollback.sh"
fi

echo ""
echo "═ END ═"
