---
name: openclaw-remote-install
description: 在远程 Linux 机器上安装、修复或升级 OpenClaw。支持远程安装（含 Node.js/飞书/QMD/bootstrap-skills 全自动）、远程升级（版本对比+Changelog 分析+Breaking Change 处理+回滚方案）、以及定时升级任务创建。触发场景：用户说「在xxx机器装 OpenClaw」「远程安装 OpenClaw」「升级 OpenClaw」「修复 OpenClaw」「远程升级」「定时升级」。
---

# openclaw-remote-install

远程 Linux 机器上的 OpenClaw 安装/修复/升级技能，**完全非交互式**，稳定可靠。

## 核心原则：SSH 命令必须加载 shell 环境

SSH 非交互式会话**不会自动加载 `.bashrc`**（`.bash_profile` 也不会 source 它），导致：
- `pnpm`/yarn/bun PATH 不在 `$PATH` 里
- `.bashrc` 里的 npm 配置、pnpm 初始化等全部失效
- **直接运行 `openclaw` 会报 `command not found`**

**升级方式**：使用 `openclaw update --yes` 进行升级（官方内置命令，自带 self-update 处理、Breaking Changes 检查、Gateway 重启）。无论目标环境之前用什么包管理器安装的 OpenClaw（npm/pnpm/yarn），`openclaw update` 都能正确处理，无需手动迁移包管理器。

**解决方案**：所有 SSH 命令用 login shell 方式执行。

```bash
# ❌ 错误：非交互式，不会加载 .bashrc
ssh root@<HOST> 'openclaw --version'

# ✅ 正确：login shell，加载 .bashrc 或 .zshrc
ssh root@<HOST> 'bash -l -c "openclaw --version"'
```

---

# 第一部分：远程安装 OpenClaw

## 安装流程概览

```
用户: 在xxx机器装OpenClaw
  ↓
① 版本确认（用户指定？默认最新版？）
  ↓
② SSH 连接 + 环境检测
  ↓
③ 执行安装（全自动化，含 QMD + bootstrap-skills）
  ↓
④ npm 源检查与切换（确保为国内镜像）
  ↓
⑤ 完整验证（verify.sh，8大检查项）
  ↓
⑥ 飞书频道绑定：用户手动执行 openclaw onboard
  ↓
⑦ 飞书插件安装：用户手动执行 npx @larksuite/openclaw-lark install（过程中自动提示扫码）
  ↓
⑧ AI 执行 post-install.sh（飞书四项优化 + bootstrap-skills 同步）
  ↓
⑨ 验证飞书连接状态（再次运行 verify.sh 确认飞书 WebSocket ok）
```

**步骤⑥⑦由用户在服务器终端手动执行，不在 subagent 内完成。步骤⑦安装过程会自动弹出扫码提示，无需单独引导。**

## 安装详细步骤

### ① 版本确认

询问用户：
- 是否指定版本？（未指定则安装最新版 `latest`）
- 目标机器 IP/域名

### ② SSH 连接 + 环境检测

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
```

### ④ 安装执行（全自动，含 QMD）

`install.sh` 脚本全自动执行，共 11 步：

```
步骤1: SSH 连接测试
步骤2: Node.js 版本检测（低于 v22 则自动升级）
步骤3: 检查并切换 npm 国内镜像（检查当前源，非国内则切换）
步骤4: 安装/升级 openclaw
步骤5: 验证 openclaw 版本
步骤6: gateway.mode 检测与设置（首次安装自动设置 local）
步骤7: QMD 安装与配置（bun + @tobilu/qmd + memory.backend=qmd）← 必选
步骤8: Gateway 安装与启动
步骤9: 状态验证
步骤10: Doctor 修复（openclaw doctor --fix）
步骤11: TUI 设备配对
```

**所有步骤全自动执行，出错则汇报给用户。**

### ⑥ 完整验证（verify.sh）⭐

安装/升级后**必须**执行 `scripts/verify.sh` 做全面验证，包含 9 大检查项：

```
[1/9] SSH 连通性         → 目标可达
[2/9] 版本确认           → openclaw + node 版本
[3/9] Gateway 状态       → 进程 running + Dashboard HTTP 200
[4/9] openclaw doctor    → 运行 doctor 检查，提取 warnings/errors
[5/9] QMD 记忆后端       → qmd 版本 + memory.backend=qmd
[6/9] 飞书插件状态       → npx @larksuite/openclaw-lark doctor（如已配置飞书）
[7/9] 企微插件状态       → doctor确认 + 日志运行记录 + 错误检查（如已配置企微）
[8/9] 日志异常检测       → 当日日志 ERROR/FATAL 计数和摘要
[9/9] npm 源 + 磁盘      → 国内镜像 + 磁盘空间
```

**飞书检查**：运行 `npx @larksuite/openclaw-lark doctor`，检查返回结果是否有 error/异常/未连接。

**企微检查**（无专用 doctor 命令，组合判断）：
1. `openclaw doctor` 输出是否包含 `企业微信: ok` 或 `configured`
2. 当日日志中是否包含企微运行成功记录（`setWeixinRuntime successfully`）
3. 当日日志中企微相关 ERROR/FATAL 数量

**日志异常检测**：用 python3 解析当日 JSON 格式日志，归纳所有 WARN/ERROR/FATAL：
- **判定逻辑**：FATAL→❌（重大问题）| ERROR→⚠️（需关注）| WARN→✅（仅记录，不影响判定）
- **归纳报告**：每类异常按频次降序排列，去重显示 top 20，附带出现次数（如 `[662x] 消息内容`）
- 报告在验证汇总后单独输出，方便用户快速定位问题

**执行方式**：
```bash
scripts/verify.sh root@<HOST> ~/.ssh/id_rsa_tnt
```

**验证报告示例**：
```
══════════════════════════════════════════
  OpenClaw 远程验证: root@43.134.173.17
══════════════════════════════════════════

  ✅ | SSH 连接        | 可达
  ✅ | OpenClaw 版本   | OpenClaw 2026.4.9
  ✅ | Node.js         | v22.22.2
  ✅ | Gateway 进程     | running
  ✅ | Dashboard       | HTTP 200
  ✅ | Doctor 检查     | 无严重问题
  ✅ | QMD 版本        | 1.2.0
  ✅ | memory.backend  | qmd
  ✅ | 飞书 doctor     | 正常
  ✅ | 企微插件        | doctor确认 + 日志正常
  ✅ | 企微 corpId     | 已配置
  ✅ | 日志异常        | 无 ERROR/FATAL
  ✅ | npm 源          | https://registry.npmmirror.com
  ✅ | 磁盘使用率      | 35%

  总计: 14 项 | ✅ 13  ⚠️ 0  ❌ 0
  🟢 全部通过
```

**结果判定**：
- 🟢 全部通过 → 安装/升级成功
- 🟡 有警告 → 可用但建议检查
- 🔴 有失败 → 必须处理后再继续

**异常处理**：
- doctor 有 warning → 先尝试 `openclaw doctor --fix` 自动修复，再跑验证
- Gateway 未运行 → 重启 Gateway 再验证
- 飞书 doctor 异常 → 检查插件配置和 token，可能需重新 `npx @larksuite/openclaw-lark install`
- 企微异常 → 检查 botId/secret 配置，查看日志具体错误
- 日志有 FATAL → 输出详细归纳报告（去重+频次），评估是否需要回滚
- 日志有 ERROR → 输出归纳报告供参考，不影响整体可用性判定
- 日志有 WARN → 记录在报告中，不判定为异常

### ⑦ 飞书插件安装（用户手动执行）⭐

安装完成后，SSH 进服务器，直接运行安装命令（**过程中会自动提示扫码**）：

```bash
ssh root@<HOST>
npx -y @larksuite/openclaw-lark install
```

按照提示用飞书 App 扫码授权，完成后告知 AI（零贰）。

> ⚠️ `openclaw onboard` 需在此步骤之前完成（步骤⑥）。

### ⑧ AI 执行 post-install.sh（飞书优化 + bootstrap-skills）⭐

用户扫码完成后，AI 自动执行 `post-install.sh`，包含：

1. **飞书四项优化配置**：
   - `channels.feishu.streaming = true`
   - `channels.feishu.footer.elapsed = true`
   - `channels.feishu.footer.status = true`
   - `channels.feishu.threadSession = true`

2. **Gateway 重启 + 状态验证**

3. **bootstrap-skills 同步**：
   - 添加 `https://eeffa2cab255f9034e033c929f58488f799e5b3e@git.moguyn.cn/transiglobal/bootstrap-skills.git` remote（如未添加）
   - `git submodule update --init skills/bootstrap-skills`

## 安装典型场景

### 场景A：干净环境（无 Node.js）

```
→ 安装 Node.js 22 LTS
→ npm install -g openclaw
→ gateway.mode = local
→ QMD 自动安装（bun + @tobilu/qmd + memory.backend=qmd）
→ Gateway 安装 + 启动
→ 验证
→ 告知用户：SSH 进服务器，先跑 openclaw onboard，再跑 npx @larksuite/openclaw-lark install（过程自动提示扫码）
→ 用户扫码完成后告知 AI
→ AI 执行 post-install.sh
```

### 场景B：有 pnpm/yarn 安装的旧版本，openclaw update 自动处理

```
→ 检测到已有 OpenClaw（无论用 pnpm/npm/yarn 安装）
→ 直接使用 openclaw update --yes 升级
→ openclaw update 自动处理包管理器差异
→ 验证通过
→ 告知用户：SSH 进服务器，先跑 openclaw onboard，再跑 npx @larksuite/openclaw-lark install（过程自动提示扫码）
→ 用户扫码完成后告知 AI
→ AI 执行 post-install.sh
```

### 场景C：已安装同版本 OpenClaw

```
→ 对比版本号一致
→ 询问：覆盖 or 跳过
→ 用户选择后执行
```

### 场景D：安装完成，引导用户完成飞书绑定

```
→ subagent 报告安装完成
→ 告知用户：
    步骤⑥ ssh root@HOST → openclaw onboard（选飞书频道类型）
    步骤⑦ npx -y @larksuite/openclaw-lark install（过程中自动提示扫码，扫一下就完成）
→ 用户扫码完成后告知 AI
→ AI 执行 post-install.sh
→ 飞书插件配置完成
```

### 场景E：全新机器，完整安装（含飞书 + QMD + bootstrap-skills）

```
→ 用户说：在 43.134.173.17 上装 OpenClaw
→ AI 确认版本、IP
→ subagent 执行 install.sh（全自动，含 QMD）
→ AI 汇报安装完成，告知用户：
    先跑 openclaw onboard，再跑 npx @larksuite/openclaw-lark install，扫码即完成
→ 用户扫码完成后告知 AI
→ AI 执行 post-install.sh（飞书四项优化 + bootstrap-skills 同步）
→ 全部完成
```

---

# 第二部分：远程升级 OpenClaw（含回滚）

当用户说「升级 OpenClaw」「远程升级」「定时升级」时触发此流程。

## 升级流程概览

```
用户: 在xxx机器上升级OpenClaw
  ↓
① 版本确认（当前版本 vs 最新版本/指定版本）
  ↓
② 获取变更日志（Changelog），特别关注 Breaking Changes
  ↓
③ Breaking Change 处理：需要用户确认则询问，否则自动生成处理步骤
  ↓
④ 规划回滚方案（备份当前版本+配置，生成回滚脚本）
  ↓
⑤ 执行升级（scripts/upgrade.sh）
  ↓
⑥ 重启 Gateway + 验证结果
  ↓
⑦ 汇总报告（含回滚信息）
  ↓
⑧ 建议定时升级任务（用户确认后创建）
```

## 升级详细步骤

### ① 版本确认与对比

```bash
# 获取当前版本
ssh $SSH_USER@$HOST 'bash -l -c "openclaw --version"'

# 获取最新版本（从 npm registry）
ssh $SSH_USER@$HOST 'bash -l -c "npm view openclaw version"'

# 或从 GitHub releases 获取
curl -s https://api.github.com/repos/openclaw/openclaw/releases/latest | grep -oP '"tag_name":\s*"\K[^"]+'
```

**版本对比逻辑**：
- 当前版本 == 最新版本 → 询问是否覆盖安装
- 当前版本 < 最新版本 → 执行升级
- 当前版本 > 最新版本 → 提示用户，确认是否降级
- 未安装 → 建议使用 install.sh 全新安装

### ② 获取变更日志（Changelog）

从 GitHub 获取变更日志：

```bash
# 从 GitHub releases API 获取（推荐，结构化数据）
curl -s https://api.github.com/repos/openclaw/openclaw/releases/latest

# 从 CHANGELOG.md 获取
curl -s https://raw.githubusercontent.com/openclaw/openclaw/main/CHANGELOG.md
```

**分析维度**：
- **Breaking Changes**：删除/废弃的功能、API 变更、配置格式变更
- **新功能**：新工具、新能力、性能改进
- **Bug 修复**：影响当前使用的问题修复
- **依赖变更**：新增/移除的依赖，可能影响系统环境

**输出格式**：
```
📝 v2026.4.9 → v2026.4.11 变更摘要

⚠️ Breaking Changes: 无 / [具体变更]

🌟 新功能:
  - Dreaming/memory-wiki: ChatGPT 导入支持
  - 飞书: 文档评论会话增强

🔧 Bug 修复 (15+ 项):
  - OpenAI/Codex OAuth 登录失败修复
  - 音频转录 DNS 验证问题修复
```

### ③ Breaking Change 处理（Agent 自主决策）

`upgrade.sh` 检测到 BC 时会输出 `=== BC_REPORT ===` 结构化数据并以 exit 2 暂停。Agent 收到 BC_REPORT 后**自主分析并决策**，而非一律询问用户。

**Agent 决策流程**：

```
upgrade.sh 检测到 BC → 输出 BC_REPORT → exit 2
  ↓
Agent 解析 BC_REPORT
  ↓
Agent 判断 BC 类型
  ├─ 安全（不影响当前使用）→ Agent 直接用 --force 重新执行，不问用户
  ├─ 可自动处理（配置迁移等）→ Agent 先执行迁移步骤，再用 --force
  └─ 必须用户手动操作 → Agent 暂停，询问用户
```

**判定标准**：

| BC 类型 | Agent 处理方式 | 示例 |
|---------|--------------|------|
| 内部 SDK 路径重构（保留兼容导出） | 直接 `--force` | 插件 SDK 子路径拆分 |
| 废弃功能但有替代方案 | 直接 `--force` | 旧字段名 → 新字段名 |
| 依赖版本变更 | 直接 `--force` | npm 依赖升级 |
| 配置字段重命名 | 先迁移配置，再 `--force` | `old.field` → `new.field` |
| 功能删除无替代 | **询问用户** | 移除某工具 |
| 需要数据迁移 | **询问用户** | 数据库 schema 变更 |
| 不确定影响范围 | **询问用户** | agent 无法判断 |

**询问话术**（仅在必须用户操作时）：
```
⚠️ v{TARGET_VERSION} 包含需要手动处理的 Breaking Changes：

1. [变更描述]
   影响：[影响说明]
   建议处理：[操作步骤]

请先完成上述处理，然后回复「继续」，我再执行升级。
```

**关键原则**：Agent 能判断的自己判断，能处理的自己处理，只有必须用户操作的才停下来。

### ④ 规划回滚方案

升级前自动生成回滚方案：

```bash
# 备份目录
BACKUP_DIR="/tmp/openclaw-rollback-$(date +%Y%m%d%H%M%S)"
mkdir -p "$BACKUP_DIR"

# 备份当前版本信息
ssh $SSH_USER@$HOST 'npm list -g openclaw' > "$BACKUP_DIR/npm-list.txt"

# 备份配置文件
scp $SSH_USER@$HOST:~/.openclaw/openclaw.json "$BACKUP_DIR/openclaw-config.json"

# 生成回滚脚本
cat > "$BACKUP_DIR/rollback.sh" << 'EOF'
#!/bin/bash
# 一键回滚
ssh $SSH_USER@$HOST 'bash -l -c "npm install -g openclaw@{CURRENT_VER}"'
scp "$BACKUP_DIR/openclaw-config.json" $SSH_USER@$HOST:~/.openclaw/openclaw.json
ssh $SSH_USER@$HOST 'bash -l -c "openclaw gateway restart"'
echo "✅ 回滚完成: v{CURRENT_VER}"
EOF
chmod +x "$BACKUP_DIR/rollback.sh"
```

**回滚信息包含**：
- 回滚目标版本号
- 回滚脚本路径
- 配置备份路径
- 回滚命令（一键执行）

### ⑤ 执行升级

使用 `openclaw update --yes` 命令执行升级（官方内置升级命令）：

```bash
# 远程执行升级
ssh $SSH_USER@$HOST 'bash -l -c "openclaw update --yes --timeout 600"'
```

**为什么用 `openclaw update` 而不是 `npm install -g`？**
- `openclaw update` 是官方内置的升级命令
- 自带 self-update 处理（不会出现 "替换了正在运行的文件" 导致的 MODULE_NOT_FOUND 错误）
- 自动处理包管理器差异（npm/pnpm/yarn 都能正确升级）
- 自带 Breaking Changes 检查
- 自动重启 Gateway + doctor 检查
- 支持 `--dry-run` 预检、`--tag` 指定版本

使用 `scripts/upgrade.sh` 执行（封装了回滚、验证等逻辑）：

```bash
# 用法
scripts/upgrade.sh <USER@HOST> [SSH_KEY] [TARGET_VERSION]

# 示例：升级到最新版
scripts/upgrade.sh trclaw2@100.81.167.91 ~/.ssh/id_rsa_tnt

# 示例：升级到指定版本
scripts/upgrade.sh root@43.134.173.17 ~/.ssh/id_rsa_tnt 2026.4.11
```

**升级步骤**（upgrade.sh 内部逻辑）：
1. SSH 连接测试
2. 版本检测与对比
3. 获取变更日志（输出供外部解析）
4. 生成回滚脚本
5. 执行 `openclaw update --yes --tag <VERSION>`
6. 验证版本
7. 重启 Gateway
8. 验证 Gateway 运行状态
9. 输出汇总报告

### ⑥ 完整验证（verify.sh）⭐

升级后**必须**执行 `scripts/verify.sh` 做全面验证（与安装相同），包含 8 大检查项：

```bash
scripts/verify.sh $SSH_USER@$HOST ~/.ssh/id_rsa_tnt
```

验证项：SSH连通性 → 版本确认 → Gateway状态 → openclaw doctor → QMD记忆后端 → 飞书插件状态 → 企微插件状态 → npm源+磁盘

**结果判定**：
- 🟢 全部通过 → 升级成功
- 🟡 有警告 → 可用但建议检查
- 🔴 有失败 → 考虑回滚（回滚脚本在步骤④已生成）

**异常处理**：
- doctor 有 warning → 先 `openclaw doctor --fix` 再验证
- Gateway 未运行 → `systemctl --user restart openclaw-gateway` 再验证
- 飞书/企微断连 → 检查插件配置，可能需要重新授权
- 验证失败且无法修复 → 询问用户是否回滚

### ⑦ 汇总报告

升级完成后输出报告：

```
══════════════════════════════════════════
  OpenClaw 升级报告
══════════════════════════════════════════

  目标机器: {user}@{host}
  升级路径: v{current} → v{target}
  升级结果: ✅ 成功 / ❌ 失败
  Gateway: 🟢 运行中 / 🔴 未运行
  npm 源: {registry}

  📦 回滚信息:
     回滚脚本: {rollback_path}
     回滚命令: bash {rollback_path}

  🆕 新版本亮点:
     - [feature 1]
     - [feature 2]

  ⚠️ Breaking Changes:
     - [change 1]（如有）
══════════════════════════════════════════
```

### ⑧ 建议定时升级任务

升级完成后，询问用户是否创建定时升级任务：

```
✅ 升级完成！

💡 建议创建定时升级任务，自动保持 OpenClaw 为最新版本。
   每天凌晨自动检查并升级（有 Breaking Changes 时暂停并通知用户确认）。

是否创建定时升级任务？
```

用户确认后：

1. **部署定时升级脚本**到目标机器：

```bash
scp scripts/scheduled-upgrade.sh $SSH_USER@$HOST:~/.openclaw/scripts/
ssh $SSH_USER@$HOST 'chmod +x ~/.openclaw/scripts/scheduled-upgrade.sh'
```

2. **创建 OpenClaw Cron Job**：

```json
{
  "name": "系统更新",
  "schedule": { "kind": "cron", "expr": "30 4 * * *", "tz": "Asia/Shanghai" },
  "payload": {
    "kind": "agentTurn",
    "message": "执行 OpenClaw 自动升级：运行 openclaw update --yes --timeout 600 命令。完成后汇报升级结果：1) 新旧版本号 2) 是否成功 3) 如失败说明原因。成功或失败都通知用户。"
  },
  "delivery": { "mode": "announce" },
  "sessionTarget": "isolated"
}
```

## 升级典型场景

### 场景A：常规升级（无 Breaking Changes）

```
→ 检测到 v2026.4.9 → v2026.4.11
→ 无 Breaking Changes
→ 直接执行升级
→ 验证通过
→ 汇报：升级成功，无 Breaking Changes
```

### 场景B：有 Breaking Changes（Agent 自主决策）

**情况 1：BC 安全，Agent 自动跳过**
```
→ 检测到 v2026.4.9 → v2026.4.11
→ script exit 2，BC_REPORT: 插件 SDK 路径拆分（保留兼容导出）
→ Agent 判断：内部 SDK 重构，保留兼容性，安全
→ Agent 自动用 --force 重新执行，不问用户
→ 验证通过
→ 汇报：升级成功，BC 为内部 SDK 路径拆分，不影响使用
```

**情况 2：BC 需配置迁移，Agent 自动处理**
```
→ 检测到 v2026.5.0 → v2026.5.1
→ script exit 2，BC_REPORT: 字段 feishu.threadSession 已废弃，改用 channels.feishu.threadMode
→ Agent 判断：可自动迁移
→ Agent 先修改 openclaw.json：threadSession: true → threadMode: "session"
→ Agent 用 --force 重新执行升级
→ 验证通过
→ 汇报：升级成功，已自动迁移 threadSession → threadMode
```

**情况 3：BC 需用户操作，Agent 暂停询问**
```
→ 检测到 v2026.6.0 → v2026.7.0
→ script exit 2，BC_REPORT: 移除旧版 memory 插件，需迁移到 QMD 后端
→ Agent 判断：需要用户确认数据迁移方案
→ Agent 暂停，询问用户
→ 用户确认后执行升级
→ 汇报：升级成功
```

### 场景C：升级失败回滚

```
→ 执行升级
→ Gateway 启动失败
→ 尝试修复（重启、检查配置）
→ 修复失败
→ 询问用户是否回滚
→ 用户确认回滚
→ 执行 rollback.sh
→ 验证回滚成功
→ 汇报：升级失败，已回滚到 v2026.4.9
```

### 场景D：定时升级（自动）

```
→ Cron Job 每天凌晨 4:00 执行
→ 检查是否有新版本
→ 无更新 → 跳过
→ 有更新但有 Breaking Changes → 暂停，通知用户
→ 有更新且无 Breaking Changes → 自动升级
→ 升级结果推送到飞书通知
```

## 脚本说明

| 脚本 | 路径 | 用途 |
|------|------|------|
| `install.sh` | `scripts/install.sh` | 全新安装（含 QMD + bootstrap-skills） |
| `upgrade.sh` | `scripts/upgrade.sh` | 一次性远程升级（含回滚） |
| `verify.sh` | `scripts/verify.sh` | 安装/升级后完整验证（8大检查项，含 doctor + 飞书 + 企微） |
| `scheduled-upgrade.sh` | `scripts/scheduled-upgrade.sh` | 部署到目标机器的定时升级脚本 |
| `diagnose.sh` | `scripts/diagnose.sh` | 远程机器快速诊断 |
| `post-install.sh` | `scripts/post-install.sh` | 飞书四项优化 + bootstrap-skills 同步 |

---

# 第三部分：远程 Gateway CLI 管理（含 Pairing）

在目标机器上执行 `openclaw cron`、`openclaw devices` 等管理命令时，需要先完成 Gateway CLI 配对。

## 为什么需要配对？

Gateway 监听在 `127.0.0.1:18789`，远程 SSH 连接时，CLI 会被当作新设备，出现错误：
```
gateway connect failed: pairing required
```

## 配对方法（关键机制）

CLI 有一个 **local pairing fallback** 机制：当检测到目标是本地 loopback 且收到 "pairing required" 时，会 fallback 到直接读写本地 pairing store 文件，跳过 Gateway RPC。因此 SSH 进机器后**不需要指定 `--url`**（指定了就无法触发 fallback），直接运行命令即可触发 fallback。

### 操作步骤

**第一步：SSH 进目标机器，检查是否有待批准的配对请求**

```bash
ssh -i ~/.ssh/id_rsa_tnt -o StrictHostKeyChecking=no root@<HOST> 'openclaw devices list'
```

输出示例：
```
Pending (1)
┌────────────────────────────────────┬────────────────┬──────────┬─────────────┬────────┐
│ Request ID                         │ Device         │ Role     │ Age         │ Flags  │
│ 3e93eae6-9123-433a-b26c-5ecaa00   │ 06dcb3c95363… │ operator │ 2m ago      │ repair │
└────────────────────────────────────┴────────────────┴──────────┴─────────────┴────────┘
```

> ⚠️ 如果显示 `command not found`，可能 PATH 未加载 bash 环境，用 `bash -l -c` 包裹命令。

**第二步：批准配对请求**

```bash
ssh -i ~/.ssh/id_rsa_tnt -o StrictHostKeyChecking=no root@<HOST> 'openclaw devices approve <Request ID>'
```

**第三步：验证**

```bash
ssh -i ~/.ssh/id_rsa_tnt -o StrictHostKeyChecking=no root@<HOST> 'openclaw cron list'
```

能正常输出 Cron Job 列表即表示配对成功，后续所有 `openclaw` 管理命令均可正常使用。

### 常见问题

**Q：`openclaw: command not found`**
→ PATH 未加载，用 login shell：`bash -l -c "openclaw ..."`

**Q：devices list 显示 `command not found`**
→ openclaw 版本较旧，尝试 `openclaw devices -- list`（双横线分隔）

**Q：配对后仍然 `pairing required`**
→ 可能配对了错误的角色，用 `openclaw devices list` 查看当前已配对设备，用 `openclaw devices revoke --device <id> --role <role>` 撤销后重新配对

## 典型应用场景

### 场景：在目标机器上创建 Cron Job

```bash
# 1. 先配对
ssh -i ~/.ssh/id_rsa_tnt -o StrictHostKeyChecking=no root@<HOST> 'openclaw devices list'
# 看到 pending 请求后批准
ssh -i ~/.ssh/id_rsa_tnt -o StrictHostKeyChecking=no root@<HOST> 'openclaw devices approve <requestId>'

# 2. 创建 Cron Job
ssh -i ~/.ssh/id_rsa_tnt -o StrictHostKeyChecking=no root@<HOST> 'openclaw cron add \
  --name "定时升级任务" \
  --cron "30 4 * * *" \
  --tz "Asia/Shanghai" \
  --session isolated \
  --wake now \
  --message "执行升级脚本..." \
  --timeout-seconds 900 \
  --announce \
  --channel feishu \
  --to "<飞书用户 open_id>"'
```
