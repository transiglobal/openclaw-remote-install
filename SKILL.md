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

### ④ 飞书机器人配置询问（不可跳过）

在开始安装前，**必须询问用户**（不可跳过）：

```
目标机器 OpenClaw 的飞书机器人配置：
请选择：
  1. 创建新的飞书机器人（将引导创建流程）
  2. 使用已有的机器人配置（需要提供 appId 和 appSecret）
```

**选择 1（新建机器人）**：引导用户在飞书开放平台创建应用，获取 appId/appSecret。

**选择 2（使用已有）**：要求用户提供 `appId` 和 `appSecret`。

> ⚠️ 禁止跳过此步骤。飞书插件和配置是安装流程的必要组成部分。

### ⑤ 安装执行（subagent + 实时监控）

通过 `sessions_spawn` 启动 subagent 执行安装，**分步执行 + 实时监控**，特别是在飞书插件安装步骤。

#### subagent 任务内容（全部使用 login shell）

subagent 按以下顺序分步执行，**每步完成后立即汇报**（不等全部跑完）：

```
步骤1: SSH 连接测试
步骤2: Node.js 版本检测
步骤3: 设置 npm 国内镜像
步骤4: 安装/升级 openclaw
步骤5: gateway.mode 检测与设置
步骤6: 配置飞书（appId/appSecret）
步骤7: 安装飞书插件 ← 关键步骤，需要 PTY
步骤8: 飞书优化配置
步骤9: Gateway 重启
步骤10: 还原 npm 源
步骤11: 最终验证
```

**关键：步骤7（飞书插件安装）必须用 PTY 执行**

飞书插件 `npx -y @larksuite/openclaw-lark install` 运行时会弹出交互询问：
- 扫码授权（显示 QR code URL 或图片）
- 命令行交互提示（选择机器人、确认操作等）

**PTY 执行方式**（使用 `exec` 的 `pty: true` 参数）：

```javascript
// 安装飞书插件（PTY 模式，实时捕获交互提示）
exec({
  command: `ssh -tt -i $SSH_KEY -o StrictHostKeyChecking=no root@$HOST '$SHELL_CMD "npx -y @larksuite/openclaw-lark install 2>&1"'`,
  pty: true,
  timeout: 300,
  yieldMs: 280000  // 4分46秒后强制结束 SSH
})
```

`-tt` 强制分配 PTY，确保插件的交互提示能实时回传。

#### 实时监控机制（替代 30s 轮询）

**主线程在启动 subagent 后，每 10s 检查一次 subagent 输出**：

```bash
sessions_history <subagent_session_key> --limit 3 --includeTools false
```

**检测到以下关键词时，立即将提示转发给用户**：
- "scan" / "QR" / "qrcode" / "扫码"
- "auth" / "authorize" / "授权"
- "press enter" / "press any key" / "按任意键"
- "password"（飞书相关）
- "select" / "choose"（选择提示）
- emoji QR code 图片（直接转发给用户）

**转发格式**：
```
🔔 飞书插件安装需要您的操作：
[插件输出的完整提示]
请扫描上方二维码，或回复您的选择
```

**等待用户回复后**，通过 `sessions_send` 继续 subagent，或手动执行后续步骤。

#### 非交互场景（如已配置 appId/appSecret）

如果飞书插件安装时**没有弹出任何交互提示**（已配置机器人信息），则自动继续下一步，无需用户介入。

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
