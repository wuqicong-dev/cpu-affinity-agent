#!/bin/bash

# 1.16 内存带宽监控
# 用途: 使用 perf 监控目标进程的内存带宽使用情况
# 使用: ./16_memory_bandwidth.sh <PID> [DURATION]

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 输出文件配置
OUTPUT_DIR="profiler_output"
OUTPUT_TXT="${OUTPUT_DIR}/memory_bandwidth.txt"
OUTPUT_JSON="${OUTPUT_DIR}/memory_bandwidth.json"

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
echo -e "${GREEN}1.16 内存带宽监控${NC}"
echo -e "${GREEN}========================================${NC}"
echo -e "目标进程: ${BLUE}$PID${NC} (${GREEN}$PROCESS_NAME${NC})"
echo -e "监控参数: ${BLUE}时长 ${DURATION} 秒${NC}"
echo ""

# 采集数据
{
    echo "################################################################################"
    echo "# 内存带宽监控 - PID: $PID"
    echo "# 监控时长: ${DURATION} 秒"
    echo "# 开始时间: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "################################################################################"
    echo ""
    echo "监控事件 (Intel CPU 内存带宽事件):"
    echo "  cpu/event=0xd1,umask=0x01/  - 内存读取次数"
    echo "  cpu/event=0xd1,umask=0x02/  - 内存写入次数"
    echo "  cpu/event=0xd1,umask=0x04/  - 内存读取时间（周期）"
    echo "  cpu/event=0xd1,umask=0x08/  - 内存写入时间（周期）"
    echo ""
} > $TEMP_DIR/bandwidth_raw.txt

echo -e "${BLUE}执行命令: perf stat -e cpu/event=0xd1,umask=0x01/,... -p $PID sleep $DURATION${NC}"
timeout $((DURATION + 2)) perf stat -e cpu/event=0xd1,umask=0x01/,cpu/event=0xd1,umask=0x02/,cpu/event=0xd1,umask=0x04/,cpu/event=0xd1,umask=0x08/ -p $PID sleep $DURATION 2>&1 | tee -a $TEMP_DIR/bandwidth_raw.txt

# 保存原始数据
cp $TEMP_DIR/bandwidth_raw.txt $OUTPUT_TXT

# 解析数据
echo ""
echo -e "${GREEN}解析结果:${NC}"

# 解析 perf 输出中的内存事件
# perf stat 输出格式: event_name 或 raw event code
# 我们需要尝试多种格式来提取数据

# 方法1: 尝试匹配原始事件码
MEM_READS=$(grep "cpu/event=0xd1,umask=0x01/" $TEMP_DIR/bandwidth_raw.txt 2>/dev/null | awk '{print $1}' | sed 's/,//g' | grep -E '^[0-9]+$' || echo "0")
# 如果没找到，尝试匹配 <event_name> 格式
if [ "$MEM_READS" = "0" ]; then
    MEM_READS=$(grep -E "mem-loads|MEM_LOAD_RETIRED" $TEMP_DIR/bandwidth_raw.txt 2>/dev/null | awk '{print $1}' | sed 's/,//g' | grep -E '^[0-9]+$' || echo "0")
fi

MEM_WRITES=$(grep "cpu/event=0xd1,umask=0x02/" $TEMP_DIR/bandwidth_raw.txt 2>/dev/null | awk '{print $1}' | sed 's/,//g' | grep -E '^[0-9]+$' || echo "0")
if [ "$MEM_WRITES" = "0" ]; then
    MEM_WRITES=$(grep -E "mem-stores|MEM_INST_RETIRED" $TEMP_DIR/bandwidth_raw.txt 2>/dev/null | awk '{print $1}' | sed 's/,//g' | grep -E '^[0-9]+$' || echo "0")
fi

MEM_READ_TIME=$(grep "cpu/event=0xd1,umask=0x04/" $TEMP_DIR/bandwidth_raw.txt 2>/dev/null | awk '{print $1}' | sed 's/,//g' | grep -E '^[0-9]+$' || echo "0")
if [ "$MEM_READ_TIME" = "0" ]; then
    MEM_READ_TIME=$(grep -E "mem-read-cycles|MEM_LOAD_UOPS_RETIRED" $TEMP_DIR/bandwidth_raw.txt 2>/dev/null | awk '{print $1}' | sed 's/,//g' | grep -E '^[0-9]+$' || echo "0")
fi

MEM_WRITE_TIME=$(grep "cpu/event=0xd1,umask=0x08/" $TEMP_DIR/bandwidth_raw.txt 2>/dev/null | awk '{print $1}' | sed 's/,//g' | grep -E '^[0-9]+$' || echo "0")
if [ "$MEM_WRITE_TIME" = "0" ]; then
    MEM_WRITE_TIME=$(grep -E "mem-write-cycles|MEM_INST_RETIRED" $TEMP_DIR/bandwidth_raw.txt 2>/dev/null | awk '{print $1}' | sed 's/,//g' | grep -E '^[0-9]+$' || echo "0")
fi

# 如果所有方法都失败，尝试提取所有数字（作为最后手段）
if [ "$MEM_READS" = "0" ] && [ "$MEM_WRITES" = "0" ]; then
    # 提取 perf 输出中的所有数字行（排除标题）
    VALUES=$(grep -E "^[0-9]+[[:space:]]+" $TEMP_DIR/bandwidth_raw.txt 2>/dev/null | awk '{print $1}' | sed 's/,//g')
    VALUE_COUNT=$(echo "$VALUES" | grep -c '^[0-9]$' || echo "0")

    if [ "$VALUE_COUNT" -ge 4 ]; then
        # 假设按顺序是 reads, writes, read_time, write_time
        MEM_READS=$(echo "$VALUES" | sed -n '1p')
        MEM_WRITES=$(echo "$VALUES" | sed -n '2p')
        MEM_READ_TIME=$(echo "$VALUES" | sed -n '3p')
        MEM_WRITE_TIME=$(echo "$VALUES" | sed -n '4p')
    fi
fi

# 显示结果
echo -e "${GREEN}内存带宽统计:${NC}"
echo -e "  ${BLUE}•${NC} 内存读取次数: ${GREEN}${MEM_READS}${NC}"
echo -e "  ${BLUE}•${NC} 内存写入次数: ${GREEN}${MEM_WRITES}${NC}"
echo -e "  ${BLUE}•${NC} 内存读取周期: ${GREEN}${MEM_READ_TIME}${NC}"
echo -e "  ${BLUE}•${NC} 内存写入周期: ${GREEN}${MEM_WRITE_TIME}${NC}"

# 计算总内存操作
TOTAL_MEM_OPS=$((MEM_READS + MEM_WRITES))
TOTAL_MEM_TIME=$((MEM_READ_TIME + MEM_WRITE_TIME))

echo ""
echo -e "${GREEN}内存操作统计:${NC}"
echo -e "  ${BLUE}•${NC} 总内存操作: ${GREEN}${TOTAL_MEM_OPS}${NC}"
echo -e "  ${BLUE}•${NC} 总内存周期: ${GREEN}${TOTAL_MEM_TIME}${NC}"

# 计算速率（每秒）
if [ $DURATION -gt 0 ]; then
    READS_PER_SEC=$(awk "BEGIN {printf \"%.0f\", $MEM_READS / $DURATION}")
    WRITES_PER_SEC=$(awk "BEGIN {printf \"%.0f\", $MEM_WRITES / $DURATION}")
    OPS_PER_SEC=$(awk "BEGIN {printf \"%.0f\", $TOTAL_MEM_OPS / $DURATION}")

    echo ""
    echo -e "${GREEN}内存操作速率:${NC}"
    echo -e "  ${BLUE}•${NC} 读取速率: ${GREEN}${READS_PER_SEC}${NC} 次/秒"
    echo -e "  ${BLUE}•${NC} 写入速率: ${GREEN}${WRITES_PER_SEC}${NC} 次/秒"
    echo -e "  ${BLUE}•${NC} 总操作速率: ${GREEN}${OPS_PER_SEC}${NC} 次/秒"
else
    READS_PER_SEC=0
    WRITES_PER_SEC=0
    OPS_PER_SEC=0
fi

# 计算读写比例
if [ $MEM_WRITES -gt 0 ]; then
    RW_RATIO=$(awk "BEGIN {printf \"%.2f\", $MEM_READS / $MEM_WRITES}")
else
    RW_RATIO="inf"
fi

echo ""
echo -e "${GREEN}内存访问模式:${NC}"
echo -e "  ${BLUE}•${NC} 读/写比例: ${GREEN}${RW_RATIO}${NC}"

if [ $(awk "BEGIN {print $RW_RATIO > 10}") -eq 1 ]; then
    echo -e "    ${GREEN}读密集型${NC}（读取远多于写入）"
elif [ $(awk "BEGIN {print $RW_RATIO < 0.1}") -eq 1 ]; then
    echo -e "    ${GREEN}写密集型${NC}（写入远多于读取）"
else
    echo -e "    ${GREEN}读写均衡${NC}"
fi

# 分析内存带宽压力
echo ""
echo -e "${GREEN}内存带宽分析:${NC}"

# 根据操作速率判断压力
# 阈值：每秒 100万次操作为高压力
HIGH_THRESHOLD=1000000
MEDIUM_THRESHOLD=100000

if [ $(awk "BEGIN {print $OPS_PER_SEC >= $HIGH_THRESHOLD}") -eq 1 ]; then
    echo -e "  ${RED}⚠${NC} 内存带宽压力 ${YELLOW}过高${NC} (>= ${HIGH_THRESHOLD} 次/秒)"
    echo -e "     ${YELLOW}建议: 内存带宽成为瓶颈，建议优化内存访问模式或增加内存带宽${NC}"
    BANDWIDTH_PRESSURE="high"
elif [ $(awk "BEGIN {print $OPS_PER_SEC >= $MEDIUM_THRESHOLD}") -eq 1 ]; then
    echo -e "  ${YELLOW}⚠${NC} 内存带宽压力 ${YELLOW}中等${NC} (>= ${MEDIUM_THRESHOLD} 次/秒)"
    BANDWIDTH_PRESSURE="medium"
else
    echo -e "  ${GREEN}✓${NC} 内存带宽压力 ${GREEN}正常${NC} (< ${MEDIUM_THRESHOLD} 次/秒)"
    BANDWIDTH_PRESSURE="low"
fi

# 生成 JSON 数据
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
JSON_UNIX_TIME=$(date +%s)

# 输出 JSON
cat > $OUTPUT_JSON << EOF
{
  "timestamp": "$TIMESTAMP",
  "unix_time": $JSON_UNIX_TIME,
  "data_type": "memory_bandwidth",
  "target_pid": $PID,
  "process_name": "$PROCESS_NAME",
  "monitoring": {
    "duration_sec": $DURATION,
    "tool": "perf"
  },
  "operations": {
    "reads": $MEM_READS,
    "writes": $MEM_WRITES,
    "total": $TOTAL_MEM_OPS,
    "read_write_ratio": $RW_RATIO
  },
  "cycles": {
    "read_cycles": $MEM_READ_TIME,
    "write_cycles": $MEM_WRITE_TIME,
    "total_cycles": $TOTAL_MEM_TIME
  },
  "rates": {
    "reads_per_sec": $READS_PER_SEC,
    "writes_per_sec": $WRITES_PER_SEC,
    "total_ops_per_sec": $OPS_PER_SEC
  },
  "analysis": {
    "bandwidth_pressure": "$BANDWIDTH_PRESSURE",
    "threshold_high": $HIGH_THRESHOLD,
    "threshold_medium": $MEDIUM_THRESHOLD
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
