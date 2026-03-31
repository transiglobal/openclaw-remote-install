---
name: openclaw-remote-install
description: 在远程 Linux 机器上安装或修复 OpenClaw。处理以下复杂情况：(1) 用户指定版本或默认安装最新版；(2) 已安装则查版本，不一致时询问用户；(3) Node.js 版本低于 v22；(4) SSH 非交互式会话不加载 .bashrc 导致 pnpm 等环境缺失；(5) npm install 超时被 kill；(6) 飞书插件安装需交互（扫码/选择机器人）；(7) 完成后还原 npm 国际源。触发场景：用户说「在xxx机器上安装 OpenClaw」「远程安装 OpenClaw」「升级 OpenClaw」「修复 OpenClaw」。
---

# openclaw-remote-install

远程 Linux 机器上的 OpenClaw 安装/修复技能，完整流程带用户交互确认。

## 核心原则：SSH 命令必须加载 shell 环境

SSH 非交互式会话**不会自动加载 `.bashrc`**（`.bash_profile` 也不会 source 它），导致：
- `pnpm` PATH 不在 `$PATH` 里
- `.bashrc` 里的 npm 配置、pnpm 初始化、openclaw completion 等全部失效
- **直接运行 `openclaw` 会报 `command not found`**

**解决方案**：所有 SSH 命令用 login shell 方式执行，确保加载完整环境。

```bash
# ❌ 错误：非交互式，不会加载 .bashrc
ssh root@<HOST> 'openclaw --version'

# ✅ 正确：login shell，加载 .bashrc 或 .zshrc
ssh root@<HOST> 'bash -l -c "openclaw --version"'

# ✅ 通用写法（bash/zsh 兼容）
ssh root@<HOST> 'bash -l -c "source ~/.bashrc && openclaw --version"'
```

## 流程概览

```
用户: 在xxx机器装OpenClaw
  ↓
① 版本确认（用户指定？默认最新版？）
  ↓
② SSH连接 + 环境检测（login shell）
  ↓
③ 已安装？版本对比 → 不一致则询问用户
  ↓
④ 询问用户：创建新飞书机器人还是用已有的？
  ↓
⑤ 执行安装（全流程通过 subagent + 30s 轮询）
  ↓
⑥ 完成后还原 npm 国内源
  ↓
⑦ 验证 + 总结报告
```

## 详细步骤

### ① 版本确认

询问用户：
- 是否指定版本？（未指定则安装最新版 `latest`）
- 目标机器 IP/域名

### ② SSH 连接 + 环境检测（login shell 方式）

```bash
# SSH 连接测试
ssh -i ~/.ssh/id_rsa_tnt -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@<HOST> 'echo "SSH OK"'

# 检测 Shell 类型（bash / zsh）
ssh root@<HOST> 'bash -l -c "echo $SHELL"'

# 检测 Node.js 版本（login shell）
ssh root@<HOST> 'bash -l -c "node --version"'

# 检测现有 openclaw（login shell，自动加载 .bashrc 中的 pnpm PATH）
ssh root@<HOST> 'bash -l -c "openclaw --version 2>/dev/null || echo NOT_INSTALLED"'

# 如果 openclaw not found，检查 pnpm 是否在 .bashrc 中初始化
ssh root@<HOST> 'bash -l -c "which openclaw 2>/dev/null || echo not_found"'
```

### ③ 已安装时版本对比与询问

如果目标机器已有 OpenClaw：
- 提取现有版本号
- 与用户要求版本对比
- **版本一致**：询问是否覆盖安装或跳过
- **版本不一致**：询问是否升级

询问话术：
```
目标机器已安装 OpenClaw <现有版本>
您要求安装 <用户指定版本/最新版>
请选择：
  1. 覆盖安装（升级/重装）
  2. 保留现有版本，跳过安装
  3. 仅更新飞书插件
```

### ④ 飞书机器人配置询问

在开始安装前，必须询问用户：

```
目标机器 OpenClaw 的飞书机器人配置：
请选择：
  1. 创建新的飞书机器人（将引导创建流程）
  2. 使用已有的机器人配置（需要提供 appId 和 appSecret）
  3. 先跳过飞书配置，后续再配置
```

**选择 1（新建机器人）**：引导用户在飞书开放平台创建应用，获取 appId/appSecret。

**选择 2（使用已有）**：要求用户提供 `appId` 和 `appSecret`。

**选择 3**：跳过飞书配置，但安装后需要手动配置。

### ⑤ 安装执行（subagent + 30s 轮询）

通过 `sessions_spawn` 启动 subagent 执行安装，主线程每 30s 检查一次状态。

#### subagent 任务内容（全部使用 login shell）

```bash
# ============================================================
# 在远程机器 root@<HOST> 上执行（全部用 bash -l -c）
# ============================================================

# 0. 前置：确保使用 login shell
SHELL_CMD="bash -l -c"

# 1. 设置 npm 国内镜像（login shell，确保环境完整）
ssh root@<HOST> "$SHELL_CMD" 'npm config set registry https://registry.npmmirror.com && npm config get registry'

# 2. Node.js 升级（如需要，v18 → v22）
ssh root@<HOST> "$SHELL_CMD" 'curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && apt-get install -y nodejs && node --version'

# 3. 安装 openclaw（login shell，自动使用 .bashrc 中的 pnpm 环境）
# 方式A: npm 安装
ssh root@<HOST> "$SHELL_CMD" "npm install -g openclaw@$VERSION"
# 方式B: 如果已有 pnpm openclaw，验证版本即可
ssh root@<HOST> "$SHELL_CMD" 'openclaw --version'

# 4. 配置飞书（如用户提供 appId/appSecret）
if [ -n "$FEISHU_APPID" ]; then
    ssh root@<HOST> "$SHELL_CMD" "openclaw config set channels.feishu.appId $FEISHU_APPID"
    ssh root@<HOST> "$SHELL_CMD" "openclaw config set channels.feishu.appSecret $FEISHU_APPSECRET"
    ssh root@<HOST> "$SHELL_CMD" "openclaw config set channels.feishu.enabled true"
fi

# 5. 安装/更新飞书插件
ssh root@<HOST> "$SHELL_CMD" 'npx -y @larksuite/openclaw-lark install'
# 或更新：ssh root@<HOST> "$SHELL_CMD" 'npx -y @larksuite/openclaw-lark update'

# 6. 飞书优化配置
ssh root@<HOST> "$SHELL_CMD" 'openclaw config set channels.feishu.streaming true'
ssh root@<HOST> "$SHELL_CMD" 'openclaw config set channels.feishu.footer.elapsed true'
ssh root@<HOST> "$SHELL_CMD" 'openclaw config set channels.feishu.footer.status true'
ssh root@<HOST> "$SHELL_CMD" 'openclaw config set channels.feishu.threadSession true'

# 7. 重启 gateway
ssh root@<HOST> "$SHELL_CMD" 'openclaw gateway restart'
sleep 8

# 8. 验证
ssh root@<HOST> "$SHELL_CMD" 'openclaw gateway status'
ssh root@<HOST> "$SHELL_CMD" 'tail -20 /tmp/openclaw/openclaw-$(date +%Y-%m-%d).log | grep -E "ws client ready|feishu|error"'
```

#### Shell 检测（自动适配 bash/zsh）

```bash
# 检测远程机器的默认 shell
REMOTE_SHELL=$(ssh root@<HOST> 'echo $SHELL' | xargs basename)
echo "Remote shell: $REMOTE_SHELL"

if [[ "$REMOTE_SHELL" == "zsh" ]]; then
    SHELL_CMD="zsh -l -c"
else
    SHELL_CMD="bash -l -c"
fi
```

#### 30s 轮询监控

主线程在启动 subagent 后，每 30s 查询一次状态：

```bash
sessions_history <subagent_session_key> --limit 5 --includeTools false
```

**检测到用户交互提示**：立即停止轮询，将完整提示返回给用户，等待用户操作后继续。

**检测到 subagent 完成**：进入下一步。

**检测到错误/中断**：尝试修复或重新启动 subagent。

#### 飞书插件安装的交互处理

飞书插件 `npx -y @larksuite/openclaw-lark install` 可能会触发：
- **QR 码扫码授权**：将二维码图片或 URL 返回给用户
- **命令行交互提示**：停止轮询，完整返回提示内容

当 subagent 输出包含 "scan" / "QR" / "扫码" / "auth" / "password" 等关键词时：
→ 立即返回给用户，等待扫码或确认后继续

### ⑥ 完成后还原 npm 国内源

OpenClaw 安装/升级后可能将 npm 源改回国际源，必须还原：

```bash
ssh root@<HOST> 'bash -l -c "npm config set registry https://registry.npmmirror.com && npm config get registry"'
```

### ⑦ 最终验证与报告

```bash
# Gateway 状态
ssh root@<HOST> 'bash -l -c "systemctl --user status openclaw-gateway.service | grep -E '\''Active:|running'\''"'

# 飞书 WebSocket
ssh root@<HOST> 'bash -l -c "tail -10 /tmp/openclaw/openclaw-\$(date +%Y-%m-%d).log | grep '\''ws client ready'\''"'

# 版本确认
ssh root@<HOST> 'bash -l -c "openclaw --version"'

# 飞书插件
ssh root@<HOST> 'bash -l -c "openclaw plugins list | grep openclaw-lark"'

# npm 源确认
ssh root@<HOST> 'bash -l -c "npm config get registry"'
```

汇总报告：
- OpenClaw 版本
- 飞书插件状态
- Gateway 运行状态
- 飞书连接状态
- npm 源状态

## 典型场景处理

### 场景A：干净环境（无 Node.js）

```
→ 安装 Node.js 22 LTS
→ npm install -g openclaw（login shell）
→ 安装飞书插件（交互）
→ 配置飞书
→ 重启验证
```

### 场景B：有 pnpm 残留，直接用 login shell 加载

```
→ bash -l -c "openclaw --version"  # 自动用 .bashrc 中的 pnpm PATH
→ 更新飞书插件
→ 配置
→ 重启验证
```

### 场景C：Node.js 版本不足（v18）

```
→ 升级 Node.js 到 v22
→ login shell 验证 openclaw
→ 更新飞书插件
→ 配置
→ 重启验证
```

### 场景D：npm install 超时被 kill

```
→ 改用 npm cache clean + retry
→ 或分步安装（先装小依赖，再装 openclaw）
→ 或改用 pnpm：bash -l -c "pnpm add -g openclaw"
```

## 关键路径速查

| 远程机器 SSH | `root@<HOST>`，密钥 `~/.ssh/id_rsa_tnt` |
| SSH 命令格式 | `bash -l -c "命令"`（自动加载 .bashrc）|
| zsh 机器 | `zsh -l -c "命令"` |
| openclaw 配置 | `/root/.openclaw/openclaw.json` |
| openclaw 日志 | `/tmp/openclaw/openclaw-YYYY-MM-DD.log` |
| Gateway 服务 | `systemctl --user status openclaw-gateway.service` |
