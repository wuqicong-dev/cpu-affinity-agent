#!/bin/bash

# 1.6 线程 CPU 使用率采集
# 用途: 采集目标进程线程 CPU 使用率（5次采样）
# 使用: ./06_thread_cpu_usage.sh <PID>

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 输出文件配置
OUTPUT_DIR="profiler_output"
OUTPUT_TXT="${OUTPUT_DIR}/thread_cpu_usage.txt"
OUTPUT_JSON="${OUTPUT_DIR}/thread_cpu_usage.json"

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

# 判断是否为 VLLM 进程
IS_VLLM=false
if echo "$PROCESS_NAME" | grep -qiE "vllm|python"; then
    CMDLINE=$(ps -p $PID -o args= 2>/dev/null || echo "")
    if echo "$CMDLINE" | grep -qi "vllm"; then
        IS_VLLM=true
    fi
fi

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}1.6 线程 CPU 使用率采集${NC}"
echo -e "${GREEN}========================================${NC}"
echo -e "目标进程: ${BLUE}$PID${NC} (${GREEN}$PROCESS_NAME${NC})"

if [ "$IS_VLLM" = true ]; then
    echo -e "进程类型: ${GREEN}VLLM${NC} (监控 VLLM::Worker, acl_thread, release_thread)"
else
    echo -e "进程类型: ${YELLOW}通用${NC} (监控 CPU 最高的 5 个线程)"
fi
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

# 5次采样 - 使用纯 ps 命令获取所有线程
{
    echo "################################################################################"
    echo "# 线程 CPU 使用率监控 (按CPU使用率排序) - PID: $PID"
    echo "# 采样间隔: 1秒, 采样次数: 5次"
    echo "# 开始时间: $(date '+%Y-%m-%d %H:%M:%S')"
    if [ "$IS_VLLM" = true ]; then
        echo "# 核心线程: VLLM::Worker, acl_thread, release_thread"
    else
        echo "# 核心线程: CPU 最高的 5 个线程"
    fi
    echo "################################################################################"
} > $TEMP_DIR/thread_cpu_usage_raw.txt

echo -e "${BLUE}执行 5 次采样...${NC}"
for i in {1..5}; do
    add_separator $TEMP_DIR/thread_cpu_usage_raw.txt $i
    echo -e "  采样 #$i..."
    {
        echo "=== 按CPU使用率排序 ==="
        # 使用 awk 排序，确保包含所有线程（包括 0% CPU 的）
        ps -L -p $PID -o pid,lwp,psr,pcpu,stat,time,comm 2>/dev/null | \
            awk 'NR>1 {
                cpu = $4 + 0
                printf "%10.2f %s\n", cpu, $0
            }' | \
            sort -rn | \
            awk '{print substr($0, 12)}' || echo "ps 命令执行失败"
        echo ""
        echo "=== 核心线程筛选 ==="
        if [ "$IS_VLLM" = true ]; then
            # VLLM: 筛选 VLLM::Worker, acl_thread, release_thread
            ps -L -p $PID -o pid,lwp,psr,pcpu,stat,time,comm 2>/dev/null | \
                awk 'NR>1 {
                    cpu = $4 + 0
                    printf "%10.2f %s\n", cpu, $0
                }' | \
                sort -rn | \
                awk '{print substr($0, 12)}' | \
                grep -E "VLLM::Worker|acl_thread|release_thread" || echo "未找到核心线程"
        else
            # 通用: CPU 最高的 5 个线程
            ps -L -p $PID -o pid,lwp,psr,pcpu,stat,time,comm 2>/dev/null | \
                awk 'NR>1 {
                    cpu = $4 + 0
                    printf "%10.2f %s\n", cpu, $0
                }' | \
                sort -rn | \
                awk '{print substr($0, 12)}' | \
                head -5 || echo "未找到线程"
        fi
        echo ""
    } >> $TEMP_DIR/thread_cpu_usage_raw.txt
    [ $i -lt 5 ] && sleep 1
done

# 保存原始数据
cp $TEMP_DIR/thread_cpu_usage_raw.txt $OUTPUT_TXT

# 解析最后一次采样数据用于 JSON 和 stdout 显示
FINAL_SAMPLE=$TEMP_DIR/final_sample.txt
grep -A 100 "采样 #5" $TEMP_DIR/thread_cpu_usage_raw.txt | \
    awk '/=== 按CPU使用率排序 ===/,/^=== 核心线程筛选 ===$/' | \
    grep -E "^[[:space:]]*[0-9]+" > $FINAL_SAMPLE

# 核心线程数据
CORE_THREADS_DATA=$TEMP_DIR/core_threads.txt
if [ "$IS_VLLM" = true ]; then
    grep -A 100 "采样 #5" $TEMP_DIR/thread_cpu_usage_raw.txt | \
        awk '/=== 核心线程筛选 ===/,0' | \
        grep -E "VLLM::Worker|acl_thread|release_thread" > $CORE_THREADS_DATA
else
    grep -A 100 "采样 #5" $TEMP_DIR/thread_cpu_usage_raw.txt | \
        awk '/=== 核心线程筛选 ===/,0' | \
        grep -E "^[[:space:]]*[0-9]+" > $CORE_THREADS_DATA
fi

# 显示最后一次采样的结果
echo ""
echo -e "${GREEN}最后一次采样结果 (按 CPU 使用率排序，前 20 个):${NC}"
echo "    PID    LWP    PSR    %CPU  STAT     TIME     COMMAND"

cat $FINAL_SAMPLE | head -20 | while read line; do
    pid=$(echo "$line" | awk '{print $1}')
    lwp=$(echo "$line" | awk '{print $2}')
    psr=$(echo "$line" | awk '{print $3}')
    pcpu=$(echo "$line" | awk '{print $4}')
    stat=$(echo "$line" | awk '{print $5}')
    time=$(echo "$line" | awk '{print $6}')
    comm=$(echo "$line" | awk '{for(i=7;i<=NF;i++) printf "%s ", $i; print ""}' | sed 's/[[:space:]]*$//')
    printf "    %-5s  %-5s  %-3s   %-5s  %-4s  %-8s %s\n" "$pid" "$lwp" "$psr" "$pcpu" "$stat" "$time" "$comm"
done

# 统计核心线程
echo ""
echo -e "${GREEN}核心线程 CPU 使用率统计:${NC}"

if [ -s $CORE_THREADS_DATA ]; then
    if [ "$IS_VLLM" = true ]; then
        # VLLM 进程：统计各类核心线程
        VLLM_COUNT=0
        VLLM_TOTAL_CPU=0
        ACL_COUNT=0
        ACL_TOTAL_CPU=0
        RELEASE_COUNT=0
        RELEASE_TOTAL_CPU=0

        echo "    PID    LWP    PSR    %CPU  STAT     TIME     COMMAND"
        while read line; do
            pid=$(echo "$line" | awk '{print $1}')
            lwp=$(echo "$line" | awk '{print $2}')
            psr=$(echo "$line" | awk '{print $3}')
            pcpu=$(echo "$line" | awk '{print $4}')
            stat=$(echo "$line" | awk '{print $5}')
            time=$(echo "$line" | awk '{print $6}')
            comm=$(echo "$line" | awk '{for(i=7;i<=NF;i++) printf "%s ", $i; print ""}' | sed 's/[[:space:]]*$//')

            printf "    %-5s  %-5s  %-3s   %-5s  %-4s  %-8s %s\n" "$pid" "$lwp" "$psr" "$pcpu" "$stat" "$time" "$comm"

            # 统计
            cpu_val=$(echo "$pcpu" | sed 's/%//')
            if echo "$comm" | grep -q "VLLM::Worker"; then
                VLLM_COUNT=$((VLLM_COUNT + 1))
                VLLM_TOTAL_CPU=$(echo "$VLLM_TOTAL_CPU + $cpu_val" | bc)
            elif echo "$comm" | grep -q "acl_thread"; then
                ACL_COUNT=$((ACL_COUNT + 1))
                ACL_TOTAL_CPU=$(echo "$ACL_TOTAL_CPU + $cpu_val" | bc)
            elif echo "$comm" | grep -q "release_thread"; then
                RELEASE_COUNT=$((RELEASE_COUNT + 1))
                RELEASE_TOTAL_CPU=$(echo "$RELEASE_TOTAL_CPU + $cpu_val" | bc)
            fi
        done < $CORE_THREADS_DATA

        echo ""
        echo -e "${GREEN}统计汇总:${NC}"
        [ $VLLM_COUNT -gt 0 ] && echo -e "  ${BLUE}•${NC} VLLM::Worker:  数量=${GREEN}$VLLM_COUNT${NC}, 总CPU=${GREEN}${VLLM_TOTAL_CPU}%${NC}"
        [ $ACL_COUNT -gt 0 ] && echo -e "  ${BLUE}•${NC} acl_thread:     数量=${GREEN}$ACL_COUNT${NC}, 总CPU=${GREEN}${ACL_TOTAL_CPU}%${NC}"
        [ $RELEASE_COUNT -gt 0 ] && echo -e "  ${BLUE}•${NC} release_thread: 数量=${GREEN}$RELEASE_COUNT${NC}, 总CPU=${GREEN}${RELEASE_TOTAL_CPU}%${NC}"
    else
        # 通用进程：统计主要线程
        PRIMARY_COUNT=0
        PRIMARY_TOTAL_CPU=0

        echo "    PID    LWP    PSR    %CPU  STAT     TIME     COMMAND"
        while read line; do
            pid=$(echo "$line" | awk '{print $1}')
            lwp=$(echo "$line" | awk '{print $2}')
            psr=$(echo "$line" | awk '{print $3}')
            pcpu=$(echo "$line" | awk '{print $4}')
            stat=$(echo "$line" | awk '{print $5}')
            time=$(echo "$line" | awk '{print $6}')
            comm=$(echo "$line" | awk '{for(i=7;i<=NF;i++) printf "%s ", $i; print ""}' | sed 's/[[:space:]]*$//')

            printf "    %-5s  %-5s  %-3s   %-5s  %-4s  %-8s %s\n" "$pid" "$lwp" "$psr" "$pcpu" "$stat" "$time" "$comm"

            # 统计
            cpu_val=$(echo "$pcpu" | sed 's/%//')
            PRIMARY_COUNT=$((PRIMARY_COUNT + 1))
            PRIMARY_TOTAL_CPU=$(echo "$PRIMARY_TOTAL_CPU + $cpu_val" | bc)
        done < $CORE_THREADS_DATA

        echo ""
        echo -e "${GREEN}统计汇总:${NC}"
        echo -e "  ${BLUE}•${NC} 主要线程 (Top CPU):  数量=${GREEN}$PRIMARY_COUNT${NC}, 总CPU=${GREEN}${PRIMARY_TOTAL_CPU}%${NC}"

        # 兼容 VLLM 变量（用于后续 JSON 生成）
        VLLM_COUNT=$PRIMARY_COUNT
        VLLM_TOTAL_CPU=$PRIMARY_TOTAL_CPU
        ACL_COUNT=0
        ACL_TOTAL_CPU=0
        RELEASE_COUNT=0
        RELEASE_TOTAL_CPU=0
    fi
else
    if [ "$IS_VLLM" = true ]; then
        echo -e "  ${YELLOW}未找到核心线程 (VLLM::Worker/acl_thread/release_thread)${NC}"
    else
        echo -e "  ${YELLOW}未找到主要线程${NC}"
    fi
    VLLM_COUNT=0
    VLLM_TOTAL_CPU=0
    ACL_COUNT=0
    ACL_TOTAL_CPU=0
    RELEASE_COUNT=0
    RELEASE_TOTAL_CPU=0
fi

# 生成 JSON 数据
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
JSON_UNIX_TIME=$(date +%s)

# 构建线程 JSON 数组（所有线程，按 CPU 使用率排序）
THREADS_JSON=""
while read line; do
    pid=$(echo "$line" | awk '{print $1}')
    lwp=$(echo "$line" | awk '{print $2}')
    psr=$(echo "$line" | awk '{print $3}')
    pcpu=$(echo "$line" | awk '{print $4}')
    comm=$(echo "$line" | awk '{for(i=7;i<=NF;i++) printf "%s ", $i; print ""}' | sed 's/[[:space:]]*$//')

    pcpu_clean=$(echo "$pcpu" | sed 's/%//')

    if [ -n "$THREADS_JSON" ]; then
        THREADS_JSON="$THREADS_JSON,"
    fi
    THREADS_JSON="$THREADS_JSON{\"pid\": $pid, \"tid\": $lwp, \"cpu\": $psr, \"cpu_usage\": $pcpu_clean, \"comm\": \"$comm\"}"
done < $FINAL_SAMPLE

# 构建核心线程 JSON 数组
CORE_THREADS_JSON=""
while read line; do
    pid=$(echo "$line" | awk '{print $1}')
    lwp=$(echo "$line" | awk '{print $2}')
    psr=$(echo "$line" | awk '{print $3}')
    pcpu=$(echo "$line" | awk '{print $4}')
    comm=$(echo "$line" | awk '{for(i=7;i<=NF;i++) printf "%s ", $i; print ""}' | sed 's/[[:space:]]*$//')

    pcpu_clean=$(echo "$pcpu" | sed 's/%//')

    # 确定线程类型
    if [ "$IS_VLLM" = true ]; then
        thread_type="other"
        if echo "$comm" | grep -q "VLLM::Worker"; then
            thread_type="vllm_worker"
        elif echo "$comm" | grep -q "acl_thread"; then
            thread_type="acl_thread"
        elif echo "$comm" | grep -q "release_thread"; then
            thread_type="release_thread"
        fi
    else
        thread_type="primary"
    fi

    if [ -n "$CORE_THREADS_JSON" ]; then
        CORE_THREADS_JSON="$CORE_THREADS_JSON,"
    fi
    CORE_THREADS_JSON="$CORE_THREADS_JSON{\"pid\": $pid, \"tid\": $lwp, \"cpu\": $psr, \"cpu_usage\": $pcpu_clean, \"comm\": \"$comm\", \"type\": \"$thread_type\"}"
done < $CORE_THREADS_DATA

# 计算平均值
VLLM_AVG_CPU="0.00"
ACL_AVG_CPU="0.00"
RELEASE_AVG_CPU="0.00"

if [ $VLLM_COUNT -gt 0 ]; then
    VLLM_AVG_CPU=$(echo "scale=2; $VLLM_TOTAL_CPU / $VLLM_COUNT" | bc)
fi
if [ $ACL_COUNT -gt 0 ]; then
    ACL_AVG_CPU=$(echo "scale=2; $ACL_TOTAL_CPU / $ACL_COUNT" | bc)
fi
if [ $RELEASE_COUNT -gt 0 ]; then
    RELEASE_AVG_CPU=$(echo "scale=2; $RELEASE_TOTAL_CPU / $RELEASE_COUNT" | bc)
fi

# 输出 JSON
if [ "$IS_VLLM" = true ]; then
    PROCESS_TYPE="vllm"
else
    PROCESS_TYPE="generic"
fi

cat > $OUTPUT_JSON << EOF
{
  "timestamp": "$TIMESTAMP",
  "unix_time": $JSON_UNIX_TIME,
  "data_type": "thread_cpu_usage",
  "target_pid": $PID,
  "process_name": "$PROCESS_NAME",
  "process_type": "$PROCESS_TYPE",
  "sampling": {
    "interval_sec": 1,
    "count": 5
  },
  "primary_threads_summary": {
    "count": $VLLM_COUNT,
    "total_cpu": $VLLM_TOTAL_CPU,
    "avg_cpu": $VLLM_AVG_CPU
  },
  "vllm_specific": {
    "vllm_worker": {
      "count": $VLLM_COUNT,
      "total_cpu": $VLLM_TOTAL_CPU,
      "avg_cpu": $VLLM_AVG_CPU
    },
    "acl_thread": {
      "count": $ACL_COUNT,
      "total_cpu": $ACL_TOTAL_CPU,
      "avg_cpu": $ACL_AVG_CPU
    },
    "release_thread": {
      "count": $RELEASE_COUNT,
      "total_cpu": $RELEASE_TOTAL_CPU,
      "avg_cpu": $RELEASE_AVG_CPU
    }
  },
  "all_threads": [$THREADS_JSON],
  "core_threads": [$CORE_THREADS_JSON]
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
