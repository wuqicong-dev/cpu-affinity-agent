#!/bin/bash

# 1.2 目标进程线程列表
# 用途: 获取目标进程的所有线程列表
# 使用: ./02_thread_list.sh <PID>

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

# 输出文件配置
OUTPUT_DIR="profiler_output"
OUTPUT_TXT="${OUTPUT_DIR}/thread_list.txt"
OUTPUT_JSON="${OUTPUT_DIR}/thread_list.json"

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

TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

# 获取进程命令名
PROCESS_NAME=$(ps -p $PID -o comm= 2>/dev/null || echo "Unknown")

# 判断是否为 VLLM 进程（检查进程名或命令行）
IS_VLLM=false
if echo "$PROCESS_NAME" | grep -qiE "vllm|python"; then
    # 进一步检查命令行是否包含 vllm
    CMDLINE=$(ps -p $PID -o args= 2>/dev/null || echo "")
    if echo "$CMDLINE" | grep -qi "vllm"; then
        IS_VLLM=true
    fi
fi

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}1.2 目标进程线程列表${NC}"
echo -e "${GREEN}========================================${NC}"
echo -e "目标进程: ${BLUE}$PID${NC} (${GREEN}$PROCESS_NAME${NC})"

if [ "$IS_VLLM" = true ]; then
    echo -e "进程类型: ${GREEN}VLLM${NC} (使用 VLLM 特定线程识别)"
else
    echo -e "进程类型: ${YELLOW}通用${NC} (使用动态线程识别: CPU 最高的 5 个线程为主要线程)"
fi
echo ""

# 优先使用 ps 命令获取线程列表，失败时使用 /proc 兜底
USE_PROC=false

if ps -L -p $PID -o lwp= > /dev/null 2>&1; then
    echo -e "${BLUE}使用 ps 命令获取线程列表...${NC}"

    # 获取所有线程（不使用 --sort，确保包含 CPU 使用率为 0 的线程）
    # 然后按 CPU 使用率降序排序
    {
        echo "################################################################################"
        echo "# 目标进程线程列表 - PID: $PID"
        echo "# 采集时间: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "# 采集方法: ps"
        echo "################################################################################"
        echo ""
        echo "格式: PID | LWP(线程ID) | PSR(运行核心) | %CPU | STAT | TIME | COMM"
        echo ""
        # 使用 awk 按第4列（%CPU）数值降序排序
        ps -L -p $PID -o pid,lwp,psr,pcpu,stat,time,comm 2>/dev/null | \
            awk 'NR>1 {
                cpu = $4 + 0  # 转换为数值
                printf "%10.2f %s\n", cpu, $0
            }' | \
            sort -rn | \
            awk '{print substr($0, 12)}'
    } > $TEMP_DIR/target_threads.txt

    # 获取线程ID列表（获取所有线程）
    TARGET_THREADS=$(ps -L -p $PID -o lwp= 2>/dev/null | tr '\n' ' ' | xargs)
    echo "$TARGET_THREADS" > $TEMP_DIR/target_threads_list.txt

    # 获取线程总数
    ACTUAL_THREAD_COUNT=$(ps -L -p $PID -o lwp= 2>/dev/null | grep -c '.' || echo "0")

    # 检查是否获取到数据
    if [ -z "$TARGET_THREADS" ] || [ "$ACTUAL_THREAD_COUNT" -eq 0 ]; then
        echo -e "${YELLOW}ps 命令未获取到线程数据，尝试 /proc 方法...${NC}"
        USE_PROC=true
    fi
else
    echo -e "${YELLOW}ps 命令不可用，尝试 /proc 方法...${NC}"
    USE_PROC=true
fi

# 使用 /proc 方法兜底
if [ "$USE_PROC" = true ]; then
    if [ -d /proc/$PID/task ]; then
        echo -e "${BLUE}使用 /proc 方法获取线程列表...${NC}"

        # 获取线程数
        ACTUAL_THREAD_COUNT=$(ls /proc/$PID/task/ 2>/dev/null | wc -l)

        # 获取线程详情
        {
            echo "################################################################################"
            echo "# 目标进程线程列表 - PID: $PID"
            echo "# 采集时间: $(date '+%Y-%m-%d %H:%M:%S')"
            echo "# 采集方法: /proc"
            echo "# 线程总数: $ACTUAL_THREAD_COUNT"
            echo "################################################################################"
            echo ""
            echo "格式: PID | LWP(线程ID) | PSR(运行核心) | %CPU | STAT | TIME | COMM"
            echo ""

            for tid in $(ls /proc/$PID/task/ 2>/dev/null); do
                ps -p $PID -T -o pid,lwp,psr,pcpu,stat,time,comm 2>/dev/null | grep "^[[:space:]]*$PID[[:space:]]\+$tid[[:space:]]"
            done | sort -t. -k4 -nr
        } > $TEMP_DIR/target_threads.txt

        # 保存线程ID列表
        TARGET_THREADS=$(ls /proc/$PID/task/ 2>/dev/null | tr '\n' ' ' | xargs)
        echo "$TARGET_THREADS" > $TEMP_DIR/target_threads_list.txt
    else
        echo -e "${RED}错误: 无法获取线程列表，ps 和 /proc 方法都失败${NC}"
        exit 1
    fi
fi

echo ""
echo -e "${GREEN}线程列表:${NC}"
cat $TEMP_DIR/target_threads.txt

echo ""
echo -e "${GREEN}统计信息:${NC}"
echo -e "  ${BLUE}•${NC} 线程总数: ${GREEN}$ACTUAL_THREAD_COUNT${NC}"
echo -e "  ${BLUE}•${NC} 线程ID列表: ${GREEN}$(cat $TEMP_DIR/target_threads_list.txt)${NC}"

# 保存原始数据
cp $TEMP_DIR/target_threads.txt $OUTPUT_TXT

# 生成 JSON 数据
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
JSON_UNIX_TIME=$(date +%s)

# 解析线程详情用于 JSON
THREADS_JSON=""
COLLECTION_METHOD="ps"
if [ "$USE_PROC" = true ]; then
    COLLECTION_METHOD="proc"
fi

# 构建线程 JSON 数组
while IFS= read -r line; do
    # 跳过标题行和注释行
    [[ "$line" =~ ^# ]] && continue
    [[ "$line" =~ ^格式 ]] && continue
    [[ "$line" =~ ^$ ]] && continue

    # 解析行数据
    read -ra fields <<< "$line"
    if [ ${#fields[@]} -ge 7 ]; then
        pid="${fields[0]}"
        lwp="${fields[1]}"
        psr="${fields[2]}"
        pcpu="${fields[3]}"
        stat="${fields[4]}"
        time="${fields[5]}"
        comm="${fields[@]:6}"

        # 清理 %CPU 中的百分号
        pcpu="${pcpu%\%}"

        if [ -n "$THREADS_JSON" ]; then
            THREADS_JSON="$THREADS_JSON,"
        fi
        THREADS_JSON="$THREADS_JSON{\"pid\": $pid, \"tid\": $lwp, \"cpu_usage\": \"$pcpu\", \"comm\": \"$comm\"}"
    fi
done < $TEMP_DIR/target_threads.txt

# 判断线程类型并统计
if [ "$IS_VLLM" = true ]; then
    # VLLM 进程：使用原有的线程识别逻辑
    CORE_THREADS=$(echo "$THREADS_JSON" | grep -o '"comm": "VLLM::Worker' | wc -l)
    ACL_THREADS=$(echo "$THREADS_JSON" | grep -o '"comm": "acl_thread' | wc -l)
    RELEASE_THREADS=$(echo "$THREADS_JSON" | grep -o '"comm": "release_thread' | wc -l)
    PRIMARY_THREADS=$CORE_THREADS
    AUXILIARY_THREADS=$((ACTUAL_THREAD_COUNT - CORE_THREADS - ACL_THREADS - RELEASE_THREADS))
    THREAD_TYPE="vllm"
else
    # 通用进程：CPU 最高的 5 个线程为主要线程
    PRIMARY_THREADS=5
    if [ $ACTUAL_THREAD_COUNT -lt 5 ]; then
        PRIMARY_THREADS=$ACTUAL_THREAD_COUNT
    fi
    AUXILIARY_THREADS=$((ACTUAL_THREAD_COUNT - PRIMARY_THREADS))
    CORE_THREADS=0
    ACL_THREADS=0
    RELEASE_THREADS=0
    THREAD_TYPE="generic"
fi

# 输出 JSON
cat > $OUTPUT_JSON << EOF
{
  "timestamp": "$TIMESTAMP",
  "unix_time": $JSON_UNIX_TIME,
  "data_type": "thread_list",
  "target_pid": $PID,
  "process_name": "$PROCESS_NAME",
  "process_type": "$THREAD_TYPE",
  "collection_method": "$COLLECTION_METHOD",
  "thread_count": {
    "total": $ACTUAL_THREAD_COUNT,
    "primary_threads": $PRIMARY_THREADS,
    "auxiliary_threads": $AUXILIARY_THREADS
  },
  "vllm_specific": {
    "vllm_worker": $CORE_THREADS,
    "acl_thread": $ACL_THREADS,
    "release_thread": $RELEASE_THREADS,
    "other": $(($ACTUAL_THREAD_COUNT - $CORE_THREADS - $ACL_THREADS - $RELEASE_THREADS))
  },
  "threads": [$THREADS_JSON]
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
