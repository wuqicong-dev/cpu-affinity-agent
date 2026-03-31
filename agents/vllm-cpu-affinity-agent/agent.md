---
name: llm-cpu-affinity-agent
description: LLM推理与训练服务CPU亲和性诊断与优化编排器。支持VLLM、SGLang、TGI、vLLM C++、TensorRT-LLM等推理框架，以及Megatron-LM、DeepSpeed、PyTorch DDP、MindSpore + MindSpeed等训练框架。支持单进程和多进程场景。协调执行3个诊断步骤（内存瓶颈分析、CPU亲和性分析、网络IO性能分析），进行多进程资源协调优化，最后调用bind-core-policy生成综合优化报告和绑核脚本。
Tools: ALL tools
Model: Inherit from parent
---

# LLM推理与训练服务CPU亲和性诊断与优化Agent

协调执行LLM推理与训练服务（推理：VLLM、SGLang、TGI、vLLM C++、TensorRT-LLM等；训练：Megatron-LM、DeepSpeed、PyTorch DDP、MindSpore+MindSpeed等）的CPU亲和性诊断，收集各步骤的分析结果，支持多进程场景下的资源协调与优化，最后调用bind-core-policy生成综合优化报告和绑核脚本。

## 执行流程

```
用户请求
   ↓
验证输入（支持单个或多个PID、线程信息）
   ↓
收集基础信息（CPU拓扑、NUMA节点）
   ↓
计算多进程资源分配策略
   ↓
并行执行3个诊断任务（针对每个进程）
   ↓
聚合分析结果 + 多进程协调
   ↓
调用 bind-core-policy skill
   (输入：所有进程诊断报告 + 资源分配策略)
   ↓
bind-core-policy 生成：
   - 多进程综合优化报告
   - 统一的精简绑核脚本
   ↓
第六步：执行绑核脚本（含前置检查）
   - 绑定前备份当前状态
   - 执行绑核脚本
   - 失败时自动回滚
   ↓
第七步：验证绑定结果
   - 自动验证绑核成功率
   - 检查NUMA亲和性
   - 多进程场景验证进程隔离
   - 失败时提示回滚或重新绑核
   ↓
输出结果（含验证报告）
```

## 输入验证

启动前确认用户提供：

### 必需信息

1. **目标进程PID** - 必需
   - **推理框架**：VLLM、SGLang、TGI、vLLM C++、TensorRT-LLM等
   - **训练框架**：Megatron-LM、DeepSpeed、PyTorch DDP/FSDP、MindSpore+MindSpeed、Ray Train 等
   - 支持单个PID或多进程PID列表（逗号分隔或JSON数组）
   - 例如：`12345` 或 `12345,23456,34567`

2. **工作负载类型** - 必需
   - **推理（Inference）**：单模型推理、批量推理、流式推理
   - **训练（Training）**：预训练、微调、Distributed训练、FSDP/FSDP2、ZeRO优化

3. **进程线程说明** - 必需
   - 每个进程的线程数量（推理线程/训练线程）
   - 辅助线程说明（数据加载、梯度通信、参数服务器、检查点保存等）
   - 格式：进程ID与线程配置的映射关系
   - 支持指定框架类型，或使用自动识别

### 多进程模式说明

当用户提供多个PID时，Agent将：
- 识别每个进程的业务类型和角色（推理主进程、数据加载、参数更新、梯度同步等）
- 检测进程间的依赖关系和通信拓扑（数据并行、模型并行、流水线并行等）
- 规划NUMA节点和核心资源的分配，考虑训练通信模式
- 避免进程间核心冲突和资源竞争，特别是通信线程的隔离

### 使用AskUserQuestion获取信息

如果输入不完整，使用AskUserQuestion工具询问：
```
问题1: 请提供需要绑核的推理服务进程PID（单个或多个，逗号分隔）
问题2: 请提供每个进程的推理线程数量和辅助线程说明
问题3: （多进程时）是否有进程间依赖关系需要特殊处理？
```

---

## 多进程资源协调策略

### 资源分配原则

**核心原则**：多进程绑核时，需要进程间相互隔离、资源有序分配、避免跨NUMA访问，并在SMT场景下避免物理核冲突。

1. **NUMA节点分配**
   - 优先将同一业务链路的进程部署在同一NUMA节点，降低内存访问延迟
   - 多业务进程可跨NUMA节点隔离，减少跨节点干扰
   - 每个NUMA节点应预留1-2物理核心用于系统服务

2. **SMT场景下的核心映射规则**
   - **检测SMT开启状态**：通过 `lscpu | grep "Thread(s) per core"` 判断
   - **物理核独占原则**：热点线程独占整个物理核（SMT场景下禁用该物理核的其它虚拟核）
   - **虚拟核隔离策略**：
     - SMT开启时，可选择性禁用SMT（`echo 0 > /sys/devices/system/cpu/cpu${cpu}/online`）来绑核物理核
     - 或者确保同一物理核的不同虚拟核不被两个竞争线程同时绑定
   - **核心分配算法**：
     - 先按物理核数计算可用资源（非逻辑核数）
     - 为每个进程分配连续的物理核范围
     - 热点进程优先获取完整的物理核（独占模式）

3. **核心映射规则（非SMT或SMT已优化）**
   - 进程按优先级分配核心区域（高优先级进程获取独立NUMA节点或核心池）
   - 同一NUMA节点内，核心分配为连续区间，便于后续扩展
   - 同一进程的线程绑定在连续核心上，避免跨Cluster/Die调度

4. **多进程隔离策略**
   - **物理隔离**：不同进程绑定到互不重叠的物理核集合
   - **NUMA隔离**：进程间优先选择不同NUMA节点
   - **核心池管理**：使用位图跟踪已分配的物理核，确保无重叠
   - **进程内协调**：当同一NUMA节点内存在多个进程时，通过cpuset cgroup进行资源配额隔离

5. **负载类型适配**
   - **CPU密集型进程**：独占物理核和L3缓存分区，避免缓存污染
   - **内存密集型进程**：优先本地NUMA内存绑定，与内存带宽需求匹配
   - **IO密集型进程**：优先绑定至IO设备同NUMA节点，缩短传输路径

6. **SMT冲突检测与避免**
   - **进程内**：确保同一进程内的线程不会竞争同一物理核的不同虚拟核
   - **进程间**：确保不同进程的线程不会竞争同一物理核
   - **检测方法**：通过 `lscpu -p=CPU,CORE` 建立逻辑核到物理核的映射关系

7. **进程优先级定义**
   - **P1（最高优先级）**：推理/训练主进程、核心计算任务（forward/backward/推理线程）
   - **P2（高优先级）**：数据加载、预处理、模型推理/训练辅助线程
   - **P3（中等优先级）**：通信线程（NCCL/HCCL）、同步线程、监控线程
   - **P4（低优先级）**：日志、维护、后台清理线程、检查点保存线程

### 资源分配计算（支持SMT和多进程）

**输入数据收集**：
- 系统CPU核心总数（逻辑核数、物理核数）、NUMA节点数、每个NUMA的核心数
- SMT状态：`THREADS_PER_CORE`（1=关闭，2=开启）
- 每个进程的线程总数、推理/训练线程数、负载类型
- 进程优先级（用户指定或自动识别）
- 工作负载类型：推理（Inference）或训练（Training）

**计算步骤**：

1. **SMT环境检测与资源计算**
   - 检测SMT状态：`THREADS_PER_CORE=$(lscpu | grep "Thread(s) per core" | awk '{print $NF}')`
   - 如果 `THREADS_PER_CORE > 1`：
     - 可用物理核 = `lscpu | grep "^Core(s) per socket:" | awk '{print $NF}'`
     - SMT冲突避免策略：选择独占物理核模式或虚拟核隔离模式
   - 资源类型选择：优先使用物理核数进行分配，避免SMT性能争抢

2. **计算每个进程所需核心数**
   - **非SMT场景**：`所需核心 = 推理线程数 + 辅助线程数 + 预留核心(1-2)`
   - **SMT场景（独占物理核模式）**：`所需物理核 = ceil(总线程数 / THREADS_PER_CORE) + 预留物理核(1-2)`
   - **SMT场景（虚拟核隔离模式）**：使用逻辑核数分配，确保同一物理核不绑定竞争线程

3. **核心充足性检查**
   - **非SMT场景**：`Σ所需核心 <= 总逻辑核数 - 系统预留核数`
   - **SMT场景**：`Σ所需物理核 <= 总物理核数 - 系统预留物理核数`
   - 分配失败策略：提示用户资源不足，建议减少进程数量或线程数

4. **按优先级排序进程**
   - 用户可指定优先级，或按以下顺序自动识别：
     1. 推理主进程（P1）
     2. 数据加载/预处理进程（P2）
     3. 通信/同步进程（P3）
     4. 监控/日志进程（P4）

5. **多进程核心冲突检测**
   - 建立**全局核心池位图**：`core_pool[physical_core_id] = {owner_pid, allocation_time}`
   - **SMT场景检测**：使用专门的SMT冲突检测脚本 `./scripts/detect_smt_conflict.sh`，该脚本能够：
     - 检测进程间的物理核冲突（同一物理核被不同进程的线程占用）
     - 验证硬件SMT状态并生成物理核到逻辑核的映射关系
     - 识别热点线程和辅助线程的物理核使用情况
     - 输出冲突报告和建议的优化策略

6. **NUMA节点分配**
   - **场景1：进程总数 ≤ NUMA节点数**
     - 一进程一NUMA，按优先级顺序分配
     - 高优先级进程优先选择资源最充足的NUMA节点
   - **场景2：进程总数 > NUMA节点数**
     - 同NUMA部署多个非竞争进程
     - 按进程优先级和核心需求分批分配
     - 确保同一NUMA内的进程总核心需求不超过该NUMA的可分配核心数

7. **核心映射与绑核策略**
   - **SMT关闭场景**：直接分配连续逻辑核区间
   - **SMT开启场景**：
     - **独占物理核模式**：分配连续物理核，进程内线程共享物理核的所有虚拟核
     - **虚拟核隔离模式**：为每个线程分配独立的虚拟核，通过映射表确保不冲突

**SMT示例**：
- 系统：64逻辑核（32物理核，SMT开启，2线程/核），2个NUMA节点（每节点16物理核/32逻辑核）
- 2个进程：主推理（线程15）、数据加载（线程8）
- **资源计算（独占物理核模式）**：
  - 主推理：需要 ceil(15/2)=8个物理核
  - 数据加载：需要 ceil(8/2)=4个物理核
  - 系统预留：2个物理核
- **分配方案**：
  - NUMA0：主推理进程 物理核0-7（独占，共用虚拟核0-15）
  - NUMA1：数据加载进程 物理核0-3（独占，共用虚拟核32-39）
  - 预留：NUMA1物理核4-5（系统服务）

**多进程冲突检测实现**：
- 上述资源分配计算通过核心池位图确保无重叠分配
- 绑核前可调用 `./scripts/detect_smt_conflict.sh <PID列表>` 复查潜在冲突
- 绑核后使用 `./scripts/verify_process_isolation.sh <PID列表>` 验证隔离性

---

## 第一步：获取基础信息

**基础信息收集**：系统CPU拓扑、NUMA节点信息已由 `inference-cpu-affinity-analyzer` 收集，无需重复执行。如需独立收集，可使用以下脚本：

```bash
# 收集CPU拓扑信息（含SMT状态检测）
./scripts/collect_cpu_topology_info.sh

# 收集NUMA节点拓扑信息
./scripts/collect_numa_topology_info.sh

# 收集指定进程的绑核状态和线程信息
./scripts/collect_process_affinity_info.sh <PID列表>
```

这些脚本位于 `scripts/` 目录下，提供：
- **collect_cpu_topology_info.sh** - CPU拓扑、SMT状态、物理核到逻辑核映射
- **collect_numa_topology_info.sh** - NUMA节点信息、CPU分组、内存分配
- **collect_process_affinity_info.sh** - 进程绑核状态、线程列表、SMT冲突检测

---

## 泛化线程分类架构

### 线程分类框架（通用架构支持）

本agent不仅支持推理场景（VLLM、SGLang、TGI、vLLM C++、TensorRT-LLM等），还支持训练场景（Megatron-LM、DeepSpeed、PyTorch DDP、MindSpore+MindSpeed等），并设计了泛化框架以适应其他业务架构。

**通用线程分类模型**：

| 线程类别 | 特征识别模式 | 典型命名模式 | 绑核策略 |
|---------|-------------|-------------|---------|
| **主线程/主循环线程** | CPU占用高、调度频繁、单线程 | `main`, `Main`, `MainThread`, `engine`, `EngineCore` | 独占首物理核，禁用迁移 |
| **推理/计算流水线线程** | CPU密集、关键路径、周期性执行 | `worker`, `Worker`, `infer`, `compute`, `thread`, `Thread` | 独占连续物理核，按顺序分配 |
| **异步任务处理线程** | 事件驱动、短周期、响应式 | `release`, `awaiting`, `event`, `async`, `callback` | 邻近主线程，低延迟绑定 |
| **数据加载/预处理线程** | IO密集、阻塞操作、批处理 | `dataload`, `loader`, `preproc`, `reader`, `parse` | 独立核心池，与计算核心隔离 |
| **通信/协调线程** | 网络IO、消息传递、同步 | `comm`, `communicator`, `rpc`, `mq`, `sync` | 靠近网络接口的NUMA节点，低优先级 |
| **监控/日志线程** | 低CPU、周期性任务、非关键路径 | `monitor`, `watcher`, `logger`, `log`, `stats` | 独立低优先级核心池，远离计算核心 |
| **GC/内存管理线程** | 周期性触发、内存操作、暂停业务 | `gc`, `garbage`, `mem`, `compact`, `sweeper` | 独立核心，避免与业务线程竞争 |
| **缓存/加速库线程** | 对应外部库、线程池模式 | `caffe`, `mxnet`, `nccl`, `cublas`, `mkl`, `aoe` | 邻近计算线程，共享核心池 |
| **未识别线程** | 模式匹配失败、系统线程 | `unknown`, `Thread-XXX`, 数字命名 | 共享核心池，动态调度 |

**架构映射表**：

| 业务架构 | 主要线程模式 | 特殊处理需求 |
|---------|-------------|-------------|
| **VLLM** | Worker主线程 + release_thread + acl_thread | release线程需隔离，acl_thread需邻近Worker |
| **SGLang** | 引擎线程 + 工作线程池 + 数据加载线程 | 需区分热点工作线程和辅助线程 |
| **TGI** | 推理线程 + 预处理线程 + 后处理线程 | 推理线程优先绑定，其他线程隔离 |
| **Megatron-LM** | 前向计算线程 + 反向传播线程 + 通信线程 | 通信线程需NCCL绑定，计算/传播线程分离 |
| **DeepSpeed** | 前向/反向线程 + 优化器线程 + 通信线程 | ZeRO分片线程需隔离，通信线程独立核心池 |
| **PyTorch DDP** | 训练线程 + NCCL通信线程 + DataLoader线程 | NCCL线程绑定专用CPU池，避免与计算线程竞争 |
| **PyTorch FSDP** | 前向/反向线程 + 参数分片线程 + 通信线程 | 参数分片线程需要独立NUMA节点与内存 |
| **MindSpore+MindSpeed** | 前向/反向线程 + 通信线程 + Context线程 | HCCL通信线程需绑定，Context线程流水线隔离 |
| **TensorRT-LLM** | 推理线程 + 内存池线程 | 内存高层线程需低延迟绑定模式 |
| **vLLM C++** | 工作线程池 + I/O线程池 | 避免I/O线程与计算线程跨NUMA |
| **PyTorch DDP** | 主进程 + DataLoader线程集 + NCCL通信线程 | NCCL线程需绑定到专用CPU池，避免干扰计算 |
| **TensorFlow** | Graph执行线程 + 设备管理线程 + 统计线程 | 多线程图执行需分配足够核心池 |
| **Caffe/MXNet** | Solver主线程 + 数据层线程 + 网络层线程 | 数据层线程IO密集，网络层线程CPU密集 |
| **Go Goroutines** | 多Goroutine共享M（机器）线程 | 无法精确control，建议仅绑定M线程，设置GOMAXPROCS |
| **C++ Async服务** | IO线程池 + 工作线程池 | IO线程和工作线程分离，各自独立核心池 |
| **Java应用** | 主线程 + GC线程 + 线程池 | GC线程独占，避免STW |

**线程类型自动识别算法**：

支持推理和训练场景的泛化线程分类，使用脚本 `./scripts/classify_thread.sh` 实现：

```bash
# 使用方法
./scripts/classify_thread.sh <线程名称> [CPU使用率] [调度频率]

# 示例
./scripts/classify_thread.sh "VLLM::Worker"
./scripts/classify_thread.sh "release_thread" "85.2%"
```

**分类规则**：
- **P0级 - 热点线程识别**：
  - `main|Main|MainThread|engine|EngineCore` → 主线程/引擎线程
  - `release|awaiting|event|callback` → 异步事件线程
  - `worker|Worker|thread|Thread` → 计算工作线程
- **P1级 - 功能分类**：
  - 数据加载线程：`dataload|loader|preproc|reader|parse`
  - 通信线程：`comm|communicator|rpc|mq|sync|nccl`
  - 监控线程：`monitor|watcher|logger|log|stats`
  - 内存管理线程：`gc|garbage|mem|compact|sweeper`
  - 加速库线程：`caffe|mxnet|aoe|rtkb|cuckoo`
  - 未识别：归类为 `unknown_thread`

**绑核策略映射**：
- `hot_main_thread` → 独占首物理核，禁止迁移
- `hot_async_thread` → 独占次物理核，低延迟绑定
- `hot_compute_thread` → 独占连续物理核，按顺序分配
- 其他线程类型 → 绑定到共享核心池，与热点线程隔离

**SMT与泛化架构的兼容性处理**：

1. **架构类型检测**
   - 在第一步基础信息收集中，通过进程命令行特征自动识别业务架构

   **推理框架识别:**
   - VLLM: 包含 "vllm"、"VLLM::EngineCore" 等关键词
   - SGLang: 包含 "sglang"、"engine_worker"、"model_worker" 等关键词
   - TGI: 包含 "text-generation-inference"、"tgi" 等关键词
   - vLLM C++: 包含 "vllm_server"、"cpp_inference" 等关键词
   - TensorRT-LLM: 包含 "tensorrt_llm"、"trt_llm" 等关键词

   **训练框架识别:**
   - Megatron-LM: 包含 "megatron"、 "pretrain_gpt" 等关键词
   - DeepSpeed: 包含 "deepspeed"、"ds_engine" 等关键词
   - PyTorch DDP: 包含 "torch.distributed"、"nccl" 关键词，多进程torch启动
   - PyTorch FSDP: 包含 "torch.distributed.fsdp"、"fully_sharded" 关键词
   - MindSpore+MindSpeed: 包含 "mindspore"、"mindspeed" 关键词
   - Ray Train: 包含 "ray.train"、"tune" 关键词

   **其他框架:**
   - PyTorch: 包含 "python"、"torch"、多进程分布式训练特征
   - Java: 进程为 "java"
   - Go: 进程包含 "goroutine" 相关模式

2. **架构特定绑核策略**
   - 根据检测到的架构类型，从预定义的策略库中选择绑核方案

   **推理框架:**
   - VLLM: 识别Worker、acl_thread、release_thread等特有线程
   - SGLang: 识别engine_worker、model_worker等工作线程
   - TGI: 识别inference、preprocessing、postprocessing线程

   **训练框架:**
   - Megatron-LM: 识别前向forward、反向backward、通信communication线程
   - DeepSpeed: 识别计算线程、ZeRO分片线程、NCCL通信线程、优化器线程
   - PyTorch DDP: 识别训练主线程、NCCL通信线程、DataLoader线程
   - PyTorch FSDP: 识别计算线程、参数分片线程、梯度通信线程
   - MindSpore+MindSpeed: 识别前向/反向线程、HCCL通信线程、Context并行线程
   - Ray Train: 识别训练actor线程、dataset加载线程、collect通信线程

   - 对于未知架构，使用通用策略（按线程ID分类）

3. **SMT感知的泛化策略**
   - 无论何种架构，均执行SMT检测和物理核映射
   - 保证热点线程独占物理核，避免SMT竞争

---

## 第二步：并行执行多进程诊断任务

### 执行策略

**单进程场景**：并行启动3个诊断子任务，针对单个PID执行。

**多进程场景**：为每个进程并行启动3个诊断子任务，所有诊断任务（任务数 = 3 × 进程数）并行执行。

### 诊断任务定义

对每个进程PID，执行以下3个诊断任务：

#### 任务1：内存瓶颈分析
```
Execute task using skill: memory-bottleneck-analyzer
Input: PID=<当前进程PID>, 业务类型=推理/训练服务（VLLM/SGLang/Megatron-LM等）
Output: <PID>_memory_bottleneck_report.md
```

#### 任务2：CPU亲和性分析
```
Execute task using skill: inference-cpu-affinity-analyzer
Input: <PID>
Output: <PID>_cpu_affinity_report.md
```

#### 任务3：网络IO性能分析（全局执行一次）
```
Execute task using skill: network-io-performance
Input: 接口分析=自动, 中断分析=启用, 丢包检测=启用, 队列平衡分析=启用
Output: network_io_performance_report.md
```

**并行执行说明**：
- 单进程：3个任务并行
- 多进程（N个进程）：(3×N)个任务全部并行
- 网络IO分析为全局任务，多进程场景下只需执行一次
- 结果按进程ID分类存储，便于后续聚合分析

### ⚠️ 强制要求：三阶段诊断必须全部完成

**在生成绑核策略之前，必须确保以下三个诊断任务全部成功完成：**

1. **内存瓶颈分析** (memory-bottleneck-analyzer) - 输出完整报告
2. **CPU亲和性分析** (inference-cpu-affinity-analyzer) - 输出完整报告
3. **网络IO性能分析** (network-io-performance) - 输出完整报告

**验证机制：**
- 检查每个输出文件是否存在且非空
- 验证报告格式正确，包含必要的数据字段
- 如果任一任务失败，记录详细错误并提示用户
- 不允许跳过任何一个诊断步骤进入绑核策略生成

**错误处理：**
- 单个任务失败：中止绑核策略生成，提示用户检查该任务配置
- 部分任务输出不完整：提示用户重新执行失败的诊断任务
- 所有任务完成后，才能调用 bind-core-policy skill

---

## 第三步：聚合分析结果与多进程协调

等待所有诊断子任务完成后，聚合结果并进行多进程协调分析：

### 1. 构建进程诊断数据结构

为每个进程构建完整的诊断数据包：

```json
{
  "process_id": "<PID>",
  "process_name": "<进程名称>",
  "process_type": "<推理/数据加载/监控/其他>",
  "thread_count": <线程总数>,
  "inference_threads": <推理线程数>,
  "diagnostic_reports": {
    "cpu_affinity": "<该进程的CPU亲和性分析报告>",
    "memory_bottleneck": "<该进程的内存瓶颈报告>"
  }
}
```

### 2. 收集所有发现的问题

从各进程报告中提取问题列表，按严重程度排序：
- **P0（严重）**：跨NUMA访问频繁、核心冲突、缓存命中率极低
- **P1（中等）**：线程分布不均、部分线程跨域调度
- **P2（轻微）**：轻微负载不均、资源利用不足

### 3. 识别问题关联与进程间影响

分析进程间是否存在关联问题：
- 进程A的跨NUMA访问是否可能与进程B在同一节点导致的资源竞争
- 中断负载集中是否对特定进程的线程造成影响
- 进程间是否存在共享内存或通信导致的隐式资源争用

### 4. 生成诊断数据包

整合以下内容传递给 bind-core-policy：
- 所有进程的诊断报告数据
- 系统基础信息（CPU拓扑、NUMA拓扑）
- 多进程资源分配策略

## 第四步：调用 bind-core-policy skill

使用Skill工具调用 bind-core-policy，生成综合优化报告和绑核脚本。

### bind-core-policy 输入内容

#### 单进程输入结构

```json
{
  "mode": "single",
  "process_info": {
    "pid": "<进程ID>",
    "process_name": "<推理服务进程名，如VLLM::Worker/SGLang-Worker/TGI-Inference>",
    "thread_count": <线程总数>,
    "inference_threads": <推理线程数>
  },
  "basic_info": {
    "cpu_topology": "<lscpu输出>",
    "numa_topology": "<numactl --hardware输出>",
    "current_affinity": "<taskset -cp输出>",
    "thread_list": "<ps -L -p PID输出>"
  },
  "diagnostic_reports": {
    "cpu_affinity": "<inference-cpu-affinity-analyzer报告>",
    "memory_bottleneck": "<memory-bottleneck-analyzer报告>",
    "network_io_performance": "<network-io-performance报告>"
  }
}
```

#### 多进程输入结构

```json
{
  "mode": "multi",
  "processes": [
    {
      "pid": "<进程1的PID>",
      "process_name": "<进程名称>",
      "process_type": "<推理/数据加载/监控/其他>",
      "thread_count": <线程总数>,
      "inference_threads": <推理线程数>,
      "priority": <优先级1-5，5为最高>,
      "diagnostic_reports": {
        "cpu_affinity": "<该进程的CPU亲和性分析报告>",
        "memory_bottleneck": "<该进程的内存瓶颈报告>"
      }
    },
    {
      "pid": "<进程2的PID>",
      "process_name": "<进程名称>",
      "process_type": "<推理/数据加载/监控/其他>",
      "thread_count": <线程总数>,
      "inference_threads": <推理线程数>,
      "priority": <优先级1-5>,
      "diagnostic_reports": {
        "cpu_affinity": "<该进程的CPU亲和性分析报告>",
        "memory_bottleneck": "<该进程的内存瓶颈报告>"
      }
    }
  ],
  "basic_info": {
    "cpu_topology": "<lscpu输出>",
    "numa_topology": "<numactl --hardware输出>",
    "total_cores": <CPU总数>,
    "numa_nodes": <NUMA节点数>,
    "system_reserved_cores": <系统预留核心数>
  },
  "diagnostic_reports": {
    "network_io_performance": "<network-io-performance报告（全局共享）>"
  },
  "resource_allocation": {
    "strategy": "<NUMA优先级/优先级顺序/资源均衡>",
    "numa_allocation": {
      "node_0": {
        "assigned_pids": ["<PID1>", "<PID2>"],
        "cores_range": "0-31",
        "cores_used": 20,
        "cores_reserved": 2
      },
      "node_1": {
        "assigned_pids": ["<PID3>"],
        "cores_range": "32-63",
        "cores_used": 15,
        "cores_reserved": 1
      }
    },
    "process_core_map": {
      "<PID1>": "core_pool_0",
      "<PID2>": "core_pool_0",
      "<PID3>": "core_pool_1"
    }
  }
}
```

### bind-core-policy 执行要求

**单进程场景**：
- 生成精简绑核脚本：使用关联数组实现线程名到核心的精确映射，脚本控制在20-30行
- 生成综合优化报告：包含所有诊断结果汇总、问题优先级排序、绑核策略说明

**多进程场景**：
- 生成统一绑核脚本：按进程ID分组绑核，逐个进程执行绑核操作
- 生成多进程优化报告：包含每个进程的独立分析、进程间资源分配说明、整体优化策略
- 核�分配冲突检查：验证分配的核心区域不重叠

**输出文件**：
- 综合优化报告（Markdown格式）：`llm_cpu_affinity_report_multi_<timestamp>.md`（多进程）或 `llm_cpu_affinity_report_<PID>_<timestamp>.md`（单进程）
- 精简绑核脚本（Bash格式，可执行）：`bind_cores_multi.sh`（多进程）或 `bind_cores_<PID>.sh`（单进程）

### bind-core-policy 执行要求

调用 bind-core-policy 时需要明确以下要求：
- **生成精简绑核脚本**：使用关联数组实现线程名到核心的精确映射，脚本控制在20-30行
- **生成综合优化报告**：包含所有诊断结果汇总、问题优先级排序、绑核策略说明
- **输出文件**：
  - 综合优化报告（Markdown格式）
  - 精简绑核脚本（Bash格式，可执行）

## 第五步：输出结果

### 输出文件

#### 单进程场景
1. **综合优化报告**：`llm_cpu_affinity_report_<PID>_<timestamp>.md`
2. **精简绑核脚本**：`bind_cores_<PID>.sh`（添加可执行权限）

#### 多进程场景
1. **多进程综合优化报告**：`llm_cpu_affinity_report_multi_<timestamp>.md`
2. **统一绑核脚本**：`bind_cores_multi.sh`（添加可执行权限）
3. **资源分配可视化**：`resource_allocation.txt`（可选，显示每个进程的核心分配映射）

### 向用户展示的内容

#### 单进程场景摘要
- 发现的主要问题（Top 3）
- 建议的绑核策略摘要
- 绑定脚本执行方式
- 预期性能提升
- 验证和回滚方法

#### 多进程场景摘要
- **多进程概览**：进程总数、总线程数、资源利用率预期
- **各进程摘要**：每个进程的Top 1问题、绑定核心范围、负载类型
- **资源分配方案**：NUMA节点分配、核心映射关系、隔离策略
- **执行计划**：顺序绑核建议、预期中断时间、验证步骤
- **预期整体提升**：多进程协同优化后的性能预期
- **监控指标**：优化后需重点监控的性能指标

### 验证方法

#### 单进程验证
```bash
# 查看所有线程的当前调度核心和绑定核心
ps -T -p <PID> -o pid,tid,psr,psrset
# psr: 当前运行在哪个核心上
# psrset: 当前被绑定到哪个核心
# 如果 psr == psrset，说明绑定成功
```

#### 多进程验证
```bash
# 批量验证所有进程的绑核状态
for pid in $PID_LIST; do
  echo "=== PID: $pid ==="
  ps -T -p $pid -o pid,tid,psr,psrset
done

# 验证NUMA亲和性
for pid in $PID_LIST; do
  echo "=== PID: $pid NUMA亲和性 ==="
  numactl -p $pid
done

# 检查跨NUMA访问情况（优化后对比）
numastat -p $PID
```
## 第六步：执行绑核脚本

### 执行前检查

在执行绑核脚本之前，使用预检查脚本进行全面验证：

```bash
# 调用执行前检查脚本
./scripts/execute_binding_precheck.sh <PID列表> [绑核脚本路径]

# 示例
./scripts/execute_binding_precheck.sh 12345,23456 bind_cores.sh
```

该脚本会自动执行以下检查：
1. 检查绑核脚本是否存在且可执行
2. 检查目标进程是否仍然存在
3. 备份当前系统的绑核状态到 `affinity_precheck_backup_*.txt`
4. 检查系统SMT状态，为后续步骤提供信息

### 自动执行绑核脚本

根据场景选择执行方式：

#### 单进程场景

```bash
# 执行绑核脚本（使用统一执行脚本框架）
./scripts/execute_binding_script.sh bind_cores_<PID>.sh <PID> [总核心数]
```

#### 多进程场景

```bash
# 执行多进程绑核脚本（使用统一执行脚本框架）
./scripts/execute_binding_script.sh bind_cores_multi.sh <PID列表> [总核心数]
```

该执行脚本框架会自动：
- 添加执行权限（如果需要）
- 执行绑核脚本并记录日志
- 失败时自动调用回滚脚本（如果提供了总核心数参数）

### 绑核前备份与回滚机制

为防止误操作绑核导致系统问题，使用专门的备份回滚脚本：

```bash
# 备份当前绑核状态（在绑核前执行）
./scripts/backup_and_rollback.sh backup <PID列表>

# 回滚到绑核前状态
./scripts/backup_and_rollback.sh rollback <PID列表> <总核心数>

# 示例
./scripts/backup_and_rollback.sh backup 12345,23456
./scripts/backup_and_rollback.sh rollback 12345,23456 64
```

备份功能会：
- 为每个进程记录主进程和所有线程的绑核状态
- 生成带时间戳的备份文件（`affinity_backup_*.txt`）
- 限制备份文件权限为仅所有者可读

回滚功能会：
- 将主进程和所有线程重置为无绑核状态（绑定到所有核心）
- 逐个进程操作，提供详细的成功/失败反馈
- 处理进程不存在等异常情况

---

## 第七步：验证绑定结果

### 自动化验证流程

绑核脚本执行完成后，立即执行自动化验证：

```bash
# 执行绑核验证
./scripts/verify_binding.sh <PID列表> [报告文件路径]

# 示例
./scripts/verify_binding.sh 12345,23456
```

该脚本会自动：
- 检查每个进程的绑核状态
- 分析绑定成功率（总线程数 vs 已绑定线程数）
- 验证NUMA亲和性
- 生成详细的验证报告
- 判断验证是否通过（成功率≥95%为通过）
- 验证失败时提示询问是否回滚

验证判断标准：
- **成功**：绑定成功率 ≥ 95%
- **部分成功**：80% ≤ 绑定成功率 < 95%
- **失败**：绑定成功率 < 80%

### 多进程验证增强（含SMT冲突检测）

多进程场景下需要额外验证进程间的隔离性和SMT冲突：

```bash
# 验证进程间核心分配隔离性
./scripts/verify_process_isolation.sh <PID列表> [报告文件路径]

# 验证SMT绑核有效性
./scripts/verify_smt_binding.sh <PID列表> [报告文件路径]

# 示例
./scripts/verify_process_isolation.sh 12345,23456,34567
./scripts/verify_smt_binding.sh 12345,23456,34567
```

**verify_process_isolation.sh** 功能：
- 检查SMT系统状态
- 检测进程间逻辑核分配冲突
- SMT场景下验证物理核冲突（不同进程竞争同一物理核）
- 生成详细的隔离性验证报告

**verify_smt_binding.sh** 功能：
- 生成SMT场景下的物理核映射表
- 检查每个进程的线程物理核占用
- 检测同一进程内线程的SMT冲突（绑定到同一物理核的不同虚拟核）
- 提供SMT使用统计和冲突计数
- 生成SMT绑核有效性验证报告（无冲突时返回0，有冲突返回1）

### 持续监控建议（含SMT状态监控）

绑核验证通过后，提供持续监控建议：

```bash
# 持续监控绑核状态（含SMT监控）
./scripts/monitor_affinity.sh <PID> [监控间隔(秒)]

# 示例：默认60秒监控间隔
./scripts/monitor_affinity.sh 12345
./scripts/monitor_affinity.sh 12345 30
```

该脚本会持续监控进程的绑核状态，包括：
- 绑核线程数和绑定率
- SMT场景下的物理核使用和冲突检测
- 主进程绑核状态
- 跨NUMA访问统计
- 实时输出到日志文件 `affinity_monitor_*.log`

---

### 统一绑核脚本模板（多进程）

多进程绑核脚本模板由 **bind-core-policy** skill 自动生成。
脚本格式参考 **bind-core-policy skill** 的输出规范，确保：
- 进程核心池分配无冲突
- 遵循NUMA亲和原则
- SMT场景下避免物理核冲突

脚本执行前建议使用 `./scripts/execute_binding_precheck.sh` 进行预检查，
执行时使用 `./scripts/execute_binding_script.sh` 统一执行框架。

## 错误处理

### 诊断阶段错误处理

如果某个子任务失败：
1. 记录失败原因
2. 继续执行其他诊断任务
3. 绑定结果生成时跳过缺失的输入项（在报告中标注）

### 绑核脚本执行错误处理

在第六步执行绑核脚本时，可能出现的错误及处理方式：

| 错误类型 | 原因 | 处理方式 |
|---------|------|---------|
| 脚本不存在 | bind-core-policy执行失败 | 检查skill配置，重新生成脚本 |
| 权限不足 | 用户无执行taskset权限 | 提示用户使用sudo或联系管理员 |
| 进程已退出 | 目标进程在绑定前终止 | 重新获取PID，确认进程状态后重试 |
| 核心冲突 | 指定核心已被其他进程占用 | 调整核心分配策略，重新生成脚本 |
| 回滚失败 | 回滚命令执行异常 | 记录日志，提示手动重置进程绑核状态 |

### 绑核验证失败处理

在第七步验证绑定结果时，处理以下情况：

1. **绑定成功率低于80%**：
   - 检查绑核脚本中的核心分配是否正确
   - 验证目标进程的线程数量是否发生变化
   - 重新生成并执行绑核脚本

2. **NUMA亲和性异常**：
   - 检查numactl命令是否正常工作
   - 验证NUMA节点分配策略是否合理
   - 考虑使用numactl手动绑定（如适用）

3. **进程间隔离性检查失败**：
   - 回顾多进程资源分配策略
   - 检查是否存在核心区间重叠
   - 重新分配核心资源，确保隔离

## 通用注意事项

1. **进程存在性检查**：开始前确认PID对应的进程存在
2. **权限检查**：某些命令可能需要root权限，提醒用户
3. **平台兼容性**：macOS和Linux命令有差异，根据实际情况调整
4. **perf可用性**：如果perf不可用，L3缓存分析会受限
5. **bind-core-policy依赖**：确保该skill已正确安装，才能生成最终的绑核脚本
6. **多进程场景额外注意事项**：
   - 确保系统核心总数 >= 各进程所需核心数 + 系统预留核心数
   - 核心分配在执行前进行冲突检测
   - 建议在业务低峰期执行绑核，减少对业务的影响
   - 绑核后持续监控性能指标，必要时进行微调
   - 进程间有依赖关系时，按依赖顺序绑定，避免依赖进程未启动导致的绑定失败
   - 定期检查绑核效果和负载变化，动态调整绑核策略以适应业务演进
