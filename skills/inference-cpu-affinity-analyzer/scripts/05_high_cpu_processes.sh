#!/bin/bash

# 1.5 高 CPU 占用进程检测
# 用途: 检测高 CPU 占用的其他进程（干扰进程）
# 使用: ./05_high_cpu_processes.sh [PID]
#   参数:
#     无参数  - 检测所有高 CPU 进程
#     PID     - 排除指定 PID 及其所有子进程/子线程

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 输出文件配置
OUTPUT_DIR="profiler_output"
OUTPUT_TXT="${OUTPUT_DIR}/high_cpu_processes.txt"
OUTPUT_JSON="${OUTPUT_DIR}/high_cpu_processes.json"

# 创建输出目录
mkdir -p $OUTPUT_DIR

TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

# 参数: PID（可选，用于排除）
TARGET_PID=${1:-""}

# 构建排除列表（目标进程及其所有子进程/子线程）
EXCLUDE_LIST=""
EXCLUDE_PIDS=""

if [ -n "$TARGET_PID" ]; then
    echo -e "${BLUE}构建排除列表 (PID: $TARGET_PID)...${NC}"

    # 1. 获取目标进程的所有线程
    if [ -d /proc/$TARGET_PID/task ]; then
        for tid in $(ls /proc/$TARGET_PID/task/ 2>/dev/null); do
            EXCLUDE_PIDS="$EXCLUDE_PIDS $tid"
        done
    else
        # 使用 ps 获取线程
        EXCLUDE_PIDS=$(ps -L -p $TARGET_PID -o lwp= 2>/dev/null | tr '\n' ' ')
    fi

    # 2. 获取所有子进程（递归）
    # 使用 pstree 或 pgrep
    if command -v pstree &> /dev/null; then
        # pstree 可以显示进程树
        CHILD_PIDS=$(pstree -p $TARGET_PID -T 2>/dev/null | grep -oP '\(\K[0-9]+' | tr '\n' ' ')
        EXCLUDE_PIDS="$EXCLUDE_PIDS $CHILD_PIDS"
    fi

    # 使用 pgrep 获取子进程
    if command -v pgrep &> /dev/null; then
        # 递归查找所有子进程
        DIRECT_CHILDREN=$(pgrep -P $TARGET_PID 2>/dev/null | tr '\n' ' ')
        if [ -n "$DIRECT_CHILDREN" ]; then
            EXCLUDE_PIDS="$EXCLUDE_PIDS $DIRECT_CHILDREN"
            # 递归查找子进程的子进程（最多 2 层）
            for child in $DIRECT_CHILDREN; do
                GRANDCHILDREN=$(pgrep -P $child 2>/dev/null | tr '\n' ' ')
                EXCLUDE_PIDS="$EXCLUDE_PIDS $GRANDCHILDREN"
            done
        fi
    fi

    # 去重并排序
    EXCLUDE_PIDS=$(echo $EXCLUDE_PIDS | tr ' ' '\n' | sort -u | tr '\n' ' ' | xargs)

    # 构建 awk 排除条件（使用 && 确保所有排除条件都生效）
    for pid in $EXCLUDE_PIDS; do
        if [ -n "$EXCLUDE_LIST" ]; then
            EXCLUDE_LIST="$EXCLUDE_LIST && "
        fi
        EXCLUDE_LIST="$EXCLUDE_LIST\$2 != $pid"
    done

    echo -e "${BLUE}排除的 PID 数量: ${GREEN}$(echo $EXCLUDE_PIDS | wc -w)${NC}"
    echo -e "${BLUE}排除列表: ${GREEN}$EXCLUDE_PIDS${NC}"
else
    # 无排除条件
    EXCLUDE_LIST="1"
fi

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}1.5 高 CPU 占用进程检测${NC}"
echo -e "${GREEN}========================================${NC}"
if [ -n "$TARGET_PID" ]; then
    echo -e "目标进程: ${BLUE}$TARGET_PID${NC} (及其子进程/子线程将被排除)"
fi
echo -e "采样参数: ${BLUE}间隔 1秒, 5次采样${NC}"
echo ""

# 检查命令
if ! command -v ps &> /dev/null; then
    echo -e "${RED}错误: ps 命令未安装${NC}"
    exit 1
fi

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

# 原始数据文件
RAW_FILE=$TEMP_DIR/raw_samples.txt

# 5次采样
{
    echo "################################################################################"
    echo "# 高 CPU 占用进程监控"
    if [ -n "$TARGET_PID" ]; then
        echo "# 排除进程: $TARGET_PID 及其子进程/子线程"
    fi
    echo "# 采样间隔: 1秒, 采样次数: 5次"
    echo "# 开始时间: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "################################################################################"
} > $RAW_FILE

echo -e "${BLUE}执行 5 次采样...${NC}"
for i in {1..5}; do
    add_separator $RAW_FILE $i
    echo -e "  采样 #$i..."

    # 使用 awk 过滤排除的进程
    ps aux --sort=-%cpu | head -30 | awk "$EXCLUDE_LIST" >> $RAW_FILE

    [ $i -lt 5 ] && sleep 1
done

# 保存原始数据
cp $RAW_FILE $OUTPUT_TXT

# 最后一次采样，获取干扰进程列表 (CPU > 5%)
FINAL_SAMPLE=$TEMP_DIR/final_sample.txt
ps aux --sort=-%cpu | head -50 | awk "$EXCLUDE_LIST && \$3 > 5.0" > $FINAL_SAMPLE

echo ""
echo -e "${GREEN}高 CPU 干扰进程列表 (CPU > 5%):${NC}"

if [ -s $FINAL_SAMPLE ]; then
    echo "    %CPU  %MEM   PID    USER      COMMAND"

    # 先输出列表到 stdout
    awk '{
        pcpu = $3
        pmem = $4
        pid = $2
        user = $1
        # 命令从第11列开始
        cmd = ""
        for (i = 11; i <= NF; i++) {
            if (cmd != "") cmd = cmd " "
            cmd = cmd $i
        }
        printf "    %4s  %4s   %-6s %-9s %s\n", pcpu, pmem, pid, user, cmd
    }' $FINAL_SAMPLE

    # 使用 awk 解析并构建 JSON（输出到文件）
    INTERFERENCE_JSON=$TEMP_DIR/interference.json
    SUMMARY_FILE=$TEMP_DIR/summary.txt

    awk '
    BEGIN {
        json = ""
        count = 0
        total_cpu = 0
    }
    {
        pcpu = $3
        pmem = $4
        pid = $2
        user = $1
        # 命令从第11列开始
        cmd = ""
        for (i = 11; i <= NF; i++) {
            if (cmd != "") cmd = cmd " "
            cmd = cmd $i
        }

        # 构建 JSON
        if (count > 0) json = json ","
        json = json "{\"pid\": " pid ", \"user\": \"" user "\", \"cpu\": " pcpu ", \"mem\": " pmem ", \"command\": \"" cmd "\"}"

        total_cpu += pcpu
        count++
    }
    END {
        print json > "'"$INTERFERENCE_JSON"'"
        printf "COUNT=%d\n", count > "'"$SUMMARY_FILE"'"
        printf "TOTAL_CPU=%.2f\n", total_cpu >> "'"$SUMMARY_FILE"'"
    }
    ' $FINAL_SAMPLE

    # 读取统计信息
    INTERFERENCE_COUNT=$(grep "^COUNT=" $SUMMARY_FILE | cut -d'=' -f2)
    TOTAL_CPU=$(grep "^TOTAL_CPU=" $SUMMARY_FILE | cut -d'=' -f2)
    INTERFERENCE_JSON=$(cat $INTERFERENCE_JSON)

    echo ""
    echo -e "${GREEN}统计:${NC}"
    echo -e "  ${BLUE}•${NC} 干扰进程数: ${GREEN}$INTERFERENCE_COUNT${NC}"
    echo -e "  ${BLUE}•${NC} 总 CPU 占用: ${GREEN}${TOTAL_CPU}%${NC}"
else
    echo -e "  ${GREEN}✓${NC} 未检测到高 CPU 占用进程 (CPU > 5%)"
    INTERFERENCE_COUNT=0
    TOTAL_CPU=0
    INTERFERENCE_JSON=""
fi

# 生成 JSON 数据
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
JSON_UNIX_TIME=$(date +%s)

# 排除的进程列表（转为 JSON 数组）
EXCLUDE_JSON=""
if [ -n "$EXCLUDE_PIDS" ]; then
    FIRST=true
    for pid in $EXCLUDE_PIDS; do
        if [ "$FIRST" = true ]; then
            EXCLUDE_JSON="$pid"
            FIRST=false
        else
            EXCLUDE_JSON="$EXCLUDE_JSON, $pid"
        fi
    done
fi

cat > $OUTPUT_JSON << EOF
{
  "timestamp": "$TIMESTAMP",
  "unix_time": $JSON_UNIX_TIME,
  "data_type": "high_cpu_processes",
  "sampling": {
    "interval_sec": 1,
    "count": 5
  },
  "target_process": {
    "specified": $(if [ -n "$TARGET_PID" ]; then echo "true"; else echo "false"; fi),
    "pid": ${TARGET_PID:-null},
    "excluded_pids": [$EXCLUDE_JSON],
    "excluded_count": $(echo $EXCLUDE_PIDS | wc -w)
  },
  "interference_processes": {
    "count": $INTERFERENCE_COUNT,
    "total_cpu": $TOTAL_CPU,
    "threshold": 5.0,
    "processes": [$INTERFERENCE_JSON]
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
