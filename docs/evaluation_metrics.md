# Evaluation Metrics — RAAS

> Bộ chỉ số đánh giá toàn diện cho hệ thống RISC-V-based AI Accelerator (RAAS) trên Ultra96-v2.
> Dùng làm checklist khi hoàn thành design để báo cáo / luận văn.
> Mỗi mục: tên — đơn vị — ý nghĩa — cách đo trên stack hiện tại.

## 1. Performance — Hiệu năng tính toán

| Chỉ số | Đơn vị | Ý nghĩa | Cách đo |
|---|---|---|---|
| [ ] End-to-end latency | ms/inference | Thời gian từ start → predicted_digit | AXI Timer IP hoặc `csr_rdcycle` trên Pico |
| [ ] Per-layer latency | µs/layer | Latency từng layer (Conv1, Pool1, Conv2, Pool2, FC1-3) | Pico ghi timestamp vào mailbox/DDR sau mỗi layer |
| [ ] Per-tile latency | cycles/tile | 1 GEMM 8×8×8 từ START→DONE | Counter trong [control_unit.v](../hw/accelerator_2_0/hdl/control_unit.v) |
| [ ] Throughput | inf/sec (IPS) | Số ảnh xử lý/giây liên tục | `IPS = 1 / latency` |
| [ ] Peak compute | GOPS | MAC tối đa lý thuyết | `2 × PE_count × f_clk` (8×8 @ 100 MHz = 12.8 GOPS) |
| [ ] Sustained compute | GOPS | Throughput thực tế | `(MACs/inference × IPS × 2) / 1e9` |
| [ ] Compute efficiency | % | Sustained / Peak | Phản ánh PE idle |

**Số MAC cho LeNet-5** (tính trước để chuẩn hóa):
- Conv1: 576 × 25 × 6 = 86,400
- Conv2: 64 × 150 × 16 = 153,600
- FC1: 1 × 256 × 120 = 30,720
- FC2: 1 × 120 × 84 = 10,080
- FC3: 1 × 84 × 10 = 840
- **Tổng: ~282 K MACs/inference**

## 2. Accuracy — Độ chính xác

| Chỉ số | Đơn vị | Mục tiêu |
|---|---|---|
| [ ] Top-1 accuracy (FP32 baseline) | % | 98.6% (đã có trong `model/LeNet5-MNIST-PyTorch/models/export_0.986/`) |
| [ ] Top-1 accuracy (Q1.4.11 SW reference) | % | Quantization-aware degradation < 0.5pp |
| [ ] Top-1 accuracy (RTL simulation) | % | Bit-exact với SW reference |
| [ ] Top-1 accuracy (on-board Ultra96v2) | % | Phải bằng RTL simulation |
| [ ] Bit-exact match rate (HW vs SW ref) | % | 100% (per-element) |
| [ ] MSE / SQNR | dB | So sánh FP32 logits vs Q1.4.11 logits |
| [ ] Confusion matrix | — | Phân tích error pattern theo class |

→ 4 con số accuracy phải có riêng biệt, không gộp.

## 3. Resource Utilization — Tài nguyên FPGA

**Ultra96-v2 (ZU3EG):** 71k LUT, 141k FF, 360 DSP48, 216 BRAM (36Kb tiles), 0 URAM.

| Chỉ số | Đơn vị | Lấy từ |
|---|---|---|
| [ ] LUT | count + % | `report_utilization` post-implementation |
| [ ] FF (Register) | count + % | `report_utilization` |
| [ ] DSP48 | count + % | Mục tiêu: 1 DSP/PE = 64 DSP cho 8×8 array |
| [ ] BRAM (36Kb) | count + % | Scratchpad + accumulator + sigmoid LUT + Pico BRAM |
| [ ] URAM | count | Ultra96v2 không có |
| [ ] Hierarchical breakdown | per module | Riêng: PE grid / control_unit / post_proc / DMA / PicoRV32 / SmartConnect |

→ **Báo cáo riêng** DSP/PE — nếu > 1 có nghĩa multiplier mapping chưa tối ưu.

## 4. Timing — Tần số hoạt động

| Chỉ số | Đơn vị | Lấy từ |
|---|---|---|
| [ ] Achieved f_clk | MHz | Vivado timing report (target: ≥ 100 MHz PL) |
| [ ] WNS (Worst Negative Slack) | ns | Phải ≥ 0 mới close timing |
| [ ] TNS (Total Negative Slack) | ns | Phải = 0 |
| [ ] Critical path | description | Path nào hạn chế f_clk (PE mult? psum chain? AXI?) |
| [ ] f_max estimate | MHz | Sau khi re-pipeline critical path |

## 5. Power & Energy — Năng lượng (KPI vàng cho Edge AI)

| Chỉ số | Đơn vị | Cách đo |
|---|---|---|
| [ ] Static power | W | Vivado Power Report (post-implementation) |
| [ ] Dynamic power | W | Vivado Power Report với SAIF từ post-synth simulation |
| [ ] Total power | W | Static + Dynamic |
| [ ] Per-component power | mW | Breakdown: PL logic, BRAM, DSP, clock tree, IO, PS |
| [ ] Energy per inference | mJ/inference | `Total_power × end_to_end_latency` |
| [ ] **Energy efficiency** | **GOPS/W** | **KPI chính cho positioning vs prior work** |
| [ ] Energy efficiency (paper unit) | TOPS/W | Quy đổi từ GOPS/W |
| [ ] Board-measured power | W | Đo dòng vào jack DC 12V (shunt resistor + DMM) hoặc PMBus |

→ Đo power **board thực** quan trọng — nhiều luận văn chỉ đo Vivado estimate và bị critique.

## 6. Memory & Bandwidth — Bộ nhớ

| Chỉ số | Đơn vị | Cách đo |
|---|---|---|
| [ ] On-chip memory used | KB | BRAM cho scratchpad + accumulator + sigmoid LUT + Pico boot |
| [ ] Off-chip memory footprint | KB | Weights + fmaps + scratch + tile buffers trên DDR |
| [ ] DDR bandwidth used | MB/s + % peak | AXI Performance Monitor (APM) IP |
| [ ] Data reuse factor | × | `MACs / bytes_loaded_from_DDR` |
| [ ] Off-chip traffic/inference | KB | Tổng DMA MM2S + S2MM mỗi inference |
| [ ] Arithmetic intensity | ops/byte | Cho roofline analysis |

→ Mục tiêu sau khi thêm scratchpad: data reuse tăng từ ~1× lên 10-30×.

## 7. Compute Efficiency / PE Utilization — Hiệu suất sử dụng

| Chỉ số | Đơn vị | Cách đo |
|---|---|---|
| [ ] PE utilization | % | Trung bình bao nhiêu % PE active mỗi cycle |
| [ ] MAC utilization (effective) | % | % cycles có MAC hữu ích (loại zero-mul nếu có sparsity skip) |
| [ ] Idle cycles | % hoặc count | Cycle dành cho LOAD/DRAIN/POST_PROC thay vì COMPUTE |
| [ ] Pipeline stall ratio | % | Do DMA wait, K-accumulation SW wait, ... |
| [ ] HW vs SW time breakdown | % | % thời gian Pico làm gì (im2col, pool, polling, add psum) |
| [ ] Per-layer PE utilization | % | Đặc biệt: FC layers M=1 → underutilization rõ |
| [ ] Roofline position | plot | Memory-bound hay compute-bound? |

→ Trả lời thẳng critique "Underutilization" của hội đồng. **BẮT BUỘC có**.

## 8. Architectural Quality — Chất lượng kiến trúc

| Chỉ số | Đo |
|---|---|
| [ ] Scalability | Project được lên 16×16 / 32×32 (về mặt lý thuyết, ngay cả nếu không fit Ultra96) |
| [ ] Flexibility | Hỗ trợ bao nhiêu layer type (Conv, FC, Pool)? Bao nhiêu dataflow? |
| [ ] Programmability | API/ISA dễ dùng? LoC firmware để chạy LeNet vs chạy model khác? |
| [ ] Generality | Chạy được model khác MNIST không? (CIFAR-10 LeNet variant? tiny CNN?) |

## 9. Reliability — Độ tin cậy (chỉ làm nếu chọn RAS angle)

| Chỉ số | Đơn vị |
|---|---|
| [ ] Accuracy vs fault rate | curve (% accuracy vs SEU rate 1e-5 ... 1e-2) |
| [ ] Critical bits | % bits whose flip causes misclassification |
| [ ] Hardening overhead | %LUT, %power, %latency cho TMR/ECC |
| [ ] MTTF / MTBF (theoretical) | hours |

## 10. System-level — Cấp hệ thống

| Chỉ số | Đơn vị | Ghi chú |
|---|---|---|
| [ ] Boot time | ms | PS power-on → first inference ready |
| [ ] Configuration time | ms | Bitstream load + firmware load |
| [ ] HW/SW partition ratio | % | % computation trên PicoRV32 vs accelerator |
| [ ] Firmware size | KB | BRAM footprint Pico code (hiện ~4 KB ước tính) |

## 11. Comparison Baselines — Đối chiếu (BẮT BUỘC)

Mỗi optimization phải có ít nhất 2-3 baseline so sánh:

| Baseline | Workload | Chỉ số chính |
|---|---|---|
| [ ] CPU softmax (ARM A53, Zynq PS) | LeNet MNIST | Latency, energy/inference |
| [ ] PicoRV32 alone (pure SW, không accel) | LeNet MNIST | Tính speedup × bao nhiêu nhờ accelerator |
| [ ] RAAS baseline (trước optimization) | LeNet MNIST | Reference cho ablation |
| [ ] RAAS + optimization X | LeNet MNIST | Sau khi thêm scratchpad / im2col HW / sparsity / ... |
| [ ] Prior FPGA work | LeNet hoặc tương đương | GOPS/W, area-time product |

## 12. Productivity / Cost — Ít quan trọng

- [ ] Development time (tuần/tháng)
- [ ] Lines of HDL code
- [ ] Lines of firmware code
- [ ] Area-time product (ATP = area × latency)

---

## Ưu tiên theo mức độ quan trọng

| Hạng | Nhóm chỉ số | Lý do |
|---|---|---|
| Vàng | GOPS/W + Energy/inference | KPI vàng cho Edge AI, positioning vs prior work |
| Vàng | End-to-end latency + Throughput (IPS) | Số cơ bản — không có là không qua bảo vệ |
| Vàng | Accuracy (4 con số: FP32 / Q sim / RTL / board) | Chứng minh quantization đúng |
| Vàng | PE utilization + idle breakdown | Trả lời critique "underutilization" |
| Bạc | DSP / LUT / BRAM utilization | Required section của paper |
| Bạc | f_clk + critical path | Chứng minh design closed timing |
| Bạc | Data reuse + DDR bandwidth | Trả lời "memory wall" critique |
| Bạc | Comparison vs Pico-only baseline | Cho thấy speedup từ accelerator |
| Đồng | Per-layer/per-tile profiling | Phân tích sâu cho insight |
| Đồng | Comparison vs prior FPGA work | Khó vì paper khác workload |
| Đồng | Sparsity skip ratio (nếu có) | Biện minh contribution sparsity |
| Đồng | Boot time, FW size | Nice-to-have |

---

## Workflow đo lường — thứ tự tổ chức trong chương Evaluation

1. **Setup**: Vivado version, board, clock freq, model checkpoint hash.
2. **Accuracy validation**: 4 con số FP32 → Q sim → RTL sim → board. Target degradation < 0.5pp.
3. **Latency breakdown**: bảng per-layer cycle count + tổng end-to-end. Expose SW overhead (im2col, pool, polling).
4. **Resource utilization**: bảng Vivado utilization, comment DSP/PE ratio.
5. **Timing closure**: f_clk + WNS + critical path.
6. **Power**: Vivado Power Report breakdown + board-measured (nếu đo được). Tính GOPS/W.
7. **Throughput + roofline**: IPS, sustained GOPS, vẽ roofline plot.
8. **PE utilization analysis**: % active per layer, expose FC underutilization.
9. **Ablation study**: bật/tắt từng feature mới (scratchpad, im2col HW, sparsity, ...) → impact riêng từng cái.
10. **Comparison**: vs Pico-only + vs ≥ 1 prior FPGA work.

→ Mỗi optimization có **bảng trước-sau** trên tất cả 5 nhóm số chính (latency, accuracy, resource, power, utilization).

---

## Instrumentation cần chuẩn bị

Để lấy đủ số liệu trong 1 lần chạy:

- [ ] **AXI Timer IP** trong block design — đếm cycle chính xác
- [ ] **AXI Performance Monitor (APM) IP** — đo DDR bandwidth, AXI throughput
- [ ] **Cycle counter** trong [control_unit.v](../hw/accelerator_2_0/hdl/control_unit.v) — đếm cycles ở mỗi state (IDLE/LOAD/COMPUTE/DRAIN/POST_PROC)
- [ ] **Mailbox timestamps**: Pico ghi `cycle_count` sau mỗi layer vào DDR (mở rộng `LAYER_DBG` section)
- [ ] **PE active counter**: counter trong [data_path.v](../hw/accelerator_2_0/hdl/data_path.v) đếm cycles có MAC ≠ 0 (cho sparsity utilization)
- [ ] **SAIF dump** từ post-synth simulation → feed vào Vivado Power Report
- [ ] **Vivado script** automation: `report_utilization`, `report_timing_summary`, `report_power` → file riêng cho mỗi build variant
- [ ] **Python post-processing**: gom các log → bảng + plot (roofline, latency breakdown, ablation)
