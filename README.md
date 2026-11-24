# 栖隼 · Qisun LA32R

Qisun (栖隼) is a dual-dispatch, dual-retirement out-of-order CPU core for the LoongArch32 Reduced (LA32R) instruction set, written in synthesizable SystemVerilog. This repository contains the BF revision, originally developed as OOO2 and benchmarked on an ACX720-V3 FPGA with DDR3.

栖隼的首个版本来自 OOO2 的 BF 冻结 RTL。它采用 16 项重排序缓冲区、两条整数执行通道和独立访存通道，配有 8 KiB I-cache、16 KiB D-cache 和 16 项 TLB，支持 LA32R 整数与特权指令。

## 源码与检查

顶层是 `mycpu_top`。按 [文件列表](rtl.f) 编译，其中 `ooo_pkg.sv` 排在其他模块之前。顶层导出 32 位 AXI 主口、外部中断和两路有序退休调试信号。集成 SoC 时需提供复位、从 `0x1c000000` 取指的存储映射，以及兼容顶层端口的 AXI 互连。FPGA 板级工程、MIG、测试镜像和位流需单独准备。板载 VIO 性能计数路径由 `ARENA_ACX_PERF` 控制，启用时需要额外的板级监控模块。

在仓库根目录用 Verilator 检查 RTL，命令已在 5.028 验证。`-Wno-CMPCONST` 适用于固定索引产生的两条常量比较告警。

```sh
verilator --lint-only -Wno-CMPCONST --top-module mycpu_top -f rtl.f
```

## 设计与版本

- [RTL 设计说明](docs/architecture.md) 涵盖流水级、执行和退休、缓存与特权模块。
- [BF 实板性能](docs/bf-board-results.md) 给出十项工作负载的周期、IPC、测量方法与时序结果。
- [源码和实测数据校验值](SHA256SUMS) 可通过 `sha256sum -c SHA256SUMS` 核对。

**BF 的 CPU 实板频率为 109.091 MHz。** 十项工作负载各冷启动三次，以 ROI 周期的中位数计算 IPC。CoreMark 实测为 **1.044 IPC**。

BF 已在 AXI 仿真中运行 Linux 至 `/init` 首条用户态指令。后续强 `IBAR` 和 `CPUCFG` 几何枚举修复属于从 BF 派生的 Linux 实板启动版本。 [BF 的系统指令实现](docs/architecture.md#53-bf-的-ibar-与缓存枚举)
