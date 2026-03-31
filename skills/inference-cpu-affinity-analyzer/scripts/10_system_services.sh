#!/bin/bash

# 1.10 系统服务列表检测
# 用途: 识别运行中的系统服务，可能成为 CPU 干扰源
# 使用: ./10_system_services.sh

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 输出文件配置
OUTPUT_DIR="profiler_output"
OUTPUT_TXT="${OUTPUT_DIR}/system_services.txt"
OUTPUT_JSON="${OUTPUT_DIR}/system_services.json"

# 创建输出目录
mkdir -p $OUTPUT_DIR

TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}1.10 系统服务列表检测${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# 检查命令
USE_SYSTEMCTL=false
if command -v systemctl &> /dev/null; then
    USE_SYSTEMCTL=true
    echo -e "${BLUE}使用 systemctl 获取系统服务...${NC}"
else
    echo -e "${YELLOW}警告: systemctl 命令未安装${NC}"
    echo -e "${BLUE}提示: 使用 init.d 或 service 命令作为备选${NC}"
    echo ""
fi

# 采集数据
{
    echo "################################################################################"
    echo "# 系统服务列表检测"
    echo "# 采集时间: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "################################################################################"
    echo ""
} > $TEMP_DIR/services_raw.txt

if [ "$USE_SYSTEMCTL" = true ]; then
    echo -e "${BLUE}执行命令: systemctl list-units --type=service --state=running --no-legend${NC}"
    {
        echo "=== 运行中的服务 (systemctl) ==="
        systemctl list-units --type=service --state=running --no-legend 2>/dev/null || echo "systemctl 命令执行失败"
        echo ""
    } >> $TEMP_DIR/services_raw.txt

    # 获取服务详细信息（CPU 占用高的服务）
    echo -e "${BLUE}获取服务详细信息...${NC}"

    # 先提取所有运行中的服务名
    SERVICE_LIST=$TEMP_DIR/service_list.txt
    systemctl list-units --type=service --state=running --no-legend --plain 2>/dev/null | \
        awk 'NR>1 && $1 != "" {
            service = $1
            # 去掉 .service 后缀
            gsub(/\.service$/, "", service)
            print service
        }' > $SERVICE_LIST

    # 逐个获取服务的 PID 和资源占用
    {
        echo "=== 服务详细信息 ==="
        echo ""

        while IFS= read -r service; do
            # 获取服务的主 PID
            MAIN_PID=$(systemctl show $service -p MainPID --value 2>/dev/null)
            if [ -n "$MAIN_PID" ] && [ "$MAIN_PID" != "0" ]; then
                # 获取该 PID 的资源使用情况
                ps -p $MAIN_PID -o pid,pcpu,pmem,comm --no-headers 2>/dev/null || true
            fi
        done < $SERVICE_LIST
        echo ""
    } >> $TEMP_DIR/services_raw.txt
else
    # 备选方案：使用 service 命令或直接查看 /etc/init.d
    {
        echo "=== 运行中的服务 (备选方案) ==="
        echo ""

        # 尝试使用 service 命令
        if command -v service &> /dev/null; then
            # 列出所有服务并检查状态
            if [ -d /etc/init.d ]; then
                for service in /etc/init.d/*; do
                    if [ -x "$service" ]; then
                        name=$(basename "$service")
                        status=$(service $name status 2>&1)
                        if echo "$status" | grep -qE "running|active|start"; then
                            echo "$name: running"
                        fi
                    fi
                done
            fi
        else
            echo "无法获取服务列表（systemctl 和 service 命令都不可用）"
        fi
        echo ""
    } >> $TEMP_DIR/services_raw.txt
fi

# 保存原始数据
cp $TEMP_DIR/services_raw.txt $OUTPUT_TXT

# 解析数据
echo ""
echo -e "${GREEN}解析结果:${NC}"

# 解析运行中的服务数量和详情
PARSED_DATA=$TEMP_DIR/parsed_data.txt

if [ "$USE_SYSTEMCTL" = true ]; then
    # 解析 systemctl 输出 - 使用 --no-legend 去掉底部说明，统计实际服务行数
    RUNNING_COUNT=$(systemctl list-units --type=service --state=running --no-legend 2>/dev/null | grep '\.service' | wc -l)

    echo -e "${GREEN}运行中的服务统计:${NC}"
    echo -e "  ${BLUE}•${NC} 运行中的服务数量: ${GREEN}${RUNNING_COUNT}${NC}"

    # 解析服务详细信息，找出 CPU 占用高的服务
    awk '
    BEGIN {
        count = 0
    }
    /^=== 服务详细信息 ===/ {
        in_services = 1
        next
    }
    /^=== / {
        if (in_services == 1) in_services = 0
        next
    }
    in_services == 1 && /^[0-9]/ {
        pid = $1
        cpu = $2
        mem = $3
        comm = $4

        if (cpu > 0) {
            printf "SERVICE_DATA|%s|%s|%s|%s\n", pid, cpu, mem, comm
            count++
        }
    }
    END {
        printf "COUNT=%d\n", count
    }
    ' $TEMP_DIR/services_raw.txt > $PARSED_DATA

    SERVICE_COUNT=$(grep "^COUNT=" $PARSED_DATA | cut -d'=' -f2)

    echo -e "  ${BLUE}•${NC} 可检测 CPU 占用的服务: ${GREEN}${SERVICE_COUNT}${NC}"

    # 显示 CPU 占用最高的服务
    echo ""
    echo -e "${GREEN}CPU 占用最高的服务 (Top 10):${NC}"
    echo "    PID    %CPU   %MEM   SERVICE"

    if [ -s $PARSED_DATA ] && grep -q "^SERVICE_DATA" $PARSED_DATA; then
        grep "^SERVICE_DATA" $PARSED_DATA | sort -t'|' -k3 -rn | head -10 | \
            awk -F'|' '{
                pid = $2
                cpu = $3
                mem = $4
                comm = $5
                printf "    %-5s  %-5s  %-5s  %s\n", pid, cpu, mem, comm
            }'
    else
        echo -e "  ${YELLOW}无数据（无法获取服务的 CPU 占用信息）${NC}"
    fi

    # 检查是否有高 CPU 占用的系统服务
    echo ""
    echo -e "${GREEN}高 CPU 占用服务检测 (>1% CPU):${NC}"

    HIGH_CPU_SERVICES=$(grep "^SERVICE_DATA" $PARSED_DATA | awk -F'|' '$3 > 1.0')

    if [ -n "$HIGH_CPU_SERVICES" ]; then
        echo "$HIGH_CPU_SERVICES" | awk -F'|' '{
            pid = $2
            cpu = $3
            mem = $4
            comm = $5
            printf "  ${YELLOW}⚠${NC} PID %-5s: ${GREEN}%s%% CPU${NC} (%s%% MEM) - %s\n", pid, cpu, mem, comm
        }'
        echo -e "  ${YELLOW}注意: 这些系统服务可能占用 CPU 资源，影响目标进程性能${NC}"
    else
        echo -e "  ${GREEN}✓${NC} 未检测到高 CPU 占用的系统服务"
    fi
else
    echo -e "${YELLOW}systemctl 不可用，无法获取详细的服务信息${NC}"
    RUNNING_COUNT=0
    SERVICE_COUNT=0
    HIGH_CPU_SERVICES=""
fi

# 生成 JSON 数据
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
JSON_UNIX_TIME=$(date +%s)

# 构建服务 JSON 数组
if [ "$USE_SYSTEMCTL" = true ]; then
    SERVICES_JSON=$(grep "^SERVICE_DATA" $PARSED_DATA | sort -t'|' -k3 -rn | awk -F'|' '
    BEGIN {
        json = ""
        count = 0
    }
    {
        pid = $2 + 0
        cpu = $3 + 0
        mem = $4 + 0
        comm = $5

        # 转义服务名中的特殊字符
        gsub(/\\/, "\\\\", comm)
        gsub(/"/, "\\\"", comm)

        if (count > 0) json = json ",\n    "
        json = json sprintf("{\"pid\": %d, \"cpu_percent\": %.2f, \"mem_percent\": %.2f, \"name\": \"%s\"}",
                            pid, cpu, mem, comm)
        count++
    }
    END {
        print json
    }')

    # 计算高 CPU 服务数量
    HIGH_CPU_COUNT=$(grep "^SERVICE_DATA" $PARSED_DATA | awk -F'|' '$3 > 1.0' | wc -l)
else
    SERVICES_JSON=""
    HIGH_CPU_COUNT=0
fi

# 输出 JSON
if [ -z "$SERVICES_JSON" ]; then
    SERVICES_JSON=" "
fi

cat > $OUTPUT_JSON << EOF
{
  "timestamp": "$TIMESTAMP",
  "unix_time": $JSON_UNIX_TIME,
  "data_type": "system_services",
  "source": "systemctl",
  "statistics": {
    "running_services": $RUNNING_COUNT,
    "tracked_services": $SERVICE_COUNT,
    "high_cpu_services": $HIGH_CPU_COUNT
  },
  "services": [
    $SERVICES_JSON
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
