#!/bin/bash

# 1.12 线程 CPU 分布检测
# 用途: 检测目标进程线程在不同 CPU 核心的分布（5次采样）
# 使用: ./12_thread_distribution.sh <PID>

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 输出文件配置
OUTPUT_DIR="profiler_output"
OUTPUT_TXT="${OUTPUT_DIR}/thread_distribution.txt"
OUTPUT_JSON="${OUTPUT_DIR}/thread_distribution.json"

# 创建输出目录
mkdir -p $OUTPUT_DIR

# 检查参数
if [ $# -ne 1 ]; then
    echo -e "${RED}错误: 请提供 PID${NC}"
    echo "用法: $0 <PID>"
    exit 1
fi

PID=$1

# 检查进程是否存在
if ! ps -p $PID > /dev/null 2>&1; then
    echo -e "${RED}错误: PID $PID 不存在${NC}"
    exit 1
fi

# 获取进程命令名
PROCESS_NAME=$(ps -p $PID -o comm= 2>/dev/null || echo "Unknown")

TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

# 采样次数
SAMPLE_COUNT=5

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}1.12 线程 CPU 分布检测${NC}"
echo -e "${GREEN}========================================${NC}"
echo -e "目标进程: ${BLUE}$PID${NC} (${GREEN}$PROCESS_NAME${NC})"
echo -e "采样参数: ${BLUE}间隔 1秒, 5次采样${NC}"
echo ""

# 辅助函数：添加分割符
add_separator() {
    local file=$1
    local sample_num=$2
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S.%3N')
    echo "" >> $file
    echo "================================================================================" >> $file
    echo "  采样 #$sample_num - 时间: $timestamp" >> $file
    echo "================================================================================" >> $file
    echo "" >> $file
}

# 采集数据
{
    echo "################################################################################"
    echo "# 线程 CPU 分布监控 - PID: $PID"
    echo "# 采样间隔: 1秒, 采样次数: 5次"
    echo "# 开始时间: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "################################################################################"
    echo ""
} > $TEMP_DIR/thread_dist_raw.txt

echo -e "${BLUE}执行 5 次采样...${NC}"
for i in {1..5}; do
    add_separator $TEMP_DIR/thread_dist_raw.txt $i
    echo -e "  采样 #$i..."
    ps -eLo pid,lwp,psr,pcpu,comm | grep "^[[:space:]]*$PID" >> $TEMP_DIR/thread_dist_raw.txt 2>/dev/null || echo "ps 命令执行失败" >> $TEMP_DIR/thread_dist_raw.txt
    [ $i -lt 5 ] && sleep 1
done

# 保存原始数据
cp $TEMP_DIR/thread_dist_raw.txt $OUTPUT_TXT

# 解析数据
echo ""
echo -e "${GREEN}解析结果 (最后一次采样):${NC}"

# 取最后一次采样数据用于分析
FINAL_SAMPLE=$TEMP_DIR/final_sample.txt
grep -A 10000 "采样 #5" $TEMP_DIR/thread_dist_raw.txt | grep -E "^[[:space:]]*[0-9]+" > $FINAL_SAMPLE

# 统计每个 CPU 上的线程数
CPU_DISTRIBUTION=$TEMP_DIR/cpu_distribution.txt
awk '{print $3}' $FINAL_SAMPLE | sort -n | uniq -c | awk '{printf "CPU_DIST|%s|%s\n", $2, $1}' > $CPU_DISTRIBUTION

echo -e "${GREEN}线程 CPU 分布:${NC}"
echo "    CPU    线程数"

TOTAL_THREADS=0
TOTAL_CPUS_USED=0

while IFS='|' read -r tag cpu count; do
    printf "    %-4s  %-5s\n" "$cpu" "$count"
    TOTAL_THREADS=$((TOTAL_THREADS + count))
    TOTAL_CPUS_USED=$((TOTAL_CPUS_USED + 1))
done < $CPU_DISTRIBUTION

echo ""
echo -e "${GREEN}统计:${NC}"
echo -e "  ${BLUE}•${NC} 总线程数: ${GREEN}${TOTAL_THREADS}${NC}"
echo -e "  ${BLUE}•${NC} 使用的 CPU 数: ${GREEN}${TOTAL_CPUS_USED}${NC}"

# 分析跨域情况
echo ""
echo -e "${GREEN}跨域分析:${NC}"

# 获取使用的 CPU 列表
USED_CPUS=$(awk '{print $3}' $FINAL_SAMPLE | sort -n -u | tr '\n' ',' | sed 's/,$//')
echo -e "  ${BLUE}•${NC} 使用的 CPU 列表: ${GREEN}[$USED_CPUS]${NC}"

# 检查跨 Cluster (每 4 个 CPU 一个 Cluster)
MIN_CPU=$(awk '{print $3}' $FINAL_SAMPLE | sort -n | head -1)
MAX_CPU=$(awk '{print $3}' $FINAL_SAMPLE | sort -n | tail -1)
MIN_CLUSTER=$((MIN_CPU / 4))
MAX_CLUSTER=$((MAX_CPU / 4))

CROSS_CLUSTER="false"
if [ $MIN_CLUSTER -ne $MAX_CLUSTER ]; then
    CROSS_CLUSTER="true"
    echo -e "  ${RED}⚠${NC} 跨 Cluster 运行: Cluster ${MIN_CLUSTER} -> Cluster ${MAX_CLUSTER}"
else
    echo -e "  ${GREEN}✓${NC} 未跨 Cluster 运行 (Cluster ${MIN_CLUSTER})"
fi

# 检查跨 Die (每 32 个 CPU 一个 Die)
MIN_DIE=$((MIN_CPU / 32))
MAX_DIE=$((MAX_CPU / 32))

CROSS_DIE="false"
if [ $MIN_DIE -ne $MAX_DIE ]; then
    CROSS_DIE="true"
    echo -e "  ${RED}⚠${NC} 跨 Die 运行: Die ${MIN_DIE} -> Die ${MAX_DIE}"
else
    echo -e "  ${GREEN}✓${NC} 未跨 Die 运行 (Die ${MIN_DIE})"
fi

# 检查跨 NUMA 节点
if command -v numactl &> /dev/null; then
    # 获取每个 NUMA 节点的 CPU 列表
    declare -A NUMA_CPUS
    while read line; do
        if [[ $line =~ node[[:space:]]+([0-9]+)[[:space:]]+cpus: ]]; then
            node_id="${BASH_REMATCH[1]}"
            cpus=$(echo "$line" | sed 's/.*cpus://')
            NUMA_CPUS[$node_id]="$cpus"
        fi
    done < <(numactl --hardware 2>/dev/null)

    # 检查线程分布在不同 NUMA 节点
    USED_NUMA_NODES=()
    for node in "${!NUMA_CPUS[@]}"; do
        node_cpus=${NUMA_CPUS[$node]}
        for cpu in $(echo "$USED_CPUS" | tr ',' ' '); do
            if echo "$node_cpus" | grep -qw "$cpu"; then
                USED_NUMA_NODES+=($node)
                break
            fi
        done
    done

    # 去重
    USED_NUMA_NODES=($(echo "${USED_NUMA_NODES[@]}" | tr ' ' '\n' | sort -u))

    CROSS_NUMA="false"
    if [ ${#USED_NUMA_NODES[@]} -gt 1 ]; then
        CROSS_NUMA="true"
        echo -e "  ${RED}⚠${NC} 跨 NUMA 节点运行: ${USED_NUMA_NODES[@]}"
    else
        echo -e "  ${GREEN}✓${NC} 未跨 NUMA 节点运行 (Node ${USED_NUMA_NODES[0]:-0})"
    fi
else
    CROSS_NUMA="false"
    echo -e "  ${YELLOW}⚠${NC} 无法检测 NUMA 跨域 (numactl 不可用)"
fi

# 分析线程在 CPU 上的分布均匀性
echo ""
echo -e "${GREEN}负载分布分析:${NC}"

# 计算每个 CPU 的平均线程数
AVG_THREADS_PER_CPU=$(awk "BEGIN {printf \"%.2f\", $TOTAL_THREADS / $TOTAL_CPUS_USED}")
echo -e "  ${BLUE}•${NC} 平均每 CPU 线程数: ${GREEN}${AVG_THREADS_PER_CPU}${NC}"

# 计算标准差
VARIANCE=0
while IFS='|' read -r tag cpu count; do
    diff=$(awk "BEGIN {printf \"%.2f\", $count - $AVG_THREADS_PER_CPU}")
    sq_diff=$(awk "BEGIN {printf \"%.2f\", $diff * $diff}")
    VARIANCE=$(awk "BEGIN {printf \"%.2f\", $VARIANCE + $sq_diff}")
done < $CPU_DISTRIBUTION

STDDEV=$(awk "BEGIN {printf \"%.2f\", sqrt($VARIANCE / $TOTAL_CPUS_USED)}")

echo -e "  ${BLUE}•${NC} 标准差: ${GREEN}${STDDEV}${NC}"

# 判断负载是否均衡
IS_BALANCED="true"
# 确保变量有值再进行比较
if [ -n "$STDDEV" ] && [ -n "$AVG_THREADS_PER_CPU" ]; then
    # 使用 bc 进行浮点数比较
    result=$(echo "$STDDEV > $AVG_THREADS_PER_CPU * 0.5" | bc 2>/dev/null || echo "0")
    if [ "$result" = "1" ]; then
        IS_BALANCED="false"
        echo -e "  ${YELLOW}⚠${NC} 负载分布不均衡"
    else
        echo -e "  ${GREEN}✓${NC} 负载分布相对均衡"
    fi
else
    echo -e "  ${YELLOW}⚠${NC} 无法判断负载均衡（数据不足）"
fi

# 生成 JSON 数据
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
JSON_UNIX_TIME=$(date +%s)

# 构建每个 CPU 的分布 JSON
CPU_DIST_JSON=""
while IFS='|' read -r tag cpu count; do
    if [ -n "$CPU_DIST_JSON" ]; then
        CPU_DIST_JSON="$CPU_DIST_JSON,"
    fi
    CPU_DIST_JSON="$CPU_DIST_JSON{\"cpu\": $cpu, \"thread_count\": $count}"
done < $CPU_DISTRIBUTION

# 输出 JSON
cat > $OUTPUT_JSON << EOF
{
  "timestamp": "$TIMESTAMP",
  "unix_time": $JSON_UNIX_TIME,
  "data_type": "thread_distribution",
  "target_pid": $PID,
  "process_name": "$PROCESS_NAME",
  "sampling": {
    "interval_sec": 1,
    "count": 5
  },
  "statistics": {
    "total_threads": $TOTAL_THREADS,
    "cpus_used": $TOTAL_CPUS_USED,
    "avg_threads_per_cpu": $AVG_THREADS_PER_CPU,
    "stddev": $STDDEV,
    "is_balanced": $IS_BALANCED
  },
  "distribution": {
    "used_cpus": "$USED_CPUS",
    "min_cpu": $MIN_CPU,
    "max_cpu": $MAX_CPU,
    "cpus": [$CPU_DIST_JSON]
  },
  "cross_domain": {
    "cross_cluster": $CROSS_CLUSTER,
    "min_cluster": $MIN_CLUSTER,
    "max_cluster": $MAX_CLUSTER,
    "cross_die": $CROSS_DIE,
    "min_die": $MIN_DIE,
    "max_die": $MAX_DIE,
    "cross_numa": $CROSS_NUMA
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
