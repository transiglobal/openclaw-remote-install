# AGENTS.md - Agent 行为规范

## 配置更新与 Gateway 重启规范

⚠️ 配置变更后必须通过 gateway 工具重启，禁止用 exec 直接调用 openclaw gateway restart 来应用配置变更。

### 配置更新（改配置 + 重启）

1. 先获取 baseHash：调用 `gateway` 工具，action=`config.get`
2. 通过 `session_status` 获取当前 session 的完整 key
3. 调用 `gateway` 工具，action=`config.patch`，带上以下参数：
   - `raw`：完整配置 JSON 字符串
   - `baseHash`：上一步 config.get 返回的 hash
   - `note`：格式 `"Gateway已重启，原因：XXX"`
   - `sessionKey`：完整 key（如 `agent:main:feishu:default:direct:ou_xxx`），**不能用简写 agent:main**

```javascript
// 正确示例：两步完成配置更新
// 第一步：获取 baseHash
gateway({ action: "config.get" })
// 第二步：调用 config.patch
gateway({
  action: "config.patch",
  raw: "{\"agents\":{...}}",
  baseHash: "从 config.get 获取",
  note: "Gateway已重启，原因：修改默认模型为 glm5t",
  sessionKey: "agent:main:feishu:default:direct:ou_xxx"
})
```

**强制规则：**
1. ✅ **必须用**：`gateway config.patch` / `gateway config.apply` / `gateway update.run`
2. ✅ **必须先获取**：`baseHash`（通过 `gateway config.get`）
3. ✅ **必须传**：`note` 参数，格式 `"Gateway已重启，原因：XXX"`
4. ✅ **必须传**：`sessionKey` 参数，完整 key，通过 `session_status` 获取
5. ❌ **禁止用**：`exec: openclaw gateway restart` 做配置变更后的重启
6. ❌ **禁止用**：`exec: openclaw update`（没有重启通知）

### 单纯重启（不改配置）

使用 `openclaw gateway restart`（仅当不涉及配置变更时）。

---

## 其他规范

### SSH 执行环境
所有 SSH 命令必须使用 login shell 加载环境变量：
```bash
bash -l -c "openclaw ..."
```

### 技能安装
安装任何 skill 前必须完成安全审计。

### 黄线操作记录
执行 sudo、systemctl、iptables 等黄线操作后，必须记录到当日 memory 文件。
