#!/bin/bash
# openclaw-remote-install - 远程机器 OpenClaw 安装/修复脚本
# 用法: ./install.sh <HOST> [SSH_KEY] [VERSION] [WITH_QMD]
# 示例: ./install.sh 119.27.181.8 ~/.ssh/id_rsa_tnt latest
# 示例(含QMD): ./install.sh 119.27.181.8 ~/.ssh/id_rsa_tnt latest qmd
# 注意：飞书插件扫码需安装完成后单独运行（见最后说明）

set -e

HOST="${1:?用法: $0 <HOST> [SSH_KEY] [VERSION] [WITH_QMD]}"
SSH_KEY="${2:-$HOME/.ssh/id_rsa_tnt}"
VERSION="${3:-latest}"
WITH_QMD="${4:-}"
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
echo "QMD: ${WITH_QMD:+是}else 否"
echo "远程 Shell: $REMOTE_SHELL → $SHELL_CMD"
echo "总步骤: 9 步"
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

# 5. 安装 openclaw
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

# 7. 检测并设置 gateway.mode（全新环境必须，否则 gateway start 被拦截）
echo "[7/9] 检测并设置 gateway.mode..."
GW_MODE=$(ssh $SSH_OPTS root@$HOST "$SHELL_CMD 'openclaw config get gateway.mode 2>/dev/null'" 2>/dev/null || echo "")
if [[ -z "$GW_MODE" ]] || [[ "$GW_MODE" == "null" ]]; then
    echo "  gateway.mode 未设置，自动设为 local..."
    ssh $SSH_OPTS root@$HOST "$SHELL_CMD 'openclaw config set gateway.mode local' 2>&1 | grep -v "^Warning" | tail -1"
else
    echo "  gateway.mode 已为: $GW_MODE"
fi

# 8. QMD 安装与配置（可选）
echo "[8/9] QMD 安装与配置..."
if [[ "$WITH_QMD" == "qmd" ]]; then
    # 8.1 安装 bun（如未安装）
    BUN_VER=$(ssh $SSH_OPTS root@$HOST "$SHELL_CMD 'bun --version 2>/dev/null'" 2>/dev/null || echo "")
    if [[ -z "$BUN_VER" ]]; then
        echo "  安装 bun..."
        ssh $SSH_OPTS root@$HOST "$SHELL_CMD 'curl -fsSL https://bun.sh/install | bash && source ~/.bashrc && bun --version'"
    else
        echo "  bun $BUN_VER (跳过)"
    fi

    # 8.2 安装 QMD
    echo "  安装 QMD (@tobilu/qmd)..."
    ssh $SSH_OPTS root@$HOST "$SHELL_CMD 'bun install -g @tobilu/qmd 2>&1 | tail -5'"

    # 8.3 确认 qmd 在 PATH
    QMD_PATH=$(ssh $SSH_OPTS root@$HOST "$SHELL_CMD 'which qmd 2>/dev/null || echo not_found'" 2>/dev/null)
    if [[ "$QMD_PATH" == "not_found" ]]; then
        echo "  创建 qmd 符号链接到 /usr/local/bin..."
        ssh $SSH_OPTS root@$HOST "$SHELL_CMD 'ln -sf ~/.bun/bin/qmd /usr/local/bin/qmd && which qmd'"
    else
        echo "  qmd 路径: $QMD_PATH"
    fi

    # 8.4 配置 memory.backend = "qmd"
    echo "  配置 memory.backend = qmd..."
    ssh $SSH_OPTS root@$HOST "$SHELL_CMD 'openclaw config set memory.backend qmd 2>&1 | grep -v "^Warning" | tail -1'"
    echo "  QMD 配置完成"
else
    echo "  跳过（未指定 WITH_QMD=qmd）"
fi

# 9. Gateway 重启与验证
echo "[9/9] Gateway 重启与验证..."
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
if [[ "$WITH_QMD" == "qmd" ]]; then
    echo "QMD: 已安装 ($(ssh $SSH_OPTS root@$HOST "$SHELL_CMD 'qmd --version 2>/dev/null || bun x qmd --version'"))"
fi
echo ""
echo "=========================================="
echo "=== 飞书配置（需单独完成，2步）==="
echo "=========================================="
echo ""
echo "第一步 - 绑定飞书频道："
echo "  ssh root@$HOST"
echo "  openclaw onboard"
echo "  （选择飞书频道，按提示完成）"
echo ""
echo "第二步 - 安装飞书插件："
echo "  npx -y @larksuite/openclaw-lark install"
echo "  （用飞书 App 扫码授权）"
echo ""
echo "完成后飞书机器人即可使用。"
