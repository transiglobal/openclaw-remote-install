---
name: openclaw-remote-install
description: 在远程 Linux 机器上安装或修复 OpenClaw。处理以下复杂情况：(1) 用户指定版本或默认安装最新版；(2) 已安装则查版本，不一致时询问用户；(3) Node.js 版本低于 v22；(4) SSH 非交互式会话不加载 .bashrc 导致 pnpm 等环境缺失；(5) npm install 超时被 kill；(6) 可选安装 QMD 本地搜索增强（BM25+向量搜索+重排序）；(7) 完成后还原 npm 国际源。**飞书插件安装需用户在自己的设备上扫码，不在自动化步骤内**。触发场景：用户说「在xxx机器装 OpenClaw」「远程安装 OpenClaw」「升级 OpenClaw」「修复 OpenClaw」「装QMD」。
---

# openclaw-remote-install

远程 Linux 机器上的 OpenClaw 安装/修复技能，**完全非交互式**，稳定可靠。

## 核心原则：SSH 命令必须加载 shell 环境

SSH 非交互式会话**不会自动加载 `.bashrc`**（`.bash_profile` 也不会 source 它），导致：
- `pnpm` PATH 不在 `$PATH` 里
- `.bashrc` 里的 npm 配置、pnpm 初始化等全部失效
- **直接运行 `openclaw` 会报 `command not found`**

**解决方案**：所有 SSH 命令用 login shell 方式执行。

```bash
# ❌ 错误：非交互式，不会加载 .bashrc
ssh root@<HOST> 'openclaw --version'

# ✅ 正确：login shell，加载 .bashrc 或 .zshrc
ssh root@<HOST> 'bash -l -c "openclaw --version"'
```

## 流程概览

```
用户: 在xxx机器装OpenClaw
  ↓
① 版本确认（用户指定？默认最新版？）
  ↓
② QMD 确认（是否安装 QMD？）
  ↓
③ SSH 连接 + 环境检测
  ↓
④ 执行安装（全自动化，无任何交互提示）
  ↓
⑤ npm 源还原
  ↓
⑥ 验证 + 总结报告
  ↓
⑦ 飞书频道绑定：用户手动执行 openclaw onboard
  ↓
⑧ 飞书插件扫码：用户手动执行 npx @larksuite/openclaw-lark install
```

**步骤⑦⑧由用户在本地终端执行，不在 subagent 内完成。**

## 详细步骤

### ① 版本确认

询问用户：
- 是否指定版本？（未指定则安装最新版 `latest`）
- 目标机器 IP/域名

### ② QMD 确认

询问用户是否安装 QMD（本地搜索增强，支持 BM25+向量搜索+重排序）：
- 用户说「装 QMD」/「带 QMD」→ 安装 QMD
- 未提及 → 不安装 QMD，保持默认内置搜索

**QMD 功能说明**：
- 本地运行，无需 API Key
- 支持向量搜索 + 重排序，搜索质量更高
- 可索引 workspace 外的内容
- 首次搜索会自动下载 GGUF 模型（约 2GB）

### ③ SSH 连接 + 环境检测

```bash
# SSH 连接测试
ssh -i ~/.ssh/id_rsa_tnt -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@<HOST> 'echo "SSH OK"'

# 检测 Shell 类型
ssh root@<HOST> 'bash -l -c "echo $SHELL"'

# 检测 Node.js 版本
ssh root@<HOST> 'bash -l -c "node --version"'

# 检测现有 openclaw
ssh root@<HOST> 'bash -l -c "openclaw --version 2>/dev/null || echo NOT_INSTALLED"'
```

### ④ 已安装时版本对比与询问

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
```

### ⑤ 安装执行（全自动，无交互）

按顺序执行，全部自动化，无需用户输入。

```
步骤1: SSH 连接测试
步骤2: Node.js 版本检测（低于 v22 则自动升级）
步骤3: 设置 npm 国内镜像
步骤4: 安装/升级 openclaw
步骤5: gateway.mode 检测与设置（首次安装自动设置 local）
步骤6: 创建 .openclaw 必要目录
步骤7: QMD 安装与配置（如用户要求）← bun + @tobilu/qmd + memory.backend=qmd
步骤8: Gateway 重启
```

**所有步骤全自动执行，出错则汇报给用户。**

### ⑥ 完成后还原 npm 国内源

OpenClaw 安装/升级后可能将 npm 源改回国际源，必须还原：

```bash
ssh root@<HOST> 'bash -l -c "npm config set registry https://registry.npmmirror.com && npm config get registry"'
```

### ⑦ 最终验证与报告

```bash
# Gateway 状态
ssh root@<HOST> 'bash -l -c "systemctl --user status openclaw-gateway.service | grep -E '\''Active:|running'\''"'

# 版本确认
ssh root@<HOST> 'bash -l -c "openclaw --version"'

# npm 源确认
ssh root@<HOST> 'bash -l -c "npm config get registry"'
```

汇总报告：
- OpenClaw 版本
- Gateway 运行状态
- npm 源状态
- QMD 状态（如已安装）

### ⑧ 飞书频道绑定（用户手动执行）⭐

**`openclaw onboard` 必须在飞书扫码之前完成**，用于绑定飞书频道。

安装完成后，告知用户执行以下命令：

```bash
ssh root@<HOST>
openclaw onboard
```

按提示选择飞书频道类型，完成频道绑定。

### ⑨ 飞书插件安装（用户手动执行）⭐

绑定完频道后，扫码安装飞书插件：

```bash
npx -y @larksuite/openclaw-lark install
```

扫码完成后，继续配置四项优化（可选但推荐）：

```bash
openclaw config set channels.feishu.streaming true
openclaw config set channels.feishu.footer.elapsed true
openclaw config set channels.feishu.footer.status true
openclaw config set channels.feishu.threadSession true
openclaw gateway restart
```

**四项优化说明**：
- `streaming`：流式输出（打字机效果）
- `footer.elapsed`：显示回复耗时
- `footer.status`：显示处理状态
- `threadSession`：启用话题会话

**操作流程**：
1. SSH 登录到目标服务器
2. 运行 `npx -y @larksuite/openclaw-lark install`，用飞书 App 扫码
3. 扫码完成后，运行上述四项优化配置命令
4. Gateway 自动重启，飞书配置完成

## 典型场景处理

### 场景A：干净环境（无 Node.js）

```
→ 安装 Node.js 22 LTS
→ npm install -g openclaw
→ gateway.mode = local
→ （QMD 安装，如要求）
→ Gateway 重启
→ 验证
→ 告知用户手动跑飞书扫码
```

### 场景B：有 pnpm 残留，直接用 login shell 加载

```
→ 检测到 pnpm 存在
→ 用 bash -l -c 自动加载 .bashrc
→ 验证版本
→ 升级/安装 OpenClaw
→ （QMD 安装，如要求）
→ 验证
→ 告知用户手动跑飞书扫码
```

### 场景C：已安装同版本 OpenClaw

```
→ 对比版本号一致
→ 询问：覆盖 or 跳过
→ 用户选择后执行
```

### 场景D：安装完成，用户扫码

```
→ subagent 报告安装完成
→ 告知用户：在服务器上运行 npx @larksuite/openclaw-lark install
→ 用户 SSH 进服务器，跑命令，扫码
→ 飞书插件配置完成
```

### 场景E：安装时带 QMD

```
→ 用户明确要求「装 QMD」或「带 QMD」
→ 步骤7自动安装 bun（如未安装）
→ bun install -g @tobilu/qmd
→ openclaw config set memory.backend qmd
→ symlink qmd 到 /usr/local/bin
→ Gateway 重启
→ QMD 首次搜索会自动下载 GGUF 模型
```
