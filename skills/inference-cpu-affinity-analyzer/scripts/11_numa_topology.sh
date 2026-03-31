#!/bin/bash

# 1.11 NUMA 拓扑检测
# 用途: 获取系统 NUMA 架构信息
# 使用: ./11_numa_topology.sh

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 输出文件配置
OUTPUT_DIR="profiler_output"
OUTPUT_TXT="${OUTPUT_DIR}/numa_topology.txt"
OUTPUT_JSON="${OUTPUT_DIR}/numa_topology.json"

# 创建输出目录
mkdir -p $OUTPUT_DIR

TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}1.11 NUMA 拓扑检测${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# 检查命令
USE_NUMACTL=false
if command -v numactl &> /dev/null; then
    USE_NUMACTL=true
    echo -e "${BLUE}使用 numactl 获取 NUMA 拓扑...${NC}"
else
    echo -e "${YELLOW}警告: numactl 命令未安装${NC}"
    echo -e "${BLUE}提示: numactl 包含在 numactl 包中${NC}"
    echo ""
fi

# 备选方案：从 /sys 文件系统获取 NUMA 信息
USE_SYS=false
if [ -d /sys/devices/system/node ]; then
    USE_SYS=true
    echo -e "${BLUE}使用 /sys 文件系统获取 NUMA 信息...${NC}"
fi

# 采集数据
{
    echo "################################################################################"
    echo "# NUMA 拓扑信息"
    echo "# 采集时间: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "################################################################################"
    echo ""
} > $TEMP_DIR/numa_raw.txt

if [ "$USE_NUMACTL" = true ]; then
    echo -e "${BLUE}执行命令: numactl --hardware${NC}"
    {
        echo "=== NUMA 拓扑 (numactl --hardware) ==="
        numactl --hardware 2>/dev/null || echo "numactl 命令执行失败"
        echo ""
    } >> $TEMP_DIR/numa_raw.txt
fi

if [ "$USE_SYS" = true ]; then
    echo -e "${BLUE}获取 /sys 文件系统 NUMA 信息...${NC}"
    {
        echo "=== NUMA 节点信息 (/sys) ==="
        echo ""

        # 遍历所有 NUMA 节点
        for node in /sys/devices/system/node/node*; do
            if [ -d "$node" ]; then
                node_id=$(basename "$node" | sed 's/node//')
                echo "Node $node_id:"

                # 获取该节点的 CPU 列表
                if [ -f "$node/cpulist" ]; then
                    cpus=$(cat "$node/cpulist")
                    echo "  CPUs: $cpus"
                elif [ -f "$node/cpumap" ]; then
                    # 如果有 cpumap，转换为 CPU 列表
                    cpumap=$(cat "$node/cpumap")
                    echo "  CPU map: $cpumap"
                fi

                # 获取内存信息
                if [ -f "$node/meminfo" ]; then
                    mem_total=$(grep "^Node.*MemTotal:" "$node/meminfo" | awk '{print $2}')
                    mem_free=$(grep "^Node.*MemFree:" "$node/meminfo" | awk '{print $2}')
                    echo "  Memory: ${mem_total:-0} kB total, ${mem_free:-0} kB free"
                fi

                # 获取距离信息
                if [ -f "$node/distance" ]; then
                    distance=$(cat "$node/distance")
                    echo "  Distance: $distance"
                fi

                echo ""
            fi
        done
    } >> $TEMP_DIR/numa_raw.txt
fi

# 获取 CPU 拓扑信息（用于分析 Cluster/Die）
echo -e "${BLUE}获取 CPU 拓扑信息...${NC}"
{
    echo "=== CPU 拓扑信息 (lscpu) ==="
    if command -v lscpu &> /dev/null; then
        lscpu 2>/dev/null || echo "lscpu 命令执行失败"
    else
        echo "lscpu 不可用"
    fi
    echo ""
} >> $TEMP_DIR/numa_raw.txt

# 保存原始数据
cp $TEMP_DIR/numa_raw.txt $OUTPUT_TXT

# 解析数据
echo ""
echo -e "${GREEN}解析结果:${NC}"

PARSED_DATA=$TEMP_DIR/parsed_data.txt

# 解析 NUMA 节点信息
if [ "$USE_NUMACTL" = true ]; then
    # 解析 numactl 输出
    NUMA_COUNT=$(grep "node(s)" $TEMP_DIR/numa_raw.txt 2>/dev/null | head -1 | awk '{print $1}')

    echo -e "${GREEN}NUMA 拓扑统计:${NC}"
    echo -e "  ${BLUE}•${NC} NUMA 节点数: ${GREEN}${NUMA_COUNT:-1}${NC}"

    # 提取每个节点的 CPU 列表和内存大小
    awk '
    /^node.*cpus:/ {
        # 格式: node 0 cpus: 0 1 2 3 4 5 6 7
        node_id = $2
        cpu_list = ""
        for (i = 4; i <= NF; i++) {
            if ($i !~ /^[0-9]+$/) continue
            if (cpu_list != "") cpu_list = cpu_list ","
            cpu_list = cpu_list $i
        }
        node_cpus[node_id] = cpu_list
    }
    /^node.*size:/ {
        # 格式: node 0 size: 65536 MB
        node_id = $2
        size = $4
        unit = $5
        node_size[node_id] = size " " unit
    }
    END {
        for (id in node_cpus) {
            size = (id in node_size) ? node_size[id] : "unknown"
            printf "NUMA_NODE|%s|%s|%s\n", id, node_cpus[id], size
        }
    }
    ' $TEMP_DIR/numa_raw.txt > $PARSED_DATA

    # 显示每个 NUMA 节点的 CPU 分布
    echo ""
    echo -e "${GREEN}NUMA 节点信息:${NC}"

    while IFS='|' read -r tag node_id cpus size; do
        echo -e "  ${BLUE}•${NC} Node $node_id:"
        echo -e "    CPUs: ${GREEN}[$cpus]${NC}"
        echo -e "    Memory: ${GREEN}${size}${NC}"

        # 计算该节点的 CPU 数量
        cpu_count=$(echo "$cpus" | tr ',' '\n' | wc -l)
        echo "    CPU 数量: $cpu_count"
    done < $PARSED_DATA

elif [ "$USE_SYS" = true ]; then
    # 从 /sys 解析 NUMA 信息
    NUMA_COUNT=$(ls -d /sys/devices/system/node/node* 2>/dev/null | wc -l)

    echo -e "${GREEN}NUMA 拓扑统计:${NC}"
    echo -e "  ${BLUE}•${NC} NUMA 节点数: ${GREEN}${NUMA_COUNT:-1}${NC}"

    # 提取每个节点的 CPU 列表和内存信息
    > $PARSED_DATA

    for node in /sys/devices/system/node/node*; do
        if [ -d "$node" ]; then
            node_id=$(basename "$node" | sed 's/node//')

            # 获取 CPU 列表
            cpus=""
            if [ -f "$node/cpulist" ]; then
                cpus=$(cat "$node/cpulist" 2>/dev/null)
            fi

            # 获取内存信息
            size="unknown"
            if [ -f "$node/meminfo" ]; then
                mem_total=$(grep "^Node.*MemTotal:" "$node/meminfo" 2>/dev/null | awk '{print $2}')
                if [ -n "$mem_total" ]; then
                    size="${mem_total} kB"
                fi
            fi

            if [ -n "$cpus" ]; then
                echo "NUMA_NODE|$node_id|$cpus|$size" >> $PARSED_DATA
            fi
        fi
    done

    # 显示每个 NUMA 节点的 CPU 分布
    echo ""
    echo -e "${GREEN}NUMA 节点信息:${NC}"

    while IFS='|' read -r tag node_id cpus size; do
        echo -e "  ${BLUE}•${NC} Node $node_id:"
        echo -e "    CPUs: ${GREEN}[$cpus]${NC}"
        echo -e "    Memory: ${GREEN}${size}${NC}"

        # 计算该节点的 CPU 数量
        cpu_count=$(echo "$cpus" | tr ',' '\n' | wc -l)
        echo "    CPU 数量: $cpu_count"
    done < $PARSED_DATA
else
    echo -e "${YELLOW}无法获取 NUMA 信息（numactl 和 /sys 都不可用）${NC}"
    NUMA_COUNT=1
    > $PARSED_DATA
fi

# 解析 CPU 拓扑信息
SOCKET_COUNT=$(awk '/^Socket\(s\):/ {print $2}' $TEMP_DIR/numa_raw.txt 2>/dev/null || echo "1")
CORES_PER_SOCKET=$(awk '/^Core\(s\) per socket:/ {print $4}' $TEMP_DIR/numa_raw.txt 2>/dev/null || echo "1")
THREADS_PER_CORE=$(awk '/^Thread\(s\) per core:/ {print $4}' $TEMP_DIR/numa_raw.txt 2>/dev/null || echo "1")

echo ""
echo -e "${GREEN}CPU 拓扑信息:${NC}"
echo -e "  ${BLUE}•${NC} Socket 数量: ${GREEN}${SOCKET_COUNT}${NC}"
echo -e "  ${BLUE}•${NC} 每个 Socket 的 Core 数: ${GREEN}${CORES_PER_SOCKET}${NC}"
echo -e "  ${BLUE}•${NC} 每个 Core 的线程数: ${GREEN}${THREADS_PER_CORE}${NC}"

# 分析 NUMA 边界
echo ""
echo -e "${GREEN}NUMA 边界分析:${NC}"

# 计算 Cluster 边界（每 4 个 CPU 一个 Cluster）
TOTAL_CPUS=$(lscpu 2>/dev/null | grep "^CPU(s):" | awk '{print $2}' || echo "1")
CLUSTER_SIZE=4
CLUSTER_COUNT=$((TOTAL_CPUS / CLUSTER_SIZE))

echo -e "  ${BLUE}•${NC} 总 CPU 数: ${GREEN}${TOTAL_CPUS}${NC}"
echo -e "  ${BLUE}•${NC} Cluster 大小: ${GREEN}${CLUSTER_SIZE} CPUs${NC}"
echo -e "  ${BLUE}•${NC} Cluster 数量: ${GREEN}${CLUSTER_COUNT}${NC}"

# 计算 Die 边界（每 32 个 CPU 一个 Die）
DIE_SIZE=32
DIE_COUNT=$((TOTAL_CPUS / DIE_SIZE))

echo -e "  ${BLUE}•${NC} Die 大小: ${GREEN}${DIE_SIZE} CPUs${NC}"
echo -e "  ${BLUE}•${NC} Die 数量: ${GREEN}${DIE_COUNT}${NC}"

# 生成 JSON 数据
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
JSON_UNIX_TIME=$(date +%s)

# 构建节点 JSON 数组
NODES_JSON=""
while IFS='|' read -r tag node_id cpus size; do
    if [ -n "$NODES_JSON" ]; then
        NODES_JSON="$NODES_JSON,"
    fi

    # 计算该节点的 CPU 数量
    cpu_count=$(echo "$cpus" | tr ',' '\n' | wc -l | tr -d ' ')

    # 处理内存大小（转换为数字 kB）
    memory_kb="0"
    if [[ "$size" =~ ([0-9]+) ]]; then
        memory_kb="${BASH_REMATCH[1]}"
    fi

    NODES_JSON="$NODES_JSON{\"node_id\": $node_id, \"cpu_count\": $cpu_count, \"cpus\": \"$cpus\", \"memory_size\": \"$size\", \"memory_kb\": $memory_kb}"
done < $PARSED_DATA

# 如果没有节点数据，创建默认单节点
if [ -z "$NODES_JSON" ]; then
    NODES_JSON="{\"node_id\": 0, \"cpu_count\": $TOTAL_CPUS, \"cpus\": \"0-$(($TOTAL_CPUS - 1))\", \"memory_size\": \"unknown\", \"memory_kb\": 0}"
fi

# 输出 JSON
cat > $OUTPUT_JSON << EOF
{
  "timestamp": "$TIMESTAMP",
  "unix_time": $JSON_UNIX_TIME,
  "data_type": "numa_topology",
  "source": "numactl",
  "topology": {
    "numa_nodes": ${NUMA_COUNT:-1},
    "sockets": $SOCKET_COUNT,
    "cores_per_socket": $CORES_PER_SOCKET,
    "threads_per_core": $THREADS_PER_CORE,
    "total_cpus": $TOTAL_CPUS
  },
  "boundaries": {
    "cluster_size": $CLUSTER_SIZE,
    "cluster_count": $CLUSTER_COUNT,
    "die_size": $DIE_SIZE,
    "die_count": $DIE_COUNT
  },
  "nodes": [
    $NODES_JSON
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
