#!/bin/bash

# 1.15 系统缓存统计
# 用途: 使用 cachestat 监控系统级缓存行为
# 使用: ./15_cachestat.sh [INTERVAL] [COUNT]

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 输出文件配置
OUTPUT_DIR="profiler_output"
OUTPUT_TXT="${OUTPUT_DIR}/cachestat.txt"
OUTPUT_JSON="${OUTPUT_DIR}/cachestat.json"

# 创建输出目录
mkdir -p $OUTPUT_DIR

# 检查参数
INTERVAL=${1:-1}
COUNT=${2:-5}

TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}1.15 系统缓存统计${NC}"
echo -e "${GREEN}========================================${NC}"
echo -e "采样参数: ${BLUE}间隔 ${INTERVAL} 秒, ${COUNT} 次采样${NC}"
echo ""

# 检查命令
USE_CACHESTAT=false
CACHESTAT_CMD=""

if command -v cachestat &> /dev/null; then
    USE_CACHESTAT=true
    CACHESTAT_CMD="cachestat"
    echo -e "${BLUE}使用 cachestat 命令...${NC}"
elif [ -f /usr/share/bcc/tools/cachestat ]; then
    USE_CACHESTAT=true
    CACHESTAT_CMD="/usr/share/bcc/tools/cachestat"
    echo -e "${BLUE}使用 /usr/share/bcc/tools/cachestat...${NC}"
else
    echo -e "${YELLOW}警告: cachestat 命令未安装${NC}"
    echo -e "${BLUE}提示: cachestat 包含在 bcc-tools 包中${NC}"
    echo ""
fi

# 采集数据
{
    echo "################################################################################"
    echo "# 系统缓存统计 (cachestat)"
    echo "# 采样间隔: ${INTERVAL} 秒, 采样次数: ${COUNT} 次"
    echo "# 开始时间: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "################################################################################"
    echo ""
    echo "说明:"
    echo "  TOTAL    - 总缓存访问次数"
    echo "  MISSES   - 缓存未命中次数"
    echo "  HIT%     - 缓存命中率"
    echo "  DTLB     - 数据 TLB"
    echo "  ITLB     - 指令 TLB"
    echo ""
} > $TEMP_DIR/cachestat_raw.txt

if [ "$USE_CACHESTAT" = true ]; then
    echo -e "${BLUE}执行命令: $CACHESTAT_CMD $INTERVAL $COUNT${NC}"
    timeout $((INTERVAL * COUNT + 2)) $CACHESTAT_CMD $INTERVAL $COUNT 2>/dev/null | tee -a $TEMP_DIR/cachestat_raw.txt
else
    echo "cachestat 不可用" >> $TEMP_DIR/cachestat_raw.txt
fi

# 保存原始数据
cp $TEMP_DIR/cachestat_raw.txt $OUTPUT_TXT

# 解析数据
echo ""
echo -e "${GREEN}解析结果:${NC}"

if [ "$USE_CACHESTAT" = false ]; then
    echo -e "${YELLOW}无法解析（cachestat 不可用）${NC}"

    # 输出空 JSON
    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
    JSON_UNIX_TIME=$(date +%s)

    cat > $OUTPUT_JSON << EOF
{
  "timestamp": "$TIMESTAMP",
  "unix_time": $JSON_UNIX_TIME,
  "data_type": "cachestat",
  "available": false,
  "error": "cachestat command not found"
}
EOF

    echo ""
    echo -e "${GREEN}文件已保存:${NC}"
    echo -e "  ${BLUE}•${NC} 原始数据: ${GREEN}$OUTPUT_TXT${NC}"
    echo -e "  ${BLUE}•${NC} JSON 数据: ${GREEN}$OUTPUT_JSON${NC}"
    exit 0
fi

# 解析 cachestat 输出
# cachestat 输出格式示例:
#   TOTAL    MISSES     HIT%     DTLB    iTLB
#   1234567  123456     90.0%    99.5%    98.2%

PARSED_DATA=$TEMP_DIR/parsed_data.txt

# 跳过标题行和空行，提取数据行
grep -E '^[0-9]' $TEMP_DIR/cachestat_raw.txt > $PARSED_DATA 2>/dev/null || true

SAMPLE_COUNT=$(wc -l < $PARSED_DATA 2>/dev/null | tr -d ' ')

if [ "$SAMPLE_COUNT" -eq 0 ]; then
    echo -e "${YELLOW}未获取到有效数据${NC}"
    exit 0
fi

echo -e "${GREEN}采样数据 (${SAMPLE_COUNT} 次采样):${NC}"
echo ""
echo "    总访问      未命中     命中率    DTLB命中率  iTLB命中率"

# 解析并显示每次采样
awk '{
    total = $1
    misses = $2
    hit_rate = $3
    dtlb = $4
    itlb = $5

    printf "    %-10s  %-9s  %-8s  %-10s  %s\n", total, misses, hit_rate, dtlb, itlb
}' $PARSED_DATA

# 计算平均值
AVG_TOTAL=$(awk '{sum+=$1} END {printf "%.0f", sum/NR}' $PARSED_DATA)
AVG_MISSES=$(awk '{sum+=$2} END {printf "%.0f", sum/NR}' $PARSED_DATA)

# 提取命中率（去掉百分号）
AVG_HIT_RATE=$(awk '{
    gsub(/%/, "", $3)
    sum+=$3
} END {
    printf "%.2f", sum/NR
}' $PARSED_DATA)

AVG_DTLB=$(awk '{
    gsub(/%/, "", $4)
    sum+=$4
} END {
    printf "%.2f", sum/NR
}' $PARSED_DATA)

AVG_ITLB=$(awk '{
    gsub(/%/, "", $5)
    sum+=$5
} END {
    printf "%.2f", sum/NR
}' $PARSED_DATA)

echo ""
echo -e "${GREEN}平均统计:${NC}"
echo -e "  ${BLUE}•${NC} 平均总访问: ${GREEN}${AVG_TOTAL}${NC}"
echo -e "  ${BLUE}•${NC} 平均未命中: ${GREEN}${AVG_MISSES}${NC}"
echo -e "  ${BLUE}•${NC} 平均命中率: ${GREEN}${AVG_HIT_RATE}%${NC}"
echo -e "  ${BLUE}•${NC} 平均 DTLB 命中率: ${GREEN}${AVG_DTLB}%${NC}"
echo -e "  ${BLUE}•${NC} 平均 iTLB 命中率: ${GREEN}${AVG_ITLB}%${NC}"

# 分析缓存行为
echo ""
echo -e "${GREEN}缓存行为分析:${NC}"

# 命中率分析
if [ $(awk "BEGIN {print $AVG_HIT_RATE < 80}") -eq 1 ]; then
    echo -e "  ${RED}⚠${NC} 系统缓存命中率较低 (< 80%)"
    echo -e "     ${YELLOW}建议: 可能存在缓存压力，建议检查系统负载${NC}"
    CACHE_PRESSURE="high"
elif [ $(awk "BEGIN {print $AVG_HIT_RATE < 90}") -eq 1 ]; then
    echo -e "  ${YELLOW}⚠${NC} 系统缓存命中率中等 (80-90%)"
    CACHE_PRESSURE="medium"
else
    echo -e "  ${GREEN}✓${NC} 系统缓存命中率良好 (>= 90%)"
    CACHE_PRESSURE="low"
fi

# TLB 命中率分析
if [ $(awk "BEGIN {print $AVG_DTLB < 95}") -eq 1 ]; then
    echo -e "  ${YELLOW}⚠${NC} DTLB 命中率较低 (< 95%)"
    echo -e "     ${YELLOW}建议: 可能存在大量页表遍历，影响性能${NC}"
else
    echo -e "  ${GREEN}✓${NC} DTLB 命中率良好 (>= 95%)"
fi

# 生成 JSON 数据
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
JSON_UNIX_TIME=$(date +%s)

# 构建采样数据 JSON
SAMPLES_JSON=""
awk '{
    total = $1
    misses = $2
    gsub(/%/, "", $3)
    hit_rate = $3
    gsub(/%/, "", $4)
    dtlb = $4
    gsub(/%/, "", $5)
    itlb = $5

    if (json != "") json = json ",\n    "
    json = json sprintf("{\"total\": %s, \"misses\": %s, \"hit_percent\": %.2f, \"dtlb_percent\": %.2f, \"itlb_percent\": %.2f}",
                        total, misses, hit_rate, dtlb, itlb)
}
END {
    print json
}' $PARSED_DATA > $TEMP_DIR/samples_json.txt

SAMPLES_JSON=$(cat $TEMP_DIR/samples_json.txt)

# 输出 JSON
cat > $OUTPUT_JSON << EOF
{
  "timestamp": "$TIMESTAMP",
  "unix_time": $JSON_UNIX_TIME,
  "data_type": "cachestat",
  "available": true,
  "sampling": {
    "interval_sec": $INTERVAL,
    "count": $COUNT,
    "actual_samples": $SAMPLE_COUNT
  },
  "statistics": {
    "avg_total": $AVG_TOTAL,
    "avg_misses": $AVG_MISSES,
    "avg_hit_percent": $AVG_HIT_RATE,
    "avg_dtlb_percent": $AVG_DTLB,
    "avg_itlb_percent": $AVG_ITLB
  },
  "analysis": {
    "cache_pressure": "$CACHE_PRESSURE"
  },
  "samples": [
    $SAMPLES_JSON
  ]
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
