#!/bin/bash
# openclaw-remote-diagnose - 远程机器 OpenClaw 状态诊断
# 用法: ./diagnose.sh <HOST> [SSH_KEY]

HOST="${1:?用法: $0 <HOST> [SSH_KEY]}"
SSH_KEY="${2:-$HOME/.ssh/id_rsa_tnt}"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"

# 检测远程 shell 类型
REMOTE_SHELL=$(ssh $SSH_OPTS root@$HOST 'echo $SHELL' 2>/dev/null | xargs basename || echo "bash")
if [[ "$REMOTE_SHELL" == "zsh" ]]; then
    SHELL_CMD="zsh -l -c"
else
    SHELL_CMD="bash -l -c"
fi

echo "=== OpenClaw 远程诊断: $HOST ==="
echo "远程 Shell: $REMOTE_SHELL"
echo ""

echo "=== Node ==="
ssh $SSH_OPTS root@$HOST "$SHELL_CMD 'node --version'"

echo ""
echo "=== openclaw (login shell) ==="
ssh $SSH_OPTS root@$HOST "$SHELL_CMD 'openclaw --version 2>/dev/null || echo NOT_FOUND'"

echo ""
echo "=== which openclaw ==="
ssh $SSH_OPTS root@$HOST "$SHELL_CMD 'which openclaw 2>/dev/null || echo not_in_PATH'"

echo ""
echo "=== Gateway ==="
ssh $SSH_OPTS root@$HOST "$SHELL_CMD 'systemctl --user status openclaw-gateway.service | grep -E \"Active:|running\"'"

echo ""
echo "=== 飞书 WebSocket ==="
ssh $SSH_OPTS root@$HOST "$SHELL_CMD 'tail -10 /tmp/openclaw/openclaw-\$(date +%Y-%m-%d).log | grep \"ws client ready\"'"

echo ""
echo "=== npm 源 ==="
ssh $SSH_OPTS root@$HOST "$SHELL_CMD 'npm config get registry'"
