#!/bin/bash
# openclaw-remote-install - 远程机器 OpenClaw 安装/修复脚本
# 用法: ./install.sh <HOST> [SSH_KEY] [VERSION] [FEISHU_APPID] [FEISHU_APPSECRET]
# 示例: ./install.sh 119.27.181.8 ~/.ssh/id_rsa_tnt latest
# 示例(含飞书): ./install.sh 119.27.181.8 ~/.ssh/id_rsa_tnt latest cli_xxx secret_xxx

set -e

HOST="${1:?用法: $0 <HOST> [SSH_KEY] [VERSION] [FEISHU_APPID] [FEISHU_APPSECRET]}"
SSH_KEY="${2:-$HOME/.ssh/id_rsa_tnt}"
VERSION="${3:-latest}"
FEISHU_APPID="${4:-}"
FEISHU_APPSECRET="${5:-}"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"

# 检测远程 shell 类型，生成 login shell 命令
REMOTE_SHELL=$(ssh $SSH_OPTS root@$HOST 'echo $SHELL' 2>/dev/null | xargs basename || echo "bash")
if [[ "$REMOTE_SHELL" == "zsh" ]]; then
    SHELL_CMD="zsh -l -c"
else
    SHELL_CMD="bash -l -c"
fi

echo "=== OpenClaw 远程安装/修复 ==="
echo "目标: $HOST"
echo "版本: $VERSION"
echo "远程 Shell: $REMOTE_SHELL → $SHELL_CMD"
echo "飞书: ${FEISHU_APPID:+已配置}未配置"
echo "总步骤: 10 步"
echo ""

# 1. SSH 连接测试
echo "[1/9] SSH 连接测试..."
ssh $SSH_OPTS root@$HOST 'echo "SSH OK"' || { echo "SSH 失败"; exit 1; }

# 2. 检测现有安装
echo "[2/9] 检测现有安装..."
NODE_VER=$(ssh $SSH_OPTS root@$HOST "$SHELL_CMD 'node --version'")
OPENCLAW_VER=$(ssh $SSH_OPTS root@$HOST "$SHELL_CMD 'openclaw --version 2>/dev/null'" 2>/dev/null || echo "NOT_INSTALLED")

echo "  Node.js: $NODE_VER"
echo "  openclaw: ${OPENCLAW_VER:0:50}"

# 3. 设置 npm 国内镜像
echo "[3/9] 设置 npm 国内镜像..."
ssh $SSH_OPTS root@$HOST "$SHELL_CMD 'npm config set registry https://registry.npmmirror.com && npm config get registry'"

# 4. Node.js 升级（如需要）
if [[ "$NODE_VER" == "v18"* ]] || [[ "$NODE_VER" == *"not found"* ]]; then
    echo "[4/9] 升级/安装 Node.js v22..."
    ssh $SSH_OPTS root@$HOST "$SHELL_CMD 'curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && apt-get install -y nodejs && node --version'"
else
    echo "[4/9] Node.js $NODE_VER (跳过)"
fi

# 5. 安装 openclaw（login shell 自动加载 pnpm PATH）
echo "[5/9] 安装/验证 openclaw..."
if [[ "$OPENCLAW_VER" == "OpenClaw"* ]]; then
    echo "  已安装: $OPENCLAW_VER，跳过安装"
else
    echo "  用 npm 安装 openclaw@$VERSION ..."
    ssh $SSH_OPTS root@$HOST "$SHELL_CMD \"npm install -g openclaw@$VERSION 2>&1 | tail -10\""
fi

# 6. 验证 openclaw
echo "[6/9] 验证 openclaw..."
OPENCLAW_VER_FINAL=$(ssh $SSH_OPTS root@$HOST "$SHELL_CMD 'openclaw --version'")
echo "  版本: $OPENCLAW_VER_FINAL"

# 7. 飞书插件安装
echo "[7/9] 飞书插件安装..."
FEISHU_INSTALLED=$(ssh $SSH_OPTS root@$HOST "$SHELL_CMD 'openclaw plugins list 2>/dev/null | grep -c openclaw-lark'" || echo "0")
if [[ -n "$FEISHU_APPID" ]] && [[ -n "$FEISHU_APPSECRET" ]]; then
    echo "  配置 appId: $FEISHU_APPID"
    ssh $SSH_OPTS root@$HOST "$SHELL_CMD \"openclaw config set channels.feishu.appId $FEISHU_APPID\""
    ssh $SSH_OPTS root@$HOST "$SHELL_CMD \"openclaw config set channels.feishu.appSecret $FEISHU_APPSECRET\""
    ssh $SSH_OPTS root@$HOST "$SHELL_CMD \"openclaw config set channels.feishu.enabled true\""
    echo "  安装飞书插件..."
    ssh $SSH_OPTS root@$HOST "$SHELL_CMD 'npx -y @larksuite/openclaw-lark install 2>&1 | tail -5'"
elif [[ "$FEISHU_INSTALLED" -gt 0 ]]; then
    echo "  飞书插件已存在，跳过安装"
else
    echo "  跳过（未提供飞书配置，且无已有插件）"
fi

# 8. 飞书优化配置（仅在飞书插件已安装后才设置，否则报错 must_NOT_have_additional_properties）
echo "[8/9] 飞书优化配置..."
FEISHU_NOW_INSTALLED=$(ssh $SSH_OPTS root@$HOST "$SHELL_CMD 'openclaw plugins list 2>/dev/null | grep -c openclaw-lark'" || echo "0")
if [[ "$FEISHU_NOW_INSTALLED" -gt 0 ]] || [[ -n "$FEISHU_APPID" ]]; then
    ssh $SSH_OPTS root@$HOST "$SHELL_CMD 'openclaw config set channels.feishu.streaming true' 2>&1 | grep -v "^Warning" | tail -1"
    ssh $SSH_OPTS root@$HOST "$SHELL_CMD 'openclaw config set channels.feishu.footer.elapsed true' 2>&1 | grep -v "^Warning" | tail -1"
    ssh $SSH_OPTS root@$HOST "$SHELL_CMD 'openclaw config set channels.feishu.footer.status true' 2>&1 | grep -v "^Warning" | tail -1"
    ssh $SSH_OPTS root@$HOST "$SHELL_CMD 'openclaw config set channels.feishu.threadSession true' 2>&1 | grep -v "^Warning" | tail -1"
else
    echo "  跳过（飞书插件未安装）"
fi

# 9. 检测并设置 gateway.mode（全新环境必须，否则 gateway start 被拦截）
echo "[9/10] 检测并设置 gateway.mode..."
GW_MODE=$(ssh $SSH_OPTS root@$HOST "$SHELL_CMD 'openclaw config get gateway.mode 2>/dev/null'" 2>/dev/null || echo "")
if [[ -z "$GW_MODE" ]] || [[ "$GW_MODE" == "null" ]]; then
    echo "  gateway.mode 未设置，自动设为 local..."
    ssh $SSH_OPTS root@$HOST "$SHELL_CMD 'openclaw config set gateway.mode local' 2>&1 | grep -v "^Warning" | tail -1"
else
    echo "  gateway.mode 已为: $GW_MODE"
fi

# 10. Gateway 重启与验证
echo "[10/10] Gateway 重启与验证..."
ssh $SSH_OPTS root@$HOST "$SHELL_CMD 'openclaw gateway restart' 2>&1 | tail -3"
sleep 8
GW_STATUS=$(ssh $SSH_OPTS root@$HOST "$SHELL_CMD 'openclaw gateway status 2>&1 | grep -E \"RPC probe.*ok|Runtime.*running\"" 2>/dev/null | head -1 || echo "检查失败")
WS_STATUS=$(ssh $SSH_OPTS root@$HOST "$SHELL_CMD 'tail -10 /tmp/openclaw/openclaw-\$(date +%Y-%m-%d).log | grep '\''ws client ready'\''" 2>/dev/null || echo "未就绪")
echo "  Gateway: $GW_STATUS"
echo "  WebSocket: $WS_STATUS"

# 完成后还原 npm 国内源
echo ""
echo "=== 还原 npm 国内源 ==="
ssh $SSH_OPTS root@$HOST "$SHELL_CMD 'npm config set registry https://registry.npmmirror.com && npm config get registry'"

echo ""
echo "=== 安装完成 ==="
echo "OpenClaw: $(ssh $SSH_OPTS root@$HOST "$SHELL_CMD 'openclaw --version'")"
echo "Gateway: $GW_STATUS"
echo "WebSocket: ${WS_STATUS:+OK}"
