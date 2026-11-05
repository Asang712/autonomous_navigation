#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# push.sh — ROS2 自主导航项目一键提交并推送到 GitHub
#
# 用法：
#   ./push.sh                 # 手动模式：自动生成 commit message，一次性 push
#   ./push.sh "说明一句话"     # 手动模式：自定义 commit message
#   ./push.sh watch           # 守护进程模式：后台常驻，每 10s 轮询自动同步
#   ./push.sh daemon          # 同 watch，别名
#
# 守护进程模式参考 ~/ros2_project/.git/auto_sync.sh 的设计：
#   - 不干扰 merge/rebase/cherry-pick（检测 MERGE_HEAD 等锁文件）
#   - 远端有新提交时跳过，不自动 pull（避免冲突）
#   - 防抖：发现改动后再等 10s，确保编辑稳定
#   - 网络 push 失败自动重试 3 次（指数退避）
#
# 依赖：git
# -----------------------------------------------------------------------------
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REMOTE_URL="https://github.com/Asang712/autonomous_navigation.git"
BRANCH="main"
POLL_INTERVAL=10          # 守护进程轮询间隔（秒）
STABLE_WAIT=10            # 防抖等待：改动后再等几秒确认真的稳定
PUSH_MAX_RETRIES=3        # push 网络失败重试次数

# =============================================================================
# 公共：仓库初始化 / remote 修正
# =============================================================================
ensure_repo() {
  cd "$PROJECT_ROOT"
  if ! git rev-parse --git-dir >/dev/null 2>&1; then
    echo "⚠️  还不是 git 仓库，自动初始化并关联 $REMOTE_URL ..."
    git init -b main
  fi
  if ! git remote get-url origin >/dev/null 2>&1; then
    git remote add origin "$REMOTE_URL"
  elif [[ "$(git remote get-url origin)" != "$REMOTE_URL" ]]; then
    echo "🔧 修正 remote origin 为 $REMOTE_URL"
    git remote set-url origin "$REMOTE_URL"
  fi
  # 确保上游跟踪关系存在
  git branch --set-upstream-to="origin/$BRANCH" "$BRANCH" 2>/dev/null || true
}

# =============================================================================
# 公共：检查 git author 归属（避免 commit 被错误匹配到 GitHub 上同名陌生人）
# =============================================================================
check_author() {
  local email name
  email="$(git config --global user.email 2>/dev/null || true)"
  name="$(git config --global user.name 2>/dev/null || true)"

  # asang@users.noreply.github.com 这种格式会匹配到 GitHub 上 login 叫 "asang"
  # 的印度用户 Asang Dani，不是你。正确格式是 <id>+<login>@users.noreply.github.com
  if [[ "$email" == "asang@users.noreply.github.com" || \
        "$email" =~ ^[a-z]+@users\.noreply\.github\.com$ && "$name" == "asang" ]]; then
    cat <<EOF

⚠️ 你的 git user.name/user.email 可能错了！
   当前: $name <$email>

   你 GitHub 账号是 Asang712（id 293708804），正确的 noreply 邮箱格式是：
     Asang712 <293708804+Asang712@users.noreply.github.com>

   错误的 asang@users.noreply.github.com 会把 commit 归到 GitHub 上另一个
   叫 "asang"（印度 Arista Networks 的 Asang Dani）的陌生人名下。

EOF
    read -r -p "现在帮你修正 git config？[Y/n] " ans
    ans="${ans:-Y}"
    if [[ "$ans" =~ ^[Yy]$ ]]; then
      git config --global user.name "Asang712"
      git config --global user.email "293708804+Asang712@users.noreply.github.com"
      echo "✅ 已修正：$(git config --global user.name) <$(git config --global user.email)>"
      echo "   历史 commit 归属要改的话再跑 git filter-branch 手动重写，新 commit 自动正确。"
    fi
  fi
}

# =============================================================================
# 公共：网络 push（带重试 + 指数退避）
# =============================================================================
do_push() {
  local branch="$1"
  local attempt=1
  local wait=1
  while (( attempt <= PUSH_MAX_RETRIES )); do
    if git push -u origin "$branch" 2>&1; then
      return 0
    fi
    # 不是网络问题就直接放弃（比如 rebase-needed 冲突）
    if ! git push -u origin "$branch" 2>&1 | grep -qiE "Failed to connect|Couldn't connect|gnutls|timed out|network"; then
      return 1
    fi
    echo "⚠️  push 网络失败，${wait}s 后第 $attempt/$PUSH_MAX_RETRIES 次重试..."
    sleep "$wait"
    wait=$(( wait * 2 ))
    (( attempt++ )) || true
  done
  return 1
}

# =============================================================================
# 公共：提交逻辑
#   参数 $1: commit message（可为空，自动生成）
# =============================================================================
do_commit_and_push() {
  local msg="${1:-}"
  local timestamp changes

  # 工作区干净直接返回
  if git diff --quiet && git diff --cached --quiet; then
    return 0
  fi

  git add -A

  if git diff --cached --quiet 2>/dev/null; then
    return 0
  fi

  if [[ -z "$msg" ]]; then
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    changes="$(git diff --cached --name-status 2>/dev/null | head -5 | tr '\n' ' ')"
    [[ -z "$changes" ]] && changes="project files"
    msg="auto: sync ${changes}${timestamp}"
  fi

  echo "📝 commit: $msg"
  git commit -m "$msg"

  local current_branch
  current_branch="$(git rev-parse --abbrev-ref HEAD)"
  echo "🚀 push $current_branch → origin ..."
  if do_push "$current_branch"; then
    echo "✅ push done"
    return 0
  else
    echo "❌ push 失败，远程有分叉或持续网络问题。人工介入。"
    return 1
  fi
}

# =============================================================================
# 守护进程模式（核心循环）
# =============================================================================
run_watcher() {
  echo "🔄 守护进程启动：每 ${POLL_INTERVAL}s 轮询，检测到改动后防抖 ${STABLE_WAIT}s 再提交"
  echo "   按 Ctrl+C 退出"
  echo ""

  while true; do
    sleep "$POLL_INTERVAL"

    # 1) merge/rebase/cherry-pick 进行中 → 跳过，让人工解决冲突
    if [[ -f .git/MERGE_HEAD || -f .git/REBASE_HEAD || -d .git/rebase-merge || -f .git/CHERRY_PICK_HEAD ]]; then
      continue
    fi

    # 2) 远端领先 → 跳过（push 会被拒），等人工 pull
    git fetch origin -q 2>/dev/null || true
    if [[ -n "$(git rev-list HEAD..origin/$BRANCH 2>/dev/null)" ]]; then
      continue
    fi

    # 3) 工作区真有改动？
    if git diff --quiet && git diff --cached --quiet; then
      continue
    fi

    # 4) 防抖：等 STABLE_WAIT 秒再确认
    sleep "$STABLE_WAIT"
    if git diff --quiet && git diff --cached --quiet; then
      continue
    fi

    # 5) 提交 + 推送
    echo "--- $(date '+%H:%M:%S') 检测到改动 ---"
    do_commit_and_push "" || echo "⚠️  本次 commit 失败，下一轮继续"
  done
}

# =============================================================================
# 主入口
# =============================================================================
main() {
  ensure_repo
  check_author

  case "${1:-}" in
    watch|daemon|--daemon|-d)
      run_watcher
      ;;
    *)
      # 手动模式（向后兼容）
      echo "📂 项目根目录: $PROJECT_ROOT"
      echo ""
      echo "🔎 改动预览："
      git status --short || true
      echo ""
      if git diff --quiet && git diff --cached --quiet; then
        # 工作区干净，但本地可能还有 commit 没 push → 继续往下走
        true
      fi
      local msg="$*"
      local current_branch ahead_count
      current_branch="$(git rev-parse --abbrev-ref HEAD)"

      # 1) 工作区有改动 → 先 commit
      if ! git diff --quiet || ! git diff --cached --quiet; then
        if [[ -z "$msg" ]]; then
          local timestamp changes
          timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
          changes="$(git diff --name-status HEAD 2>/dev/null | head -20 || true)"
          msg="[$timestamp] 自动提交：${changes:-project files}"
        fi
        echo "📝 commit message: $msg"
        git add -A
        git commit -m "$msg"
      else
        echo "ℹ️  工作区干净，跳过 commit"
      fi

      # 2) 本地领先远程 → push（哪怕工作区干净）
      ahead_count="$(git rev-list --count HEAD..origin/$current_branch 2>/dev/null || echo 0)"
      # 注意 rev-list A..B 是 B 有 A 没有的，所以 HEAD..origin 是远程领先
      # 我们要的是本地领先：origin..HEAD
      ahead_count="$(git rev-list --count origin/$current_branch..HEAD 2>/dev/null || echo 0)"
      if [[ "$ahead_count" -gt 0 ]]; then
        echo "🚀 push $current_branch → origin ...（$ahead_count 个 commit 待推送）"
        if do_push "$current_branch"; then
          echo ""
          echo "🎉 推送成功！仓库地址：$REMOTE_URL"
        else
          echo ""
          echo "❌ 推送失败，常见原因："
          echo "   - 没有登录 GitHub：gh auth login 或配置 SSH key"
          echo "   - 远程有新提交：先 git pull --rebase origin $current_branch 再 push"
          exit 1
        fi
      else
        echo "✅ 本地与 origin/$current_branch 同步，无需 push。"
      fi
      ;;
  esac
}

main "$@"
