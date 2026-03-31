---
name: "memory-bottleneck-analyzer"
description: "用于检测计算密集型任务的内存瓶颈，包括内存水位、带宽、跨NUMA/跨片访问、页迁移、分配策略等分析。当用户需要监控特定进程的内存使用情况、排查内存延迟升高、内存交换频繁、跨节点访问过多等问题时使用。支持ARM64/x86_64平台，适用于AI推理、向量搜索、矩阵计算等内存密集型工作负载。触发关键词：内存瓶颈、内存监控、性能分析、内存泄漏、NUMA优化、跨片访问、内存延迟、内存交换、页迁移、内存碎片、malloc监控、推理性能、计算性能、资源监控、系统调优、perf分析、numactl、vmstat、iostat、lscpu、numastat、sar、dmesg、tcmalloc、malloc_stats、pmap"
compatibility: "需要root权限执行perf、numactl、vmstat等系统监控命令；需要安装perf工具；适用于Linux系统；需要目标进程的PID"
---
