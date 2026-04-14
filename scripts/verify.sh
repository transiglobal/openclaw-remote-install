#!/bin/bash
# openclaw-remote-verify - 安装/升级后的完整验证脚本
# 用法: ./verify.sh <USER@HOST> [SSH_KEY]
# 输出: 结构化验证报告，每项 ✅/⚠️/❌

set -euo pipefail

TARGET="${1:?用法: $0 <USER@HOST> [SSH_KEY]}"
SSH_KEY="${2:-$HOME/.ssh/id_rsa_tnt}"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"

# 检测远程 shell
REMOTE_SHELL=$(ssh $SSH_OPTS "$TARGET" 'echo $SHELL' 2>/dev/null | xargs basename || echo "bash")
if [[ "$REMOTE_SHELL" == "zsh" ]]; then
    SC="zsh -l -c"
else
    SC="bash -l -c"
fi

run() {
    ssh $SSH_OPTS "$TARGET" "$SC \"$1\"" 2>/dev/null
}

PASS=0
WARN=0
FAIL=0
RESULTS=()

check() {
    local name="$1" status="$2" detail="$3"
    RESULTS+=("$status | $name | $detail")
    case "$status" in
        ✅) PASS=$((PASS+1)) ;;
        ⚠️) WARN=$((WARN+1)) ;;
        ❌) FAIL=$((FAIL+1)) ;;
    esac
}

echo "══════════════════════════════════════════"
echo "  OpenClaw 远程验证: $TARGET"
echo "══════════════════════════════════════════"
echo ""

# ──────────────────────────────────────
# 1. SSH 连通性
# ──────────────────────────────────────
echo "[1/9] SSH 连通性..."
if ssh $SSH_OPTS "$TARGET" 'echo OK' >/dev/null 2>&1; then
    check "SSH 连接" "✅" "可达"
else
    check "SSH 连接" "❌" "不可达"
    echo "❌ SSH 不可达，终止验证"
    exit 1
fi

# ──────────────────────────────────────
# 2. 版本确认
# ──────────────────────────────────────
echo "[2/9] 版本确认..."
VER=$(run 'openclaw --version 2>/dev/null' || echo "NOT_FOUND")
if [[ "$VER" == "NOT_FOUND" || -z "$VER" ]]; then
    check "OpenClaw 版本" "❌" "未安装或不在 PATH"
else
    check "OpenClaw 版本" "✅" "$VER"
fi

NODE_VER=$(run 'node --version 2>/dev/null' || echo "NOT_FOUND")
if [[ "$NODE_VER" == "NOT_FOUND" ]]; then
    check "Node.js" "❌" "未安装"
else
    NODE_MAJOR=$(echo "$NODE_VER" | sed 's/v\([0-9]*\)\..*/\1/')
    if [[ "$NODE_MAJOR" -lt 22 ]]; then
        check "Node.js" "⚠️" "$NODE_VER（需 >= 22）"
    else
        check "Node.js" "✅" "$NODE_VER"
    fi
fi

# ──────────────────────────────────────
# 3. Gateway 状态
# ──────────────────────────────────────
echo "[3/9] Gateway 状态..."
GW_STATUS=$(run 'systemctl --user status openclaw-gateway.service 2>&1 | grep "Active:"' || echo "查询失败")
if echo "$GW_STATUS" | grep -q "running"; then
    check "Gateway 进程" "✅" "running"
else
    check "Gateway 进程" "❌" "$GW_STATUS"
fi

# Dashboard 可用性
DASH=$(run 'curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:18789/ 2>/dev/null' || echo "000")
if [[ "$DASH" == "200" ]]; then
    check "Dashboard" "✅" "HTTP 200"
else
    check "Dashboard" "⚠️" "HTTP $DASH"
fi

# ──────────────────────────────────────
# 4. openclaw doctor
# ──────────────────────────────────────
echo "[4/9] openclaw doctor..."
DOCTOR_OUTPUT=$(run 'openclaw doctor 2>&1' || echo "执行失败")

# 检查 doctor 有无 error/critical
if echo "$DOCTOR_OUTPUT" | grep -qiE "error|critical"; then
    ERRORS=$(echo "$DOCTOR_OUTPUT" | grep -iE "error|critical" | grep -v "config schema" | head -5 | tr '\n' '; ')
    check "Doctor 检查" "⚠️" "发现异常: $ERRORS"
else
    check "Doctor 检查" "✅" "无严重问题"
fi

# Doctor warnings 计数
DOCTOR_WARNINGS=$(echo "$DOCTOR_OUTPUT" | grep -c "⚠\|Warning\|warning" || echo "0")
if [[ "$DOCTOR_WARNINGS" -gt 0 ]]; then
    check "Doctor warnings" "⚠️" "${DOCTOR_WARNINGS} 个警告"
fi

# ──────────────────────────────────────
# 5. QMD 记忆后端
# ──────────────────────────────────────
echo "[5/9] QMD 记忆后端..."
QMD_VER=$(run 'qmd --version 2>/dev/null' || run 'bun x qmd --version 2>/dev/null' || echo "NOT_FOUND")
if [[ "$QMD_VER" == "NOT_FOUND" ]]; then
    check "QMD 版本" "❌" "未安装"
else
    check "QMD 版本" "✅" "$QMD_VER"
fi

MEM_BACKEND=$(run 'openclaw config get memory.backend 2>/dev/null' || echo "")
if [[ "$MEM_BACKEND" == *"qmd"* ]]; then
    check "memory.backend" "✅" "qmd"
elif [[ -z "$MEM_BACKEND" || "$MEM_BACKEND" == "null" ]]; then
    check "memory.backend" "⚠️" "未设置（默认非 qmd）"
else
    check "memory.backend" "⚠️" "$MEM_BACKEND"
fi

# ──────────────────────────────────────
# 6. 飞书插件状态（如已配置）
# ──────────────────────────────────────
echo "[6/9] 飞书插件状态..."
FEISHU_PLUGIN=$(run 'openclaw config get plugins.entries.feishu.enabled 2>/dev/null' || echo "")
FEISHU_CHANNEL=$(run 'openclaw config get channels.feishu.appId 2>/dev/null' || echo "")

if [[ "$FEISHU_PLUGIN" == *"false"* ]]; then
    check "飞书插件" "ℹ️" "插件 disabled"
elif [[ -n "$FEISHU_CHANNEL" && "$FEISHU_CHANNEL" != "null" ]]; then
    # 飞书已配置，运行 lark doctor
    echo "  运行 npx @larksuite/openclaw-lark doctor..."
    LARK_DOCTOR=$(run 'npx -y @larksuite/openclaw-lark doctor 2>&1' || echo "执行失败")
    if echo "$LARK_DOCTOR" | grep -qiE "error|fail|异常|未连接"; then
        LARK_ERRORS=$(echo "$LARK_DOCTOR" | grep -iE "error|fail|异常|未连接" | head -3 | tr '\n' '; ')
        check "飞书 doctor" "⚠️" "$LARK_ERRORS"
    else
        check "飞书 doctor" "✅" "正常"
    fi
    # 保留详细输出供汇总
    LARK_DETAIL=$(echo "$LARK_DOCTOR" | head -20)
else
    # doctor 输出中的飞书状态
    if echo "$DOCTOR_OUTPUT" | grep -q "Feishu: ok"; then
        check "飞书插件" "✅" "doctor 确认 ok"
    else
        check "飞书插件" "ℹ️" "未配置（非飞书环境可忽略）"
    fi
fi

# ──────────────────────────────────────
# 7. 企微插件状态（如已配置）
# ──────────────────────────────────────
echo "[7/9] 企微插件状态..."
WECOM_PLUGIN=$(run 'openclaw config get plugins.entries.wecom-openclaw-plugin.enabled 2>/dev/null' || echo "")
WECOM_CHANNEL=$(run 'openclaw config get channels.wecom.botId 2>/dev/null' || echo "")
WECOM_WEIXIN=$(run 'openclaw config get plugins.entries.openclaw-weixin 2>/dev/null' || echo "")

if [[ "$WECOM_PLUGIN" == *"true"* ]] || [[ -n "$WECOM_CHANNEL" && "$WECOM_CHANNEL" != "null" ]]; then
    # 企微已配置，组合检查
    WECOM_OK=true
    WECOM_ISSUES=""

    # 检查1：doctor 输出
    if echo "$DOCTOR_OUTPUT" | grep -q "企业微信: ok\|openclaw-weixin: ok"; then
        : # ok
    elif echo "$DOCTOR_OUTPUT" | grep -q "openclaw-weixin: configured\|企业微信: configured"; then
        : # configured 也算 ok
    else
        WECOM_OK=false
        WECOM_ISSUES+="doctor未确认; "
    fi

    # 检查2：日志中企微运行状态
    WECOM_LOG=$(run 'tail -100 /tmp/openclaw/openclaw-$(date +%Y-%m-%d).log 2>/dev/null | grep -iE "wecom|weixin" | grep -ciE "setWeixinRuntime|runtime.*success|compat.*OK"' || echo "0")
    if [[ "$WECOM_LOG" -gt 0 ]]; then
        : # 日志有成功记录
    else
        WECOM_OK=false
        WECOM_ISSUES+="日志未发现运行记录; "
    fi

    # 检查3：日志中企微错误
    WECOM_ERR=$(run 'tail -200 /tmp/openclaw/openclaw-$(date +%Y-%m-%d).log 2>/dev/null | grep -iE "wecom|weixin" | grep -ciE "ERROR|FATAL|fail"' || echo "0")
    if [[ "$WECOM_ERR" -gt 0 ]]; then
        WECOM_OK=false
        WECOM_ISSUES+="发现 ${WECOM_ERR} 个错误日志; "
    fi

    # 检查4：MCP server 连通性（调用 wecom_mcp list contact）
    WECOM_MCP=$(run 'echo test' 2>/dev/null) # 简单连接测试
    # 注：无法直接 SSH 调用 wecom_mcp，只能通过运行中的 gateway 操作

    if $WECOM_OK; then
        check "企微插件" "✅" "doctor确认 + 日志正常"
    else
        check "企微插件" "⚠️" "$WECOM_ISSUES"
    fi

    # 配置完整性
    WECOM_CORPID=$(run 'openclaw config get channels.wecom.corpId 2>/dev/null || echo ""' || echo "")
    if [[ -n "$WECOM_CORPID" && "$WECOM_CORPID" != "null" ]]; then
        check "企微 corpId" "✅" "已配置"
    else
        check "企微 corpId" "⚠️" "未配置"
    fi
else
    check "企微插件" "ℹ️" "未配置（非企微环境可忽略）"
fi

# ──────────────────────────────────────
# ──────────────────────────────────────
# ──────────────────────────────────────
# 8. 日志异常检测与归纳报告
# ──────────────────────────────────────
echo "[8/9] 日志异常检测与归纳..."
LOG_FILE="/tmp/openclaw/openclaw-\$(date +%Y-%m-%d).log"
LOG_EXISTS=$(run "test -f $LOG_FILE && echo YES || echo NO")

if [[ "$LOG_EXISTS" == "NO" ]]; then
    check "日志文件" "⚠️" "当日日志不存在"
else
    # 用 python3 解析 JSON 格式日志，提取并归纳所有异常
    LOG_ANALYSIS=$(run "python3 -c '
import json, sys, collections

counts = {\"FATAL\": 0, \"ERROR\": 0, \"WARN\": 0}
messages = {\"FATAL\": [], \"ERROR\": [], \"WARN\": []}

try:
    with open(\"$LOG_FILE\", \"r\") as f:
        for line in f:
            try:
                entry = json.loads(line.strip())
                level = entry.get(\"_meta\", {}).get(\"logLevelName\", \"\")
                if level in counts:
                    counts[level] += 1
                    # 提取消息内容
                    msg = entry.get(\"0\", \"\") or entry.get(\"1\", \"\")
                    # 截取前200字符，去除换行
                    msg = str(msg)[:200].replace(chr(10), \" \").replace(chr(13), \" \")
                    if msg:
                        messages[level].append(msg)
            except (json.JSONDecodeError, KeyError):
                continue
except Exception as e:
    print(f\"PARSE_ERROR: {e}\")
    sys.exit(0)

# 输出计数
for level in [\"FATAL\", \"ERROR\", \"WARN\"]:
    print(f\"{level}:{counts[level]}\")

# 输出去重后的归纳（频次排序，每个类别最多10条）
for level in [\"FATAL\", \"ERROR\", \"WARN\"]:
    print(f\"--- {level} ---\")
    if messages[level]:
        counter = collections.Counter(messages[level])
        for msg, cnt in counter.most_common(20):
            print(f\"  [{cnt}x] {msg}\")
    else:
        print(\"  (无)\")
' 2>&1" || echo "PARSE_ERROR: 日志分析失败")

    if echo "$LOG_ANALYSIS" | grep -q "PARSE_ERROR"; then
        check "日志分析" "⚠️" "日志解析失败"
    else
        # 解析计数
        FATAL_C=$(echo "$LOG_ANALYSIS" | grep "^FATAL:" | sed 's/FATAL://')
        ERROR_C=$(echo "$LOG_ANALYSIS" | grep "^ERROR:" | sed 's/ERROR://')
        WARN_C=$(echo "$LOG_ANALYSIS" | grep "^WARN:" | sed 's/WARN://')
        FATAL_C=${FATAL_C:-0}; ERROR_C=${ERROR_C:-0}; WARN_C=${WARN_C:-0}

        # 判定状态：FATAL→❌ ERROR→⚠️ WARN→仅记录
        if [[ "$FATAL_C" -gt 0 ]]; then
            check "日志异常" "❌" "FATAL:$FATAL_C ERROR:$ERROR_C WARN:$WARN_C"
        elif [[ "$ERROR_C" -gt 0 ]]; then
            check "日志异常" "⚠️" "ERROR:$ERROR_C WARN:$WARN_C（无FATAL）"
        else
            check "日志异常" "✅" "WARN:$WARN_C（无ERROR/FATAL）"
        fi

        # 保存分析结果供详细报告
        LOG_SUMMARY_REPORT="$LOG_ANALYSIS"
    fi
fi

# 9. 包管理器源 + 系统环境
# ──────────────────────────────────────
# 统一使用 npm（pnpm v10 approve-builds 在 SSH 下不可用）
OPENCLAW_BIN_PATH=$(run 'which openclaw 2>/dev/null' || echo "")
DETECTED_PKG_MGR="npm"
if echo "$OPENCLAW_BIN_PATH" | grep -q "pnpm"; then
    DETECTED_PKG_MGR="npm (迁移自 pnpm)"
fi

echo "[9/9] npm 源 + 系统环境..."
NPM_REG=$(run 'npm config get registry 2>/dev/null' || echo "未获取")
if echo "$NPM_REG" | grep -qE "npmmirror|tencent|cnpm|aliyun|huawei"; then
    check "npm 源" "✅" "$NPM_REG"
else
    check "npm 源" "⚠️" "$NPM_REG（非国内镜像）"
fi

DISK=$(run 'df -h / | tail -1 | awk "{print \\$5}"' || echo "未知")
check "磁盘使用率" "✅" "$DISK"

# ──────────────────────────────────────
# 汇总报告
# ──────────────────────────────────────
echo ""
echo "══════════════════════════════════════════"
echo "  验证汇总"
echo "══════════════════════════════════════════"
echo ""

for r in "${RESULTS[@]}"; do
    echo "  $r"
done

echo ""
TOTAL=$((PASS + WARN + FAIL))
echo "  总计: $TOTAL 项 | ✅ $PASS  ⚠️ $WARN  ❌ $FAIL"

# 日志异常详细报告（如有异常）
if [[ -n "${LOG_SUMMARY_REPORT:-}" ]]; then
    echo ""
    echo "══════════════════════════════════════════"
    echo "  📋 日志异常归纳报告"
    echo "══════════════════════════════════════════"
    echo ""
    echo "$LOG_SUMMARY_REPORT" | grep -v "^--- COUNTS ---$" | grep -v "^FATAL:" | grep -v "^ERROR:" | grep -v "^WARN:" | grep -v "^$" | while IFS= read -r line; do
        # 分类标题行
        if [[ "$line" == "--- FATAL ---" ]]; then
            echo "  🔴 FATAL 错误："
        elif [[ "$line" == "--- ERROR ---" ]]; then
            echo "  🟠 ERROR 错误："
        elif [[ "$line" == "--- WARN ---" ]]; then
            echo "  🟡 WARN 警告："
        else
            echo "    $line"
        fi
    done
    echo ""
fi
echo ""

if [[ $FAIL -gt 0 ]]; then
    echo "  🔴 存在失败项，需要处理"
    exit 1
elif [[ $WARN -gt 0 ]]; then
    echo "  🟡 存在警告项，建议检查"
    exit 0
else
    echo "  🟢 全部通过"
    exit 0
fi
