#!/bin/bash
# ====================================
# 脚本名称: collect_process_affinity_info.sh
# ====================================
#
# 功能概述:
#   收集指定进程的CPU亲和性状态和线程分布信息
#   支持多进程PID列表，可检测SMT冲突
#
# 依赖工具:
#   - taskset (系统自带)
#   - ps (系统自带)
#   - lscpu (系统自带)
#   - numactl (需安装)
#
# 参数:
#   $1 - PID列表（逗号分隔，如: 12345,23456）
#
# 输出:
#   stdout输出每个进程的线程亲和性信息
#
# 使用场景:
#   - 诊断阶段收集现有进程的绑核状态
#   - 检测SMT场景下的物理核冲突
#   - 绑核前备份当前状态用于回滚
#
# ====================================

PID_LIST=$1

if [ -z "$PID_LIST" ]; then
    echo "错误: 请提供PID列表"
    echo "用法: $0 <PID列表>"
    echo "示例: $0 12345,23456"
    exit 1
fi

# 检测SMT状态
THREADS_PER_CORE=$(lscpu | grep "Thread(s) per core" | awk '{print $NF}')

# 将逗号分隔的PID列表转换为空格分隔
PID_LIST=$(echo $PID_LIST | tr ',' ' ')

# 绑定总览（如已有绑定）
for pid in $PID_LIST; do
  echo "=== PID: $pid ==="

  # 检查进程是否存在
  if ! ps -p $pid > /dev/null 2>&1; then
    echo "错误: 进程 $pid 不存在"
    echo ""
    continue
  fi

  taskset -cp $pid 2>/dev/null || echo "未检测到当前绑定"

  # 检查是否有同一物理核的不同虚拟核被占用的情况
  if [ "$THREADS_PER_CORE" -gt 1 ]; then
    echo "=== 线程亲和性详情 ==="
    for tid in $(ps -T -p $pid -o tid --no-headers); do
      affinity=$(taskset -pc $tid 2>/dev/null | tail -1 | awk '{print $NF}')
      echo "  线程 $tid -> $affinity"
    done
  fi

  # 更新后的进程线程信息
  echo "=== PID: $pid 线程信息 ==="
  ps -L -p $pid -o pid,tid,psr,comm
  echo "=== NUMA亲和性 ==="
  numactl -p $pid 2>/dev/null || echo "无NUMA绑定信息"

  echo "=== 线程绑核冲突检测（SMT场景）==="
  if [ "$THREADS_PER_CORE" -gt 1 ]; then
    # 检测同一进程内是否存在线程绑定到同一物理核的不同虚拟核
    declare -A phy_core_usage
    for tid in $(ps -T -p $pid -o tid --no-headers); do
      affinity=$(taskset -cp $tid 2>/dev/null | tail -1 | awk '{print $NF}')
      phy_core=$(lscpu -p=CPU,CORE | awk -F, -v cpu="$affinity" '$1 == cpu {print $2}')
      if [ -n "$phy_core" ]; then
        if [ -n "${phy_core_usage[$phy_core]}" ]; then
          echo "  ⚠ 警告：线程 ${phy_core_usage[$phy_core]} 和 $tid 竞争同一物理核 $phy_core（SMT冲突）"
        else
          phy_core_usage[$phy_core]=$tid
        fi
      fi
    done
    [ ${#phy_core_usage[@]} -eq 0 ] && echo "  未检测到SMT冲突"
  fi
  echo ""
done
