#!/bin/bash
# ============================================
# WinUtil 中文版 - Cloudflare Workers 部署脚本
# ============================================
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_PS1="$SCRIPT_DIR/../winutil.ps1"
WORKER_DIR="$SCRIPT_DIR"
OUTPUT_WORKER="$WORKER_DIR/src/worker.js"

echo "========================================"
echo "  WinUtil 中文版 → Cloudflare Workers"
echo "========================================"
echo ""

# 检查源文件
if [ ! -f "$SOURCE_PS1" ]; then
    echo "❌ 未找到 winutil.ps1，请先编译"
    echo "   运行: python3 compile.py"
    exit 1
fi

SIZE=$(wc -c < "$SOURCE_PS1")
SIZE_KB=$((SIZE / 1024))
echo "📄 winutil.ps1: ${SIZE_KB}KB"

# 检查是否在 1MB 限制内
if [ $SIZE -gt 1048576 ]; then
    echo "❌ 文件超过 1MB，超出 Cloudflare Workers 免费限制"
    echo "   建议使用 Cloudflare Pages 或 Workers + KV"
    exit 1
fi

echo "✅ 文件大小在 1MB 限制内"

# 生成 worker.js
echo ""
echo "⚙️  生成 worker.js..."

mkdir -p "$WORKER_DIR/src"

# 读取 winutil.ps1 内容并转义
WINUTIL_CONTENT=$(python3 -c "
import json, sys
with open('$SOURCE_PS1', 'r', encoding='utf-8') as f:
    content = f.read()
print(json.dumps(content, ensure_ascii=False))
")

# 生成最终的 worker.js
python3 -c "
import json

with open('$WORKER_DIR/worker.js.template', 'r', encoding='utf-8') as f:
    template = f.read()

with open('$SOURCE_PS1', 'r', encoding='utf-8') as f:
    content = f.read()

# 转义为 JSON 字符串
escaped = json.dumps(content, ensure_ascii=False)
output = template.replace('{{WINUTIL_CONTENT}}', escaped)

with open('$OUTPUT_WORKER', 'w', encoding='utf-8') as f:
    f.write(output)

print(f'✅ 生成: {output}')
print(f'   大小: {len(output.encode(\"utf-8\")) / 1024:.0f}KB')
"

echo ""
echo "========================================"
echo "  部署命令:"
echo "========================================"
echo ""
echo "  cd cloudflare-worker"
echo "  npx wrangler deploy"
echo ""
echo "  或首次运行:"
echo "  npx wrangler login"
echo "  npx wrangler deploy"
echo ""
echo "========================================"
echo "  配置域名:"
echo "========================================"
echo ""
echo "  在 Cloudflare Dashboard 中:"
echo "  1. Workers & Pages → winutil-zh → Triggers"
echo "  2. 添加自定义域名: win.mozuiapp.cn"
echo "  3. 用户即可使用:"
echo ""
echo "  irm https://win.mozuiapp.cn/win | iex"
