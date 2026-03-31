---
name: inference-cpu-affinity-analyzer
description: Use for analyzing CPU affinity and scheduling issues for inference workloads (VLLM, SGLang, or any LLM inference service). This skill provides a comprehensive toolkit of 16 modular bash scripts for diagnosing CPU pinning problems, thread migration, NUMA cross-domain access, cache contention, and memory bandwidth issues. Always use this skill when the user mentions inference CPU performance, CPU affinity, thread scheduling, core pinning, NUMA optimization, or any CPU-related diagnostics for LLM inference workloads (VLLM, SGLang, TGI, vLLM, TensorRT-LLM, etc.), even if they don't explicitly say "affinity" or "pinning". The tool automatically detects the process type and adapts its analysis accordingly.
parameters:
  - name: pid
    description: The Process ID (PID) of the inference service to analyze. Required for most diagnostic scripts. If not provided, the skill will prompt the user for it.
    required: true
---
