# 栖隼实板性能

栖隼在 ACX720-V3 的板载 DDR3 平台上以 **109.091 MHz** 运行。AXI 时钟为 100 MHz，DDR3 参考时钟为 200 MHz。

## 测试来源

测试程序选自龙芯教育团队在 Chiplab 中提供的 NSCSCC 性能测试集，位于上游的 `software/examples/nscscc_perf`。上板时按栖隼的实际缓存几何调整了测试镜像的缓存初始化参数。本仓库发布的是栖隼实测的硬件计数和统计，原始测试程序由上游提供。Chiplab 主项目采用木兰宽松许可证第 2 版（MulanPSL-2.0），部分测试程序另有随附许可。 [Chiplab 测试说明](https://gitee.com/loongson-edu/chiplab/blob/chiplab_diff/nscscc_readme.md) · [Chiplab 项目与许可证](https://gitee.com/loongson-edu/chiplab)

## 板测口径

十项工作负载各冷启动三次，共 30 次实板运行。每次核对 DDR 校准、镜像抽样读回、程序完成、计时窗口数和退休指令数。ROI 为程序中成对的 `get_count_my` 入口退休之间的计时区间，多段相加。每项以三次 ROI 周期的中位数作为周期数，并用该项 ROI 退休指令数除以周期数计算 IPC。 [逐次实板数据](../evidence/board-results.json)

| 工作负载 | ROI 周期中位数 | ROI 退休指令数 | IPC |
| --- | ---: | ---: | ---: |
| bitcount | 210,457 | 306,719 | 1.457 |
| bubble_sort | 1,055,407 | 936,846 | 0.888 |
| coremark | 2,735,714 | 2,855,313 | 1.044 |
| crc32 | 946,571 | 1,708,620 | 1.805 |
| dhrystone | 27,583 | 31,160 | 1.130 |
| quick_sort | 1,457,404 | 1,330,356 | 0.913 |
| select_sort | 510,449 | 751,576 | 1.472 |
| sha | 1,213,571 | 1,525,750 | 1.257 |
| stream_copy | 80,843 | 77,726 | 0.961 |
| stringsearch | 110,534 | 130,720 | 1.183 |

CoreMark 一行记录运行 Chiplab 所附程序时的硬件计数和退休 IPC。EEMBC 的 CoreMark 分数有单独的运行与发布规则。 [EEMBC CoreMark 运行与发布规则](https://github.com/eembc/coremark#run-rules)

## 实现时序

CPU PLL 为 `50 × 24 ÷ 11 MHz`。在 Vivado 2026.1 中执行布线后的 `AggressiveExplore` 物理优化后，建立时序余量 WNS 为 **+0.004 ns**，保持时序余量 WHS 为 **+0.039 ns**。脉宽、bus skew、DRC 与约束检查通过。最紧的建立路径从串行指令操作码寄存器到数据地址转换结果寄存器，数据路径延时为 9.095 ns，其中布线延时为 7.123 ns。
