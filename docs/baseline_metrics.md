# Baseline Metrics — RAAS (Phase 0 measurement)

> Template được điền sau khi Phase 0 instrumentation hoàn thành và chạy được trên board.
> Tham chiếu methodology: [evaluation_metrics.md](evaluation_metrics.md).
> Mọi optimization sau (Phase 1+) sẽ có cột "after" để so sánh với "baseline" ở đây.

## 1. Setup

| Field | Value |
|---|---|
| Vivado version | 2025.2.1 |
| Vitis version | 2025.2.1 |
| RISC-V toolchain | riscv32-xilinx-elf-gcc |
| Board | Avnet Ultra96-v2 (ZU3EG) |
| PL clock | 100 MHz (target) |
| Workload | LeNet-5 trên MNIST |
| Model checkpoint | `model/LeNet5-MNIST-PyTorch/models/export_0.986/` |
| Datatype | Q1.4.11 fixed-point |
| Test set size | _____ samples |
| Bitstream commit hash | _____ |
| Firmware commit hash | _____ |

## 2. Accuracy

| Stage | Accuracy (%) | Note |
|---|---|---|
| FP32 baseline (PyTorch) | 98.6 | Đã có trong checkpoint |
| Q1.4.11 software reference | _____ | Chạy `lenet5_infer(use_hw=0)` trên Pico |
| RTL simulation (Vivado) | _____ | Cycle-accurate sim trên 100 samples |
| On-board hardware | _____ | Chạy `lenet5_infer(use_hw=1)` trên Ultra96 |

| Metric | Value |
|---|---|
| Accuracy degradation (FP32 → Q1.4.11) | _____ pp |
| Bit-exact match rate (HW vs SW reference) | _____ % |
| MSE / SQNR | _____ dB |

## 3. Latency Breakdown

### 3.1 End-to-end

| Mode | Cycles | Time @ 100 MHz | IPS |
|---|---|---|---|
| HW (accelerator) | _____ | _____ ms | _____ |
| SW (Pico-only) | _____ | _____ ms | _____ |
| Speedup HW/SW | _____ × | — | — |

Đo bằng `LENET_DDR_HW_CYCLES_OFF` / `LENET_DDR_SW_CYCLES_OFF` trong mailbox.

### 3.2 Per-layer (HW mode)

Đo bằng `LENET_DDR_LAYER_CYC_OFF` array (Phase 0 instrumentation: `lstamp(0..8)`).
Delta giữa các slot = layer cycles.

| Layer | Cycles | % of total | Note |
|---|---|---|---|
| Conv1 + transpose | lstamp(1)−lstamp(0) = _____ | _____ % | im2col SW + GEMM HW + transpose SW |
| Pool1 | lstamp(2)−lstamp(1) = _____ | _____ % | 100% SW |
| Conv2 + transpose | lstamp(3)−lstamp(2) = _____ | _____ % | |
| Pool2 | lstamp(4)−lstamp(3) = _____ | _____ % | 100% SW |
| FC1 | lstamp(5)−lstamp(4) = _____ | _____ % | M=1 → 87.5% PE idle |
| FC2 | lstamp(6)−lstamp(5) = _____ | _____ % | |
| FC3 | lstamp(7)−lstamp(6) = _____ | _____ % | |
| Argmax | lstamp(8)−lstamp(7) = _____ | _____ % | 100% SW |

### 3.3 Accelerator state breakdown (HW mode)

Đo bằng `LENET_DDR_ACCEL_CNT_OFF` snapshot (Phase 0 instrumentation).

| State | Cycles | % of total |
|---|---|---|
| ST_IDLE | cnt.idle = _____ | _____ % |
| ST_LOAD_W_* | cnt.load_w = _____ | _____ % |
| ST_LOAD_BIAS | cnt.load_b = _____ | _____ % |
| ST_LOAD_IN | cnt.load_in = _____ | _____ % |
| ST_COMPUTE | cnt.compute = _____ | _____ % |
| ST_POST_PROC | cnt.post_proc = _____ | _____ % |
| ST_SEND_OUT | cnt.send = _____ | _____ % |
| ST_DONE | cnt.done = _____ | _____ % |
| Total | cnt.total = _____ | 100 % |

| Derived | Value |
|---|---|
| PE-active cycles (`cnt.pe_active`) | _____ |
| PE-active ratio (`cnt.pe_active / cnt.compute`) | _____ % |
| Idle ratio (`cnt.idle / cnt.total`) | _____ % |
| HW vs SW time breakdown | HW=_____% / SW=_____% |

→ Idle ratio cao = accelerator chờ Pico. PE-active ratio < 100% = có sparsity tự nhiên (chưa khai thác).

## 4. Resource Utilization (Vivado post-implementation)

Ultra96-v2 ZU3EG: 71k LUT, 141k FF, 360 DSP48, 216 BRAM 36Kb tiles, 0 URAM.

| Resource | Used | Available | % |
|---|---|---|---|
| LUT | _____ | 71280 | _____ % |
| LUTRAM | _____ | 28800 | _____ % |
| FF (Register) | _____ | 141760 | _____ % |
| DSP48 | _____ | 360 | _____ % |
| BRAM (36Kb tile) | _____ | 216 | _____ % |
| URAM | 0 | 0 | — |

### Hierarchical breakdown

| Module | LUT | FF | DSP | BRAM |
|---|---|---|---|---|
| `accelerator` (top) | _____ | _____ | _____ | _____ |
| ├── `control_unit` | _____ | _____ | _____ | _____ |
| ├── `data_path` (8×8 PE) | _____ | _____ | _____ | _____ |
| │   └── `pe` × 64 | _____ | _____ | _____ | _____ |
| ├── `post_proc` | _____ | _____ | _____ | _____ |
| │   └── `sigmoid_lookup` | _____ | _____ | _____ | _____ |
| └── AXI shims | _____ | _____ | _____ | _____ |
| PicoRV32 IP | _____ | _____ | _____ | _____ |
| AXI DMA | _____ | _____ | _____ | _____ |
| AXI SmartConnect | _____ | _____ | _____ | _____ |
| Shared Boot BRAM (64KB) | _____ | _____ | _____ | _____ |

| Derived | Value | Target |
|---|---|---|
| DSP per PE (mục tiêu: 1) | _____ | 1.0 |

## 5. Timing

| Field | Value |
|---|---|
| Target f_clk | 100 MHz |
| Achieved f_clk | _____ MHz |
| WNS (Worst Negative Slack) | _____ ns |
| TNS (Total Negative Slack) | _____ ns |
| Critical path | _____ (mô tả module + signal) |
| f_max estimate (after re-pipeline) | _____ MHz |

## 6. Power (Vivado Power Report)

| Component | Power (W) |
|---|---|
| Total | _____ |
| Static | _____ |
| Dynamic | _____ |
| → PL Logic | _____ |
| → BRAM | _____ |
| → DSP | _____ |
| → Clock tree | _____ |
| → IO | _____ |
| → PS | _____ |

| Derived | Value |
|---|---|
| Energy per inference | total_power × latency_HW = _____ mJ |
| Energy efficiency (sustained) | _____ GOPS/W |
| Energy efficiency | _____ TOPS/W |

### Board-measured power (optional)

| Field | Value |
|---|---|
| Method | Shunt resistor / PMBus / external multimeter |
| Idle current (before inference) | _____ A @ 12V = _____ W |
| Peak current (during inference) | _____ A @ 12V = _____ W |
| Average during inference | _____ W |

## 7. Memory Bandwidth

| Metric | Value | Source |
|---|---|---|
| On-chip BRAM used | _____ KB | Vivado utilization |
| Off-chip DDR footprint | _____ KB | Sum of LeNet weights + fmaps + scratch |
| DDR read bandwidth (avg) | _____ MB/s | AXI Performance Monitor (APM) |
| DDR write bandwidth (avg) | _____ MB/s | APM |
| Peak DDR utilization | _____ % | APM |
| MM2S transfer count | _____ | APM/DMA counter |
| S2MM transfer count | _____ | APM/DMA counter |
| Total bytes/inference (DDR↔Accel) | _____ KB | Calculated |
| Data reuse factor | MACs / bytes_loaded = _____ × | Phase 0 baseline ≈ 1×; Phase 1 target ≥ 10× |

## 8. Compute Efficiency

| Metric | Value |
|---|---|
| Peak compute | 2 × 64 × 100MHz = 12.8 GOPS |
| Sustained compute | (282K MACs/inf × 2 × IPS) / 1e9 = _____ GOPS |
| Compute efficiency | sustained / peak = _____ % |
| PE utilization (per-layer breakdown) | Xem section 3.3 |

## 9. Sample Outputs

### Mailbox dump sau 1 inference

```
0x00040000 MAILBOX        : 0x________ (expect 0xC0DEC0DE = PASS)
0x00040004 PREDICTED      : 0x________ (digit 0..9)
0x00040008 LAYER_DBG      : 0x________ (last layer reached, expect 8)
0x0004000C HW_CYCLES      : 0x________
0x00040010 SW_CYCLES      : 0x________
0x00040020 LAYER_CYC[0]   : 0x________ (start baseline)
0x00040024 LAYER_CYC[1]   : 0x________ (after Conv1)
0x00040028 LAYER_CYC[2]   : 0x________ (after Pool1)
0x0004002C LAYER_CYC[3]   : 0x________ (after Conv2)
0x00040030 LAYER_CYC[4]   : 0x________ (after Pool2)
0x00040034 LAYER_CYC[5]   : 0x________ (after FC1)
0x00040038 LAYER_CYC[6]   : 0x________ (after FC2)
0x0004003C LAYER_CYC[7]   : 0x________ (after FC3)
0x00040040 LAYER_CYC[8]   : 0x________ (after argmax)
0x00040050 ACCEL.idle     : 0x________
0x00040054 ACCEL.load_w   : 0x________
0x00040058 ACCEL.load_b   : 0x________
0x0004005C ACCEL.load_in  : 0x________
0x00040060 ACCEL.compute  : 0x________
0x00040064 ACCEL.post_proc: 0x________
0x00040068 ACCEL.send     : 0x________
0x0004006C ACCEL.done     : 0x________
0x00040070 ACCEL.total    : 0x________
0x00040074 ACCEL.pe_active: 0x________
```

## 10. Notes & Anomalies

(Để trống cho người đo điền sau)

- _____
- _____

---

## Append: Methodology cross-reference

- Section 2 ↔ [evaluation_metrics.md §2 Accuracy](evaluation_metrics.md)
- Section 3 ↔ [evaluation_metrics.md §1 Performance + §7 Compute Efficiency](evaluation_metrics.md)
- Section 4 ↔ [evaluation_metrics.md §3 Resource Utilization](evaluation_metrics.md)
- Section 5 ↔ [evaluation_metrics.md §4 Timing](evaluation_metrics.md)
- Section 6 ↔ [evaluation_metrics.md §5 Power & Energy](evaluation_metrics.md)
- Section 7 ↔ [evaluation_metrics.md §6 Memory & Bandwidth](evaluation_metrics.md)
- Section 8 ↔ [evaluation_metrics.md §7 Compute Efficiency](evaluation_metrics.md)
