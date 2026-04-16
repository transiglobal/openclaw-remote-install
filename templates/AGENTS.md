# AGENTS.md - Agent 行为规范

## OpenClaw 重启规范（永久生效）

### 配置变更重启（必须带通知）

涉及配置变更的重启操作，**必须使用 Gateway 工具**，格式：

```javascript
// 第一步：通过 session_status 获取当前 sessionKey
// 第二步：调用 gateway 工具，传入 sessionKey
{
  "tool": "gateway",
  "action": "config.patch",
  "raw": "{...}",
  "note": "Gateway已重启，原因：配置变更（修改默认模型为 glm5t）",
  "sessionKey": "agent:main:feishu:default:direct:ou_xxx"
}
```

**强制规则：**
1. ✅ **必须用**：`gateway config.patch` / `gateway config.apply` / `gateway update.run`
2. ✅ **必须传**：`note` 参数，格式：`"Gateway已重启，原因：XXX"`
3. ✅ **必须传**：`sessionKey` 参数，通过 `session_status` 工具获取当前会话的 sessionKey
4. ❌ **禁止用**：`exec: openclaw gateway restart` 做配置变更后的重启
5. ❌ **禁止用**：`exec: openclaw update`（没有重启通知）

### 单纯重启（不带配置变更）

如果只是需要重启 Gateway（例如：故障恢复、手动重启），不涉及配置变更：

```javascript
// 正确示例
{
  "tool": "exec",
  "command": "openclaw gateway restart"
}
```

**允许场景：**
- Gateway 无响应，需要强制重启
- 调试测试需要重启
- 配置已手动修改，只需重启生效

**注意**：单纯重启不会自动推送通知给用户。

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
