#!/bin/bash

# 1.9 CPU 频率监控
# 用途: 采集 CPU 频率数据（5次采样）
# 使用: ./09_cpu_frequency.sh

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}1.9 CPU 频率监控${NC}"
echo -e "${GREEN}========================================${NC}"
echo -e "采样参数: ${BLUE}间隔 1秒, 5次采样${NC}"
echo ""

# 检查命令
USE_PROC=false
if ! command -v turbostat &> /dev/null; then
    echo -e "${YELLOW}警告: turbostat 命令未安装${NC}"
    echo -e "${BLUE}提示: turbostat 包含在 linux-tools-common 包中${NC}"
    echo ""
    echo -e "${YELLOW}使用 /proc/cpuinfo 获取频率信息...${NC}"
    USE_PROC=true
fi

# 输出文件配置
OUTPUT_DIR="profiler_output"
OUTPUT_TXT="${OUTPUT_DIR}/cpu_frequency.txt"
OUTPUT_JSON="${OUTPUT_DIR}/cpu_frequency.json"

# 创建输出目录
mkdir -p $OUTPUT_DIR

# 基于 /proc/cpuinfo 的采集
if [ "$USE_PROC" = true ]; then
    # 获取 CPU 核心数量
    CPU_COUNT=$(grep -c "^processor" /proc/cpuinfo 2>/dev/null || echo "1")

    echo -e "${BLUE}检测到 ${GREEN}${CPU_COUNT}${NC} 个逻辑 CPU${NC}"
    echo ""

    # 创建数据文件
    {
        echo "################################################################################"
        echo "# CPU 频率监控 (/proc/cpuinfo)"
        echo "# 采样间隔: 1秒, 采样次数: 5次"
        echo "# CPU 核心数: $CPU_COUNT"
        echo "# 开始时间: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "################################################################################"
        echo ""
    } > $TEMP_DIR/cpu_freq_raw.txt

    # 5次采样，保存所有 CPU 的频率数据
    echo -e "${BLUE}执行 5 次采样...${NC}"
    for sample in {1..5}; do
        echo -e "  采样 #$sample..."
        echo "=== 采样 #$sample - $(date '+%H:%M:%S') ===" >> $TEMP_DIR/cpu_freq_raw.txt

        # 读取所有 CPU 的当前频率
        # /proc/cpuinfo 格式: "cpu MHz : 3109.540" -> 频率在第4列
        awk '
        /^processor/ {cpu=$3}
        /^cpu MHz/ {freq=$4; printf "CPU %s: %s MHz\n", cpu, freq}
        ' /proc/cpuinfo >> $TEMP_DIR/cpu_freq_raw.txt
        echo "" >> $TEMP_DIR/cpu_freq_raw.txt

        [ $sample -lt 5 ] && sleep 1
    done

    # 保存原始数据
    cp $TEMP_DIR/cpu_freq_raw.txt $OUTPUT_TXT

    # 解析数据并计算每个 CPU 的平均频率
    echo ""
    echo -e "${GREEN}解析结果 (所有 ${CPU_COUNT} 个 CPU 核心的平均频率):${NC}"
    echo "    CPU    平均频率(MHz)    最小频率(MHz)    最大频率(MHz)    波动(MHz)"

    # 使用 awk 解析并计算统计信息
    PARSED_DATA=$TEMP_DIR/parsed_data.txt
    awk -v cpu_count=$CPU_COUNT '
    BEGIN {
        # 初始化数组
        for (i = 0; i < cpu_count; i++) {
            cpu_sum[i] = 0
            cpu_min[i] = 999999
            cpu_max[i] = 0
            cpu_samples[i] = 0
        }
        total_min = 999999
        total_max = 0
    }
    /^=== 采样/ {
        next
    }
    /^CPU/ {
        # 格式: CPU 0: 3109.540 MHz
        # $1="CPU" $2="0:" $3="3109.540" $4="MHz"

        # 从 $2 提取 CPU 编号（去掉冒号）
        split($2, cpu_part, ":")
        cpu = cpu_part[1] + 0

        # 频率在 $3
        freq = $3 + 0

        cpu_sum[cpu] += freq
        cpu_samples[cpu]++

        if (freq < cpu_min[cpu]) cpu_min[cpu] = freq
        if (freq > cpu_max[cpu]) cpu_max[cpu] = freq

        if (freq < total_min) total_min = freq
        if (freq > total_max) total_max = freq
    }
    END {
        # 输出每个 CPU 的统计
        for (i = 0; i < cpu_count; i++) {
            if (cpu_samples[i] > 0) {
                avg = cpu_sum[i] / cpu_samples[i]
                variation = cpu_max[i] - cpu_min[i]
                printf "CPU_DATA|%d|%.2f|%.2f|%.2f|%.2f\n", i, avg, cpu_min[i], cpu_max[i], variation
            }
        }

        # 计算总体统计
        total_avg = 0
        valid_cpus = 0
        for (i = 0; i < cpu_count; i++) {
            if (cpu_samples[i] > 0) {
                total_avg += cpu_sum[i] / cpu_samples[i]
                valid_cpus++
            }
        }
        if (valid_cpus > 0) {
            total_avg = total_avg / valid_cpus
        }

        printf "STATS|%d|%.2f|%.2f|%.2f\n", valid_cpus, total_avg, total_min, total_max
    }
    ' $TEMP_DIR/cpu_freq_raw.txt > $PARSED_DATA

    # 读取统计信息
    STATS_LINE=$(grep "^STATS" $PARSED_DATA)
    VALID_CPUS=$(echo "$STATS_LINE" | cut -d'|' -f2)
    TOTAL_AVG=$(echo "$STATS_LINE" | cut -d'|' -f3)
    TOTAL_MIN=$(echo "$STATS_LINE" | cut -d'|' -f4)
    TOTAL_MAX=$(echo "$STATS_LINE" | cut -d'|' -f5)

    # 显示所有 CPU 的数据
    grep "^CPU_DATA" $PARSED_DATA | sort -t'|' -k2 -n | while IFS='|' read -r tag cpu avg min max variation; do
        printf "    %-4s  %-14s  %-14s  %-14s  %-10s\n" "$cpu" "$avg" "$min" "$max" "$variation"
    done

    echo ""
    echo -e "${GREEN}总体统计:${NC}"
    echo -e "  ${BLUE}•${NC} CPU 核心数: ${GREEN}${VALID_CPUS}${NC}"
    echo -e "  ${BLUE}•${NC} 平均频率: ${GREEN}${TOTAL_AVG} MHz${NC} ($(awk "BEGIN {printf \"%.2f\", $TOTAL_AVG / 1000}") GHz)"
    echo -e "  ${BLUE}•${NC} 最小频率: ${GREEN}${TOTAL_MIN} MHz${NC}"
    echo -e "  ${BLUE}•${NC} 最大频率: ${GREEN}${TOTAL_MAX} MHz${NC}"

    # 频率波动分析
    echo ""
    echo -e "${GREEN}频率波动分析:${NC}"

    VARIATION=$(awk "BEGIN {printf \"%.2f\", $TOTAL_MAX - $TOTAL_MIN}")
    VARIATION_PERCENT=$(awk "BEGIN {if ($TOTAL_MAX > 0) printf \"%.1f\", ($TOTAL_MAX - $TOTAL_MIN) * 100 / $TOTAL_MAX; else print \"0.0\"}")

    echo -e "  ${BLUE}•${NC} 波动范围: ${GREEN}${VARIATION} MHz${NC} (${VARIATION_PERCENT}%)"

    if [ $(echo "$VARIATION_PERCENT > 20" | bc 2>/dev/null || echo 0) -eq 1 ]; then
        echo -e "    ${YELLOW}注意: 频率波动较大 (${VARIATION_PERCENT}%)${NC}"
    else
        echo -e "    ${GREEN}✓${NC} 频率相对稳定"
    fi

    # 生成 JSON 数据
    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
    JSON_UNIX_TIME=$(date +%s)

    # 使用 awk 直接构建 CPU 数组 JSON（避免子 shell 问题）
    CPUS_JSON=$(grep "^CPU_DATA" $PARSED_DATA | sort -t'|' -k2 -n | awk -F'|' '
    BEGIN {
        json = ""
        count = 0
    }
    {
        tag = $1
        cpu = $2 + 0
        avg = $3 + 0
        min = $4 + 0
        max = $5 + 0
        variation = $6 + 0

        # 计算波动比例（波动占平均频率的百分比）
        if (avg > 0) {
            variation_ratio = (variation / avg) * 100
        } else {
            variation_ratio = 0
        }

        if (count > 0) json = json ",\n    "
        json = json sprintf("{\"cpu\": %d, \"avg_mhz\": %.2f, \"min_mhz\": %.2f, \"max_mhz\": %.2f, \"variation_mhz\": %.2f, \"variation_percent\": %.2f}",
                            cpu, avg, min, max, variation, variation_ratio)
        count++
    }
    END {
        print json
    }
    ')

    # 输出 JSON
    cat > $OUTPUT_JSON << EOF
{
  "timestamp": "$TIMESTAMP",
  "unix_time": $JSON_UNIX_TIME,
  "data_type": "cpu_frequency",
  "source": "proc_cpuinfo",
  "sampling": {
    "interval_sec": 1,
    "count": 5
  },
  "statistics": {
    "cpu_count": $VALID_CPUS,
    "avg_mhz": $TOTAL_AVG,
    "min_mhz": $TOTAL_MIN,
    "max_mhz": $TOTAL_MAX,
    "variation_mhz": $VARIATION,
    "variation_percent": $VARIATION_PERCENT,
    "stable": $(if [ $(echo "$VARIATION_PERCENT <= 20" | bc 2>/dev/null || echo 1) -eq 1 ]; then echo "true"; else echo "false"; fi)
  },
  "cpus": [$CPUS_JSON]
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

    exit 0
fi

# 采集数据 (turbostat)
{
    echo "################################################################################"
    echo "# CPU 频率和功耗监控 (turbostat)"
    echo "# 采样间隔: 1秒, 采样次数: 5次"
    echo "# 开始时间: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "################################################################################"
    echo ""
} > $TEMP_DIR/turbostat.txt

echo -e "${BLUE}执行命令: turbostat -i 1 -n 5${NC}"
timeout 7 turbostat -i 1 -n 5 2>/dev/null | tee -a $TEMP_DIR/turbostat.txt

echo ""
echo -e "${GREEN}解析结果:${NC}"

# 解析频率数据
if grep -q "Average" $TEMP_DIR/turbostat.txt 2>/dev/null; then
    # 如果有 Average 行，使用它
    echo -e "${GREEN}Average 行数据:${NC}"
    grep "Average" $TEMP_DIR/turbostat.txt
else
    # 否则计算平均值
    data_lines=$(grep -v "^#" $TEMP_DIR/turbostat.txt | grep -E "^[0-9]" | head -5)

    if [ -n "$data_lines" ]; then
        # 计算平均频率 (需要根据实际输出列调整)
        avg_mhz=$(echo "$data_lines" | awk '{sum+=$3; count++} END {if(count>0) print int(sum/count); else print 0}')

        echo -e "${GREEN}CPU 频率统计:${NC}"
        echo -e "  ${BLUE}•${NC} 平均频率: ${GREEN}${avg_mhz} MHz${NC} ($(($avg_mhz / 1000)) GHz)"

        # 获取基准频率
        if [ -f /sys/devices/system/cpu/cpu0/cpufreq/base_frequency ]; then
            base_mhz=$(($(cat /sys/devices/system/cpu/cpu0/cpufreq/base_frequency) / 1000))
            echo -e "  ${BLUE}•${NC} 基准频率: ${GREEN}${base_mhz} MHz${NC} ($(($base_mhz / 1000)) GHz)"
        fi

        # 获取最大频率
        if [ -f /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq ]; then
            max_mhz=$(($(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq) / 1000))
            echo -e "  ${BLUE}•${NC} 最大频率: ${GREEN}${max_mhz} MHz${NC} ($(($max_mhz / 1000)) GHz)"
        fi
    fi
fi

# 频率波动分析
echo ""
echo -e "${GREEN}频率波动分析:${NC}"

freq_samples=$(grep -v "^#" $TEMP_DIR/turbostat.txt | grep -E "^[0-9]" | awk '{print $3}' | grep -E "^[0-9]+$")

if [ -n "$freq_samples" ]; then
    count=$(echo "$freq_samples" | wc -l)
    min_freq=$(echo "$freq_samples" | sort -n | head -1)
    max_freq=$(echo "$freq_samples" | sort -n | tail -1)

    echo -e "  ${BLUE}•${NC} 采样数: ${GREEN}$count${NC}"
    echo -e "  ${BLUE}•${NC} 最小频率: ${GREEN}${min_freq} MHz${NC}"
    echo -e "  ${BLUE}•${NC} 最大频率: ${GREEN}${max_freq} MHz${NC}"

    if [ $max_freq -gt 0 ]; then
        variation=$((max_freq - min_freq))
        variation_percent=$((variation * 100 / max_freq))
        echo -e "  ${BLUE}•${NC} 波动范围: ${GREEN}${variation} MHz${NC} (${variation_percent}%)"

        if [ $variation_percent -gt 20 ]; then
            echo -e "    ${YELLOW}注意: 频率波动较大 (${variation_percent}%)${NC}"
        else
            echo -e "    ${GREEN}✓${NC} 频率相对稳定"
        fi
    fi
else
    echo -e "  ${YELLOW}无法解析频率数据${NC}"
fi

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}采集完成${NC}"
echo -e "${GREEN}========================================${NC}"
