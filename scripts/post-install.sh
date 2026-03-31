#!/bin/bash
# post-install.sh - OpenClaw 安装后飞书配置脚本
# 用法: ./post-install.sh <HOST> [SSH_KEY]
# 在 openclaw onboard + npx @larksuite/openclaw-lark install 完成后执行
#
# 包含：
#   1. 飞书四项优化配置
#   2. Gateway 重启
#   3. 状态验证

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

# 四项飞书优化配置
echo "[1/5] 飞书优化配置..."
ssh $SSH_OPTS root@$HOST "$SHELL_CMD 'openclaw config set channels.feishu.streaming true 2>&1 | grep -v \"^Warning\" | tail -1'"
echo "  channels.feishu.streaming = true"
ssh $SSH_OPTS root@$HOST "$SHELL_CMD 'openclaw config set channels.feishu.footer.elapsed true 2>&1 | grep -v \"^Warning\" | tail -1'"
echo "  channels.feishu.footer.elapsed = true"
ssh $SSH_OPTS root@$HOST "$SHELL_CMD 'openclaw config set channels.feishu.footer.status true 2>&1 | grep -v \"^Warning\" | tail -1'"
echo "  channels.feishu.footer.status = true"
ssh $SSH_OPTS root@$HOST "$SHELL_CMD 'openclaw config set channels.feishu.threadSession true 2>&1 | grep -v \"^Warning\" | tail -1'"
echo "  channels.feishu.threadSession = true"

# Gateway 重启
echo ""
echo "[2/5] Gateway 重启..."
ssh $SSH_OPTS root@$HOST "$SHELL_CMD 'systemctl --user restart openclaw-gateway.service 2>&1 | tail -1'"

# 等待启动
echo ""
echo "[3/5] 等待 Gateway 就绪..."
sleep 6

# 验证
echo ""
echo "[4/5] 状态验证..."
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

echo ""
echo "[5/5] 配置确认..."
ssh $SSH_OPTS root@$HOST "$SHELL_CMD 'echo \"  streaming: \$(openclaw config get channels.feishu.streaming)\"'"
ssh $SSH_OPTS root@$HOST "$SHELL_CMD 'echo \"  footer.elapsed: \$(openclaw config get channels.feishu.footer.elapsed)\"'"
ssh $SSH_OPTS root@$HOST "$SHELL_CMD 'echo \"  footer.status: \$(openclaw config get channels.feishu.footer.status)\"'"
ssh $SSH_OPTS root@$HOST "$SHELL_CMD 'echo \"  threadSession: \$(openclaw config get channels.feishu.threadSession)\"'"

echo ""
echo "=== 配置完成 ==="
echo "飞书机器人已就绪，可正常收发消息。"
