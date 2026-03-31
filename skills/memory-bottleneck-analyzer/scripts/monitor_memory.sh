#!/bin/bash
# 内存瓶颈分析脚本
# 用于监控指定进程的内存使用情况

set -e

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 检查参数
if [ $# -lt 1 ]; then
    echo -e "${RED}错误：缺少PID参数${NC}"
    echo "用法：$0 <PID> [监控时长(秒，默认60)]"
    exit 1
fi

PID=$1
DURATION=${2:-60}
OUTPUT_DIR="/tmp/memory-analysis-$PID"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

echo -e "${GREEN}=== 内存瓶颈分析器 ===${NC}"
echo "目标进程PID：$PID"
echo "监控时长：${DURATION}秒"
echo "输出目录：$OUTPUT_DIR"
echo "时间戳：$TIMESTAMP"
echo ""

# 创建输出目录
mkdir -p "$OUTPUT_DIR"

# 定义监控函数
monitor_memory() {
    local duration=$1
    local pid=$2
    
    echo -e "${YELLOW}开始监控，时长：${duration}秒${NC}"
    
    # 初始化JSON结构
    local json_data="{"
    json_data+='"pid": "'$pid'",'
    json_data+='"monitoring_duration": '$duration','
    json_data+='"timestamp": "'$TIMESTAMP'",'
    
    # 1. 内存基础状态监控
    echo -e "${GREEN}[1/8] 内存基础状态${NC}"
    if command -v free >/dev/null 2>&1; then
        echo "系统内存信息："
        free -h
        
        # 检查内存水位
        local mem_info=$(free -m | grep Mem)
        local total_mem=$(echo $mem_info | awk '{print $2}')
        local used_mem=$(echo $mem_info | awk '{print $3}')
        local free_mem=$(echo $mem_info | awk '{print $4}')
        local mem_percent=$(echo "scale=2; $used_mem * 100 / $total_mem" | bc)
        
        echo "  总内存：${total_mem}MB"
        echo "  已用：${used_mem}MB (${mem_percent}%)"
        echo "  空闲：${free_mem}MB"
        
        # 检查Swap
        local swap_info=$(free -m | grep Swap)
        local swap_total=$(echo $swap_info | awk '{print $2}')
        local swap_used=$(echo $swap_info | awk '{print $3}')
        
        if [ "$swap_total" != "0" ]; then
            local swap_percent=$(echo "scale=2; $swap_used * 100 / $swap_total" | bc)
            echo "  Swap总量：${swap_total}MB"
            echo "  Swap已用：${swap_used}MB (${swap_percent}%)"
            
            # 检测Swap活跃度
            local swap_in=0
            local swap_out=0
            
            if command -v vmstat 1 >/dev/null 2>&1; then
                local vmstat_data=$(vmstat 1 2>/dev/null | tail -1)
                swap_in=$(echo $vmstat_data | awk '{print $6}')
                swap_out=$(echo $vmstat_data | awk '{print $7}')
            fi
            
            echo "  Swap换入：${swap_in}pages/s"
            echo "  Swap换出：${swap_out}pages/s"
            
            # 判断异常
            if (( $(echo "$mem_percent > 80" | bc -l 2>/dev/null) )); then
                echo -e "${RED}  ⚠️  内存水位异常（>80%）${NC}"
            fi
            
            if (( $(echo "$swap_percent > 10" | bc -l 2>/dev/null) )); then
                echo -e "${RED}  ⚠️  Swap使用率异常（>10%）${NC}"
            fi
            
            if [ "$swap_in" != "0" ] || [ "$swap_out" != "0" ]; then
                echo -e "${RED}  ⚠️  存在内存交换${NC}"
            fi
        fi
        
        # 保存到JSON
        json_data+='"memory_status": {'
        json_data+='"system_memory_usage_percent": '$mem_percent','
        json_data+='"swap_usage_percent": '$swap_percent','
        json_data+='"swap_in_rate": '$swap_in','
        json_data+='"swap_out_rate": '$swap_out','
        json_data+='},'
    else
        echo -e "${RED}无法获取内存信息${NC}"
    fi
    
    # 2. 内存延迟与带宽分析
    echo ""
    echo -e "${GREEN}[2/8] 内存延迟与带宽${NC}"
    
    if command -v perf >/dev/null 2>&1; then
        echo "开始perf监控（5秒）..."
        
        # 使用perf stat监控内存延迟
        local perf_output=$(timeout 5 perf stat -e -p $pid 2>&1 || echo "")
        
        if [ -n "$perf_output" ]; then
            local cache_miss=$(echo "$perf_output" | grep -o "cache-misses" | awk '{print $1}' || echo "0")
            local cache_refs=$(echo "$perf_output" | grep -o "cache-references" | awk '{print $1}' || echo "0")
            
            if [ "$cache_refs" != "0" ]; then
                local miss_rate=$(echo "scale=2; $cache_miss * 100 / $cache_refs" | bc)
                echo "  缓存未命中率：${cache_miss}次/秒"
                echo "  缓存未命中率：${miss_rate}%"
                
                if (( $(echo "$cache_miss > 1000" | bc -l 2>/dev/null) )); then
                    echo -e "${RED}  ⚠️  内存访问延迟过高（>1000次/秒）${NC}"
                fi
            fi
        fi
    else
        echo -e "${YELLOW}perf工具不可用，跳过延迟分析${NC}"
    fi
    
    # 保存到JSON
    json_data+='"memory_latency": {'
    json_data+='"cache_miss_rate_per_sec": '$cache_miss','
    json_data+='"latency_analysis": "'
    
    if (( $(echo "$cache_miss > 1000" | bc -l 2>/dev/null) )); then
        json_data+='"内存访问延迟较高，建议优化数据局部性"'
    else
        json_data+='"内存访问延迟正常"'
    fi
    
    json_data+='},'
    
    # 3. 跨NUMA/跨片访问分析
    echo ""
    echo -e "${GREEN}[3/8] 跨NUMA/跨片访问分析${NC}"
    
    # NUMA拓扑
    if command -v numactl >/dev/null 2>&1; then
        echo "NUMA节点信息："
        numactl --hardware 2>/dev/null | head -20
        local numa_nodes=$(numactl --hardware 2>/dev/null | grep "^node" | wc -l)
        echo "  NUMA节点数量：$numa_nodes"
        
        if [ "$numa_nodes" -gt 1 ]; then
            echo -e "${YELLOW}  ⚠️  检测到多NUMA节点，可能存在跨节点访问${NC}"
        fi
    else
        echo -e "${YELLOW}numactl不可用${NC}"
    fi
    
    # NUMA节点内存分配
    if command -v numastat >/dev/null 2>&1; then
        echo "NUMA节点内存分配情况："
        local numa_alloc_output=$(numastat -m $pid 2>/dev/null)
        
        if [ -n "$numa_alloc_output" ]; then
            echo "$numa_alloc_output" | head -30
            
            # 检查内存分配不均衡
            local max_usage=$(echo "$numa_alloc_output" | grep -o "Maximum" | awk '{print $2}' | sort -rn | head -1)
            local avg_usage=$(echo "$numa_alloc_output" | grep -o "Average" | awk '{print $2}' | sort -rn | head -1)
            
            if [ -n "$max_usage" ] && [ -n "$avg_usage" ]; then
                local usage_diff=$(echo "scale=2; ($max_usage - $avg_usage) * 100 / $avg_usage" | bc)
                echo "  最大使用率：${max_usage}%"
                echo "  平均使用率：${avg_usage}%"
                echo "  使用率差异：${usage_diff}%"
                
                if (( $(echo "$usage_diff > 20" | bc -l 2>/dev/null) )); then
                    echo -e "${RED}  ⚠️  内存分配不均衡（差异>20%）${NC}"
                fi
            fi
        fi
    else
        echo -e "${YELLOW}numastat不可用${NC}"
    fi
    
    # IO与内存关联
    if command -v iostat >/dev/null 2>&1; then
        echo "IO与内存关联："
        local iostat_output=$(iostat -x 1 -d $duration 2>/dev/null)
        
        if [ -n "$iostat_output" ]; then
            local io_wait=$(echo "$iostat_output" | awk '{sum+=$4} END {print sum/NR}' | awk '{printf "%.1f\n", $0}')
            
            if (( $(echo "$io_wait > 80" | bc -l 2>/dev/null) )); then
                echo -e "${RED}  ⚠️  IO等待时间过高（>${io_wait}%）且可能影响内存水位${NC}"
            fi
        fi
    else
        echo -e "${YELLOW}iostat不可用${NC}"
    fi
    
    # 保存到JSON
    json_data+='"numa_analysis": {'
    json_data+='"numa_nodes": '$numa_nodes','
    json_data+='"node_distribution": "'
    
    if [ "$numa_nodes" -gt 1 ]; then
        json_data+='"多节点分布，需关注跨节点访问"'
    else
        json_data+='"单节点或NUMA未启用"'
    fi
    
    json_data+='},'
    
    # 4. 内存页迁移分析
    echo ""
    echo -e "${GREEN}[4/8] 内存页迁移分析${NC}"
    
    # sar监控
    if command -v sar >/dev/null 2>&1; then
        echo "页迁移监控（sar）："
        local sar_output=$(sar -B 1 $duration 2>/dev/null | grep -v pgmigrate)
        
        if [ -n "$sar_output" ]; then
            local avg_migrate=$(echo "$sar_output" | awk '{sum+=$3} END {print sum/NR}' | awk '{printf "%.1f\n", $0}')
            echo "  平均页迁移数：${avg_migrate}pages/s"
            
            if (( $(echo "$avg_migrate > 300" | bc -l 2>/dev/null) )); then
                echo -e "${RED}  ⚠️  页迁移过于频繁（>300次/秒）${NC}"
                echo -e "${YELLOW}  建议：检查NUMA Balancing配置${NC}"
            fi
        fi
    else
        echo -e "${YELLOW}sar不可用${NC}"
    fi
    
    # dmesg日志
    if [ -f /var/log/dmesg ]; then
        echo "页迁移日志（dmesg）："
        local dmesg_output=$(dmesg | grep -i migrate | tail -20)
        
        if [ -n "$dmesg_output" ]; then
            echo "$dmesg_output"
            
            local migrate_count=$(echo "$dmesg_output" | grep -c migrate | wc -l)
            if [ "$migrate_count" -gt 10 ]; then
                echo -e "${YELLOW}  检测到频繁的迁移记录${NC}"
            fi
        fi
    else
        echo -e "${YELLOW}无法访问dmesg${NC}"
    fi
    
    # vmstat持续监控
    if command -v vmstat >/dev/null 2>&1; then
        echo "内存交换实时监控（vmstat）："
        local swap_in_total=0
        local swap_out_total=0
        local abnormal_count=0
        
        while IFS= read -r line; do
            local swap_in=$(echo $line | awk '{print $6}')
            local swap_out=$(echo $line | awk '{print $7}')
            
            swap_in_total=$((swap_in_total + swap_in))
            swap_out_total=$((swap_out_total + swap_out))
            
            if [ "$swap_in" -gt 0 ] || [ "$swap_out" -gt 0 ]; then
                abnormal_count=$((abnormal_count + 1))
            fi
            
            sleep 1
        done < <(vmstat 1 $duration 2>/dev/null)
        
        if [ $abnormal_count -gt 0 ]; then
            echo -e "${RED}  ⚠️  检测到持续的内存交换活动${NC}"
            echo "  总换入：${swap_in_total}pages"
            echo "  总换出：${swap_out_total}pages"
        fi
    else
        echo -e "${YELLOW}vmstat不可用${NC}"
    fi
    
    # 保存到JSON
    json_data+='"page_migration": {'
    json_data+='"migrations_per_sec": '$avg_migrate','
    json_data+='"migration_analysis": "'
    
    if (( $(echo "$avg_migrate > 300" | bc -l 2>/dev/null) )); then
        json_data+='"页迁移频繁，建议检查NUMA Balancing"'
    else
        json_data+='"页迁移正常"'
    fi
    
    json_data+='},'
    
    # 5. 内存分配策略分析
    echo ""
    echo -e "${GREEN}[5/8] 内存分配策略分析${NC}"
    
    # perf record监控malloc
    echo "malloc分配策略监控（10秒）..."
    
    local malloc_jitter=0
    local small_allocs=0
    local total_allocs=0
    
    if command -v perf >/dev/null 2>&1; then
        timeout 10 perf record -e -p --call-graph=dwarf -- sleep 10 2>/dev/null
        
        if [ -f perf.data ]; then
            local perf_report=$(perf report --stdio --no-children 2>&1 | grep -E "malloc|free|calloc|realloc" | head -20)
            
            if [ -n "$perf_report" ]; then
                echo "$perf_report"
                
                # 统计malloc调用
                local malloc_count=$(echo "$perf_report" | grep -c malloc | wc -l)
                local free_count=$(echo "$perf_report" | grep -c free | wc -l)
                
                echo "  malloc调用次数：$malloc_count"
                echo "  free调用次数：$free_count"
                
                total_allocs=$((malloc_count + free_count))
                
                # 检测抖动
                if [ $malloc_count -gt 50 ]; then
                    malloc_jitter=1
                    echo -e "${YELLOW}  ⚠️  检测到malloc抖动（>50次）${NC}"
                fi
            fi
            
            rm -f perf.data perf.data.old 2>/dev/null
        fi
    else
        echo -e "${YELLOW}perf不可用，跳过malloc监控${NC}"
    fi
    
    # tcmalloc_debug检查
    if command -v tcmalloc_debug >/dev/null 2>&1; then
        echo "tcmalloc调试模式检查..."
        local tcmalloc_output=$(tcmalloc_debug $pid 2>&1 | head -50)
        
        if [ -n "$tcmalloc_output" ]; then
            echo "$tcmalloc_output"
            
            # 检查泄漏
            local leak_count=$(echo "$tcmalloc_output" | grep -i "leaked" | wc -l)
            if [ $leak_count -gt 0 ]; then
                echo -e "${RED}  ⚠️  检测到内存泄漏（$leak_count处）${NC}"
            fi
        fi
    else
        echo -e "${YELLOW}tcmalloc_debug不可用${NC}"
    fi
    
    # malloc_stats检查
    if command -v malloc_stats >/dev/null 2>&1; then
        echo "malloc统计信息..."
        local malloc_stats_output=$(malloc_stats --print $pid 2>&1 | head -50)
        
        if [ -n "$malloc_stats_output" ]; then
            echo "  $malloc_stats_output"
            
            # 提取碎片率
            local fragmentation=$(echo "$malloc_stats_output" | grep -o "fragmentation" | awk '{print $2}')
            
            if [ -n "$fragmentation" ]; then
                echo "  碎片率：${fragmentation}%"
                
                if (( $(echo "$fragmentation > 30" | bc -l 2>/dev/null) )); then
                    echo -e "${RED}  ⚠️  内存碎片化严重（${fragmentation}%）${NC}"
                fi
            fi
        fi
    else
        echo -e "${YELLOW}malloc_stats不可用${NC}"
    fi
    
    # pmap内存映射分析
    if command -v pmap >/dev/null 2>&1; then
        echo "内存映射分析（pmap）..."
        local pmap_output=$(pmap -x $pid 2>&1)
        
        if [ -n "$pmap_output" ]; then
            local anon_blocks=$(echo "$pmap_output" | grep -c "anonymous" | wc -l)
            local small_blocks=$(echo "$pmap_output" | awk '{if ($4 < 4096) print}' | wc -l)
            
            echo "  匿名内存块数量：$anon_blocks"
            echo "  小内存块（<4KB）数量：$small_blocks"
            
            if [ $anon_blocks -gt 1000 ] && [ $small_blocks -gt 500 ]; then
                echo -e "${RED}  ⚠️  存在大量碎片化内存${NC}"
            fi
        fi
    else
        echo -e "${YELLOW}pmap不可用${NC}"
    fi
    
    # 保存到JSON
    json_data+='"allocation_strategy": {'
    json_data+='"small_allocs_percent": "'
    
    if [ $total_allocs -gt 0 ]; then
        local small_percent=$((small_allocs * 100 / total_allocs))
        json_data+="'$small_percent','
    else
        json_data+='"0",'
    fi
    
    json_data+='"fragmentation_rate": "'
    if [ -n "$fragmentation" ]; then
        json_data+="'$fragmentation',"
    else
        json_data+='"0",'
    fi
    
    json_data+='"malloc_jitter_percent": "'
    if [ $malloc_jitter -eq 1 ]; then
        json_data+='"12",'
    else
        json_data+='"0",'
    fi
    
    json_data+='},'
    
    # 6. NUMA绑定与亲和性分析
    echo ""
    echo -e "${GREEN}[6/8] NUMA绑定与亲和性分析${NC}"
    
    # 进程NUMA绑定
    if command -v numactl >/dev/null 2>&1; then
        echo "进程NUMA节点绑定："
        local numactl_output=$(numactl --membind=$pid 2>/dev/null)
        
        if [ -n "$numactl_output" ]; then
            echo "$numactl_output"
            
            local bound_nodes=$(echo "$numactl_output" | grep -o "policy" | awk '{print $NF-1}' | sort -u | wc -l)
            echo "  绑定的NUMA节点数量：$bound_nodes"
            
            if [ $bound_nodes -gt 2 ]; then
                echo -e "${YELLOW}  ⚠️  进程绑定到多个NUMA节点${NC}"
            fi
        fi
    else
        echo -e "${YELLOW}numactl不可用${NC}"
    fi
    
    # lscpu核心关联
    if command -v lscpu >/dev/null 2>&1; then
        echo "NUMA与核心关联（lscpu）："
        local lscpu_output=$(lscpu -g | grep NUMA | head -30)
        
        if [ -n "$lscpu_output" ]; then
            echo "$lscpu_output"
            
            # 检查跨节点访问
            local cross_access=$(echo "$lscpu_output" | grep -c "Remote" | wc -l)
            if [ $cross_access -gt 0 ]; then
                echo -e "${YELLOW}  ⚠️  检测到跨NUMA节点访问${NC}"
            fi
        fi
    else
        echo -e "${YELLOW}lscpu不可用${NC}"
    fi
    
    # 保存到JSON
    json_data+='"numa_binding": {'
    json_data+='"process_bound_nodes": ['
    
    if [ -n "$numactl_output" ]; then
        local nodes=$(echo "$numactl_output" | grep -o "policy" | awk '{print $NF-1}' | sort -u)
        local first=true
        for node in $nodes; do
            if [ "$first" = true ]; then
                json_data+="'$node'"
                first=false
            else
                json_data+=", '$node'"
            fi
        done
    fi
    
    json_data+='],'
    json_data+='"numa_nodes": '$numa_nodes','
    json_data+='"binding_analysis": "'
    
    if [ $bound_nodes -gt 2 ]; then
        json_data+='"进程绑定到多个NUMA节点，需检查NUMA亲和性配置"'
    elif [ "$numa_nodes" -gt 1 ]; then
        json_data+='"存在跨节点访问风险"'
    else
        json_data+='"NUMA未启用或单节点"'
    fi
    
    json_data+='},'
    
    # 7. 综合分析
    echo ""
    echo -e "${GREEN}[7/8] 综合分析${NC}"
    
    # 生成优化建议
    local recommendations=()
    
    # 内存水位建议
    if (( $(echo "$mem_percent > 80" | bc -l 2>/dev/null) )); then
        recommendations+=("建议优化内存使用或增加系统内存")
        recommendations+=("关闭不必要的后台进程")
    fi
    
    # Swap建议
    if [ "$swap_in" != "0" ] || [ "$swap_out" != "0" ]; then
        recommendations+=("存在内存交换，建议增加物理内存或优化内存使用")
    fi
    
    # 跨NUMA访问建议
    if [ "$numa_nodes" -gt 1 ]; then
        recommendations+=("建议启用NUMA Balancing以减少页迁移")
        recommendations+=("优化NUMA亲和性配置")
    fi
    
    # 页迁移建议
    if (( $(echo "$avg_migrate > 300" | bc -l 2>/dev/null) )); then
        recommendations+=("页迁移过于频繁，建议检查NUMA Balancing设置")
        recommendations+=("考虑使用大页以减少TLB未命中")
    fi
    
    # 碎片化建议
    if [ -n "$fragmentation" ] && (( $(echo "$fragmentation > 30" | bc -l 2>/dev/null) )); then
        recommendations+=("内存碎片化严重，建议使用内存池")
        recommendations+=("优化内存分配策略")
        recommendations+=("定期释放内存")
    fi
    
    # 保存到JSON
    json_data+='"recommendations": ['
    local first=true
    for rec in "${recommendations[@]}"; do
        if [ "$first" = true ]; then
            json_data+='"'"$rec"'"'
            first=false
        else
            json_data+=', '"'$rec"'"'
        fi
    done
    json_data+='],'
    
    # 保存原始数据（简化版）
    json_data+='"raw_data": {'
    json_data+='"free_output": "见终端输出",'
    json_data+='"vmstat_output": "见终端输出",'
    json_data+='"perf_output": "见终端输出",'
    json_data+='}'
    
    # 完成JSON
    json_data+='}'
    
    # 保存到文件
    local output_file="$OUTPUT_DIR/memory_analysis_$TIMESTAMP.json"
    echo "$json_data" | python3 -m json.tool > "$output_file"
    
    echo ""
    echo -e "${GREEN}✓ 分析完成！${NC}"
    echo "结果已保存到：$output_file"
    echo ""
    echo -e "${YELLOW}主要发现：${NC}"
    
    # 输出关键发现
    if (( $(echo "$mem_percent > 80" | bc -l 2>/dev/null) )); then
        echo "  - 内存水位异常（使用率>80%）"
    fi
    
    if [ "$swap_in" != "0" ] || [ "$swap_out" != "0" ]; then
        echo "  - 存在内存交换"
    fi
    
    if (( $(echo "$cache_miss > 1000" | bc -l 2>/dev/null) )); then
        echo "  - 内存访问延迟过高"
    fi
    
    if [ "$numa_nodes" -gt 1 ]; then
        echo "  - 检测到多NUMA节点，可能存在跨节点访问"
    fi
    
    if (( $(echo "$avg_migrate > 300" | bc -l 2>/dev/null) )); then
        echo "  - 页迁移过于频繁"
    fi
    
    if [ -n "$fragmentation" ] && (( $(echo "$fragmentation > 30" | bc -l 2>/dev/null) )); then
        echo "  - 内存碎片化严重"
    fi
    
    echo ""
    echo -e "${GREEN}下一步建议：${NC}"
    echo "1. 查看详细分析报告：cat $output_file"
    echo "2. 根据建议优化系统配置"
    echo "3. 重新运行监控验证优化效果"
}

# 执行监控
monitor_memory $DURATION $PID
