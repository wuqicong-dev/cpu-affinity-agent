#!/bin/bash

# 1.3 整体 CPU 使用率采集
# 用途: 采集系统整体 CPU 使用率（5次采样）
# 使用: ./03_system_cpu_usage.sh

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 输出文件配置
OUTPUT_DIR="profiler_output"
OUTPUT_TXT="${OUTPUT_DIR}/system_cpu_usage.txt"
OUTPUT_JSON="${OUTPUT_DIR}/system_cpu_usage.json"

# 创建输出目录
mkdir -p $OUTPUT_DIR

TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}1.3 整体 CPU 使用率采集${NC}"
echo -e "${GREEN}========================================${NC}"
echo -e "采样参数: ${BLUE}间隔 1秒, 5次采样${NC}"
echo ""

# 检查命令
if ! command -v sar &> /dev/null; then
    echo -e "${RED}错误: sar 命令未安装 (属于 sysstat 包)${NC}"
    exit 1
fi

# 采集数据
echo -e "${BLUE}执行命令: sar -u 1 5${NC}"
RAW_DATA=$TEMP_DIR/sar_raw.txt
timeout 7 sar -u 1 5 2>/dev/null | tee $RAW_DATA

# 保存原始数据
{
    echo "################################################################################"
    echo "# 整体 CPU 使用率监控"
    echo "# 采样间隔: 1秒, 采样次数: 5次"
    echo "# 开始时间: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "################################################################################"
    echo ""
    cat $RAW_DATA
} > $OUTPUT_TXT

echo -e "${BLUE}[DEBUG] 使用 awk 解析数据...${NC}"

# 使用 awk 解析数据并输出 JSON
PARSED_JSON=$TEMP_DIR/parsed_json.txt
PARSED_STATS=$TEMP_DIR/parsed_stats.txt

awk '
BEGIN {
    count = 0
    json_samples = ""
    sum_user = 0; sum_nice = 0; sum_sys = 0; sum_io = 0; sum_steal = 0; sum_idle = 0
}
/^[0-9][0-9]:[0-9][0-9]:[0-9][0-9]/ {
    # 匹配时间开头的行（数据行）
    # 检查是否有 AM/PM
    has_ampm = 0
    for (i = 1; i <= NF; i++) {
        if ($i == "AM" || $i == "PM") {
            has_ampm = 1
            break
        }
    }

    # 确定数据列索引
    if (has_ampm) {
        cpu_col = 3
        user_idx = 4
        nice_idx = 5
        sys_idx = 6
        io_idx = 7
        steal_idx = 8
        idle_idx = 9
    } else {
        cpu_col = 2
        user_idx = 3
        nice_idx = 4
        sys_idx = 5
        io_idx = 6
        steal_idx = 7
        idle_idx = 8
    }

    # 检查 CPU 列是否为 "all"
    if ($(cpu_col) != "all") next

    # 获取数值
    user = $(user_idx)
    nice = $(nice_idx)
    sys = $(sys_idx)
    io = $(io_idx)
    steal = $(steal_idx)
    idle = $(idle_idx)

    # 累加用于计算平均值
    sum_user += user
    sum_nice += nice
    sum_sys += sys
    sum_io += io
    sum_steal += steal
    sum_idle += idle

    # 构建 JSON 样本
    if (count > 0) json_samples = json_samples ","
    json_samples = json_samples "{\"user\": " user ", \"nice\": " nice ", \"system\": " sys ", \"iowait\": " io ", \"steal\": " steal ", \"idle\": " idle "}"

    # 保存样本用于计算标准差
    samples_user[count] = user
    samples_nice[count] = nice
    samples_sys[count] = sys
    samples_io[count] = io
    samples_steal[count] = steal
    samples_idle[count] = idle

    count++
}
END {
    # 输出样本 JSON
    print json_samples > "'"$PARSED_JSON"'"

    # 计算平均值
    if (count > 0) {
        avg_user = sum_user / count
        avg_nice = sum_nice / count
        avg_sys = sum_sys / count
        avg_io = sum_io / count
        avg_steal = sum_steal / count
        avg_idle = sum_idle / count

        # 计算标准差
        var_user = 0; var_nice = 0; var_sys = 0; var_io = 0; var_steal = 0; var_idle = 0
        for (i = 0; i < count; i++) {
            var_user += (samples_user[i] - avg_user) ^ 2
            var_nice += (samples_nice[i] - avg_nice) ^ 2
            var_sys += (samples_sys[i] - avg_sys) ^ 2
            var_io += (samples_io[i] - avg_io) ^ 2
            var_steal += (samples_steal[i] - avg_steal) ^ 2
            var_idle += (samples_idle[i] - avg_idle) ^ 2
        }
        stddev_user = sqrt(var_user / count)
        stddev_nice = sqrt(var_nice / count)
        stddev_sys = sqrt(var_sys / count)
        stddev_io = sqrt(var_io / count)
        stddev_steal = sqrt(var_steal / count)
        stddev_idle = sqrt(var_idle / count)

        # 输出统计信息
        printf "USER_AVG=%.2f\n", avg_user > "'"$PARSED_STATS"'"
        printf "NICE_AVG=%.2f\n", avg_nice >> "'"$PARSED_STATS"'"
        printf "SYSTEM_AVG=%.2f\n", avg_sys >> "'"$PARSED_STATS"'"
        printf "IOWAIT_AVG=%.2f\n", avg_io >> "'"$PARSED_STATS"'"
        printf "STEAL_AVG=%.2f\n", avg_steal >> "'"$PARSED_STATS"'"
        printf "IDLE_AVG=%.2f\n", avg_idle >> "'"$PARSED_STATS"'"
        printf "USER_STDDEV=%.2f\n", stddev_user >> "'"$PARSED_STATS"'"
        printf "NICE_STDDEV=%.2f\n", stddev_nice >> "'"$PARSED_STATS"'"
        printf "SYSTEM_STDDEV=%.2f\n", stddev_sys >> "'"$PARSED_STATS"'"
        printf "IOWAIT_STDDEV=%.2f\n", stddev_io >> "'"$PARSED_STATS"'"
        printf "STEAL_STDDEV=%.2f\n", stddev_steal >> "'"$PARSED_STATS"'"
        printf "IDLE_STDDEV=%.2f\n", stddev_idle >> "'"$PARSED_STATS"'"
        printf "COUNT=%d\n", count >> "'"$PARSED_STATS"'"
    } else {
        # 无数据
        printf "USER_AVG=0.00\n" > "'"$PARSED_STATS"'"
        printf "NICE_AVG=0.00\n" >> "'"$PARSED_STATS"'"
        printf "SYSTEM_AVG=0.00\n" >> "'"$PARSED_STATS"'"
        printf "IOWAIT_AVG=0.00\n" >> "'"$PARSED_STATS"'"
        printf "STEAL_AVG=0.00\n" >> "'"$PARSED_STATS"'"
        printf "IDLE_AVG=0.00\n" >> "'"$PARSED_STATS"'"
        printf "USER_STDDEV=0.00\n" >> "'"$PARSED_STATS"'"
        printf "NICE_STDDEV=0.00\n" >> "'"$PARSED_STATS"'"
        printf "SYSTEM_STDDEV=0.00\n" >> "'"$PARSED_STATS"'"
        printf "IOWAIT_STDDEV=0.00\n" >> "'"$PARSED_STATS"'"
        printf "STEAL_STDDEV=0.00\n" >> "'"$PARSED_STATS"'"
        printf "IDLE_STDDEV=0.00\n" >> "'"$PARSED_STATS"'"
        printf "COUNT=0\n" >> "'"$PARSED_STATS"'"
    }
}
' $RAW_DATA

# 读取解析结果
SAMPLE_COUNT=$(grep "^COUNT=" $PARSED_STATS | cut -d'=' -f2)
USER_AVG=$(grep "^USER_AVG=" $PARSED_STATS | cut -d'=' -f2)
NICE_AVG=$(grep "^NICE_AVG=" $PARSED_STATS | cut -d'=' -f2)
SYSTEM_AVG=$(grep "^SYSTEM_AVG=" $PARSED_STATS | cut -d'=' -f2)
IOWAIT_AVG=$(grep "^IOWAIT_AVG=" $PARSED_STATS | cut -d'=' -f2)
STEAL_AVG=$(grep "^STEAL_AVG=" $PARSED_STATS | cut -d'=' -f2)
IDLE_AVG=$(grep "^IDLE_AVG=" $PARSED_STATS | cut -d'=' -f2)
USER_STDDEV=$(grep "^USER_STDDEV=" $PARSED_STATS | cut -d'=' -f2)
NICE_STDDEV=$(grep "^NICE_STDDEV=" $PARSED_STATS | cut -d'=' -f2)
SYSTEM_STDDEV=$(grep "^SYSTEM_STDDEV=" $PARSED_STATS | cut -d'=' -f2)
IOWAIT_STDDEV=$(grep "^IOWAIT_STDDEV=" $PARSED_STATS | cut -d'=' -f2)
STEAL_STDDEV=$(grep "^STEAL_STDDEV=" $PARSED_STATS | cut -d'=' -f2)
IDLE_STDDEV=$(grep "^IDLE_STDDEV=" $PARSED_STATS | cut -d'=' -f2)

SAMPLES_JSON=$(cat $PARSED_JSON)

echo -e "${YELLOW}[DEBUG] 解析完成: ${SAMPLE_COUNT} 个样本${NC}"

echo ""
echo -e "${GREEN}解析结果 (${SAMPLE_COUNT} 次采样):${NC}"
echo -e "  ${BLUE}•${NC} User:   平均=${GREEN}${USER_AVG}%${NC}, 标准差=${GREEN}${USER_STDDEV}${NC}"
echo -e "  ${BLUE}•${NC} Nice:   平均=${GREEN}${NICE_AVG}%${NC}, 标准差=${GREEN}${NICE_STDDEV}${NC}"
echo -e "  ${BLUE}•${NC} System: 平均=${GREEN}${SYSTEM_AVG}%${NC}, 标准差=${GREEN}${SYSTEM_STDDEV}${NC}"
echo -e "  ${BLUE}•${NC} IOWait: 平均=${GREEN}${IOWAIT_AVG}%${NC}, 标准差=${GREEN}${IOWAIT_STDDEV}${NC}"
echo -e "  ${BLUE}•${NC} Steal:  平均=${GREEN}${STEAL_AVG}%${NC}, 标准差=${GREEN}${STEAL_STDDEV}${NC}"
echo -e "  ${BLUE}•${NC} Idle:   平均=${GREEN}${IDLE_AVG}%${NC}, 标准差=${GREEN}${IDLE_STDDEV}${NC}"

# 生成 JSON 数据
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
JSON_UNIX_TIME=$(date +%s)

cat > $OUTPUT_JSON << EOF
{
  "timestamp": "$TIMESTAMP",
  "unix_time": $JSON_UNIX_TIME,
  "data_type": "system_cpu_usage",
  "sampling": {
    "interval_sec": 1,
    "count": $SAMPLE_COUNT
  },
  "statistics": {
    "user": {"avg": $USER_AVG, "stddev": $USER_STDDEV},
    "nice": {"avg": $NICE_AVG, "stddev": $NICE_STDDEV},
    "system": {"avg": $SYSTEM_AVG, "stddev": $SYSTEM_STDDEV},
    "iowait": {"avg": $IOWAIT_AVG, "stddev": $IOWAIT_STDDEV},
    "steal": {"avg": $STEAL_AVG, "stddev": $STEAL_STDDEV},
    "idle": {"avg": $IDLE_AVG, "stddev": $IDLE_STDDEV}
  },
  "samples": [$SAMPLES_JSON]
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
