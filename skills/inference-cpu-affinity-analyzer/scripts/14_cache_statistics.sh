#!/bin/bash

# 1.14 缓存性能统计
# 用途: 使用 perf 监控目标进程的缓存性能（L1/L2/L3）
# 使用: ./14_cache_statistics.sh <PID> [DURATION]

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 输出文件配置
OUTPUT_DIR="profiler_output"
OUTPUT_TXT="${OUTPUT_DIR}/cache_statistics.txt"
OUTPUT_JSON="${OUTPUT_DIR}/cache_statistics.json"

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
echo -e "${GREEN}1.14 缓存性能统计${NC}"
echo -e "${GREEN}========================================${NC}"
echo -e "目标进程: ${BLUE}$PID${NC} (${GREEN}$PROCESS_NAME${NC})"
echo -e "监控参数: ${BLUE}时长 ${DURATION} 秒${NC}"
echo ""

# 采集数据
{
    echo "################################################################################"
    echo "# 缓存性能统计 - PID: $PID"
    echo "# 监控时长: ${DURATION} 秒"
    echo "# 开始时间: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "################################################################################"
    echo ""
    echo "监控事件:"
    echo "  cache-references      - 总缓存引用次数"
    echo "  cache-misses          - 缓存未命中次数"
    echo "  L1-dcache-loads       - L1 数据缓存加载次数"
    echo "  L1-dcache-load-misses - L1 数据缓存未命中次数"
    echo "  LLC-loads             - LLC (L3) 加载次数"
    echo "  LLC-load-misses       - LLC (L3) 加载未命中次数"
    echo "  LLC-stores            - LLC (L3) 存储次数"
    echo "  LLC-store-misses      - LLC (L3) 存储未命中次数"
    echo ""
} > $TEMP_DIR/cache_raw.txt

echo -e "${BLUE}执行命令: perf stat -e cache-references,cache-misses,... -p $PID sleep $DURATION${NC}"
timeout $((DURATION + 2)) perf stat -e cache-references,cache-misses,L1-dcache-loads,L1-dcache-load-misses,LLC-loads,LLC-load-misses,LLC-stores,LLC-store-misses -p $PID sleep $DURATION 2>&1 | tee -a $TEMP_DIR/cache_raw.txt

# 保存原始数据
cp $TEMP_DIR/cache_raw.txt $OUTPUT_TXT

# 解析数据
echo ""
echo -e "${GREEN}解析结果:${NC}"

# 解析函数
extract_perf_value() {
    local event=$1
    local value=$(grep "$event" $TEMP_DIR/cache_raw.txt 2>/dev/null | awk '{print $1}' | sed 's/,//g' | grep -E '^[0-9]+$' || echo "0")
    echo $value
}

# 获取各项指标
CACHE_REFS=$(extract_perf_value "cache-references")
CACHE_MISSES=$(extract_perf_value "cache-misses")
L1_LOADS=$(extract_perf_value "L1-dcache-loads")
L1_MISSES=$(extract_perf_value "L1-dcache-load-misses")
LLC_LOADS=$(extract_perf_value "LLC-loads")
LLC_LOAD_MISSES=$(extract_perf_value "LLC-load-misses")
LLC_STORES=$(extract_perf_value "LLC-stores")
LLC_STORE_MISSES=$(extract_perf_value "LLC-store-misses")

# 计算命中率
if [ $CACHE_REFS -gt 0 ]; then
    CACHE_HIT_RATE=$(awk "BEGIN {printf \"%.2f\", (1 - $CACHE_MISSES / $CACHE_REFS) * 100}")
else
    CACHE_HIT_RATE="0.00"
fi

if [ $L1_LOADS -gt 0 ]; then
    L1_HIT_RATE=$(awk "BEGIN {printf \"%.2f\", (1 - $L1_MISSES / $L1_LOADS) * 100}")
else
    L1_HIT_RATE="0.00"
fi

if [ $LLC_LOADS -gt 0 ]; then
    LLC_HIT_RATE=$(awk "BEGIN {printf \"%.2f\", (1 - $LLC_LOAD_MISSES / $LLC_LOADS) * 100}")
else
    LLC_HIT_RATE="0.00"
fi

if [ $LLC_STORES -gt 0 ]; then
    LLC_STORE_HIT_RATE=$(awk "BEGIN {printf \"%.2f\", (1 - $LLC_STORE_MISSES / $LLC_STORES) * 100}")
else
    LLC_STORE_HIT_RATE="0.00"
fi

# 显示结果
echo -e "${GREEN}缓存性能统计:${NC}"
echo -e "  ${BLUE}•${NC} 总缓存引用: ${GREEN}${CACHE_REFS}${NC}"
echo -e "  ${BLUE}•${NC} 总缓存未命中: ${GREEN}${CACHE_MISSES}${NC}"
echo -e "  ${BLUE}•${NC} 总缓存命中率: ${GREEN}${CACHE_HIT_RATE}%${NC}"

echo ""
echo -e "${GREEN}L1 数据缓存:${NC}"
echo -e "  ${BLUE}•${NC} 加载次数: ${GREEN}${L1_LOADS}${NC}"
echo -e "  ${BLUE}•${NC} 未命中次数: ${GREEN}${L1_MISSES}${NC}"
echo -e "  ${BLUE}•${NC} 命中率: ${GREEN}${L1_HIT_RATE}%${NC}"

echo ""
echo -e "${GREEN}LLC (L3) 缓存 - 加载:${NC}"
echo -e "  ${BLUE}•${NC} 加载次数: ${GREEN}${LLC_LOADS}${NC}"
echo -e "  ${BLUE}•${NC} 未命中次数: ${GREEN}${LLC_LOAD_MISSES}${NC}"
echo -e "  ${BLUE}•${NC} 命中率: ${GREEN}${LLC_HIT_RATE}%${NC}"

echo ""
echo -e "${GREEN}LLC (L3) 缓存 - 存储:${NC}"
echo -e "  ${BLUE}•${NC} 存储次数: ${GREEN}${LLC_STORES}${NC}"
echo -e "  ${BLUE}•${NC} 未命中次数: ${GREEN}${LLC_STORE_MISSES}${NC}"
echo -e "  ${BLUE}•${NC} 命中率: ${GREEN}${LLC_STORE_HIT_RATE}%${NC}"

# 分析缓存性能
echo ""
echo -e "${GREEN}缓存性能分析:${NC}"

# LLC Miss 率分析
LLC_MISS_THRESHOLD=20
if [ $(awk "BEGIN {print $LLC_HIT_RATE < (100 - $LLC_MISS_THRESHOLD)}") -eq 1 ]; then
    echo -e "  ${RED}⚠${NC} LLC Miss 率过高 (> ${LLC_MISS_THRESHOLD}%)"
    echo -e "     ${YELLOW}建议: 存在缓存争用，建议检查是否有其他进程占用相同缓存域${NC}"
    CACHE_CONTENTION="true"
else
    echo -e "  ${GREEN}✓${NC} LLC Miss 率正常 (< ${LLC_MISS_THRESHOLD}%)"
    CACHE_CONTENTION="false"
fi

# L1 命中率分析
L1_HIT_THRESHOLD=90
if [ $(awk "BEGIN {print $L1_HIT_RATE < $L1_HIT_THRESHOLD}") -eq 1 ]; then
    echo -e "  ${YELLOW}⚠${NC} L1 命中率较低 (< ${L1_HIT_THRESHOLD}%)"
    echo -e "     ${YELLOW}建议: 检查内存访问模式，可能存在缓存不友好的访问${NC}"
else
    echo -e "  ${GREEN}✓${NC} L1 命中率良好 (>= ${L1_HIT_THRESHOLD}%)"
fi

# 生成 JSON 数据
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
JSON_UNIX_TIME=$(date +%s)

# 输出 JSON
cat > $OUTPUT_JSON << EOF
{
  "timestamp": "$TIMESTAMP",
  "unix_time": $JSON_UNIX_TIME,
  "data_type": "cache_statistics",
  "target_pid": $PID,
  "process_name": "$PROCESS_NAME",
  "monitoring": {
    "duration_sec": $DURATION,
    "tool": "perf"
  },
  "total_cache": {
    "references": $CACHE_REFS,
    "misses": $CACHE_MISSES,
    "hit_rate_percent": $CACHE_HIT_RATE
  },
  "l1_dcache": {
    "loads": $L1_LOADS,
    "load_misses": $L1_MISSES,
    "hit_rate_percent": $L1_HIT_RATE
  },
  "llc_cache": {
    "loads": $LLC_LOADS,
    "load_misses": $LLC_LOAD_MISSES,
    "load_hit_rate_percent": $LLC_HIT_RATE,
    "stores": $LLC_STORES,
    "store_misses": $LLC_STORE_MISSES,
    "store_hit_rate_percent": $LLC_STORE_HIT_RATE
  },
  "analysis": {
    "llc_miss_threshold": $LLC_MISS_THRESHOLD,
    "cache_contention": $CACHE_CONTENTION
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
