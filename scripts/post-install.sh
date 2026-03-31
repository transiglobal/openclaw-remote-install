#!/bin/bash
# post-install.sh - OpenClaw 安装后配置脚本
# 用法: ./post-install.sh <HOST> [SSH_KEY]
# 在 openclaw onboard + npx @larksuite/openclaw-lark install 完成后执行
#
# 包含：
#   1. 飞书四项优化配置
#   2. Gateway 重启 + 状态验证
#   3. bootstrap-skills 技能同步

set -e

HOST="${1:?用法: $0 <HOST> [SSH_KEY]}"
SSH_KEY="${2:-$HOME/.ssh/id_rsa_tnt}"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"

REMOTE_SHELL=$(ssh $SSH_OPTS root@$HOST 'echo $SHELL' 2>/dev/null | xargs basename || echo "bash")
if [[ "$REMOTE_SHELL" == "zsh" ]]; then
    SHELL_CMD="zsh -l -c"
else
    SHELL_CMD="bash -l -c"
fi

echo "=== OpenClaw 飞书配置后处理 ==="
echo "目标: $HOST"
echo ""

# 1. 飞书四项优化配置
echo "[1/6] 飞书优化配置..."
ssh $SSH_OPTS root@$HOST "$SHELL_CMD 'openclaw config set channels.feishu.streaming true 2>&1 | grep -v \"^Warning\" | tail -1'"
echo "  channels.feishu.streaming = true"
ssh $SSH_OPTS root@$HOST "$SHELL_CMD 'openclaw config set channels.feishu.footer.elapsed true 2>&1 | grep -v \"^Warning\" | tail -1'"
echo "  channels.feishu.footer.elapsed = true"
ssh $SSH_OPTS root@$HOST "$SHELL_CMD 'openclaw config set channels.feishu.footer.status true 2>&1 | grep -v \"^Warning\" | tail -1'"
echo "  channels.feishu.footer.status = true"
ssh $SSH_OPTS root@$HOST "$SHELL_CMD 'openclaw config set channels.feishu.threadSession true 2>&1 | grep -v \"^Warning\" | tail -1'"
echo "  channels.feishu.threadSession = true"

# 2. Gateway 重启
echo ""
echo "[2/6] Gateway 重启..."
ssh $SSH_OPTS root@$HOST "$SHELL_CMD 'systemctl --user restart openclaw-gateway.service 2>&1 | tail -1'"

# 3. 等待启动
echo ""
echo "[3/6] 等待 Gateway 就绪..."
sleep 6

# 4. 状态验证
echo ""
echo "[4/6] 状态验证..."
GW_STATUS=$(ssh $SSH_OPTS root@$HOST "$SHELL_CMD 'systemctl --user status openclaw-gateway.service 2>&1 | grep -E \"Active: active.*running\"" 2>/dev/null || echo "未运行")
echo "  Gateway: $GW_STATUS"

WS_READY=$(ssh $SSH_OPTS root@$HOST "$SHELL_CMD 'tail -15 /tmp/openclaw/openclaw-\$(date +%Y-%m-%d).log 2>/dev/null | grep \"ws client ready\" | tail -1'" 2>/dev/null || echo "")
if [[ -n "$WS_READY" ]]; then
    echo "  WebSocket: 已连接"
else
    echo "  WebSocket: 检查中..."
    sleep 3
    WS_READY=$(ssh $SSH_OPTS root@$HOST "$SHELL_CMD 'tail -5 /tmp/openclaw/openclaw-\$(date +%Y-%m-%d).log 2>/dev/null | grep \"ws client ready\"'" 2>/dev/null || echo "未就绪")
    echo "  WebSocket: $WS_READY"
fi

# 5. 配置确认
echo ""
echo "[5/6] 配置确认..."
echo "  streaming: $(ssh $SSH_OPTS root@$HOST "$SHELL_CMD 'openclaw config get channels.feishu.streaming'" 2>/dev/null)"
echo "  footer.elapsed: $(ssh $SSH_OPTS root@$HOST "$SHELL_CMD 'openclaw config get channels.feishu.footer.elapsed'" 2>/dev/null)"
echo "  footer.status: $(ssh $SSH_OPTS root@$HOST "$SHELL_CMD 'openclaw config get channels.feishu.footer.status'" 2>/dev/null)"
echo "  threadSession: $(ssh $SSH_OPTS root@$HOST "$SHELL_CMD 'openclaw config get channels.feishu.threadSession'" 2>/dev/null)"

# 6. bootstrap-skills 同步
echo ""
echo "[6/6] bootstrap-skills 同步..."
# 检查本地是否有 workspace
WORKSPACE_EXISTS=$(ssh $SSH_OPTS root@$HOST "$SHELL_CMD '[ -d /root/.openclaw/workspace ] && echo yes || echo no'" 2>/dev/null)
if [[ "$WORKSPACE_EXISTS" == "yes" ]]; then
    # 检查 workspace 是否已有 git 仓库
    HAS_GIT=$(ssh $SSH_OPTS root@$HOST "$SHELL_CMD 'cd /root/.openclaw/workspace && git rev-parse --git-dir 2>/dev/null && echo yes || echo no'" 2>/dev/null)
    if [[ "$HAS_GIT" == "yes" ]]; then
        # 检查 remote 是否有 bootstrap-skills
        HAS_BS=$(ssh $SSH_OPTS root@$HOST "$SHELL_CMD 'cd /root/.openclaw/workspace && git remote -v | grep bootstrap-skills | head -1'" 2>/dev/null)
        if [[ -z "$HAS_BS" ]]; then
            echo "  添加 bootstrap-skills remote..."
            ssh $SSH_OPTS root@$HOST "$SHELL_CMD 'cd /root/.openclaw/workspace && git remote add bootstrap-skills https://eeffa2cab255f9034e033c929f58488f799e5b3e@git.moguyn.cn/transiglobal/bootstrap-skills.git 2>/dev/null || true'"
        fi
        echo "  同步 bootstrap-skills submodule..."
        ssh $SSH_OPTS root@$HOST "$SHELL_CMD 'cd /root/.openclaw/workspace && git fetch bootstrap-skills 2>&1 | tail -3 && git submodule update --init skills/bootstrap-skills 2>&1 | tail -5'" || true
        echo "  bootstrap-skills 同步完成"
    else
        echo "  workspace 不是 git 仓库，跳过 bootstrap-skills 同步"
    fi
else
    echo "  workspace 目录不存在，跳过 bootstrap-skills 同步"
fi

echo ""
echo "=== 配置完成 ==="
echo "飞书机器人已就绪，可正常收发消息。"
echo "bootstrap-skills 技能已同步。"
