#!/bin/bash
# device-pair.sh - OpenClaw 节点配对脚本（已合并到 install.sh，建议直接使用 install.sh）
#
# ⚠️ 已废弃：此脚本的功能已整合到 install.sh 第 11 步
#   直接运行 install.sh 即可完成 TUI 设备配对，无需单独运行此脚本
#
# 仅在需要手动调试时使用：
# 用法: ./device-pair.sh <HOST> [SSH_KEY]

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

OPENCLAW="bash -c 'PATH=\"/root/.nvm/versions/node/v22.22.2/bin:\$PATH\" openclaw'"

echo "=== OpenClaw 节点配对 ==="
echo "目标: $HOST"
echo ""

# 1. 在远程服务器后台启动 node run，生成配对请求
echo "[1/3] 启动 node run 生成配对请求..."
ssh $SSH_OPTS root@$HOST "$SHELL_CMD 'pkill -f \"openclaw node run\" 2>/dev/null || true; nohup sh -c \"PATH=/root/.nvm/versions/node/v22.22.2/bin:\$PATH openclaw node run --host 127.0.0.1 --port 25982 > /tmp/openclaw-node-pair.log 2>&1\" &'"
sleep 3

# 2. 获取 pending requestId（从 openclaw devices list）
echo "[2/3] 获取配对请求..."
PENDING_JSON=$(ssh $SSH_OPTS root@$HOST "$OPENCLAW devices list --json 2>&1")
echo "$PENDING_JSON" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    pending = data.get('pending', [])
    if pending:
        req = pending[0]
        print('REQUEST_ID:', req.get('requestId', ''))
        print('DEVICE_ID:', req.get('deviceId', ''))
        print('PLATFORM:', req.get('platform', ''))
        print('CLIENT:', req.get('clientId', ''))
    else:
        print('NO_PENDING')
except Exception as e:
    print('PARSE_ERROR:', e)
    sys.exit(1)
" 2>/dev/null

REQUEST_ID=$(echo "$PENDING_JSON" | python3 -c "
import json, sys
data = json.load(sys.stdin)
pending = data.get('pending', [])
if pending:
    print(pending[0].get('requestId', ''))
" 2>/dev/null)

if [[ -z "$REQUEST_ID" ]]; then
    echo "  ❌ 没有待处理的配对请求"
    echo ""
    echo "  node run 日志："
    ssh $SSH_OPTS root@$HOST "cat /tmp/openclaw-node-pair.log 2>/dev/null | tail -5"
    exit 1
fi

# 3. 批准配对请求
echo ""
echo "[3/3] 批准配对请求: $REQUEST_ID ..."
APPROVE_RESULT=$(ssh $SSH_OPTS root@$HOST "$OPENCLAW devices approve $REQUEST_ID 2>&1")
echo "  $APPROVE_RESULT"

echo ""
echo "✅ 节点配对完成！"
echo ""
echo "节点信息："
ssh $SSH_OPTS root@$HOST "$OPENCLAW nodes status 2>&1 | head -10"
