#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# watch_push.sh — 监控项目文件变动，自动提交并推送到 GitHub
#
# 两种监听模式（自动选择）：
#   1. inotifywait（首选，毫秒级事件驱动，需  sudo apt install inotify-tools）
#   2. 纯 bash 轮询（兜底，每 10 秒 diff 一次 git status）
#
# 防抖：收到事件后等 5 秒再触发 push，期间继续有事件则重新计时。
#
# 用法：
#   ./watch_push.sh                 # 前台运行，Ctrl+C 停止
#   ./watch_push.sh -d              # 后台运行，日志写入 .watch_push.log
#   ./watch_push.sh stop            # 停止后台守护进程
#   ./watch_push.sh status          # 查看后台状态
# -----------------------------------------------------------------------------
set -uo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PUSH_SCRIPT="$PROJECT_ROOT/push.sh"
PID_FILE="$PROJECT_ROOT/.watch_push.pid"
LOG_FILE="$PROJECT_ROOT/.watch_push.log"
DEBOUNCE_SECONDS=5
POLL_INTERVAL=10   # 轮询模式用

# ===== 参数解析 ==============================================================
MODE="foreground"
case "${1:-}" in
  -d|--daemon) MODE="daemon" ;;
  stop)
    if [[ -f "$PID_FILE" ]]; then
      PID="$(cat "$PID_FILE")"
      if kill -0 "$PID" 2>/dev/null; then
        kill "$PID" && rm -f "$PID_FILE"
        echo "✅ 已停止后台 watch_push (pid=$PID)"
      else
        rm -f "$PID_FILE"
        echo "⚠️  pid 文件已过期，已清理"
      fi
    else
      echo "ℹ️  没有运行中的后台进程"
    fi
    exit 0
    ;;
  status)
    if [[ -f "$PID_FILE" ]]; then
      PID="$(cat "$PID_FILE")"
      if kill -0 "$PID" 2>/dev/null; then
        echo "🟢 运行中  pid=$PID  log=$LOG_FILE"
      else
        echo "🔴 已死亡（pid 文件残留）"
        rm -f "$PID_FILE"
      fi
    else
      echo "⚪  未运行"
    fi
    exit 0
    ;;
  "") ;;
  *) echo "用法: $0 [-d] | stop | status"; exit 1 ;;
esac

# ===== 前置检查 ==============================================================
if [[ ! -f "$PUSH_SCRIPT" ]]; then
  echo "❌ 找不到 $PUSH_SCRIPT（本脚本依赖同目录下的 push.sh）"
  exit 1
fi
chmod +x "$PUSH_SCRIPT" 2>/dev/null || true

cd "$PROJECT_ROOT"

# 自动选择监听后端
if command -v inotifywait >/dev/null 2>&1; then
  BACKEND="inotifywait"
else
  BACKEND="polling"
  echo "ℹ️  未检测到 inotifywait → 降级为 ${POLL_INTERVAL}s 轮询模式"
  echo "   如需事件驱动（毫秒级），请执行：sudo apt install inotify-tools"
fi

# ===== 后台模式 ==============================================================
if [[ "$MODE" == "daemon" ]]; then
  if [[ -f "$PID_FILE" ]]; then
    PID="$(cat "$PID_FILE")"
    if kill -0 "$PID" 2>/dev/null; then
      echo "⚠️  已有后台进程在跑 (pid=$PID)，先用  $0 stop  停掉"
      exit 1
    fi
  fi
  nohup "$0" -_run_foreground >"$LOG_FILE" 2>&1 &
  echo $! > "$PID_FILE"
  echo "🟢 已启动后台 watch_push  pid=$(cat "$PID_FILE")  模式=$BACKEND"
  echo "   日志:  tail -f $LOG_FILE"
  echo "   停止:  $0 stop"
  exit 0
fi

# ===== 核心状态 ==============================================================
LAST_EVENT_TS="/tmp/watch_push_last_$$"
LAST_GIT_SNAPSHOT="/tmp/watch_push_git_$$"
: > "$LAST_EVENT_TS"

cleanup() {
  rm -f "$LAST_EVENT_TS" "$LAST_GIT_SNAPSHOT"
  rm -f "$PID_FILE" 2>/dev/null
  echo ""
  echo "🛑 已停止监听"
  exit 0
}
trap cleanup INT TERM

echo "=========================================="
echo "👀  监听目录: $PROJECT_ROOT"
echo "🔧  后端模式: $BACKEND"
echo "⏱️  防抖窗口: ${DEBOUNCE_SECONDS}s"
echo "🚀  触发后调用: push.sh"
echo "Ctrl+C 停止"
echo "=========================================="
echo ""

# ===== 防抖触发循环（两种后端共用） ==========================================
debounce_loop() {
  while true; do
    sleep 2
    LAST_TS="$(cat "$LAST_EVENT_TS" 2>/dev/null || echo 0)"
    NOW="$(date +%s)"
    if [[ -n "$LAST_TS" ]] && [[ "$LAST_TS" -gt 0 ]] \
       && [[ $(( NOW - LAST_TS )) -ge "$DEBOUNCE_SECONDS" ]]; then
      cd "$PROJECT_ROOT"
      if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
        MSG="自动提交 $(date '+%H:%M:%S') $(git diff --name-only HEAD 2>/dev/null | tr '\n' ' ')"
        echo ""
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⏳ 防抖结束 → 自动推送"
        bash "$PUSH_SCRIPT" "$MSG" || echo "⚠️  自动推送失败，下一轮继续尝试"
      fi
      : > "$LAST_EVENT_TS"    # 重置，避免重复触发
    fi
  done
}
debounce_loop &
DEBOUNCE_PID=$!

# ===== 后端 1：inotifywait 事件驱动 ==========================================
if [[ "$BACKEND" == "inotifywait" ]]; then
  inotifywait -m -r -q \
    -e close_write,moved_to,create,delete,delete_self \
    --exclude '(/\.git/|\.watch_push|/build/|/install/|/log/|__pycache__)' \
    --format '%T %w%f %e' \
    --timefmt '%s' \
    "$PROJECT_ROOT" 2>/dev/null | while read -r ts path events; do
    echo "[$(date '+%H:%M:%S')] 📁 ${events}  ${path#$PROJECT_ROOT/}"
    date +%s > "$LAST_EVENT_TS"
  done

# ===== 后端 2：轮询 diff git status ==========================================
else
  git status --porcelain > "$LAST_GIT_SNAPSHOT" 2>/dev/null || true
  while true; do
    sleep "$POLL_INTERVAL"
    cd "$PROJECT_ROOT"
    CUR="$(git status --porcelain 2>/dev/null)"
    PREV="$(cat "$LAST_GIT_SNAPSHOT" 2>/dev/null || true)"
    if [[ "$CUR" != "$PREV" ]]; then
      # 打印哪些文件变了
      DIFF="$(diff -u <(echo "$PREV") <(echo "$CUR") 2>/dev/null | grep '^[+-]' | grep -v '^+++\|^---' | head -20 || true)"
      echo "[$(date '+%H:%M:%S')] 📂 检测到变动"
      [[ -n "$DIFF" ]] && echo "$DIFF" | sed 's/^/   /'
      date +%s > "$LAST_EVENT_TS"
      echo "$CUR" > "$LAST_GIT_SNAPSHOT"
    fi
  done
fi

wait "$DEBOUNCE_PID" 2>/dev/null
