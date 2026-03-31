#!/bin/bash

# 1.13 线程迁移监控
# 用途: 使用 perf 监控目标进程的线程迁移次数
# 使用: ./13_thread_migration.sh <PID> [DURATION]

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 输出文件配置
OUTPUT_DIR="profiler_output"
OUTPUT_TXT="${OUTPUT_DIR}/thread_migration.txt"
OUTPUT_JSON="${OUTPUT_DIR}/thread_migration.json"

# 创建输出目录
mkdir -p $OUTPUT_DIR

# 检查参数
if [ $# -lt 1 ]; then
    echo -e "${RED}错误: 请提供 PID${NC}"
    echo "用法: $0 <PID> [DURATION]"
    echo "  PID       - 目标进程 ID"
    echo "  DURATION  - 监控时长（秒），默认 5"
    exit 1
fi

PID=$1
DURATION=${2:-5}

# 检查进程是否存在
if ! ps -p $PID > /dev/null 2>&1; then
    echo -e "${RED}错误: PID $PID 不存在${NC}"
    exit 1
fi

# 获取进程命令名
PROCESS_NAME=$(ps -p $PID -o comm= 2>/dev/null || echo "Unknown")

# 检查命令
if ! command -v perf &> /dev/null; then
    echo -e "${RED}错误: perf 命令未安装 (属于 linux-tools-common 包)${NC}"
    exit 1
fi

TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}1.13 线程迁移监控${NC}"
echo -e "${GREEN}========================================${NC}"
echo -e "目标进程: ${BLUE}$PID${NC} (${GREEN}$PROCESS_NAME${NC})"
echo -e "监控参数: ${BLUE}时长 ${DURATION} 秒${NC}"
echo ""

# 采集数据
{
    echo "################################################################################"
    echo "# 线程迁移监控 - PID: $PID"
    echo "# 监控时长: ${DURATION} 秒"
    echo "# 开始时间: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "################################################################################"
    echo ""
    echo "说明:"
    echo "  sched:sched_migrate_task - 线程迁移事件，表示线程从一个 CPU 迁移到另一个 CPU"
    echo ""
} > $TEMP_DIR/migration_raw.txt

echo -e "${BLUE}执行命令: perf stat -e sched:sched_migrate_task -p $PID sleep $DURATION${NC}"
timeout $((DURATION + 2)) perf stat -e sched:sched_migrate_task -p $PID sleep $DURATION 2>&1 | tee -a $TEMP_DIR/migration_raw.txt

# 保存原始数据
cp $TEMP_DIR/migration_raw.txt $OUTPUT_TXT

# 解析数据
echo ""
echo -e "${GREEN}解析结果:${NC}"

# 解析迁移次数
MIGRATION_COUNT=$(grep "sched_migrate_task" $TEMP_DIR/migration_raw.txt 2>/dev/null | awk '{print $1}' | sed 's/,//g')

# 如果没有找到，尝试其他格式
if [ -z "$MIGRATION_COUNT" ]; then
    MIGRATION_COUNT=$(grep -E "sched:sched_migrate_task" $TEMP_DIR/migration_raw.txt 2>/dev/null | awk '{print $1}' | sed 's/,//g')
fi

# 确保是数字
MIGRATION_COUNT=$(echo "$MIGRATION_COUNT" | grep -E '^[0-9]+$' || echo "0")

echo -e "${GREEN}线程迁移统计:${NC}"
echo -e "  ${BLUE}•${NC} 迁移事件数: ${GREEN}${MIGRATION_COUNT}${NC}"

# 计算每秒迁移次数
MIGRATIONS_PER_SEC=$(awk "BEGIN {printf \"%.2f\", $MIGRATION_COUNT / $DURATION}")
echo -e "  ${BLUE}•${NC} 迁移速率: ${GREEN}${MIGRATIONS_PER_SEC} 次/秒${NC}"

# 分析迁移频率
echo ""
echo -e "${GREEN}迁移分析:${NC}"

MIGRATION_THRESHOLD_HIGH=100
MIGRATION_THRESHOLD_LOW=10

if [ $MIGRATION_COUNT -gt $MIGRATION_THRESHOLD_HIGH ]; then
    echo -e "  ${RED}⚠${NC} 迁移频率 ${YELLOW}过高${NC} (> ${MIGRATION_THRESHOLD_HIGH} 次)"
    echo -e "     ${YELLOW}建议: 线程频繁迁移可能影响性能，建议检查 CPU 亲和性设置${NC}"
    MIGRATION_LEVEL="high"
elif [ $MIGRATION_COUNT -gt $MIGRATION_THRESHOLD_LOW ]; then
    echo -e "  ${YELLOW}⚠${NC} 迁移频率 ${YELLOW}中等${NC} (> ${MIGRATION_THRESHOLD_LOW} 次)"
    echo -e "     ${YELLOW}建议: 可以考虑优化 CPU 绑定以减少迁移${NC}"
    MIGRATION_LEVEL="medium"
else
    echo -e "  ${GREEN}✓${NC} 迁移频率 ${GREEN}正常${NC} (<= ${MIGRATION_THRESHOLD_LOW} 次)"
    echo -e "     ${GREEN}线程迁移次数在合理范围内${NC}"
    MIGRATION_LEVEL="low"
fi

# 获取线程数用于计算平均每线程迁移次数
THREAD_COUNT=$(ps -L -p $PID -o lwp= 2>/dev/null | grep -c '.' || echo "1")
AVG_MIGRATIONS_PER_THREAD=$(awk "BEGIN {printf \"%.2f\", $MIGRATION_COUNT / $THREAD_COUNT}")

echo -e "  ${BLUE}•${NC} 线程数: ${GREEN}${THREAD_COUNT}${NC}"
echo -e "  ${BLUE}•${NC} 平均每线程迁移: ${GREEN}${AVG_MIGRATIONS_PER_THREAD} 次${NC}"

# 生成 JSON 数据
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
JSON_UNIX_TIME=$(date +%s)

# 输出 JSON
cat > $OUTPUT_JSON << EOF
{
  "timestamp": "$TIMESTAMP",
  "unix_time": $JSON_UNIX_TIME,
  "data_type": "thread_migration",
  "target_pid": $PID,
  "process_name": "$PROCESS_NAME",
  "monitoring": {
    "duration_sec": $DURATION,
    "event": "sched:sched_migrate_task",
    "tool": "perf"
  },
  "statistics": {
    "migration_count": $MIGRATION_COUNT,
    "migrations_per_sec": $MIGRATIONS_PER_SEC,
    "thread_count": $THREAD_COUNT,
    "avg_migrations_per_thread": $AVG_MIGRATIONS_PER_THREAD
  },
  "analysis": {
    "migration_level": "$MIGRATION_LEVEL",
    "threshold_high": $MIGRATION_THRESHOLD_HIGH,
    "threshold_low": $MIGRATION_THRESHOLD_LOW,
    "needs_optimization": $([ "$MIGRATION_LEVEL" = "high" ] && echo "true" || echo "false")
  }
}
EOF

echo ""
echo -e "${GREEN}文件已保存:${NC}"
echo -e "  ${BLUE}•${NC} 原始数据: ${GREEN}$OUTPUT_TXT${NC}"
echo -e "  ${BLUE}•${NC} JSON 数据: ${GREEN}$OUTPUT_JSON${NC}"

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}采集完成${NC}"
echo -e "${GREEN}========================================${NC}"
