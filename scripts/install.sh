#!/bin/bash
# openclaw-remote-install - 远程机器 OpenClaw 安装/修复脚本
# 用法: ./install.sh <HOST> [SSH_KEY] [VERSION]
# 示例: ./install.sh 119.27.181.8 ~/.ssh/id_rsa_tnt latest

set -e

HOST="${1:?用法: $0 <HOST> [SSH_KEY] [VERSION]}"
SSH_KEY="${2:-$HOME/.ssh/id_rsa_tnt}"
VERSION="${3:-latest}"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"

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
echo ""

# 1. SSH 连接测试
echo "[1/11] SSH 连接测试..."
ssh $SSH_OPTS root@$HOST 'echo "SSH OK"' || { echo "SSH 失败"; exit 1; }

# 2. 检测现有安装
echo "[2/11] 检测现有安装..."
NODE_VER=$(ssh $SSH_OPTS root@$HOST "$SHELL_CMD 'node --version'")
OPENCLAW_VER=$(ssh $SSH_OPTS root@$HOST "$SHELL_CMD 'openclaw --version 2>/dev/null'" 2>/dev/null || echo "NOT_INSTALLED")

echo "  Node.js: $NODE_VER"
echo "  openclaw: ${OPENCLAW_VER:0:50}"

# 3. 检查并切换 npm 国内镜像
echo "[3/11] 检查并切换 npm 国内镜像..."
_CURRENT_REG=$(ssh $SSH_OPTS root@$HOST "$SHELL_CMD 'npm config get registry 2>/dev/null'" 2>/dev/null | xargs || echo "")
if [[ -n "$_CURRENT_REG" ]] && echo "$_CURRENT_REG" | grep -qE "npmmirror|tencent|cnpm|aliyun|huawei"; then
    echo "  ✅ npm 源已是国内镜像: $_CURRENT_REG"
else
    if [[ -n "$_CURRENT_REG" ]]; then
        echo "  ⚠️  当前 npm 源非国内镜像: $_CURRENT_REG"
    else
        echo "  ⚠️  无法获取当前 npm 源"
    fi
    echo "  → 切换为 https://registry.npmmirror.com ..."
    ssh $SSH_OPTS root@$HOST "$SHELL_CMD 'npm config set registry https://registry.npmmirror.com'"
    _NEW_REG=$(ssh $SSH_OPTS root@$HOST "$SHELL_CMD 'npm config get registry 2>/dev/null'" 2>/dev/null | xargs || echo "")
    echo "  ✅ 已切换为: $_NEW_REG"
fi

# 4. Node.js 版本检查与升级
NODE_MAJOR=$(echo "$NODE_VER" | sed 's/v\([0-9]*\)\..*/\1/' | tr -d 'v')
NODE_MINOR=$(echo "$NODE_VER" | sed 's/v[0-9]*\.\([0-9]*\)\..*/\1/')
if [[ -z "$NODE_VER" ]] || [[ "$NODE_VER" == *"not found"* ]]; then
    echo "[4/11] Node.js 未安装，安装 Node.js v22..."
    ssh $SSH_OPTS root@$HOST "$SHELL_CMD 'curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && apt-get install -y nodejs && node --version'"
elif [[ "$NODE_MAJOR" -lt 22 ]]; then
    echo "[4/11] Node.js $NODE_VER 太旧，升级到 v22..."
    ssh $SSH_OPTS root@$HOST "$SHELL_CMD 'curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && apt-get install -y nodejs && node --version'"
elif [[ "$NODE_MAJOR" -eq 22 ]] && [[ "$NODE_MINOR" -lt 14 ]]; then
    echo "[4/11] Node.js $NODE_VER 版本过低（需 >= 22.14），升级..."
    ssh $SSH_OPTS root@$HOST "$SHELL_CMD 'curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && apt-get install -y nodejs && node --version'"
else
    echo "[4/11] Node.js $NODE_VER 已符合要求（>= 22.14），跳过"
fi

# 5. 安装 openclaw
echo "[5/11] 安装/验证 openclaw..."
if [[ "$OPENCLAW_VER" == "OpenClaw"* ]]; then
    echo "  已安装: $OPENCLAW_VER，跳过安装"
else
    echo "  用 npm 安装 openclaw@$VERSION ..."
    ssh $SSH_OPTS root@$HOST "$SHELL_CMD \"npm install -g openclaw@$VERSION 2>&1 | tail -10\""
fi

# 6. 验证 openclaw
echo "[6/11] 验证 openclaw..."
OPENCLAW_VER_FINAL=$(ssh $SSH_OPTS root@$HOST "$SHELL_CMD 'openclaw --version'")
echo "  版本: $OPENCLAW_VER_FINAL"

# 7. gateway.mode 检测与设置
echo "[7/11] 检测并设置 gateway.mode..."
GW_MODE=$(ssh $SSH_OPTS root@$HOST "$SHELL_CMD 'openclaw config get gateway.mode 2>/dev/null'" 2>/dev/null || echo "")
if [[ -z "$GW_MODE" ]] || [[ "$GW_MODE" == "null" ]]; then
    echo "  gateway.mode 未设置，自动设为 local..."
    ssh $SSH_OPTS root@$HOST "$SHELL_CMD 'openclaw config set gateway.mode local 2>&1 | grep -v \"^Warning\" | tail -1'"
else
    echo "  gateway.mode 已为: $GW_MODE"
fi

# 8. QMD 安装与配置（必选）
echo "[8/11] QMD 安装与配置..."
# 8.1 安装 bun
BUN_VER=$(ssh $SSH_OPTS root@$HOST "$SHELL_CMD 'bun --version 2>/dev/null'" 2>/dev/null || echo "")
if [[ -z "$BUN_VER" ]]; then
    echo "  安装 bun..."
    ssh $SSH_OPTS root@$HOST "$SHELL_CMD 'curl -fsSL https://bun.sh/install | bash 2>&1 | tail -5'"
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
ssh $SSH_OPTS root@$HOST "$SHELL_CMD 'openclaw config set memory.backend qmd 2>&1 | grep -v \"^Warning\" | tail -1'"
echo "  QMD 配置完成"

# 9. Gateway 安装与启动
echo "[9/11] Gateway 安装与启动..."
ssh $SSH_OPTS root@$HOST "$SHELL_CMD 'openclaw gateway install 2>&1 | tail -5'"
ssh $SSH_OPTS root@$HOST "$SHELL_CMD 'systemctl --user start openclaw-gateway.service && sleep 5'"
sleep 3
GW_STATUS=$(ssh $SSH_OPTS root@$HOST "$SHELL_CMD 'systemctl --user status openclaw-gateway.service 2>&1 | grep -E \"Active:.*running\"" 2>/dev/null || echo "检查失败")
echo "  Gateway: $GW_STATUS"

# 10. Doctor 修复（修复 systemd service path 等问题）
echo "[10/11] Doctor 修复..."
ssh $SSH_OPTS root@$HOST "$SHELL_CMD 'openclaw doctor --fix 2>&1 | tail -5'"
echo "  Doctor 修复完成"


# 11. TUI 设备配对（V2026.03.31+ 必需）
echo "[11/11] TUI 设备配对..."

# 动态获取远程机器的 Node 路径（兼容 nvm/fnm/nodesource/brew 等各种安装方式）
NODE_BIN_DIR=$(ssh $SSH_OPTS root@$HOST "$SHELL_CMD 'dirname \$(which node)'" 2>/dev/null | xargs)
if [[ -z "$NODE_BIN_DIR" || "$NODE_BIN_DIR" == *"not found"* || "$NODE_BIN_DIR" == *"which: no"* ]]; then
    echo "  ⚠️ which node 失败，遍历常见路径..."
    NODE_BIN_DIR=""
    for candidate in /usr/local/bin /usr/bin; do
        if ssh $SSH_OPTS root@$HOST "test -x $candidate/node" 2>/dev/null; then
            NODE_BIN_DIR="$candidate"
            break
        fi
    done
    # nvm 路径（glob 展开）
    if [[ -z "$NODE_BIN_DIR" ]]; then
        NODE_BIN_DIR=$(ssh $SSH_OPTS root@$HOST "$SHELL_CMD 'ls -d ~/.nvm/versions/node/*/bin 2>/dev/null | head -1'" 2>/dev/null | xargs)
    fi
    # fnm 路径
    if [[ -z "$NODE_BIN_DIR" ]]; then
        NODE_BIN_DIR=$(ssh $SSH_OPTS root@$HOST "$SHELL_CMD 'ls -d ~/.fnm/node-versions/*/installation/bin 2>/dev/null | head -1'" 2>/dev/null | xargs)
    fi
fi

if [[ -z "$NODE_BIN_DIR" ]]; then
    echo "  ❌ 无法确定 Node.js 路径，跳过 TUI 配对"
    echo "  请手动执行: openclaw devices list && openclaw devices approve <requestId>"
else
    echo "  Node.js 路径: $NODE_BIN_DIR"
    echo "  启动 openclaw tui 生成配对请求..."
    # 后台启动 tui，发送一条消息后退出，触发配对请求
    ssh $SSH_OPTS root@$HOST "$SHELL_CMD 'TOKEN=\$(openclaw config get gateway.auth.token 2>/dev/null | tr -d \"\\n\"); nohup sh -c \"PATH=${NODE_BIN_DIR}:\\\$PATH openclaw tui --url ws://127.0.0.1:25982 --token \\$TOKEN --thinking off --message ping --deliver > /tmp/openclaw-tui-pair.log 2>&1\" &'"
    sleep 5
    # 获取 pending requestId
    PENDING_JSON=$(ssh $SSH_OPTS root@$HOST "$SHELL_CMD 'PATH=${NODE_BIN_DIR}:\$PATH openclaw devices list --json 2>&1'" 2>/dev/null)
    REQUEST_ID=$(echo "$PENDING_JSON" | python3 -c "
import json, sys
data = json.load(sys.stdin)
pending = data.get('pending', [])
if pending:
    print(pending[0].get('requestId', ''))
" 2>/dev/null)
    if [[ -n "$REQUEST_ID" ]]; then
        echo "  配对请求: $REQUEST_ID"
        APPROVE_RESULT=$(ssh $SSH_OPTS root@$HOST "$SHELL_CMD 'PATH=${NODE_BIN_DIR}:\$PATH openclaw devices approve $REQUEST_ID 2>&1'")
        echo "  批准结果: $APPROVE_RESULT"
        echo "  ✅ 设备配对完成"
    else
        echo "  ⚠️ 未发现待处理配对请求（可能已存在或无需配对）"
    fi
fi
# 完成后还原 npm 国内源
echo ""
echo "=== 还原 npm 国内源 ==="
ssh $SSH_OPTS root@$HOST "$SHELL_CMD 'npm config set registry https://registry.npmmirror.com && npm config get registry'"

echo ""
echo "=== 安装完成 ==="
echo "OpenClaw: $(ssh $SSH_OPTS root@$HOST "$SHELL_CMD 'openclaw --version'")"
echo "Gateway: $GW_STATUS"
echo "QMD: 已安装 ($(ssh $SSH_OPTS root@$HOST "$SHELL_CMD 'qmd --version 2>/dev/null || echo unknown'"))"
echo ""
echo "=========================================="
echo "=== 后续操作（2步，需人工）==="
echo "=========================================="
echo ""
echo "第一步 - 飞书频道绑定："
echo "  ssh root@$HOST"
echo "  openclaw onboard"
echo "  （选择飞书频道，按提示完成）"
echo ""
echo "第二步 - 安装飞书插件："
echo "  npx -y @larksuite/openclaw-lark install"
echo "  （用飞书 App 扫码授权）"
echo ""
echo "完成后告知我（零贰），我来执行 post-install.sh 完成飞书优化。"
echo ""
