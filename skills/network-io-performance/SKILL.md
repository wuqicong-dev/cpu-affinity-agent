---
name: network-io-performance
description: 检测和分析网络IO性能，包括TCP/UDP流量、网络报文收发、网络中断和丢包检测。当用户提到网络性能检查、网络IO分析、TCP/UDP流量监控、网络丢包检测、中断负载分析或查看网络接口统计信息时触发此技能。当用户提到网络瓶颈、网络吞吐量或网络接口诊断时也触发。
---

# 网络IO性能检测和分析

此技能通过分析网络接口、中断、丢包和流量分布来诊断网络性能问题。

## 何时使用此技能

在以下情况使用此技能：
- 用户想要检查网络性能或网络IO
- 用户提到TCP/UDP流量分析
- 用户需要检测网络丢包
- 用户想要分析网络中断负载
- 用户询问网络接口统计信息
- 用户报告网络瓶颈或吞吐量问题
- 用户想要检查网络队列平衡

## 概述

网络性能问题可能源于：
- **中断不均衡**：网络中断集中在少数核心上
- **丢包**：网络接口丢弃数据包
- **队列不均衡**：TX/RX队列分布不均匀
- **高中断负载**：单个中断消耗过多CPU

此技能提供全面分析，包括：
1. **环境分析**：识别活跃网络接口及其中断号
2. **中断负载分析**：检查中断分布并识别热点
3. **丢包检测**：检查接口上的丢包情况
4. **队列平衡分析**：验证TX/RX队列分布

## 所需工具

你需要：
- `bash` 工具用于执行命令
- `write` 工具用于创建报告
- `read` 工具用于检查系统文件

## 分步工作流程

### 步骤1：网络接口发现

识别所有处于link up状态的网络接口，并确定哪些正在主动处理流量。

**运行的命令：**

```bash
# 运行网络接口发现脚本
bash /root/.config/opencode/skills/network-io-performance/scripts/01_network_interfaces.sh
```

**保存活跃接口列表：**
```bash
# 保存活跃接口供后续分析使用
active_ifaces=$(sar -n DEV 1 5 2>/dev/null | tail -n +1 | awk '{
    if (NF >= 8) {
        iface = $2
        ifutil = $3 + $4
        if (ifutil > 0) {
            print iface
        }
    }
}')
echo "$active_ifaces" > /tmp/active_interfaces.txt
```

### 步骤2：中断信息收集

对于每个活跃接口，收集中断号及其CPU亲和性。

**运行的命令：**

```bash
echo ""
echo "=== 活动接口的中断信息 ==="

for iface in $active_ifaces; do
    echo ""
    echo "接口: $iface"

    # 获取此接口的中断号
    irqs=$(cat /proc/interrupts | grep "$iface" | awk '{print $1}' | tr -d ':')

    if [ -n "$irqs" ]; then
        echo "中断号: $irqs"

        # 获取此接口的NUMA节点
        numa_node=$(cat /sys/class/net/$iface/device/numa_node 2>/dev/null || echo "unknown")
        echo "NUMA节点: $numa_node"

        # 获取每个中断的亲和性
        for irq in $irqs; do
            affinity=$(cat /proc/irq/$irq/smp_affinity_list 2>/dev/null || echo "unknown")
            echo "  中断 $irq -> 核心: $affinity"
        done
    else
        echo "未找到 $iface 的中断号"
    fi
done
```

### 步骤3：中断负载分析

检查中断负载分布并识别任何负载较高（>10%）的中断。

**运行的命令：**

```bash
echo ""
echo "=== 中断负载分析 ==="

# 使用irqtop获取中断统计（短暂运行）
timeout 3 irqtop -b 2>/dev/null > /tmp/irqtop_output.txt || echo "irqtop不可用"

# 解析irqtop输出查找高负载中断
if [ -f /tmp/irqtop_output.txt ]; then
    echo "负载 > 10% 的中断："
    grep -E "Total|irq" /tmp/irqtop_output.txt | grep -A 1 "Total" | \
    awk '{
        if (NF >= 3) {
            irq = $1
            load = $2
            gsub(/%/, "", load)
            if (load > 10) {
                print irq, load"%"
            }
        }
    }' | while read irq load; do
        echo "  $irq: $load (高负载)"
    done

    # 检查负载不均衡
    echo ""
    echo "中断负载分布："
    grep -E "Total" /tmp/irqtop_output.txt | tail -n +2 | \
    awk '{
        if (NF >= 3) {
            print $1, $2
        }
    }' | head -10
else
    echo "irqtop命令不可用 - 跳过中断负载分析"
    echo "替代方案：手动检查 /proc/interrupts"
fi
```

### 步骤4：丢包检测

检查所有网络接口的丢包情况。

**运行的命令：**

```bash
echo ""
echo "=== 丢包分析 ==="

# 使用netstat -i检查接口统计
netstat -i | grep -v "kernel" | grep -v "Iface" | while read line; do
    iface=$(echo "$line" | awk '{print $1}')
    rx_ierr=$(echo "$line" | awk '{print $5}')
    tx_ierr=$(echo "$line" | awk '{print $7}')
    rx_drop=$(echo "$line" | awk '{print $6}')
    tx_drop=$(echo "$line" | awk '{print $8}')
    rx_coll=$(echo "$line" | awk '{print $4}')
    tx_coll=$(echo "$line" | awk '{print $9}')

    # 计算总错误和丢包数
    total_errors=$((rx_ierr + tx_ierr))
    total_drops=$((rx_drop + tx_drop))
    total_collisions=$((rx_coll + tx_coll))

    echo "接口: $iface"
    echo "  RX错误: $rx_ierr, 丢包: $rx_drop, 冲突: $rx_coll"
    echo "  TX错误: $tx_ierr, 丢包: $tx_drop, 冲突: $tx_coll"

    if [ $total_errors -gt 0) ] || [ $total_drops -gt 0 ] || [ $total_collisions -gt 0 ]; then
        echo "  ⚠️  检测到问题：存在错误/丢包/冲突"
    else
        echo "  ✅ 未检测到丢包"
    fi
done
```

### 步骤5：队列平衡分析

使用ethtool统计检查TX/RX队列是否平衡。

**运行的命令：**

```bash
echo ""
echo "=== TX/RX队列平衡分析面 ==="

for iface in $active_ifaces; do
    echo ""
    echo "接口: $iface"

    # 获取ethtool统计信息
    ethtool -S $iface 2>/dev/null > /tmp/ethtool_${iface}.txt

    if [ -f /tmp/ethtool_${iface}.txt ]; then
        echo "队列统计："
        cat /tmp/ethtool_${iface}.txt | grep -E "rx-|tx-" | \
        awk '{
            if ($1 ~ /rx-/) {
                rx_queue = substr($1, 4)
                rx_packets = $2
                rx_bytes = $3
                printf "  RX队列 %s: %s报文, %s字节\n", rx_queue, rx_packets, rx_bytes
            } else if ($1 ~ /tx-/) {
                tx_queue = substr($1, 4)
                tx_packets = $2
                tx_bytes = $3
                printf "  TX队列 %s: %s报文, %s字节\n", tx_queue, tx_packets, tx_bytes
            }
        }'

        # 分析平衡性
        echo ""
        echo "平衡分析："
        cat /tmp/ethtool_${iface}.txt | grep -E "rx-|tx-" | \
        awk '{
            if ($1 ~ /rx-/) {
                rx_queue = substr($1, 4)
                rx_packets = $2
                rx_total += rx_packets
                rx_count++
            } else if ($1 ~ /tx-/) {
                tx_queue = substr($1, 4)
                tx_packets = $2
                tx_total += tx_packets
                tx_count++
            }
        } END {
            if (rx_count > 0) {
                rx_avg = rx_total / rx_count
                printf "  RX平均: %.0f报文/队列\n", rx_avg
            }
            if (tx_count > 0) {
                tx_avg = tx_total / tx_count
                printf "  TX平均: %.0f报文/队列\n", tx_avg
            }

            # 检查不均衡（简单方差检查）
            if (rx_count > 1 || tx_count > 1) {
                # 重读文件计算方差
                while ((getline line < "/tmp/ethtool_'$iface'.txt")) {
                    if (line ~ /rx-/) {
                        split(line, fields, "- ")
                        rx_val = fields[2]
                        rx_diff = rx_val - rx_avg
                        rx_variance += rx_diff * rx_diff
                    } else if (line ~ /tx-/) {
                        split(line, fields, "- ")
                        tx_val = fields[2]
                        tx_diff = tx_val - tx_avg
                        tx_variance += tx_diff * tx_diff
                    }
                }
' | tail -5
    else
        echo "  ethtool统计不可用（可能需要root权限）"
    fi
done
```

### 步骤6：流量速率计算

计算每秒的当前流量速率。

**运行的命令：**

```bash
echo ""
echo "=== 流量速率分析 ==="

for iface in $active_ifaces; do
    echo ""
    echo "接口: $iface"

    # 获取初始统计
    rx_pkts_1=$(cat /sys/class/net/$iface/statistics/rx_packets)
    tx_pkts_1=$(cat /sys/class/net/$iface/statistics/tx_packets)

    sleep 1

    # 获取1秒后的统计
    rx_pkts_2=$(cat /sys/class/net/$iface/statistics/rx_packets)
    tx_pkts_2=$(cat /sys/class/net/$iface/statistics/tx_packets)

    # 计算速率
    rx_rate=$((rx_pkts_2 - rx_pkts_1))
    tx_rate=$((tx_pkts_2 - tx_pkts_1))

    echo "  RX速率: $rx_rate 报文/秒"
    echo "  TX速率: $tx_rate 报文/秒"
    echo "  总速率: $((rx_rate + tx_rate)) 报文/秒"

    # 转换为Mbps（假设1500字节平均报文大小）
    rx_mbps=$((rx_rate * 1500 * 8 / 1000000))
    tx_mbps=$((tx_rate * 1500 * 8 / 1000000))
    echo "  RX: ~${rx_mbps} Mbps"
    echo "  TX: ~${tx_mbps} Mbps"
done
```

### 步骤7：生成综合报告

创建包含所有发现的markdown报告。

**报告结构：**

```markdown
# 网络IO性能分析报告

## 执行摘要
[简要摘要：活跃接口数量、检测到的任何关键问题]

## 活动网络接口
[列出所有link up接口及流量信息]

## 中断分析
[中断号、核心绑定、负载分布、不均衡检测]

## 丢包分析
[丢包状态、错误率、丢包率]

## 队列平衡分析
[TX/RX队列分布、平衡评估]

## 流量速率分析
[每个接口的每秒报文数、Mbps估算]

## 建议
[基于发现的可操作建议]

## 验证命令
[用于持续监控性能的命令]
```

**生成报告：**

```bash
# 创建报告文件
report_file="network_io_performance_report.md"

cat > $report_file << 'EOF'
# 网络IO性能分析报告

**生成时间**: $(date '+%Y-%m-%d %H:%M:%S')
**主机名**: $(hostname)

EOF

# 根据收集的数据添加各部分
# （使用之前步骤保存在 /tmp/ 中的数据）

echo "报告已保存到: $report_file"
```

## 错误处理

优雅地处理这些常见错误：

1. **命令未找到**：注意哪些工具缺失（irqtop、ethtool、netstat）
2. **权限被拒绝**：注意哪些步骤需要root权限
3. **无活跃接口**：如果没有接口正在处理流量则报告
4. **设备文件不可访问**：使用备用方法优雅处理

## 验证

分析完成后，提供持续监控的命令：

```bash
# 实时监控中断负载
watch -n 1 'cat /proc/interrupts | grep -E "eth|ens|eno"'

# 监控网络接口统计
watch -n 1 'netstat -i'

# 监控流量速率
sar -n DEV 1 5

# 监控特定接口队列平衡
watch -n 1 'ethtool -S <interface>'
```

## 重要说明

- 某些命令（irqtop、ethtool）可能需要root权限
- 分析提供快照；生产环境建议持续监控
- 丢包可能是瞬态的；运行多次以获得准确评估
- 队列平衡取决于网卡硬件能力
- 单个核心上的高中断负载（>10%）可能表明需要中断重平衡

## 常见问题及解决方案

### 单个核心上的高中断负载
**症状**：单个中断消耗 >10% CPU
**解决方案**：使用 `irqbalance` 服务或手动将中断分散到多个核心

### 检测到丢包
**症状**：非零错误/丢包计数器
**解决方案**：检查：
- 接口过载（升级带宽）
- 驱动问题（更新驱动）
- 硬件问题（更换网卡）
- 缓冲区溢出（增大环形缓冲区大小）

### 队列不均衡
**症状**：TX/RX队列分布不均匀
**解决方案**：配置RSS/RPS/XPS设置以分散负载

### 高负载但低流量
**症状**：高CPU但低报文速率
**解决方案**：检查：
- 中断风暴
- 驱动bug
- 恶意流量（DDoS）
