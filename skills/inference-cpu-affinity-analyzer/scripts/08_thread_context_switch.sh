#!/bin/bash

# 1.8 线程上下文切换采集
# 用途: 采集线程上下文切换情况（5次采样）
# 使用: ./08_thread_context_switch.sh <PID>

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 输出文件配置
OUTPUT_DIR="profiler_output"
OUTPUT_TXT="${OUTPUT_DIR}/thread_context_switch.txt"
OUTPUT_JSON="${OUTPUT_DIR}/thread_context_switch.json"

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

# 检查命令
if ! command -v pidstat &> /dev/null; then
    echo -e "${RED}错误: pidstat 命令未安装 (属于 sysstat 包)${NC}"
    exit 1
fi

# 获取进程命令名
PROCESS_NAME=$(ps -p $PID -o comm= 2>/dev/null || echo "Unknown")

TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

# 采样次数
SAMPLE_COUNT=5

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}1.8 线程上下文切换采集${NC}"
echo -e "${GREEN}========================================${NC}"
echo -e "目标进程: ${BLUE}$PID${NC} (${GREEN}$PROCESS_NAME${NC})"
echo -e "采样参数: ${BLUE}间隔 1秒, 5次采样${NC}"
echo ""

# 采集数据
{
    echo "################################################################################"
    echo "# 线程上下文切换监控 - PID: $PID"
    echo "# 采样间隔: 1秒, 采样次数: 5次"
    echo "# 开始时间: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "################################################################################"
    echo ""
    echo "说明:"
    echo "  cswch/s:     自愿上下文切换/秒 (线程等待资源)"
    echo "  nvcswch/s:   非自愿上下文切换/秒 (线程被抢占)"
    echo ""
} > $TEMP_DIR/thread_context_switch_raw.txt

echo -e "${BLUE}执行命令: pidstat -w -p $PID -t 1 5${NC}"
timeout 7 pidstat -w -p $PID -t 1 5 2>/dev/null | tee -a $TEMP_DIR/thread_context_switch_raw.txt

# 保存原始数据
cp $TEMP_DIR/thread_context_switch_raw.txt $OUTPUT_TXT

# 使用 awk 解析数据并计算平均值
PARSED_DATA=$TEMP_DIR/parsed_data.txt

awk -v sample_count=$SAMPLE_COUNT '
BEGIN {
    total_vol = 0
    total_invol = 0
}
{
    line = $0

    # 跳过空行
    if (line ~ /^[[:space:]]*$/) next

    # 跳过标题行和说明行
    if (line ~ /^#/ || line ~ /^Time/ || line ~ /^Linux/ || line ~ /^Average/) next
    if (line ~ /说明/ || line ~ /cswch\/s/ || line ~ /nvcswch\/s/) next
    if (line ~ /自愿上下文切换/ || line ~ /非自愿上下文切换/) next

    # 检查是否有 AM/PM
    has_ampm = (line ~ /[0-9][0-9]:[0-9][0-9]:[0-9][0-9] [AP]M/)

    # 使用 split 解析
    n = split(line, f)

    if (has_ampm && n >= 8) {
        tid = f[5]
        cswch = f[6]
        nvcswch = f[7]
        # 直接使用 f[8]
        cmd = f[8]
    } else if (!has_ampm && n >= 7) {
        tid = f[4]
        cswch = f[5]
        nvcswch = f[6]
        # 直接使用 f[7]
        cmd = f[7]
    } else {
        next  # 跳过格式不正确的行
    }

    # 跳过 TID 为 "-" 的汇总行
    if (tid == "-" || tid == "") next
    if (tid !~ /^[0-9]+$/) next

    # 验证数值
    if (cswch !~ /^[0-9.]+$/) cswch = 0
    if (nvcswch !~ /^[0-9.]+$/) nvcswch = 0

    # 累加汇总
    total_vol += cswch
    total_invol += nvcswch

    # 记录线程数据（累加所有采样）
    thread_vol[tid] += cswch
    thread_invol[tid] += nvcswch
    thread_cmd[tid] = cmd
    thread_samples[tid]++
}
END {
    # 计算平均值
    avg_vol = total_vol / sample_count
    avg_invol = total_invol / sample_count

    # 输出总体统计
    printf "TOTAL_VOL=%.2f\n", avg_vol
    printf "TOTAL_INVOL=%.2f\n", avg_invol
    printf "THREAD_COUNT=%d\n", length(thread_vol)

    # 输出每个线程的平均值
    for (tid in thread_vol) {
        vol_avg = thread_vol[tid] / sample_count
        invol_avg = thread_invol[tid] / sample_count
        total_avg = vol_avg + invol_avg
        cmd = thread_cmd[tid]
        # 清理 cmd：去除首尾空格、前导的 | 和 __
        gsub(/^[[:space:]]+/, "", cmd)
        gsub(/[[:space:]]+$/, "", cmd)
        gsub(/^\|+/, "", cmd)      # 去除前导的 |
        gsub(/^__+/, "", cmd)      # 去除前导的 __
        printf "%d|%.2f|%.2f|%s\n", tid, vol_avg, invol_avg, cmd
    }
}
' $TEMP_DIR/thread_context_switch_raw.txt > $PARSED_DATA

# 读取解析结果
TOTAL_VOL=$(grep "^TOTAL_VOL=" $PARSED_DATA | cut -d'=' -f2)
TOTAL_INVOL=$(grep "^TOTAL_INVOL=" $PARSED_DATA | cut -d'=' -f2)
THREAD_COUNT=$(grep "^THREAD_COUNT=" $PARSED_DATA | cut -d'=' -f2)

echo ""
echo -e "${GREEN}解析结果 (平均值，${SAMPLE_COUNT}次采样):${NC}"

echo -e "${GREEN}总体统计:${NC}"
echo -e "  ${BLUE}•${NC} 平均自愿切换:     ${GREEN}${TOTAL_VOL}${NC} 次/秒"
echo -e "  ${BLUE}•${NC} 平均非自愿切换:   ${GREEN}${TOTAL_INVOL}${NC} 次/秒"
echo -e "  ${BLUE}•${NC} 线程数:           ${GREEN}${THREAD_COUNT}${NC}"

# 显示切换次数最高的线程
echo ""
echo -e "${GREEN}上下文切换最高的线程 (Top 10，按平均值排序):${NC}"
echo "    TID    自愿切换  非自愿切换  总计    COMMAND"

# 排序并显示
grep "^[0-9]" $PARSED_DATA | awk -F'|' '{
    tid = $1
    vol = $2
    invol = $3
    cmd = $4
    total = vol + invol
    printf "%.2f|%s|%s|%s|%s\n", total, tid, vol, invol, cmd
}' | sort -t'|' -rn -k1 | head -10 | while IFS='|' read -r total tid vol invol cmd; do
    printf "    %-5s  %-8s  %-10s  %-7s  %s\n" "$tid" "$vol" "$invol" "$total" "$cmd"
done

# 分析
echo ""
echo -e "${GREEN}分析:${NC}"

# 切换比例
if [ $(echo "$TOTAL_INVOL > 0" | bc 2>/dev/null || echo 0) -eq 1 ]; then
    ratio=$(awk "BEGIN {printf \"%.2f\", $TOTAL_INVOL / $TOTAL_VOL}")
    echo -e "  ${BLUE}•${NC} 非自愿/自愿切换比: ${GREEN}$ratio${NC}"
    if [ $(echo "$ratio > 0.5" | bc 2>/dev/null || echo 0) -eq 1 ]; then
        echo -e "    ${YELLOW}注意: 非自愿切换比例较高，可能存在 CPU 争用${NC}"
    else
        echo -e "    ${GREEN}✓${NC} 非自愿切换比例正常"
    fi
else
    echo -e "  ${BLUE}•${NC} 非自愿/自愿切换比: ${GREEN}0.00${NC}"
    echo -e "    ${GREEN}✓${NC} 无非自愿切换，CPU 资源充足"
fi

# 生成 JSON 数据
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
JSON_UNIX_TIME=$(date +%s)

echo -e "${YELLOW}[DEBUG] 开始构建 JSON...${NC}"

# 使用 awk 直接构建 JSON（避免子 shell 问题）
# 先排序，再构建 JSON
THREADS_JSON=$(grep "^[0-9]" $PARSED_DATA | awk -F'|' '{
    tid = $1
    vol = $2 + 0
    invol = $3 + 0
    cmd = $4
    total = vol + invol
    printf "%.2f|%s|%.2f|%.2f|%.2f|%s\n", total, tid, vol, invol, total, cmd
}' | sort -t'|' -rn -k1 | awk -F'|' '
BEGIN {
    json = ""
    count = 0
}
{
    tid = $2
    vol = $3 + 0
    invol = $4 + 0
    total = $5 + 0
    cmd = $6

    # 计算比例
    if (vol > 0) {
        ratio = sprintf("%.2f", invol / vol)
    } else {
        ratio = "0.00"
    }

    # 转义命令中的引号和反斜杠
    gsub(/\\/, "\\\\", cmd)
    gsub(/"/, "\\\"", cmd)

    # 构建 JSON
    if (count > 0) json = json ",\n    "
    json = json sprintf("{\"tid\": %s, \"voluntary\": %.2f, \"involuntary\": %.2f, \"total\": %.2f, \"command\": \"%s\", \"ratio\": %s}",
                        tid, vol, invol, total, cmd, ratio)
    count++
}
END {
    print json
}
')

# 计算总体切换比例
if [ $(echo "$TOTAL_VOL > 0" | bc 2>/dev/null || echo 0) -eq 1 ]; then
    TOTAL_RATIO=$(awk "BEGIN {printf \"%.2f\", $TOTAL_INVOL / $TOTAL_VOL}")
else
    TOTAL_RATIO="0.00"
fi

# 判断是否有 CPU 争用
CPU_CONTENTION="false"
if [ $(echo "$TOTAL_RATIO > 0.5" | bc 2>/dev/null || echo 0) -eq 1 ]; then
    CPU_CONTENTION="true"
fi
echo -e "${YELLOW}[DEBUG] TOTAL_RATIO=$TOTAL_RATIO, CPU_CONTENTION=$CPU_CONTENTION${NC}"

# 输出 JSON
cat > $OUTPUT_JSON << EOF
{
  "timestamp": "$TIMESTAMP",
  "unix_time": $JSON_UNIX_TIME,
  "data_type": "thread_context_switch",
  "target_pid": $PID,
  "process_name": "$PROCESS_NAME",
  "sampling": {
    "interval_sec": 1,
    "count": $SAMPLE_COUNT,
    "method": "average"
  },
  "statistics": {
    "avg_voluntary": $TOTAL_VOL,
    "avg_involuntary": $TOTAL_INVOL,
    "avg_total": $(awk "BEGIN {printf \"%.2f\", $TOTAL_VOL + $TOTAL_INVOL}"),
    "thread_count": $THREAD_COUNT,
    "involuntary_ratio": $TOTAL_RATIO,
    "cpu_contention": $CPU_CONTENTION
  },
  "threads": [
    $THREADS_JSON
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
