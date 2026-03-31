#!/bin/bash

# 1.4 各核心 CPU 使用率采集
# 用途: 采集各核心 CPU 使用率（5次采样）
# 使用: ./04_per_core_cpu_usage.sh [CPU范围]
#   参数:
#     无参数       - 监控所有 CPU 核心
#     0-15         - 监控 CPU 0-15
#     0,2,4,6      - 监控指定 CPU 核心

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 输出文件配置
OUTPUT_DIR="profiler_output"
OUTPUT_TXT="${OUTPUT_DIR}/per_core_cpu_usage.txt"
OUTPUT_JSON="${OUTPUT_DIR}/per_core_cpu_usage.json"

# 创建输出目录
mkdir -p $OUTPUT_DIR

TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

# 解析 CPU 范围参数
CPU_RANGE="$1"
CPU_FILTER=""

if [ -n "$CPU_RANGE" ]; then
    echo -e "${BLUE}CPU 范围参数: ${GREEN}$CPU_RANGE${NC}"

    # 解析范围或列表
    if [[ "$CPU_RANGE" =~ "-" ]]; then
        # 范围格式: 0-15
        START=$(echo "$CPU_RANGE" | cut -d'-' -f1)
        END=$(echo "$CPU_RANGE" | cut -d'-' -f2)
        CPU_FILTER="$START-$END"
        echo -e "${BLUE}监控范围: CPU $START 到 $END${NC}"
    else
        # 列表格式: 0,2,4,6
        CPU_FILTER="$CPU_RANGE"
        echo -e "${BLUE}监控列表: CPU $CPU_RANGE${NC}"
    fi
else
    echo -e "${BLUE}CPU 范围: ${GREEN}所有核心${NC}"
fi

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}1.4 各核心 CPU 使用率采集${NC}"
echo -e "${GREEN}========================================${NC}"
echo -e "采样参数: ${BLUE}间隔 1秒, 5次采样${NC}"
echo ""

# 检查命令
if ! command -v mpstat &> /dev/null; then
    echo -e "${RED}错误: mpstat 命令未安装 (属于 sysstat 包)${NC}"
    exit 1
fi

# 采集数据
echo -e "${BLUE}执行命令: mpstat -P ALL 1 5${NC}"
RAW_DATA=$TEMP_DIR/mpstat_raw.txt
timeout 7 mpstat -P ALL 1 5 2>/dev/null | tee $RAW_DATA

# 保存原始数据
{
    echo "################################################################################"
    echo "# 各核心 CPU 使用率监控"
    echo "# 采样间隔: 1秒, 采样次数: 5次"
    echo "# 开始时间: $(date '+%Y-%m-%d %H:%M:%S')"
    if [ -n "$CPU_RANGE" ]; then
        echo "# CPU 范围: $CPU_RANGE"
    else
        echo "# CPU 范围: 所有核心"
    fi
    echo "################################################################################"
    echo ""
    cat $RAW_DATA
} > $OUTPUT_TXT

echo -e "${BLUE}[DEBUG] 使用 awk 解析数据...${NC}"

# 使用 awk 解析数据
PARSED_JSON=$TEMP_DIR/parsed_json.txt
PARSED_STATS=$TEMP_DIR/parsed_stats.txt

# 构建过滤条件
FILTER_SCRIPT=""
if [ -n "$CPU_FILTER" ]; then
    if [[ "$CPU_FILTER" =~ "-" ]]; then
        # 范围过滤
        START=$(echo "$CPU_FILTER" | cut -d'-' -f1)
        END=$(echo "$CPU_FILTER" | cut -d'-' -f2)
        FILTER_SCRIPT="if (\$2 >= $START && \$2 <= $END)"
    else
        # 列表过滤
        FILTER_SCRIPT="if ("
        FIRST=true
        IFS=',' read -ra CPUS <<< "$CPU_FILTER"
        for cpu in "${CPUS[@]}"; do
            if [ "$FIRST" = true ]; then
                FILTER_SCRIPT="$FILTER_SCRIPT \$2 == $cpu"
                FIRST=false
            else
                FILTER_SCRIPT="$FILTER_SCRIPT || \$2 == $cpu"
            fi
        done
        FILTER_SCRIPT="$FILTER_SCRIPT)"
    fi
else
    # 所有核心
    FILTER_SCRIPT="if (\$2 != \"all\")"
fi

echo -e "${BLUE}[DEBUG] 过滤条件: $FILTER_SCRIPT${NC}"

# 使用 awk 解析
eval "awk '
BEGIN {
    count = 0
    sum_idle = 0
    sum_user = 0
    sum_sys = 0
}
/Average:/ {
    # mpstat 输出格式（可能有不同列数）:
    # Average:  CPU    %usr   %nice    %sys %iowait    %irq   %soft  %steal  %guest  %gnice   %idle
    # 先找到 CPU 列（$2），然后从后往前找 idle 列

    cpu = \$2

    # 跳过非数字的 CPU 列（如 "all" 或标题行）
    if (cpu !~ /^[0-9]+$/) next

    user = \$3
    nice = \$4
    sys = \$5
    iowait = \$6

    # idle 是最后一列
    idle = \$NF

    # 计算总使用率（用于排序）
    total_usage = 100 - idle

    # steal 可能是倒数第 5 列（%steal）或倒数第 4 列，需要动态判断
    if (NF >= 9) {
        if (\$9 ~ /^[0-9.]+$/) {
            steal = \$9
        } else {
            steal = 0.00
        }
    } else {
        steal = 0.00
    }

    # 应用过滤条件
    $FILTER_SCRIPT {
        # 累加用于计算平均值
        sum_idle += idle
        sum_user += user
        sum_sys += sys

        # 保存数据用于计算标准差和排序
        # 使用排序键：总使用率(降序) -> user(降序) -> sys(降序)
        sort_key = sprintf(\"%010.2f_%010.2f_%010.2f_%05d\", 1000 - total_usage, 1000 - user, 1000 - sys, cpu)
        cores_idle[count] = idle
        cores_user[count] = user
        cores_sys[count] = sys
        cores_total[count] = total_usage
        core_ids[count] = cpu
        core_nice[count] = nice
        core_iowait[count] = iowait
        core_steal[count] = steal
        sort_keys[count] = sort_key

        count++
    }
}
END {
    # 按排序键排序（降序：总使用率 -> user -> sys）
    asort(sort_keys, sorted_keys)

    # 构建 JSON（按排序后的顺序）
    json_cores = \"\"
    for (i = 1; i <= count; i++) {
        # 找到原始索引
        for (j = 0; j < count; j++) {
            if (sort_keys[j] == sorted_keys[i]) {
                idx = j
                break
            }
        }

        cpu = core_ids[idx]
        user = cores_user[idx]
        nice = core_nice[idx]
        sys = cores_sys[idx]
        iowait = core_iowait[idx]
        steal = core_steal[idx]
        idle = cores_idle[idx]

        if (i > 1) json_cores = json_cores \",\"
        json_cores = json_cores \"{\\\"cpu\\\": \" cpu \", \\\"user\\\": \" user \", \\\"nice\\\": \" nice \", \\\"system\\\": \" sys \", \\\"iowait\\\": \" iowait \", \\\"steal\\\": \" steal \", \\\"idle\\\": \" idle \"}\"
    }

    # 输出核心 JSON
    print json_cores > \"'\"$PARSED_JSON\"'\"

    # 计算统计信息
    if (count > 0) {
        avg_idle = sum_idle / count
        avg_user = sum_user / count
        avg_sys = sum_sys / count

        # 计算空闲率标准差
        var_idle = 0
        for (i = 0; i < count; i++) {
            var_idle += (cores_idle[i] - avg_idle) ^ 2
        }
        stddev_idle = sqrt(var_idle / count)

        # 输出统计
        printf \"CORE_COUNT=%d\\n\", count > \"'\"$PARSED_STATS\"'\"
        printf \"AVG_IDLE=%.2f\\n\", avg_idle >> \"'\"$PARSED_STATS\"'\"
        printf \"AVG_USER=%.2f\\n\", avg_user >> \"'\"$PARSED_STATS\"'\"
        printf \"AVG_SYSTEM=%.2f\\n\", avg_sys >> \"'\"$PARSED_STATS\"'\"
        printf \"STDDEV_IDLE=%.2f\\n\", stddev_idle >> \"'\"$PARSED_STATS\"'\"
    } else {
        printf \"CORE_COUNT=0\\n\" > \"'\"$PARSED_STATS\"'\"
        printf \"AVG_IDLE=0.00\\n\" >> \"'\"$PARSED_STATS\"'\"
        printf \"AVG_USER=0.00\\n\" >> \"'\"$PARSED_STATS\"'\"
        printf \"AVG_SYSTEM=0.00\\n\" >> \"'\"$PARSED_STATS\"'\"
        printf \"STDDEV_IDLE=0.00\\n\" >> \"'\"$PARSED_STATS\"'\"
    }
}
' $RAW_DATA"

# 读取解析结果
CORE_COUNT=$(grep "^CORE_COUNT=" $PARSED_STATS | cut -d'=' -f2)
AVG_IDLE=$(grep "^AVG_IDLE=" $PARSED_STATS | cut -d'=' -f2)
AVG_USER=$(grep "^AVG_USER=" $PARSED_STATS | cut -d'=' -f2)
AVG_SYSTEM=$(grep "^AVG_SYSTEM=" $PARSED_STATS | cut -d'=' -f2)
STDDEV_IDLE=$(grep "^STDDEV_IDLE=" $PARSED_STATS | cut -d'=' -f2)

CORES_JSON=$(cat $PARSED_JSON)

echo -e "${YELLOW}[DEBUG] 解析完成: ${CORE_COUNT} 个核心${NC}"

echo ""
echo -e "${GREEN}解析结果 (${CORE_COUNT} 个核心):${NC}"
echo "    CPU    %user   %nice   %system   %iowait   %steal   %idle"

# 显示各核心数据（从 JSON 中提取并显示）
if [ -n "$CORES_JSON" ]; then
    echo "$CORES_JSON" | sed 's/},{/}\n{/g' | sed 's/{//g' | sed 's/}//g' | while IFS=',' read -r cpu user nice system iowait steal idle; do
        cpu_val=$(echo "$cpu" | cut -d':' -f2 | tr -d '" ')
        user_val=$(echo "$user" | cut -d':' -f2 | tr -d '" ')
        nice_val=$(echo "$nice" | cut -d':' -f2 | tr -d '" ')
        system_val=$(echo "$system" | cut -d':' -f2 | tr -d '" ')
        iowait_val=$(echo "$iowait" | cut -d':' -f2 | tr -d '" ')
        steal_val=$(echo "$steal" | cut -d':' -f2 | tr -d '" ')
        idle_val=$(echo "$idle" | cut -d':' -f2 | tr -d '" ')
        printf "    %3s    %5s   %5s   %5s     %5s    %5s   %5s\n" "$cpu_val" "$user_val" "$nice_val" "$system_val" "$iowait_val" "$steal_val" "$idle_val"
    done
fi

echo ""
echo -e "${GREEN}负载均衡分析:${NC}"
echo -e "  ${BLUE}•${NC} 核心数: ${GREEN}$CORE_COUNT${NC}"
echo -e "  ${BLUE}•${NC} 平均空闲率: ${GREEN}${AVG_IDLE}%${NC}"
echo -e "  ${BLUE}•${NC} 空闲率标准差: ${GREEN}${STDDEV_IDLE}%${NC}"

if [ $(echo "$STDDEV_IDLE > 10" | bc 2>/dev/null || echo 0) -eq 1 ]; then
    echo -e "  ${RED}⚠${NC} 核心负载不均衡较高"
else
    echo -e "  ${GREEN}✓${NC} 核心负载相对均衡"
fi

# 生成 JSON 数据
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
JSON_UNIX_TIME=$(date +%s)

cat > $OUTPUT_JSON << EOF
{
  "timestamp": "$TIMESTAMP",
  "unix_time": $JSON_UNIX_TIME,
  "data_type": "per_core_cpu_usage",
  "sampling": {
    "interval_sec": 1,
    "count": 5
  },
  "cpu_filter": {
    "specified": $(if [ -n "$CPU_RANGE" ]; then echo "true"; else echo "false"; fi),
    "range": "${CPU_RANGE:-ALL}",
    "core_count": $CORE_COUNT
  },
  "statistics": {
    "avg_idle": $AVG_IDLE,
    "avg_user": $AVG_USER,
    "avg_system": $AVG_SYSTEM,
    "stddev_idle": $STDDEV_IDLE,
    "load_balanced": $(if [ $(echo "$STDDEV_IDLE <= 10" | bc 2>/dev/null || echo 1) -eq 1 ]; then echo "true"; else echo "false"; fi)
  },
  "cores": [$CORES_JSON]
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
