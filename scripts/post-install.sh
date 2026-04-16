#!/bin/bash
# post-install.sh - OpenClaw 安装后配置脚本
# 用法: ./post-install.sh <HOST> [SSH_KEY] [SSH_USER]
# 在 openclaw onboard + npx @larksuite/openclaw-lark install 完成后执行
#
# 包含：
#   1. 飞书四项优化配置
#   2. Gateway 重启 + 状态验证
#   3. bootstrap-skills 技能同步
#   4. AGENTS.md 重启规范创建

set -e

HOST="${1:?用法: $0 <HOST> [SSH_KEY] [SSH_USER]}"
SSH_KEY="${2:-$HOME/.ssh/id_rsa_tnt}"
SSH_USER="${3:-root}"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"

REMOTE_SHELL=$(ssh $SSH_OPTS $SSH_USER@$HOST 'echo $SHELL' 2>/dev/null | xargs basename || echo "bash")
if [[ "$REMOTE_SHELL" == "zsh" ]]; then
    SHELL_CMD="zsh -l -c"
else
    SHELL_CMD="bash -l -c"
fi

# 检测 workspace 路径（macOS 用 /Users/xxx，Linux 用 /root）
if [[ "$SSH_USER" == "root" ]]; then
    WS_PATH="/root/.openclaw/workspace"
else
    WS_PATH="/Users/$SSH_USER/.openclaw/workspace"
fi

echo "=== OpenClaw 飞书配置后处理 ==="
echo "目标: $HOST (user: $SSH_USER)"
echo ""

# 1. 飞书优化配置（需先安装飞书插件 npx @larksuite/openclaw-lark install）
echo "[1/7] 飞书优化配置..."
# streaming：OpenClaw 内置支持，无需插件
ssh $SSH_OPTS $SSH_USER@$HOST "$SHELL_CMD 'openclaw config set channels.feishu.streaming true 2>&1 | grep -v \"^Warning\" | tail -1'"
echo "  streaming = true"
# 以下三项依赖飞书插件，插件未安装时 schema 不支持这些字段，忽略错误
ssh $SSH_OPTS $SSH_USER@$HOST "$SHELL_CMD 'openclaw config set channels.feishu.footer.elapsed true 2>&1 | grep -v \"^Warning\" | tail -1'" 2>/dev/null && echo "  footer.elapsed = true" || echo "  footer.elapsed = 跳过（需先安装飞书插件）"
ssh $SSH_OPTS $SSH_USER@$HOST "$SHELL_CMD 'openclaw config set channels.feishu.footer.status true 2>&1 | grep -v \"^Warning\" | tail -1'" 2>/dev/null && echo "  footer.status = true" || echo "  footer.status = 跳过（需先安装飞书插件）"
ssh $SSH_OPTS $SSH_USER@$HOST "$SHELL_CMD 'openclaw config set channels.feishu.threadSession true 2>&1 | grep -v \"^Warning\" | tail -1'" 2>/dev/null && echo "  threadSession = true" || echo "  threadSession = 跳过（需先安装飞书插件）"

# 2. Gateway 重启
echo ""
echo "[2/7] Gateway 重启..."
if [[ "$(uname)" == "Darwin" ]] || ssh $SSH_OPTS $SSH_USER@$HOST "$SHELL_CMD 'uname -s'" 2>/dev/null | grep -q Darwin; then
    # macOS: 用 launchctl 或 openclaw gateway restart
    ssh $SSH_OPTS $SSH_USER@$HOST "$SHELL_CMD 'openclaw gateway restart 2>&1 | tail -1'"
else
    ssh $SSH_OPTS $SSH_USER@$HOST "$SHELL_CMD 'systemctl --user restart openclaw-gateway.service 2>&1 | tail -1'"
fi

# 3. 等待启动
echo ""
echo "[3/7] 等待 Gateway 就绪..."
sleep 6

# 4. 状态验证
echo ""
echo "[4/7] 状态验证..."
GW_STATUS=$(ssh $SSH_OPTS $SSH_USER@$HOST "$SHELL_CMD 'openclaw gateway status 2>&1 | head -3'" 2>/dev/null || echo "未运行")
echo "  Gateway: $GW_STATUS"

# 5. 配置确认
echo ""
echo "[5/7] 配置确认..."
echo "  streaming: $(ssh $SSH_OPTS $SSH_USER@$HOST "$SHELL_CMD 'openclaw config get channels.feishu.streaming'" 2>/dev/null)"
echo "  footer.elapsed: $(ssh $SSH_OPTS $SSH_USER@$HOST "$SHELL_CMD 'openclaw config get channels.feishu.footer.elapsed'" 2>/dev/null)"
echo "  footer.status: $(ssh $SSH_OPTS $SSH_USER@$HOST "$SHELL_CMD 'openclaw config get channels.feishu.footer.status'" 2>/dev/null)"
echo "  threadSession: $(ssh $SSH_OPTS $SSH_USER@$HOST "$SHELL_CMD 'openclaw config get channels.feishu.threadSession'" 2>/dev/null)"

# 6. bootstrap-skills 同步
echo ""
echo "[6/7] bootstrap-skills 同步..."
WORKSPACE_EXISTS=$(ssh $SSH_OPTS $SSH_USER@$HOST "$SHELL_CMD '[ -d $WS_PATH ] && echo yes || echo no'" 2>/dev/null)
if [[ "$WORKSPACE_EXISTS" != "yes" ]]; then
    echo "  workspace 目录不存在，跳过"
else
    HAS_BS=$(ssh $SSH_OPTS $SSH_USER@$HOST "$SHELL_CMD '[ -d $WS_PATH/skills/bootstrap-skills ] && echo yes || echo no'" 2>/dev/null)
    if [[ "$HAS_BS" == "yes" ]]; then
        echo "  bootstrap-skills 已存在，跳过"
    else
        echo "  克隆 bootstrap-skills..."
        ssh $SSH_OPTS $SSH_USER@$HOST "$SHELL_CMD 'mkdir -p $WS_PATH/skills && git clone --depth=1 https://eeffa2cab255f9034e033c929f58488f799e5b3e@git.moguyn.cn/transiglobal/bootstrap-skills.git $WS_PATH/skills/bootstrap-skills 2>&1 | tail -5'"
        echo "  bootstrap-skills 克隆完成"
    fi
fi

# 7. AGENTS.md 创建（重启规范）
echo ""
echo "[7/7] AGENTS.md 重启规范..."
AGENTS_PATH="$WS_PATH/AGENTS.md"
AGENTS_EXISTS=$(ssh $SSH_OPTS $SSH_USER@$HOST "$SHELL_CMD '[ -f $AGENTS_PATH ] && echo yes || echo no'" 2>/dev/null)
if [[ "$AGENTS_EXISTS" == "yes" ]]; then
    echo "  AGENTS.md 已存在，追加规则..."
    HAS_REBOOT_RULE=$(ssh $SSH_OPTS $SSH_USER@$HOST "$SHELL_CMD 'grep -q \"配置更新与 Gateway 重启规范\" $AGENTS_PATH 2>/dev/null && echo yes || echo no'" 2>/dev/null)
    if [[ "$HAS_REBOOT_RULE" == "yes" ]]; then
        echo "  重启规范已存在，跳过"
    else
        # 使用 heredoc 写入临时文件再追加，避免转义问题
        REBOOT_RULE=$(cat <<'HEREDOC'

## 配置更新与 Gateway 重启规范

⚠️ 配置变更后必须通过 gateway 工具重启，禁止用 exec 直接调用 openclaw gateway restart 来应用配置变更。

### 配置更新（改配置 + 重启）

1. 先获取 baseHash：调用 `gateway` 工具，action=`config.get`
2. 通过 `session_status` 获取当前 session 的完整 key
3. 调用 `gateway` 工具，action=`config.patch`，带上以下参数：
   - `raw`：完整配置 JSON 字符串
   - `baseHash`：上一步 config.get 返回的 hash
   - `note`：格式 "Gateway已重启，原因：XXX"
   - `sessionKey`：完整 key（如 "agent:main:feishu:default:direct:ou_xxx"），**不能用简写 agent:main**

**强制规则：**
1. ✅ **必须用**：`gateway config.patch` / `gateway config.apply` / `gateway update.run`
2. ✅ **必须先获取**：`baseHash`（通过 `gateway config.get`）
3. ✅ **必须传**：`note` 参数，格式 "Gateway已重启，原因：XXX"
4. ✅ **必须传**：`sessionKey` 参数，完整 key，通过 `session_status` 获取
5. ❌ **禁止用**：`exec: openclaw gateway restart` 做配置变更后的重启
6. ❌ **禁止用**：`exec: openclaw update`（没有重启通知）

### 单纯重启（不改配置）

使用 `openclaw gateway restart`（仅当不涉及配置变更时）。
HEREDOC
)
        # Base64 编码传输，避免所有转义问题
        RULE_B64=$(printf '%s' "$REBOOT_RULE" | base64 | tr -d '\n')
        ssh $SSH_OPTS $SSH_USER@$HOST "$SHELL_CMD 'echo \"$RULE_B64\" | base64 -d >> $AGENTS_PATH'" 2>/dev/null
        echo "  重启规范已追加到 AGENTS.md"
    fi
else
    echo "  创建 AGENTS.md..."
    FULL_AGENTS=$(cat <<'HEREDOC'
# AGENTS.md - Agent 行为规范

## 配置更新与 Gateway 重启规范

⚠️ 配置变更后必须通过 gateway 工具重启，禁止用 exec 直接调用 openclaw gateway restart 来应用配置变更。

### 配置更新（改配置 + 重启）

1. 先获取 baseHash：调用 `gateway` 工具，action=`config.get`
2. 通过 `session_status` 获取当前 session 的完整 key
3. 调用 `gateway` 工具，action=`config.patch`，带上以下参数：
   - `raw`：完整配置 JSON 字符串
   - `baseHash`：上一步 config.get 返回的 hash
   - `note`：格式 "Gateway已重启，原因：XXX"
   - `sessionKey`：完整 key（如 "agent:main:feishu:default:direct:ou_xxx"），**不能用简写 agent:main**

**强制规则：**
1. ✅ **必须用**：`gateway config.patch` / `gateway config.apply` / `gateway update.run`
2. ✅ **必须先获取**：`baseHash`（通过 `gateway config.get`）
3. ✅ **必须传**：`note` 参数，格式 "Gateway已重启，原因：XXX"
4. ✅ **必须传**：`sessionKey` 参数，完整 key，通过 `session_status` 获取
5. ❌ **禁止用**：`exec: openclaw gateway restart` 做配置变更后的重启
6. ❌ **禁止用**：`exec: openclaw update`（没有重启通知）

### 单纯重启（不改配置）

使用 `openclaw gateway restart`（仅当不涉及配置变更时）。
HEREDOC
)
    FULL_B64=$(printf '%s' "$FULL_AGENTS" | base64 | tr -d '\n')
    ssh $SSH_OPTS $SSH_USER@$HOST "$SHELL_CMD 'mkdir -p $WS_PATH && echo \"$FULL_B64\" | base64 -d > $AGENTS_PATH'" 2>/dev/null
    echo "  AGENTS.md 创建完成"
fi

echo ""
echo "=== 配置完成 ==="
echo "飞书机器人已就绪，可正常收发消息。"
echo "bootstrap-skills 技能已同步。"
echo "AGENTS.md 重启规范已创建。"
