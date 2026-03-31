---
name: memory-bottleneck-analyzer
description: 用于检测计算密集型任务的内存瓶颈，包括内存水位、带宽、跨NUMA/跨片访问、页迁移、分配策略等分析。当用户需要监控特定进程的内存使用情况、排查内存延迟升高、内存交换频繁、跨节点访问过多等问题时使用。支持ARM64/x86_64平台，适用于AI推理、向量搜索、矩阵计算等内存密集型工作负载。触发关键词：内存瓶颈、内存监控、性能分析、内存泄漏、NUMA优化、跨片访问、内存延迟、内存交换、页迁移、内存碎片、malloc监控、推理性能、计算性能、资源监控、系统调优、perf分析、numactl、vmstat、iostat、lscpu、numastat、sar、dmesg、tcmalloc、malloc_stats、pmap
compatibility: 需要root权限执行perf、numactl、vmstat等系统监控命令；需要安装perf工具；适用于Linux系统；需要目标进程的PID
---

# 内存瓶颈分析器

本技能用于系统化地分析计算密集型任务的内存使用情况，识别和定位内存相关性能瓶颈。

## 适用场景

- AI推理任务内存分析
- 向量搜索库（如faiss）内存优化
- 矩阵计算内存监控
- NUMA系统跨节点访问问题排查
- 内存泄漏检测
- 内存碎片化分析
- 系统内存水位监控

## 监控维度

本技能从以下6个维度分析内存瓶颈：

1. **内存基础状态** - 内存使用率、水位、Swap使用情况
2. **内存带宽与延迟** - 内存访问延迟、缓存未命中率
3. **跨NUMA/跨片访问** - NUMA拓扑、跨节点访问频率
4. **内存页迁移** - 页迁移频率、原因分析
5. **内存分配策略** - malloc分配策略、碎片化情况
6. **NUMA绑定与亲和性** - 进程与NUMA节点绑定关系

## 使用方法

### 步骤1：获取目标进程PID

首先需要用户提供要监控的目标进程PID。可以通过以下方式获取：

```bash
# 查找Python进程
ps aux | grep python | grep <进程名>

# 查找特定命令
pgrep -f <命令名>

# 使用pidof
pidof <进程名>
```

### 步骤2：运行内存监控脚本

脚本会自动执行以下监控命令（每个采集5秒）：

**内存基础监控：**
- `free -h` - 内存使用率、水位
- `vmstat 1` - 实时Swap使用
- `vmstat -s` - 内存统计信息

**内存延迟与带宽：**
- `perf stat -e -p <PID>` - 内存访问延迟、缓存未命中率

**跨NUMA/跨片访问：**
- `numactl --hardware` - NUMA拓扑、节点分布
- `numastat -m <PID>` - NUMA节点内存分配
- `lscpu -g | grep NUMA` - NUMA与核心对应关系
- `numastat <PID>` - 进程NUMA节点绑定
- `iostat -x 1` - IO与内存关联

**内存页迁移：**
- `sar -B 1` - 页迁移监控
- `dmesg | grep migrate` - 迁移日志
- `cat /proc/vmstat | grep migrate` - 迁移统计

**内存分配策略：**
- `perf record -e -p <PID>` - malloc监控
- `tcmalloc_debug` - tcmalloc调试模式
- `malloc_stats` - malloc统计
- `pmap -x <PID>` - 内存映射分析

### 步骤3：分析监控数据

脚本会自动分析采集的数据，识别以下问题：

- **内存水位异常**：系统内存使用率>80%、Swap使用率>10%
- **内存延迟过高**：缓存未命中率>1000次/秒
- **跨NUMA访问过多**：跨NUMA节点访问次数>总访问次数的15%
- **内存页迁移频繁**：每秒迁移页数>300次
- **内存交换活跃**：内存换入/换出次数持续>0
- **内存分配不均衡**：各NUMA节点内存使用率差值>20%
- **跨节点访问导致IO**：IO等待时间高且内存水位同步升高
- **内存碎片化严重**：小内存分配（<1KB）次数占比>60%或碎片率>30%
- **NUMA Balancing影响**：频繁触发numa_balancing迁移

### 步骤4：生成分析报告

输出JSON格式的分析报告，包含：
- 各项监控指标的原始数据
- 自动分析结论
- 优化建议

## 输入格式

```json
{
  "pid": "目标进程PID",
  "duration_seconds": 60,
  "output_file": "/path/to/output.json"
}
```

## 输出格式

```json
{
  "pid": 12345,
  "monitoring_duration": 60,
  "timestamp": "2024-01-01 12:00:00",
  "memory_status": {
    "system_memory_usage_percent": 75.2,
    "swap_usage_percent": 5.3,
    "swap_in_rate": 0,
    "swap_out_rate": 2
  },
  "memory_latency": {
    "cache_miss_rate_per_sec": 1250,
    "latency_analysis": "内存访问延迟较高，建议优化数据局部性"
  },
  "numa_analysis": {
    "numa_nodes": 4,
    "node_distribution": "均匀分布",
    "cross_node_access_percent": 8.5,
    "cross_node_access_detected": true
  },
  "page_migration": {
    "migrations_per_sec": 45,
    "migration_analysis": "页迁移频繁，建议检查NUMA Balancing"
  },
  "allocation_strategy": {
    "small_allocs_percent": 45,
    "fragmentation_rate": 25,
    "malloc_jitter_percent": 12
  },
  "numa_binding": {
    "process_bound_nodes": [0, 1],
    "numa_nodes": 4,
    "binding_analysis": "进程绑定到2个NUMA节点"
  },
  "recommendations": [
    "建议启用NUMA Balancing以减少页迁移",
    "建议优化数据局部性以减少跨节点访问",
    "考虑使用大页以减少TLB未命中"
  ],
  "raw_data": {
    "free_output": "...",
    "vmstat_output": "...",
    "perf_output": "..."
  }
}
```

## 使用示例

**示例1：监控Python推理进程**
```
监控PID为12345的Python推理进程60秒，输出到memory_analysis.json
```

**示例2：分析faiss搜索进程**
```
分析faiss向量搜索进程的内存使用情况，识别是否存在跨NUMA访问或内存碎片问题
```

**示例3：诊断内存泄漏**
```
使用tcmalloc_debug模式监控进程的内存分配，查找潜在的内存泄漏
```

## 优化建议

根据分析结果，技能会提供针对性的优化建议：

- **内存水位问题**：优化内存使用、增加系统内存、关闭不必要进程
- **内存延迟问题**：优化数据访问模式、提高缓存命中率、使用预取指令
- **跨NUMA访问**：优化NUMA亲和性、调整NUMA Balancing策略、使用大页
- **页迁移问题**：关闭NUMA Balancing、优化内存访问模式、减少跨节点访问
- **内存碎片化**：使用内存池、优化分配策略、定期释放内存
- **NUMA绑定问题**：调整进程亲和性、使用numactl绑定到特定NUMA节点

## 依赖工具

- `perf` - Linux性能分析工具
- `numactl` - NUMA信息查看工具
- `vmstat` - 虚拟内存统计工具
- `iostat` - IO统计工具
- `lscpu` - CPU/NUMA拓扑查看工具
- `numastat` - NUMA统计工具
- `sar` - 系统活动报告工具
- `dmesg` - 内核消息缓冲
- `tcmalloc_debug` - glibc内存分配调试
- `malloc_stats` - jemalloc统计工具
- `pmap` - 进程内存映射查看工具

## 注意事项

- 需要root权限执行大部分监控命令
- 监控过程会产生一定的系统开销
- 建议在系统负载较低时进行监控
- 对于生产环境，建议先在测试环境验证
- 某些命令（如perf record）会显著影响性能，谨慎使用

## 执行流程

1. 用户输入目标进程PID和监控时长
2. 技能创建监控脚本
3. 技能执行监控脚本（后台运行）
4. 定期采集各维度数据（每5秒）
5. 实时分析数据并生成JSON报告
6. 监控完成后，提供综合分析和优化建议
