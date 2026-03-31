#!/bin/bash

# 1.7 核心 CPU 亲和性检测
# 用途: 检测核心线程的 CPU 亲和性
# 使用: ./07_thread_affinity.sh <PID>

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 输出文件配置
OUTPUT_DIR="profiler_output"
OUTPUT_TXT="${OUTPUT_DIR}/thread_affinity.txt"
OUTPUT_JSON="${OUTPUT_DIR}/thread_affinity.json"

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
if ! command -v taskset &> /dev/null; then
    echo -e "${RED}错误: taskset 命令未安装${NC}"
    exit 1
fi

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

TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}1.7 核心 CPU 亲和性检测${NC}"
echo -e "${GREEN}========================================${NC}"
echo -e "目标进程: ${BLUE}$PID${NC} (${GREEN}$PROCESS_NAME${NC})"

if [ "$IS_VLLM" = true ]; then
    echo -e "进程类型: ${GREEN}VLLM${NC} (检查 VLLM::Worker, acl_thread, release_thread 隔离)"
else
    echo -e "进程类型: ${YELLOW}通用${NC} (检查 CPU 最高的 5 个线程隔离)"
fi
echo ""

# 采集数据
{
    echo "################################################################################"
    echo "# 核心线程 CPU 亲和性配置 - PID: $PID"
    echo "# 采集时间: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "################################################################################"
    echo ""

    # 获取所有线程
    for tid in $(ps -L -p $PID -o lwp= 2>/dev/null); do
        tcomm=$(ps -p $PID -L -o lwp,comm= 2>/dev/null | grep "^$tid" | awk '{print $2}')
        affinity=$(taskset -pc $tid 2>/dev/null | grep "affinity list" | cut -d':' -f2 | xargs || echo "unknown")
        echo "TID:$tid ($tcomm) -> CPUs:[$affinity]"
    done
    echo ""

    # 获取主进程亲和性
    echo "################################################################################"
    echo "# 主进程 CPU 亲和性配置 - PID: $PID"
    echo "################################################################################"
    echo ""
    taskset -cp $PID 2>/dev/null || echo "taskset 命令执行失败"
} > $OUTPUT_TXT

echo -e "${GREEN}所有线程 CPU 亲和性:${NC}"
cat $OUTPUT_TXT | grep -A 10000 "核心线程 CPU 亲和性配置" | grep -B 10000 "主进程 CPU" | head -n -2

# 解析核心线程的 CPU 列表
THREAD_AFFINITY_RAW=$TEMP_DIR/thread_affinity_raw.txt
ps -L -p $PID -o lwp= 2>/dev/null | while read tid; do
    tcomm=$(ps -p $PID -L -o lwp,comm= 2>/dev/null | grep "^$tid" | awk '{print $2}')
    affinity=$(taskset -pc $tid 2>/dev/null | grep "affinity list" | cut -d':' -f2 | xargs || echo "unknown")
    echo "$tid|$tcomm|$affinity"
done > $THREAD_AFFINITY_RAW

echo ""
echo -e "${GREEN}主进程 CPU 亲和性:${NC}"
cat $OUTPUT_TXT | grep -A 1000 "主进程 CPU"

# 分析核心线程隔离状态
echo ""
echo -e "${GREEN}核心线程隔离分析:${NC}"

if [ "$IS_VLLM" = true ]; then
    # VLLM 进程：使用原有的线程识别逻辑
    # 获取核心线程的CPU列表
    worker_cpus=$(grep "VLLM::Worker" $OUTPUT_TXT 2>/dev/null | grep -oP 'CPUs:\[\K[^\]]*' | tr ',' '\n' | sort -u | tr '\n' ',' | sed 's/,$//')
    acl_cpus=$(grep "acl_thread" $OUTPUT_TXT 2>/dev/null | grep -oP 'CPUs:\[\K[^\]]*' | tr ',' '\n' | sort -u | tr '\n' ',' | sed 's/,$//')
    release_cpus=$(grep "release_thread" $OUTPUT_TXT 2>/dev/null | grep -oP 'CPUs:\[\K[^\]]*' | tr ',' '\n' | sort -u | tr '\n' ',' | sed 's/,$//')

    echo "  VLLM::Worker CPUs:   [${worker_cpus:-none}]"
    echo "  acl_thread CPUs:      [${acl_cpus:-none}]"
    echo "  release_thread CPUs:  [${release_cpus:-none}]"
else
    # 通用进程：获取 CPU 最高的 5 个线程的 CPU 列表
    # 首先获取按 CPU 使用率排序的线程列表
    PRIMARY_THREADS_CSV=$(ps -L -p $PID -o pid,lwp,psr,pcpu,comm 2>/dev/null | \
        awk 'NR>1 {cpu=$4+0; printf "%10.2f %s\n", cpu, $0}' | \
        sort -rn | head -5 | \
        awk '{print $2}')

    # 获取这些线程的 CPU 亲和性
    PRIMARY_CPUS=""
    for tid in $PRIMARY_THREADS_CSV; do
        tcomm=$(grep "TID:$tid" $OUTPUT_TXT 2>/dev/null | sed 's/TID:[0-9]* (\(.*\)) -> CPUs:\[\(.*\)\]/\1/')
        affinity=$(grep "TID:$tid" $OUTPUT_TXT 2>/dev/null | grep -oP 'CPUs:\[\K[^\]]*' | tr ',' '\n' | sort -u | tr '\n' ',' | sed 's/,$//')
        if [ -n "$affinity" ]; then
            echo "  线程 $tid ($tcomm) CPUs: [$affinity]"
            if [ -n "$PRIMARY_CPUS" ]; then
                PRIMARY_CPUS="$PRIMARY_CPUS,$affinity"
            else
                PRIMARY_CPUS="$affinity"
            fi
        fi
    done

    # 去重并排序
    PRIMARY_CPUS=$(echo "$PRIMARY_CPUS" | tr ',' '\n' | sort -u | tr '\n' ',' | sed 's/,$//')

    # 用于后续检查的变量
    worker_cpus="$PRIMARY_CPUS"
    acl_cpus=""
    release_cpus=""
fi

# 检查重叠
is_isolated="true"
overlap=""
overlap_details=""

if [ "$IS_VLLM" = true ]; then
    # VLLM 进程：检查三类线程之间的重叠
    # 检查 worker-acl 重叠
    worker_acl_overlap=""
    if [ -n "$worker_cpus" ] && [ -n "$acl_cpus" ]; then
        common=$(echo "$worker_cpus $acl_cpus" | tr ',' '\n' | sort | uniq -d)
        if [ -n "$common" ]; then
            is_isolated="false"
            worker_acl_overlap="$common"
            overlap="worker-acl"
            overlap_details="$common"
        fi
    fi

    # 检查 worker-release 重叠
    worker_release_overlap=""
    if [ -n "$worker_cpus" ] && [ -n "$release_cpus" ]; then
        common=$(echo "$worker_cpus $release_cpus" | tr ',' '\n' | sort | uniq -d)
        if [ -n "$common" ]; then
            is_isolated="false"
            worker_release_overlap="$common"
            if [ -n "$overlap" ]; then
                overlap="$overlap, worker-release"
                overlap_details="$overlap_details, $common"
            else
                overlap="worker-release"
                overlap_details="$common"
            fi
        fi
    fi
fi

echo ""
if [ "$is_isolated" = "true" ]; then
    echo -e "  ${GREEN}✓${NC} 核心线程已隔离绑定"
else
    echo -e "  ${RED}⚠${NC} 核心线程未隔离: ${YELLOW}$overlap${NC}"
    echo -e "  ${YELLOW}重叠CPU: $overlap_details${NC}"
fi

# 统计各类线程数量
if [ "$IS_VLLM" = true ]; then
    worker_count=$(grep -c "VLLM::Worker" $OUTPUT_TXT 2>/dev/null || echo "0")
    acl_count=$(grep -c "acl_thread" $OUTPUT_TXT 2>/dev/null || echo "0")
    release_count=$(grep -c "release_thread" $OUTPUT_TXT 2>/dev/null || echo "0")
    primary_count=$worker_count
else
    # 通用进程：统计主要线程数量
    primary_count=$(echo "$PRIMARY_THREADS_CSV" | wc -w | tr -d ' ')
    worker_count=0
    acl_count=0
    release_count=0
fi

echo ""
echo -e "${GREEN}统计信息:${NC}"
if [ "$IS_VLLM" = true ]; then
    echo -e "  ${BLUE}•${NC} VLLM::Worker 线程数: ${GREEN}$worker_count${NC}"
    echo -e "  ${BLUE}•${NC} acl_thread 线程数: ${GREEN}$acl_count${NC}"
    echo -e "  ${BLUE}•${NC} release_thread 线程数: ${GREEN}$release_count${NC}"
else
    echo -e "  ${BLUE}•${NC} 主要线程数 (Top CPU): ${GREEN}$primary_count${NC}"
fi

# 生成 JSON 数据
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
JSON_UNIX_TIME=$(date +%s)

# 获取主进程亲和性
MAIN_AFFINITY=$(taskset -cp $PID 2>/dev/null | grep "affinity list" | cut -d':' -f2 | xargs || echo "unknown")

# 构建线程亲和性 JSON 数组
THREADS_JSON=""
while IFS='|' read -r tid tcomm affinity; do
    if [ -n "$THREADS_JSON" ]; then
        THREADS_JSON="$THREADS_JSON,"
    fi

    # 确定线程类型
    if [ "$IS_VLLM" = true ]; then
        thread_type="other"
        if echo "$tcomm" | grep -q "VLLM::Worker"; then
            thread_type="vllm_worker"
        elif echo "$tcomm" | grep -q "acl_thread"; then
            thread_type="acl_thread"
        elif echo "$tcomm" | grep -q "release_thread"; then
            thread_type="release_thread"
        fi
    else
        # 通用进程：检查是否是主要线程（Top 5 CPU）
        if echo "$PRIMARY_THREADS_CSV" | grep -qw "$tid"; then
            thread_type="primary"
        else
            thread_type="auxiliary"
        fi
    fi

    # 清理 affinity 中的空格
    affinity_clean=$(echo "$affinity" | tr -s ' ')

    THREADS_JSON="$THREADS_JSON{\"tid\": $tid, \"comm\": \"$tcomm\", \"type\": \"$thread_type\", \"affinity\": \"$affinity_clean\"}"
done < $THREAD_AFFINITY_RAW

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
  "data_type": "thread_affinity",
  "target_pid": $PID,
  "process_name": "$PROCESS_NAME",
  "process_type": "$PROCESS_TYPE",
  "main_process_affinity": "$MAIN_AFFINITY",
  "isolation": {
    "is_isolated": $is_isolated,
    "overlap_type": "${overlap:-none}",
    "overlap_cpus": "${overlap_details:-none}"
  },
  "primary_threads": {
    "count": $primary_count,
    "cpus": "${worker_cpus:-none}"
  },
  "vllm_specific": {
    "vllm_worker": {
      "count": $worker_count,
      "cpus": "${worker_cpus:-none}"
    },
    "acl_thread": {
      "count": $acl_count,
      "cpus": "${acl_cpus:-none}"
    },
    "release_thread": {
      "count": $release_count,
      "cpus": "${release_cpus:-none}"
    }
  },
  "all_threads": [$THREADS_JSON]
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
