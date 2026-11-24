# 栖隼 · Qisun LA32R

Qisun (栖隼) is a dual-dispatch, dual-retirement out-of-order CPU core for the LoongArch32 Reduced (LA32R) instruction set, written in synthesizable SystemVerilog. It has been benchmarked on an ACX720-V3 FPGA with DDR3.

栖隼是一颗面向 FPGA 的 32 位乱序处理器核，支持 LA32R 整数与特权指令，每拍最多分派和退休两条指令。它采用 16 项重排序缓冲区、两条整数执行通道和独立访存通道，配有 8 KiB I-cache、16 KiB D-cache 和 16 项 TLB。

## 源码与检查

顶层是 `mycpu_top`。按 [文件列表](rtl.f) 编译，其中 `ooo_pkg.sv` 排在其他模块之前。顶层导出 32 位 AXI 主口、外部中断和两路有序退休调试信号。集成 SoC 时需提供复位、从 `0x1c000000` 取指的存储映射，以及兼容顶层端口的 AXI 互连。FPGA 板级工程、MIG、测试镜像和位流需单独准备。板载 VIO 性能计数路径由 `ARENA_ACX_PERF` 控制，启用时需要额外的板级监控模块。

在仓库根目录用 Verilator 检查 RTL，命令已在 5.028 验证。`-Wno-CMPCONST` 适用于固定索引产生的两条常量比较告警。

```sh
verilator --lint-only -Wno-CMPCONST --top-module mycpu_top -f rtl.f
```

## 实板性能与 Linux 验证

栖隼在 ACX720-V3 的板载 DDR3 平台上以 **109.091 MHz** 运行。实板测试从龙芯 Chiplab 随附的 NSCSCC 性能测试集中选取十项工作负载，每项冷启动三次。十项工作负载的等权几何平均为 **1.181 IPC**，其中 CoreMark 计时区间实测为 **1.044 IPC**。 [实板性能报告](docs/board-results.md) · [Chiplab 测试说明](https://gitee.com/loongson-edu/chiplab/blob/chiplab_diff/nscscc_readme.md)

仓库中的 RTL 已在 AXI 仿真中运行 Linux 至 `/init` 首条用户态指令。实板冷启动验证使用了后续加入强 `IBAR` 和 `CPUCFG` 几何枚举修复的 RTL。

- [RTL 设计说明](docs/architecture.md) 涵盖流水级、执行和退休、缓存与特权模块。
- [源码和实测数据校验值](SHA256SUMS) 可通过 `sha256sum -c SHA256SUMS` 核对。

## 许可证

本仓库中的栖隼项目内容采用 PolyForm Noncommercial License 1.0.0。使用、修改和分发须遵守许可条款，商业用途需要另行取得授权。Chiplab 及其测试程序由上游提供，适用各自的许可。 [栖隼许可证全文](LICENSE) · [Chiplab 项目与许可证](https://gitee.com/loongson-edu/chiplab)

Qisun is available under the PolyForm Noncommercial License 1.0.0. Commercial use requires separate permission. Chiplab and its benchmarks are available from upstream under their respective licenses. [Qisun license text](LICENSE)
