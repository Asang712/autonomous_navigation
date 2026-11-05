#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# push.sh — ROS2 自主导航项目一键提交并推送到 GitHub
# 用法：
#   ./push.sh              # 自动生成 commit message（时间 + 改动文件列表）
#   ./push.sh "说明一句话"  # 用自定义 commit message
# 依赖：git
# -----------------------------------------------------------------------------
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REMOTE_URL="https://github.com/Asang712/autonomous_navigation.git"

# ----- 1. 进入项目根目录 -----------------------------------------------------
cd "$PROJECT_ROOT"
echo "📂 项目根目录: $PROJECT_ROOT"

# ----- 2. 确保是 git 仓库 ----------------------------------------------------
if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "⚠️  还不是 git 仓库，自动初始化并关联 $REMOTE_URL ..."
  git init -b main
  if ! git remote get-url origin >/dev/null 2>&1; then
    git remote add origin "$REMOTE_URL"
  fi
fi

# ----- 3. 确保 origin 存在 ---------------------------------------------------
if ! git remote get-url origin >/dev/null 2>&1; then
  git remote add origin "$REMOTE_URL"
elif [[ "$(git remote get-url origin)" != "$REMOTE_URL" ]]; then
  echo "🔧 修正 remote origin 为 $REMOTE_URL"
  git remote set-url origin "$REMOTE_URL"
fi

# ----- 4. 暂存所有改动 -------------------------------------------------------
echo ""
echo "🔎 改动预览："
git status --short || true
echo ""

git add -A

# ----- 5. 生成 / 获取 commit message -----------------------------------------
if [[ $# -ge 1 && -n "${1// /}" ]]; then
  MSG="$*"
else
  TIMESTAMP="$(date '+%Y-%m-%d %H:%M:%S')"
  CHANGES="$(git diff --cached --name-status 2>/dev/null | head -20 || true)"
  if [[ -z "$CHANGES" ]]; then
    echo "✅ 没有可提交的改动，退出。"
    exit 0
  fi
  MSG="[$TIMESTAMP] $CHANGES"
fi

# ----- 6. 提交 ---------------------------------------------------------------
if git diff --cached --quiet 2>/dev/null; then
  echo "✅ 没有可提交的改动（已存在 .gitignore 过滤），跳过 commit。"
else
  echo "📝 提交信息: $MSG"
  git commit -m "$MSG"
fi

# ----- 7. 推送 ---------------------------------------------------------------
CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
echo "🚀 推送分支 $CURRENT_BRANCH → origin ..."
if git push -u origin "$CURRENT_BRANCH" 2>&1; then
  echo ""
  echo "🎉 推送成功！仓库地址：$REMOTE_URL"
else
  echo ""
  echo "❌ 推送失败，常见原因："
  echo "   - 没有登录 GitHub：运行  gh auth login  或配置 SSH key"
  echo "   - 远程仓库有新提交：先  git pull --rebase origin $CURRENT_BRANCH  再 push"
  exit 1
fi
