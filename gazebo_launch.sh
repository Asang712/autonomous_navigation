#!/usr/bin/env bash
set -e

LOG_DIR="$HOME/nav2_logs/$(date +%Y%m%d_%H%M%S)"
mkdir -p "$LOG_DIR"

echo ">>> 启动 Gazebo ..."
ros2 launch turtlebot3_gazebo turtlebot3_house.launch.py \
  > "$LOG_DIR/gazebo.log" 2>&1 &
echo $! > "$LOG_DIR/gazebo.pid"
sleep 5
echo ">>> Gazebo PID: $(cat "$LOG_DIR/gazebo.pid")"
echo ">>> 日志在 $LOG_DIR"
echo ">>> 关闭：kill $(cat "$LOG_DIR/gazebo.pid")"