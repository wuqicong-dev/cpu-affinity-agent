---
name: bind-core-strategy
description: 该skill用于绑核策略生成绑核策略与绑核脚本，当需要做CPU绑核优化的时候触发或由用户手动触发。
---
## 输入要求：
* 要求用户给定监测数据与线程信息，如用户未给定，则需要给用户提示，要求其输入（必需）

## 参考依据

绑核策略生成时，将参考以下文档中的内容：

### 1. CPU架构基础：reference.md
- **内存层次与拓扑架构**：L1/L2/L3缓存、NUMA节点、Cluster/Die结构等
- **Cluster拓扑结构**：每4个CPU核心共享同一组L3缓存，每32个CPU组成一个Die
- **PTA相关线程及细粒度绑核规范**：热点线程优先绑定策略、非热点线程隔离调度等
- **细粒度绑核优化核心前提**：厘清业务进程及进程名、分析进程内部线程行为、制定细粒度绑核策略
- **绑核核心逻辑顺序**：识别模型推理、计算调度相关核心线程 → 深入分析进程内部线程行为 → 结合业务特征制定绑核策略

参考文档位置：`.claude/skills/bind-core-policy/references/cpu-architecture-reference.md`

### 2. 实战案例库：cpu-affinity-issue-reference.md
以下4个典型案例提供实战经验与优化建议：

- **案例1：Decode节点抖动（Host与GC优化）** - GC规律性抖动定位与优化、线程隔离策略
- **案例2：绑核引发的气泡及profiling数据失真问题** - Profiling场景下EngineCore多核分配、msprof线程资源争抢问题
- **案例3：Vllm PD分离架构下的Host抖动问题** - 算子下发延迟、sync延迟、pagefault优化（2M大页配置）
- **案例4：商用模型加压后网卡流量放大及跨P抖动问题** - 多流多队列+DMA直通传输、负载均衡、4X4对称绑核策略

参考文档位置：`.claude/skills/bind-core-policy/references/cpu-affinity-issue-reference.md`

## 核心判断逻辑

* 通过输入获取到服务器的基础信息,CPU计算、IO与内存相关数据,判断当前业务下的负载类型,基于不同负载类型使用不同的绑核策略。

### 1. 基于负载类型的绑定策略

- **CPU密集型**：计算为瓶颈，高CPU利用率，敏感于上下文切换、核心争抢、L3缓存命中率
  - 优化：高优先级线程独占核心及L3缓存分区，避免缓存污染，减少缓存争抢
  - 线程特征：各类worker、compute_thread、acl_thread、release_thread等计算线程占用高

- **内存密集型**：内存带宽/访问延迟为瓶颈，敏感于跨NUMA访问、本地内存亲和、L3缓存复用
  - 优化：CPU与内存本地NUMA绑定，高优先级线程独占本地内存及L3缓存，减少跨节点开销
  - 线程特征：存在大量内存分配/释放、pagefault频发、跨NUMA访问比例高

- **IO密集型（磁盘/存储）**：磁盘IO为瓶颈，敏感于调度延迟、IOPS、挂载点NUMA亲和
  - 优化：本地NUMA亲和部署，绑定专属核心，缩短数据传输路径
  - 线程特征：IO线程、loader线程占比高，存在大量block/wait状态

- **网络IO密集型**：网络传输为瓶颈，敏感于网卡队列分布、中断亲和、跨片传输效率
  - 优化：网卡接收队列/中断绑定到CPU Socket，Driver/Worker/Forward进程同P节点绑定，启用DMA直通传输
  - 线程特征：大量网络相关线程、hccs流量高、跨片数据搬运明显

- **复合负载（CPU + 网络IO）**：计算与网络传输均为瓶颈，如VLLM推理服务
  - 优化：4X4对称绑核，网卡报文接收队列分组绑定4个CPU，KV Cache预先分配至目的节点，跨片数据采用Non-cacheable DMA
  - 参考：案例4商用模型加压场景


### 2. 面向CPU计算负载的绑核策略

**算力规划**：通过获取服务器的基础信息了解容器CPU规格与内存层级划分；区分高优先级计算线程与辅助组件，分配专属核心及L3缓存分区，避免竞争损耗。

**容器亲和与隔离**：高优先级组件优先调度至同一Cluster/DIE，遵循NUMA亲和；共享数据容器同域部署，无共享组件强隔离，保障算力稳定。

**拓扑落地**：使用同Cluster/Die/NUMA连续核心，禁止跨域混跑；按专属核心池绑定，实现算力、性能、缓存可预期复用。

### 3. 面向内存负载的绑核策略

**内存规划**：量化内存需求，划分内存区域，优先分配本地NUMA内存并预留余量，关联L3缓存规划，提升访问效率。

**绑定规则**：高优先级组件内存绑定至本地NUMA，实现CPU-内存亲和；共享内存分配至公共NUMA，仅同域高优先级组件复用；优化访问路径及H2D传输协同效率。

**隔离落地**：CPU与内存同NUMA绑定，禁止核心组件跨域非必要调度；按NUMA分片部署，完成核-内存-L3缓存-业务确定性布局。

### 4. 面向IO负载的绑核策略

**核心原则**：采集硬件拓扑信息，IO进程/线程绑定至IO设备同NUMA核心，规划专属核心池，避免资源争抢。

**中断绑定**：NUMA级别绑定IO中断队列与对应CPU核心，高IOPS业务用NUMA独占核心处理中断。

**细化部署**：NUMA内细化至Cluster/DIE级别，IO线程与中断队列绑定同一Cluster/DIE连续核心，降低切换代价。

## 绑核决策流程

1. **步骤1：识别进程** - 从给定的报告或系统信息中识别目标进程名称、PID、业务类型、当前绑核状态
2. **步骤2：分析线程行为** - 分析CPU使用率、线程干扰、跨域分布、L3缓存、线程与锁监控等指标
3. **步骤3：判定负载类型** - 根据负载检测结果确定是CPU密集型/内存密集型/IO密集型
4. **步骤4：制定具体策略** - 根据负载类型应用对应的绑核策略
5. **步骤5：生成执行脚本** - 生成可执行的Bash绑定脚本

## 输出格式

### 第一部分：生成绑核策略分析结论（Markdown）

```markdown
# 绑核策略分析结论

## 一、业务概况
- **目标进程**：[进程名]
- **PID**：[进程ID]
- **业务类型**：[CPU密集型/内存密集型/IO密集型/网络IO密集型/复合负载]
- **当前绑核状态**：[已绑定/未绑定/部分绑定]
- **特殊场景识别**：[Profiling采集/GC抖动/跨片传输/无]

## 二、线程分析结果
| 线程名 | TID | CPU占用 | 功能分类 | 热点等级 | 绑定策略 |
|----------|------|---------|----------|-----------|----------|
| VLLM::Worker | 2191389 | 85.2% | 计算线程 | 第一热点 | 核心独占 |
| acl_thread | 2191971 | 62.3% | 计算线程 | 第三热点 | 固定绑定 |
| ... | ... | ... | ... | ... | ... |

**未命名线程**：[数量] 处理方式：[分组绑核/共享池]

## 三、负载类型判定
**主要负载类型**：[CPU密集型/内存密集型/IO密集型/网络IO密集型/复合负载]
**次要负载类型**：[若有]
**判定依据**：
- [依据1：如CPU高占用、线程分布特征等]
- [依据2：如内存带宽、跨NUMA访问比例等]
- [依据3：如网络流量、网卡负载特征等]
**敏感因素**：[上下文切换/核心争抢/L3缓存命中率/跨NUMA访问/调度延迟/中断亲和]

## 四、NUMA拓扑分析
**目标NUMA节点**：[节点号]
**核心范围**：[起始-结束]
**跨NUMA访问比例**：[百分比或范围]
**布局特点**：[如：NUMA节点内核心连续/分散等]
**Cluster/Die分布**：[若为CPU密集型，说明核心在Cluster/Die中的分布]

## 五、绑核策略
| 线程名 | TID | 绑定核心 | 绑定说明 |
|---------|-----|----------|----------|
| VLLM::Worker | 2191389 | 0 | 第一热点，核心独占及L3缓存分区 |
| release_thread | 2191971 | 1 | 第二热点，固定绑定，禁止线程迁移 |
| acl_thread | 2191890 | 2 | 第三热点，固定绑定 |
| ... | ... | ... | ... |

**Profiling场景特殊处理**：
- [若检测到Profiling场景：说明为EngineCore下发进程分配多个核心（如4-8核），避免msprof线程争抢]

## 六、执行计划
1. 创建新的工作目录：`<skill-name>-workspace/iteration-N/`
2. 保存分析结果：`iteration-N/eval-N/with_skill/outputs/`
3. 应用绑定策略，执行绑定脚本
4. 验证绑定结果：`ps -T -p <PID> -o pid,tid,psr,psrset` 输出三列分别对应PID、TID、当前CPU核心、当前绑定核心

## 七、优化建议（基于实战案例）

### 7.1 GC优化建议（若检测到GC抖动特征）
- **诊断特征**：规律性大抖动、GC日志显示周期性活动
- **优化方案**：
  1. 线程干扰优化：自动绑核、关闭numa平衡、线程隔离
  2. GC策略调整：关键执行前关闭GC，Device运行期间手动触发Young GC
  3. 利用Device运行时间掩盖GC耗时，消除规律性抖动
- **实施步骤**：
  ```bash
  # 关闭numa平衡
  echo 0 > /proc/sys/kernel/numa_balancing

  # 在Python代码中控制GC
  import gc
  gc.disable()  # Decode执行前关闭GC
  # ... Decode执行 ...
  gc.collect()  # Device运行期间手动触发GC
  ```

### 7.2 内存优化建议（若检测到pagefault/内存抖动）
- **诊断特征**：大量pagefault、缺页中断、sync延迟
- **优化方案**：启用2M大页内存，减少缺页中断
- **实施步骤**：
  ```bash
  # 启用2M hugepages，示例配置1024页
  echo 1024 > /proc/sys/vm/nr_hugepages
  # 或在启动时设置：echo 1024 > /proc/sys/vm/nr_hugepages

  # 验证hugepages状态
  grep Huge /proc/meminfo
  ```

### 7.3 网络IO优化建议（若检测到网络IO密集特征）
- **诊断特征**：网卡流量高、跨片传输明显、跨P抖动
- **优化方案**：
  1. 多流多队列+DMA直通传输：使能non-cacheable DMA，将KV Cache传输至本地内存
  2. 负载均衡：网卡接收队列分组绑定4个CPU，KV Cache预先分配至目的节点
  3. 4X4对称绑核：网卡中断绑定CPU Socket，Driver/Worker/Forward同一P节点
- **实施步骤**：
  ```bash
  # 网卡队列绑定示例（eth0网卡，队列0绑定NUMA节点0的CPU 0-3）
  set_irq_affinity_cpulist.sh 0-3 eth0-queue-0

  # 验证绑定结果
  cat /proc/interrupts | grep eth0
  ```

### 7.4 绑核效果验证
- **验证指标**：
  - CPU利用率分布（热点与非热点线程占比）
  - L3缓存命中率（若可获取）
  - 线程切换频率（降低为佳）
  - 响应时延（P99/P99.9）
  - 抖动频率（降低为佳）
- **验证命令**：
  ```bash
  # 查看线程绑核状态
  ps -T -p <PID> -o pid,tid,psr,psrset,comm

  # 查看NUMA统计
  numastat -p <PID>

  # 查看cache misses（如perf可用）
  perf stat -e cache-references,cache-misses -p <PID> timeout 10
  ```
```

### 第二部分：生成可执行的Bash脚本

**重要：必须严格使用以下简化模板格式，不能添加额外函数、检查逻辑或冗长代码**

**脚本设计原则**：
- 精简代码，去除冗余循环和重复逻辑
- 使用 Bash 关联数组实现线程名到核心的精确映射
- 一次遍历完成所有绑定，提高效率

**强制格式模板（按此格式生成，不要添加任何额外代码）：**
```bash
#!/bin/bash
# 绑核脚本 - <业务名称>
# PID: <进程ID>

TARGET_PID=<进程ID>

# 线程绑定映射: "线程名:核心"
declare -A THREAD_CORES=(
    ["VLLM::Worker"]=0
    ["release_thread"]=1
    ["acl_thread"]=2
<根据分析结果补充更多线程绑定>
)

# 未命名线程的核心池 (起始到结束核心)
UNNAMED_CORE_POOL_START=3
UNNAMED_CORE_POOL_END=79

echo "绑定进程 $TARGET_PID ($TARGET_PID) 的线程..."

# 遍历所有线程，按名称绑定
ps -T -p $TARGET_PID -o tid,comm --no-headers | while read tid comm; do
    if [ -n "${THREAD_CORES[$comm]}" ]; then
        # 名称已映射，使用指定核心
        taskset -cp ${THREAD_CORES[$comm]} $tid 2>/dev/null && echo "✓ $comm($tid) -> 核心${THREAD_CORES[$comm]}"
    else
        # 名称未映射，使用核心池，按顺序分配
        if [ -z "$NEXT_UNNAMED_CORE" ]; then
            NEXT_UNNAMED_CORE=$UNNAMED_CORE_POOL_START
        fi
        if [ $NEXT_UNNAMED_CORE -le $UNNAMED_CORE_POOL_END ]; then
            taskset -cp $NEXT_UNNAMED_CORE $tid 2>/dev/null && echo "✓ $comm($tid) -> 核心$NEXT_UNNAMED_CORE"
            NEXT_UNNAMED_CORE=$((NEXT_UNNAMED_CORE + 1))
        fi
    fi
done

echo "完成。验证: ps -T -p $TARGET_PID -o pid,tid,psr,psrset"
```

**注意事项：**
- 脚本应控制在20-30行内
- 不要添加颜色输出、日志函数、检查函数等额外逻辑
- 只要核心的绑核功能，简洁直接
- 每个线程名对应一个具体的核心编号

## 注意事项

1. **核心规划原则**：
   - 高优先级线程独占核心和L3缓存分区，避免缓存污染和竞争
   - 分配连续的核心区域，提高缓存局部性和指令/缓存局部性
   - 保留足够的预留核心用于系统服务（如调度器、中断处理）
   - NUMA节点内核心连续，跨域时必须跨NUMA节点分配

2. **复合线程分类体系**（热点等级 × 功能维度）：

   **热点等级维度**（基于CPU占用与性能影响）：
   | 等级 | 特征 | 绑核策略 |
   |-------|------|----------|
   | 第一热点 | CPU占用最高、主流程关键路径 | 固定绑定第1个CPU核，禁止线程迁移 |
   | 第二热点 | CPU占用较高、主要计算路径 | 固定绑定后续核心，按顺序分配 |
   | 第三热点 | CPU占用适中、辅助计算路径 | 按需分配核心，避免跨域调度 |
   | 非热点 | CPU占用低、后台/监控线程 | 物理隔离，绑定到辅助核心池 |

   **功能维度**（基于线程职责）：
   | 功能分类 | 线程名关键词 | 绑核优先级 | 隔离要求 |
   |---------|-------------|------------|----------|
   | 计算线程 | worker、compute_thread、acl_thread、release_thread、CaffeTaskThread | 最高 | 独占核心及L3缓存分区 |
   | 推理线程 | model、推理、forward、infer、VLLM::Worker | 最高 | 同Cluster/Die连续绑定，避免缓存污染 |
   | 通信线程 | hccl、hcclCommWatchdogThread、hccl_watchdog_t | 高 | NUMA亲和部署，避免跨片通信延迟 |
   | 管理线程 | main、server、manager、ZMQbg | 中 | 分配管理核心池，保持低延迟响应 |
   | 数据线程 | data、loader、fetch、python | 中/低 | 与计算线程隔离，避免缓存污染 |
   | IO线程 | io、net、eth、tcp、udp | 低 | 本地NUMA绑定，网卡队列/中断亲和 |
   | Profiling线程 | msprof、msprof_thread | 场景相关 | Profiling场景需多核分配，避免争抢 |
   | 监控线程 | watchdog、monitor | 低 | 绑定辅助核心池，避免干扰主线 |

   **热点线程示例（基于reference.md中的PTA规范）**：
   | 线程名称 | 核心职责 | 热点等级 |
   |-----------|---------|----------|
   | mainThread | Pytorch+PTA主线程，负责前向算子下发 | 第一热点 |
   | npuGuardThread | 负责PTA反向算子下发 | 第二热点 |
   | aclThread | 负责PTA二级流水（task queue）调度 | 第三热点 |
   | releaseThread | 负责PTA资源释放 | 非热点 |
   | hcclCommWatchdogThread | 负责PTA的HCCL通信监控 | 非热点 |
   | unknownThread | Pytorch线程池线程，数据并行处理 | 非热点 |

3. **未命名线程处理**：无法识别的未命名线程（线程名形式为数字）归类为"辅助线程"，统一绑定到辅助核心池

4. **验证方法**：
   ```bash
   # 查看所有线程的当前调度核心和绑定核心
   ps -T -p <PID> -o pid,tid,psr
   # psr: 当前运行在哪个核心上
   如果psr与预期绑定核心相同，则认为绑定成功
   ```
