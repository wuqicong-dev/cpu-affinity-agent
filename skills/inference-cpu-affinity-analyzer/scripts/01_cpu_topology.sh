#!/bin/bash

# 1.1 CPU 拓扑信息获取
# 用途: 获取 CPU 硬件拓扑信息
# 使用: ./01_cpu_topology.sh

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

# 输出文件配置
OUTPUT_DIR="profiler_output"
OUTPUT_TXT="${OUTPUT_DIR}/cpu_topology.txt"
OUTPUT_JSON="${OUTPUT_DIR}/cpu_topology.json"

# 创建输出目录
mkdir -p $OUTPUT_DIR

TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}1.1 CPU 拓扑信息获取${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# 检查命令
if ! command -v lscpu &> /dev/null; then
    echo -e "${RED}错误: lscpu 命令未安装${NC}"
    exit 1
fi

# 采集数据
echo -e "${BLUE}执行命令: lscpu${NC}"
lscpu > $TEMP_DIR/lscpu.txt

# 解析关键信息
CPU_COUNT=$(lscpu | grep "^CPU(s):" | awk '{print $2}')
SOCKET_COUNT=$(lscpu | grep "^Socket(s):" | awk '{print $2}')
CORES_PER_SOCKET=$(lscpu | grep "^Core(s) per socket:" | awk '{print $4}')
THREADS_PER_CORE=$(lscpu | grep "^Thread(s) per core:" | awk '{print $4}')
NUMA_NODES=$(lscpu | grep "^NUMA node(s):" | awk '{print $3}')

# 解析更多详细信息
MODEL_NAME=$(lscpu | grep "^Model name:" | cut -d':' -f2 | xargs || echo "Unknown")
VENDOR_ID=$(lscpu | grep "^Vendor ID:" | cut -d':' -f2 | xargs || echo "Unknown")
CPU_FAMILY=$(lscpu | grep "^CPU family:" | awk '{print $3}' || echo "Unknown")
CPU_ARCH=$(lscpu | grep "^Architecture:" | awk '{print $2}' || echo "Unknown")
CPU_MHZ=$(lscpu | grep "^CPU MHz:" | awk '{print $3}' || echo "Unknown")
L1D_CACHE=$(lscpu | grep "^L1d cache:" | awk '{print $3}' || echo "Unknown")
L1I_CACHE=$(lscpu | grep "^L1i cache:" | awk '{print $3}' || echo "Unknown")
L2_CACHE=$(lscpu | grep "^L2 cache:" | awk '{print $3}' || echo "Unknown")
L3_CACHE=$(lscpu | grep "^L3 cache:" | awk '{print $3}' || echo "Unknown")
STEPPING=$(lscpu | grep "^Stepping:" | awk '{print $2}' || echo "Unknown")
CPU_MAX_MHZ=$(lscpu | grep "^CPU max MHz:" | awk '{print $4}' || echo "Unknown")
CPU_MIN_MHZ=$(lscpu | grep "^CPU min MHz:" | awk '{print $4}' || echo "Unknown")

# 获取 NUMA 节点详细信息
declare -A NUMA_CPUS
for i in $(seq 0 $((NUMA_NODES - 1)) 2>/dev/null); do
    numa_cpu=$(lscpu | grep "^NUMA node${i} CPU(s):" | cut -d':' -f2 | xargs || echo "")
    NUMA_CPUS[$i]="$numa_cpu"
done

# 获取 CPU flags
CPU_FLAGS=$(lscpu | grep "^Flags:" | cut -d':' -f2 | xargs || echo "")

echo ""
echo -e "${GREEN}解析结果:${NC}"
echo -e "  ${BLUE}•${NC} 总 CPU 数: ${GREEN}$CPU_COUNT${NC}"
echo -e "  ${BLUE}•${NC} Socket 数: ${GREEN}$SOCKET_COUNT${NC}"
echo -e "  ${BLUE}•${NC} 每 Socket 核心数: ${GREEN}$CORES_PER_SOCKET${NC}"
echo -e "  ${BLUE}•${NC} 每核心线程数: ${GREEN}$THREADS_PER_CORE${NC}"
echo -e "  ${BLUE}•${NC} NUMA 节点数: ${GREEN}$NUMA_NODES${NC}"

echo ""
echo -e "${GREEN}完整输出:${NC}"
cat $TEMP_DIR/lscpu.txt

# 保存原始数据
{
    echo "################################################################################"
    echo "# CPU 拓扑信息采集结果"
    echo "# 采集时间: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "################################################################################"
    echo ""
    cat $TEMP_DIR/lscpu.txt
} > $OUTPUT_TXT

# 生成 JSON 数据
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
JSON_UNIX_TIME=$(date +%s)

# 构建 JSON 数组部分
NUMA_JSON=""
for i in $(seq 0 $((NUMA_NODES - 1)) 2>/dev/null); do
    if [ -n "${NUMA_CPUS[$i]}" ]; then
        if [ -n "$NUMA_JSON" ]; then
            NUMA_JSON="$NUMA_JSON,"
        fi
        NUMA_JSON="$NUMA_JSON{\"node_id\": $i, \"cpus\": \"${NUMA_CPUS[$i]}\"}"
    fi
done

# 输出 JSON
cat > $OUTPUT_JSON << EOF
{
  "timestamp": "$TIMESTAMP",
  "unix_time": $JSON_UNIX_TIME,
  "data_type": "cpu_topology",
  "cpu_info": {
    "total_cpus": $CPU_COUNT,
    "sockets": $SOCKET_COUNT,
    "cores_per_socket": $CORES_PER_SOCKET,
    "threads_per_core": $THREADS_PER_CORE,
    "numa_nodes": $NUMA_NODES,
    "model_name": "$MODEL_NAME",
    "vendor_id": "$VENDOR_ID",
    "cpu_family": "$CPU_FAMILY",
    "architecture": "$CPU_ARCH",
    "stepping": "$STEPPING"
  },
  "frequency": {
    "current_mhz": "$CPU_MHZ",
    "max_mhz": "$CPU_MAX_MHZ",
    "min_mhz": "$CPU_MIN_MHZ"
  },
  "cache": {
    "l1d": "$L1D_CACHE",
    "l1i": "$L1I_CACHE",
    "l2": "$L2_CACHE",
    "l3": "$L3_CACHE"
  },
  "numa_nodes": [$NUMA_JSON],
  "cpu_flags": "$CPU_FLAGS"
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
