---
name: inference-cpu-affinity-analyzer
description: Use for analyzing CPU affinity and scheduling issues for inference workloads (VLLM, SGLang, or any LLM inference service). This skill provides a comprehensive toolkit of 16 modular bash scripts for diagnosing CPU pinning problems, thread migration, NUMA cross-domain access, cache contention, and memory bandwidth issues. Always use this skill when the user mentions inference CPU performance, CPU affinity, thread scheduling, core pinning, NUMA optimization, or any CPU-related diagnostics for LLM inference workloads (VLLM, SGLang, TGI, vLLM, TensorRT-LLM, etc.), even if they don't explicitly say "affinity" or "pinning". The tool automatically detects the process type and adapts its analysis accordingly.
parameters:
  - name: pid
    description: The Process ID (PID) of the inference service to analyze. Required for most diagnostic scripts. If not provided, the skill will prompt the user for it.
    required: true
---

# 推理服务 CPU 亲核性分析工具集

本技能提供16个模块化bash脚本，用于诊断推理服务进程（VLLM、SGLang、TGI等）的CPU亲核性问题。根据具体问题场景，灵活组合使用这些脚本。

## 重要提示

**所有需要目标进程的分析都需要提供 PID 参数。**

如果用户没有提供 PID，必须明确询问用户：
- "请提供要分析的推理服务进程的 PID（进程 ID）"
- 可以提示用户使用 `ps aux | grep -E "vllm|sglang|tgi"` 查找进程

## 核心概念

**CPU 亲核性问题** 是指推理服务进程的线程没有正确绑定到特定 CPU 核心，导致：
- 线程频繁在不同核心间迁移
- 跨 NUMA 节点访问内存
- L3 缓存争用
- 内存带宽不足

这些问题会显著降低 LLM 推理性能。

## 进程类型自动识别

工具会自动检测目标进程类型：
- **VLLM 进程**：识别 `VLLM::Worker`、`acl_thread`、`release_thread` 等特有线程
- **通用推理进程**（SGLang、TGI 等）：将 CPU 使用率最高的 5 个线程识别为主要线程

脚本 02、06、07 已支持这种自动识别，输出 JSON 中包含 `process_type` 字段（"vllm" 或 "generic"）。

## 16个脚本详解

### 基础信息采集 (01-02)

#### 01_cpu_topology.sh
**作用**: 获取 CPU 硬件拓扑信息
**工具**: `lscpu`
**输出**:
- CPU 数量、Socket 数、核心数、线程数
- NUMA 节点配置
- 缓存大小 (L1/L2/L3)
- CPU 型号和频率

**使用场景**:
- 分析开始时首先运行，了解硬件基础信息
- 判断 NUMA 节点数量和 CPU 分布

**输出文件**: `profiler_output/cpu_topology.json`

#### 02_thread_list.sh
**作用**: 获取目标进程的所有线程列表
**工具**: `ps`
**参数**: `<PID>` - 目标进程ID
**输出**:
- 线程总数
- 各线程的 TID、CPU 使用率、运行核心、命令名
- **VLLM 进程**: 分类统计 VLLM::Worker、acl_thread、release_thread
- **通用进程**: 主要线程数（Top 5 CPU）、辅助线程数

**使用场景**:
- 诊断开始时获取目标进程线程信息
- 确认哪些是核心工作线程

**输出文件**: `profiler_output/thread_list.json`

### CPU 使用率分析 (03-06)

#### 03_system_cpu_usage.sh
**作用**: 采集系统整体 CPU 使用率（5次采样）
**工具**: `sar`
**输出**:
- User/System/Idle/Nice/Iowait/Steal 的平均值和标准差
- 5次采样的详细数据

**使用场景**:
- 了解系统整体负载
- 判断是否存在系统级 CPU 竞争

**输出文件**: `profiler_output/system_cpu_usage.json`

#### 04_per_core_cpu_usage.sh
**作用**: 每核 CPU 使用率监控
**工具**: `mpstat`
**输出**:
- 每个 CPU 核心的使用率
- 识别热点核心

**使用场景**:
- 检查负载是否均衡
- 发现某些核心过载

**输出文件**: `profiler_output/per_core_cpu_usage.json`

#### 05_high_cpu_processes.sh
**作用**: 识别高 CPU 占用进程
**工具**: `top`
**输出**:
- CPU 使用率 top 10 进程
- 各进程的 PID、%CPU、%MEM、命令

**使用场景**:
- 检查是否有其他进程干扰 VLLM
- 诊断系统资源竞争

**输出文件**: `profiler_output/high_cpu_processes.json`

#### 06_thread_cpu_usage.sh
**作用**: 线程级 CPU 使用率监控
**工具**: `pidstat`
**参数**: `<PID>` - 目标进程ID
**输出**:
- 每个线程的 CPU 使用率
- **VLLM 进程**: VLLM::Worker、acl_thread、release_thread 的 CPU 使用率统计
- **通用进程**: 主要线程（Top 5 CPU）的 CPU 使用率统计

**使用场景**:
- 分析哪些线程最活跃
- 检查负载分布

**输出文件**: `profiler_output/thread_cpu_usage.json`

### 线程调度与亲和性 (07-09)

#### 07_thread_affinity.sh ⭐ 核心脚本
**作用**: 检测线程 CPU 亲和性配置
**工具**: `taskset`
**参数**: `<PID>` - 目标进程ID
**输出**:
- 每个线程的 CPU 亲和性列表
- 主进程的 CPU 亲和性
- **VLLM 进程**: 检查 VLLM::Worker、acl_thread、release_thread 的隔离状态
- **通用进程**: 检查主要线程（Top 5 CPU）的隔离状态
- 线程类型标识：primary（主要线程）或 auxiliary（辅助线程）

**使用场景**:
- **诊断 CPU 亲核性问题的首要脚本**
- 检查线程是否正确绑定
- 发现线程间 CPU 重叠

**输出文件**: `profiler_output/thread_affinity.json`

**关键诊断指标**:
- `process_type`: "vllm" 或 "generic"
- `is_isolated`: 核心线程是否隔离
- `overlap_type`: 哪些线程类型存在重叠
- `overlap_cpus`: 重叠的 CPU 列表

#### 08_thread_context_switch.sh
**作用**: 线程上下文切换监控
**工具**: `pidstat`
**参数**: `<PID>` - 目标进程ID
**输出**:
- 每个线程的自愿/非自愿上下文切换次数
- 线程切换速率

**使用场景**:
- 检测线程是否频繁被调度器切换
- 非自愿切换高可能意味着 CPU 竞争

**输出文件**: `profiler_output/thread_context_switch.json`

#### 09_cpu_frequency.sh
**作用**: CPU 频率监控
**工具**: `cpupower frequency`
**输出**:
- 每个 CPU 核心的当前频率
- 调节器策略 (performance/powersave等)

**使用场景**:
- 检查 CPU 是否运行在最高频率
- 频率降低会影响性能

**输出文件**: `profiler_output/cpu_frequency.json`

### 干扰检测 (10)

#### 10_system_services.sh
**作用**: 检测运行中的系统服务
**工具**: `systemctl`
**输出**:
- 所有运行中的系统服务
- 各服务的 PID、CPU 使用率、内存使用率

**使用场景**:
- 检查系统服务是否干扰 VLLM
- 发现可能抢占 CPU 的服务

**输出文件**: `profiler_output/system_services.json`

### NUMA 与分布 (11-12)

#### 11_numa_topology.sh ⭐ 核心脚本
**作用**: 获取系统 NUMA 拓扑
**工具**: `numactl`, `lscpu`
**输出**:
- NUMA 节点数量
- 每个 NUMA 节点的 CPU 列表和内存大小
- Cluster (4 CPUs) 和 Die (32 CPUs) 边界

**使用场景**:
- **诊断跨 NUMA 访问问题的必需脚本**
- 与脚本12配合分析线程分布

**输出文件**: `profiler_output/numa_topology.json`

**关键概念**:
- **Cluster**: 4个CPU，共享L2缓存
- **Die**: 32个CPU，共享L3缓存
- **NUMA Node**: 独立内存域

#### 12_thread_distribution.sh ⭐ 核心脚本
**作用**: 线程 CPU 分布检测（5次采样）
**工具**: `ps`
**参数**: `<PID>` - 目标进程ID
**输出**:
- 每个 CPU 上的线程数量
- 使用的 CPU 列表
- **跨域检测**: Cluster/Die/NUMA
- 负载分布均衡性

**使用场景**:
- **检测跨域访问问题**
- 检查线程是否分散在不同 NUMA 节点
- 分析负载是否均衡

**输出文件**: `profiler_output/thread_distribution.json`

**关键诊断指标**:
- `cross_cluster`: 是否跨 Cluster
- `cross_die`: 是否跨 Die
- `cross_numa`: 是否跨 NUMA
- `is_balanced`: 负载是否均衡

### 高级性能分析 (13-16)

#### 13_thread_migration.sh ⭐ 核心脚本
**作用**: 线程迁移监控
**工具**: `perf`
**参数**: `<PID>` [DURATION] - DURATION默认5秒
**输出**:
- 线程迁移事件总数
- 每秒迁移次数
- 每线程平均迁移次数
- 迁移频率评级 (high/medium/low)

**使用场景**:
- **诊断线程过度迁移问题**
- 检测 CPU 亲和性是否失效
- 与脚本07配合分析

**输出文件**: `profiler_output/thread_migration.json`

**关键诊断指标**:
- `migration_count`: 迁移次数
- `migration_level`: high(>100) / medium(10-100) / low(<10)
- `needs_optimization`: 是否需要优化

#### 14_cache_statistics.sh
**作用**: 缓存性能统计
**工具**: `perf`
**参数**: `<PID>` [DURATION] - DURATION默认5秒
**输出**:
- L1 数据缓存命中率
- LLC (L3) 加载/存储命中率
- 缓存争用检测

**使用场景**:
- 检测 L3 缓存争用
- 分析缓存效率

**输出文件**: `profiler_output/cache_statistics.json`

**关键诊断指标**:
- `llc_miss_rate`: LLC 未命中率
- `cache_contention`: 是否存在缓存争用

#### 15_cachestat.sh
**作用**: 系统级缓存统计
**工具**: `cachestat` (bcc-tools)
**参数**: [INTERVAL] [COUNT] - 默认1秒间隔，5次采样
**输出**:
- 系统级缓存命中率
- DTLB/iTLB 命中率

**使用场景**:
- 分析系统整体缓存压力
- 需要安装 bcc-tools

**输出文件**: `profiler_output/cachestat.json`

#### 16_memory_bandwidth.sh
**作用**: 内存带宽监控
**工具**: `perf` (Intel CPU 事件)
**参数**: `<PID>` [DURATION] - DURATION默认5秒
**输出**:
- 内存读/写次数
- 内存读/写周期
- 读/写比例
- 带宽压力评级

**使用场景**:
- 检测内存带宽瓶颈
- 分析内存访问模式

**输出文件**: `profiler_output/memory_bandwidth.json`

**关键诊断指标**:
- `total_ops_per_sec`: 每秒内存操作数
- `bandwidth_pressure`: high(>1M/s) / medium(100K-1M/s) / low(<100K/s)
- `read_write_ratio`: 读/写比例

## 诊断流程

根据问题症状，选择合适的脚本组合：

### 场景1: 快速诊断 CPU 亲核性问题
```
必选: 01, 02, 07, 12, 13
```
1. `01_cpu_topology.sh` - 了解硬件
2. `02_thread_list.sh <PID>` - 获取线程列表
3. `07_thread_affinity.sh <PID>` - 检查亲和性配置
4. `12_thread_distribution.sh <PID>` - 检查跨域情况
5. `13_thread_migration.sh <PID>` - 检查迁移频率

### 场景2: 诊断跨 NUMA 访问问题
```
必选: 11, 12
可选: 01, 02, 07
```
1. `11_numa_topology.sh` - 获取 NUMA 拓扑
2. `12_thread_distribution.sh <PID>` - 检查线程分布
3. 对比分析线程是否跨 NUMA 节点

### 场景3: 诊断线程过度迁移
```
必选: 07, 13
可选: 08, 12
```
1. `07_thread_affinity.sh <PID>` - 检查亲和性配置
2. `13_thread_migration.sh <PID>` - 监控迁移
3. `08_thread_context_switch.sh <PID>` - 检查上下文切换

### 场景4: 诊断缓存争用问题
```
必选: 14, 15
可选: 12
```
1. `14_cache_statistics.sh <PID>` - 进程级缓存统计
2. `15_cachestat.sh` - 系统级缓存统计
3. `12_thread_distribution.sh <PID>` - 检查是否跨 Die (共享L3)

### 场景5: 诊断内存带宽问题
```
必选: 16
可选: 11, 12
```
1. `16_memory_bandwidth.sh <PID>` - 监控内存带宽
2. `11_numa_topology.sh` - NUMA 拓扑
3. `12_thread_distribution.sh <PID>` - 检查跨 NUMA 访问

### 场景6: 诊断系统干扰
```
必选: 03, 05, 10
可选: 04, 06
```
1. `03_system_cpu_usage.sh` - 系统整体负载
2. `05_high_cpu_processes.sh <PID>` - 高 CPU 进程（排除目标进程）
3. `10_system_services.sh` - 系统服务
4. `04_per_core_cpu_usage.sh` - 每核使用率
5. `06_thread_cpu_usage.sh <PID>` - 线程使用率

### 场景7: 完整诊断
```
全部: 01-16
```
运行所有脚本进行全面分析

## 执行脚本

所有脚本位于 `scripts/` 目录，需要可执行权限：

```bash
# 无需参数的脚本
./01_cpu_topology.sh
./03_system_cpu_usage.sh
./04_per_core_cpu_usage.sh
./05_high_cpu_processes.sh
./09_cpu_frequency.sh
./10_system_services.sh
./11_numa_topology.sh
./15_cachestat.sh

# 需要 PID 的脚本
./02_thread_list.sh <PID>
./06_thread_cpu_usage.sh <PID>
./07_thread_affinity.sh <PID>
./08_thread_context_switch.sh <PID>
./12_thread_distribution.sh <PID>
./13_thread_migration.sh <PID> [DURATION]
./14_cache_statistics.sh <PID> [DURATION]
./16_memory_bandwidth.sh <PID> [DURATION]
```

## 输出文件

所有脚本将结果输出到 `profiler_output/` 目录：
- `*.txt` - 原始文本输出
- `*.json` - 结构化 JSON 数据

JSON 输出格式统一包含：
- `timestamp`: 采集时间
- `unix_time`: Unix 时间戳
- `data_type`: 数据类型
- 各种指标和 `analysis` 字段

## 分析建议

根据诊断结果，提供优化建议：

### 1. CPU 亲和性问题
**症状**:
- `07_thread_affinity.json`: `is_isolated: false`
- `13_thread_migration.json`: `migration_level: high`

**建议**:
- 使用 `taskset` 或 `numactl` 绑定推理服务到特定 CPU
- **VLLM**: 为 VLLM::Worker、acl_thread、release_thread 分别绑定独立 CPU 集合
- **通用进程**: 为主要线程（Top 5 CPU）绑定专用 CPU 核心

### 2. 跨 NUMA 访问问题
**症状**:
- `12_thread_distribution.json`: `cross_numa: true`
- `16_memory_bandwidth.json`: `bandwidth_pressure: high`

**建议**:
- 使用 `numactl --cpunodebind=$NODE --membind=$NODE` 绑定 NUMA 节点
- 确保内存和 CPU 在同一 NUMA 节点

### 3. 跨 Die 访问导致 L3 争用
**症状**:
- `12_thread_distribution.json`: `cross_die: true`
- `14_cache_statistics.json`: `cache_contention: true`

**建议**:
- 将线程限制在单个 Die 内 (32个CPU)
- 减少 L3 缓存争用

### 4. 系统干扰
**症状**:
- `03_system_cpu_usage.json`: system 或 iowait 过高
- `05_high_cpu_processes.json`: 其他进程 CPU 占用高

**建议**:
- 停止不必要的服务
- 使用 cgroup 限制其他进程资源

### 5. CPU 频率问题
**症状**:
- `09_cpu_frequency.json`: 频率低于最大值

**建议**:
- 设置 CPU 调节器为 performance
- `cpupower frequency-set -g performance`

## 常见问题排查

### Q: 推理服务性能突然下降
```
1. 先运行 02, 07, 12, 13 快速诊断
2. 检查是否有系统服务干扰 (10)
3. 检查 CPU 频率 (09)
```

### Q: 线程频繁迁移
```
1. 检查亲和性配置 (07)
2. 监控迁移频率 (13)
3. 检查上下文切换 (08)
```

### Q: 内存访问慢
```
1. 检查 NUMA 分布 (11, 12)
2. 监控内存带宽 (16)
3. 检查跨 NUMA 访问
```

### Q: 缓存命中率低
```
1. 检查 L3 缓存统计 (14)
2. 检查跨 Die 分布 (12)
3. 检查系统缓存压力 (15)
```

### Q: SGLang/TGI 等其他推理服务分析
```
工具自动识别进程类型，使用方式与 VLLM 完全相同：
./02_thread_list.sh <pid>
./06_thread_cpu_usage.sh <pid>
./07_thread_affinity.sh <pid>
```

## 依赖工具

确保系统安装了以下工具：

```bash
# 基础工具
lscpu, ps, top, taskset

# 系统监控
sar, mpstat, pidstat  # sysstat 包
cpupower              # linux-tools 包
systemctl             # systemd

# NUMA
numactl

# 高级性能分析
perf                  # linux-tools-common
cachestat             # bcc-tools
```

安装命令：
```bash
# Ubuntu/Debian
apt-get install linux-tools-common linux-tools-generic sysstat numactl bcc-tools

# CentOS/RHEL
yum install kernel-tools sysstat numactl bcc-tools
```

## 工作流程

当用户请求推理服务 CPU 亲核性分析时：

1. **获取 PID**（必需）:
   - 首先询问：**"请提供要分析的推理服务进程的 PID"**
   - 如果用户不知道，提示查找方法：`ps aux | grep -E "vllm|sglang|tgi|python.*model"` 或 `pgrep -f vllm`

2. **确认目标进程类型**: 询问是 VLLM、SGLang、TGI 还是其他推理服务（可选，工具会自动识别）

3. **了解问题**: 询问具体症状（性能下降、延迟增加、吞吐量不足等）

4. **选择脚本**: 根据症状选择合适的脚本组合

5. **指导执行**: 告诉用户运行哪些脚本及参数
   - 所有需要 PID 的脚本：`./02_thread_list.sh <PID>`、`./06_thread_cpu_usage.sh <PID>`、`./07_thread_affinity.sh <PID>` 等
   - 脚本 02、06、07 会自动识别进程类型并适配分析逻辑

6. **解析结果**: 读取 profiler_output/*.json 文件

7. **综合分析**: 结合多个脚本的结果进行诊断

8. **提供建议**: 给出具体的优化建议

**记住**：
- **PID 是必需参数**，没有 PID 无法进行进程级分析
- 不要固定脚本组合，根据实际情况灵活选择
- 工具已支持 VLLM 和通用推理服务（SGLang、TGI 等）
