#!/bin/bash
# ====================================
# 脚本名称: backup_and_rollback.sh
# ====================================
#
# 功能概述:
#   绑核前备份当前亲和性设置，提供回滚功能
#   支持单进程和多进程场景，备份进程和线程的绑核状态
#
# 依赖工具:
#   - ps (系统自带)
#   - taskset (系统自带)
#
# 参数:
#   backup <PID列表> - 备份指定进程的绑核状态
#   rollback <PID列表> [<总核心数>] - 回滚指定进程到无绑核状态
#
# 输出:
#   backup: 输出备份文件路径
#   rollback: 输出回滚操作结果
#
# 使用场景:
#   - 绑核前自动备份当前状态，用于故障回滚
#   - 绑核失败时回滚到绑定前的状态
#   - 在多进程绑核场景下统一管理备份和回滚
#
# ====================================

ACTION=$1
PID_LIST=$2
TOTAL_CORES=$3

if [ "$ACTION" != "backup" ] && [ "$ACTION" != "rollback" ]; then
    echo "错误: 无效的动作"
    echo "用法: $0 <backup|rollback> <PID列表> [总核心数]"
    echo ""
    echo "示例:"
    echo "  备份: $0 backup 12345,23456"
    echo "  回滚: $0 rollback 12345,23456 64"
    exit 1
fi

if [ -z "$PID_LIST" ]; then
    echo "错误: 请提供PID列表"
    exit 1
fi

PID_LIST=$(echo $PID_LIST | tr ',' ' ')
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# 绑核前自动备份
backup_affinity() {
  local backup_file="affinity_backup_${TIMESTAMP}.txt"
  echo "绑核前备份当前亲和性设置到 $backup_file"

  for pid in $PID_LIST; do
    if ps -p $pid > /dev/null 2>&1; then
      echo "=== PID: $pid ===" >> "$backup_file"
      # 备份主进程绑核
      taskset -cp $pid 2>/dev/null >> "$backup_file" || echo "未绑核" >> "$backup_file"
      # 备份线程绑核
      ps -T -p $pid -o tid,psr,comm >> "$backup_file"
      echo "" >> "$backup_file"

      echo "✓ PID $pid 的绑核状态已备份"
    else
      echo "警告: PID $pid 不存在，跳过" >> "$backup_file"
      echo "⚠ 警告: PID $pid 不存在，跳过"
      echo "" >> "$backup_file"
    fi
  done

  chmod 600 "$backup_file"
  echo "$backup_file"
}

# 回滚函数
rollback_affinity() {
  if [ -z "$TOTAL_CORES" ]; then
    echo "错误: 回滚时需要指定总核心数"
    echo "用法: $0 rollback <PID列表> <总核心数>"
    echo "示例: $0 rollback 12345,23456 64"
    exit 1
  fi

  echo "执行回滚操作..."
  local success=true

  for pid in $PID_LIST; do
    if ps -p $pid > /dev/null 2>&1; then
      echo "重置进程 $pid 的绑核状态"
      # 重置为无绑核状态
      taskset -cp 0-$(($TOTAL_CORES-1)) $pid 2>/dev/null && \
        echo "  ✓ 主进程绑核已重置" || \
        (echo "  ✗ 主进程绑核重置失败" && success=false)

      # 重置所有线程绑定
      local tid_count=0
      local tid_fail=0
      for tid in $(ps -T -p $pid -o tid --no-headers); do
        taskset -cp 0-$(($TOTAL_CORES-1)) $tid 2>/dev/null && ((tid_count++)) || ((tid_fail++))
      done
      echo "  ✓ 线程绑核已重置 (成功: $tid_count, 失败: $tid_fail)"
    else
      echo "⚠ 进程 $pid 不存在，跳过"
    fi
  done

  if [ "$success" = true ]; then
    echo ""
    echo "✓ 回滚完成，所有进程已重置为无绑核状态"
  else
    echo ""
    echo "⚠ 回滚过程中部分操作失败，请检查上述输出"
  fi
}

# 执行操作
case $ACTION in
  backup)
    backup_affinity
    ;;
  rollback)
    rollback_affinity
    ;;
