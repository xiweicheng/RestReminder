#!/bin/bash
# RestReminder 一键同步脚本：git add + commit + push 到 GitHub
# 用法: bash git-sync.sh ["提交说明"]
# 示例: bash git-sync.sh "feat: 增加番茄钟模式"
cd "$(dirname "$0")" || exit 1

MSG="${1:-update: $(date '+%Y-%m-%d %H:%M') 改进}"

git add -A
if git diff --cached --quiet; then
  echo "没有需要提交的改动"
  exit 0
fi

git commit -m "$MSG" || exit 1
git push origin main && echo "✅ 已同步到 GitHub: https://github.com/xiweicheng/RestReminder"
