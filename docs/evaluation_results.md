# Evaluation Results — RAAS

> Bảng kết quả điền theo [evaluation_metrics.md](evaluation_metrics.md).
> Trạng thái: ✅ đo được (synth/impl/sim) · 🧮 tính từ công thức · 🟡 cần board.
> Setup: Vivado 2025.2.1, ZU3EG (Ultra96-v2), PL clock 100 MHz, model `export_0.986`.
> Build: full system (PicoRV32 + accelerator dual-mode + autonomy 2c + 1b + sparsity + ECC + TMR).

---

## 1. Performance

| Chỉ số | Giá trị | Nguồn |
|---|---|---|
| Peak compute | **12.8 GOPS** (2×64 PE×100 MHz) | 🧮 |
| MAC/inference (LeNet-5) | **282 K** | 🧮 (đã có) |
| Per-tile latency (8×8 GEMM) | ~**186 cycle** (LOAD 68 + COMPUTE 22 + POST 64 + SEND 32) + DMA | ✅ sim (đo START→DONE) |
| End-to-end latency | **~1.20 s** (119.6 M cycle @100 MHz, bitstream cũ) | 🟡 board (mới chưa đo) |
| Throughput | **~0.84 IPS** (1/latency, cũ) | 🟡 board |
| Sustained compute | ~**0.47 MOPS** (282 K×2 / 1.20 s) | 🟡 board |
| Compute efficiency | ~**0.004 %** (sustained/peak) | 🟡 — **overhead-bound**, xem ghi chú |

> **Ghi chú quan trọng (insight luận văn):** compute của array nhanh (12.8 GOPS peak) nhưng *system* bị **orchestration của PicoRV32 thống trị** (>99.9% cycle là DMA-setup/copy/poll, KHÔNG phải MAC). Đây chính là động lực của **Phase 2c autonomy** (accelerator tự lập trình DMA) — đo lại sau autonomy sẽ cho sustained cao hơn nhiều. Trình bày như baseline + optimization target.

## 2. Accuracy (4 con số riêng)

| Chỉ số | Giá trị | Nguồn |
|---|---|---|
| Top-1 FP32 baseline | **98.6 %** | ✅ `export_0.986` |
| Top-1 Q1.4.11 SW reference | 🟡 (1 ảnh: đúng; cần chạy ≥1000 ảnh — đổi `BENCHMARK_IMAGE_COUNT`) | 🟡 sim/board |
| Top-1 RTL simulation | **= SW reference** (bit-exact) | ✅ `accelerator_top_tb` (HW==SW invariant) |
| Top-1 on-board | = RTL | 🟡 board |
| Bit-exact match HW vs SW | **100 %** (per-element) | ✅ sim |
| MSE / SQNR (FP32 vs Q) | 🟡 cần script so logits | 🟡 |

## 3. Resource Utilization (ZU3EG: 70560 LUT, 141120 FF, 360 DSP, 216 BRAM)

| Tài nguyên | Dùng | % | Nguồn |
|---|---|---|---|
| **LUT** | 43,839 | **62.1 %** | ✅ impl |
| **FF** | 46,578 | **33.0 %** | ✅ impl |
| **DSP48E2** | 142 | **39.4 %** | ✅ impl |
| **BRAM** (36K tile) | 20.5 | **9.5 %** | ✅ impl (20×36K + 1×18K) |
| URAM | 0 | — | ✅ (ZU3EG không có) |
| Per-module breakdown | 🟡 chạy `report_utilization -hierarchical` | 🟡 |

> **DSP/PE ≈ 2.2** (142 cho 64 PE): do **dual-mode PE** (gộp WS+OS) → MACC tách 2 DSP. Trade có chủ đích: +DSP để gộp 2 dataflow + giảm LUT. (evaluation #3 lưu ý điều này.)

## 4. Timing — **ĐÓNG TIMING ✅**

| Chỉ số | Giá trị | Nguồn |
|---|---|---|
| Achieved f_clk | **100 MHz** (target) | ✅ impl |
| **WNS** (setup) | **+0.918 ns** ≥ 0 | ✅ impl |
| TNS | **0.000** (0 failing) | ✅ impl |
| WHS (hold) | +0.006 ns | ✅ impl |
| f_max ước tính | **~110 MHz** (1/(10−0.918)) | 🧮 |
| Critical path | 🟡 đọc Max Delay Paths trong timing report | 🟡 |

## 5. Power & Energy (KPI vàng)

| Chỉ số | Giá trị | Nguồn |
|---|---|---|
| Total On-Chip Power | **2.308 W** | ✅ impl (Vivado est, Medium) |
| Dynamic | **1.994 W** | ✅ |
| Static | **0.314 W** | ✅ |
| Energy/inference | ~**2.76 J** (2.308 W × 1.20 s, cũ) | 🟡 board |
| **Peak GOPS/W** | **5.5** (12.8/2.308) | 🧮 |
| Sustained GOPS/W | thấp (overhead) — xem #1 ghi chú | 🟡 board |
| Board-measured power | shunt 12 V DC | 🟡 board |

## 6. Memory & Bandwidth

| Chỉ số | Giá trị | Nguồn |
|---|---|---|
| On-chip memory | ~**92 KB** (20.5 BRAM tile: Pico 64 KB + scratchpad + sigmoid + ECC) | ✅ impl |
| Off-chip footprint | ~**0.3 MB** (FC1 weight 61 KB lớn nhất + fmap + im2col 28 KB + AUTO stage 80 KB) | ✅ map |
| DDR bandwidth | 🟡 AXI Performance Monitor | 🟡 board |
| Data reuse factor | 🟡 MACs/DDR-bytes (đo APM) | 🟡 board |
| Off-chip traffic/inference | 🟡 tổng DMA MM2S+S2MM | 🟡 board |

## 7. PE Utilization (trả lời critique "underutilization")

| Chỉ số | Giá trị | Nguồn |
|---|---|---|
| FC PE util (WS, M=1) | **12.5 %** (8/64) → **100 %** (OS dataflow) | 🧮 + ✅ sim |
| Conv PE util (WS) | cao (M lớn) | ✅ sim |
| Idle cycle % | 🟡 từ per-state counter (firmware đã emit) | 🟡 board |
| HW vs SW time breakdown | 🟡 per-layer cycle (firmware emit) | 🟡 board |
| Per-layer PE util | 🟡 counter `pe_active`/`compute` | 🟡 board |

> Firmware **đã emit sẵn** per-state breakdown + sparsity → board 1 lần là đầy đủ.

## 8. Architectural Quality (định tính)

| Chỉ số | Đánh giá |
|---|---|
| Scalability | Array `SA_N` tham số hóa → 16×16/32×32 về lý thuyết (đổi 1 param) |
| Flexibility | 3 layer type (Conv via im2col, FC, Pool) + **2 dataflow** (WS + OS) |
| Programmability | Descriptor API + autonomy (`gemm_auto`: 1 descriptor + AUTO_GO) |
| Generality | `gemm_auto` + tile-major descriptor → chạy GEMM bất kỳ; model khác cần weight + map |

## 9. Reliability (trụ RAS)

| Chỉ số | Giá trị | Nguồn |
|---|---|---|
| ECC SECDED scratchpad | ✅ tích hợp (sửa 1-bit, phát hiện 2-bit) | ✅ sim |
| TMR FSM state | ✅ vote 3 copy | ✅ sim (mọi path PASS) |
| Fault injection | ✅ AXI control (target ECC/FSM, bit, trigger) | ✅ |
| Accuracy vs fault rate (4 curve) | 🟡 `reliability_demo` firmware + sweep | 🟡 board |
| Hardening overhead | nhỏ: TMR +~15 FF, ECC +6 bit/word; cần build no-harden để đo chính xác | 🟡 synth 2 build |
| MTTF (theoretical) | 🟡 từ SEU rate giả định | 🧮 |

## 10. System-level

| Chỉ số | Giá trị | Nguồn |
|---|---|---|
| Firmware size | **7.1 KB** (7312 B / 64 KB BRAM) | ✅ build |
| HW/SW partition | 🟡 từ breakdown (board) | 🟡 |
| Boot/config time | 🟡 board | 🟡 |

## 11. Comparison Baselines

| Baseline | Trạng thái |
|---|---|
| PicoRV32-only (pure SW) | ✅ **đã có** — SW 437 M cycle vs HW 119.6 M = **3.65× speedup** (bitstream cũ) |
| ARM A53 (PS) | 🟡 board |
| RAAS baseline vs +optimization (ablation) | 🟡 synth mỗi config (xem dưới) |
| Prior FPGA work | 🟡 cite paper |

## 12. Productivity / Cost

| Chỉ số | Giá trị |
|---|---|
| LoC HDL | **3,392** dòng (18 file `.v`) |
| LoC firmware | **2,039** dòng (C + header) |
| Area-time product | 🧮 = LUT × latency (tính khi có latency board) |

---

## Ablation study (#11) — cần synth mỗi config

Mỗi dòng = 1 build + `report_all.tcl`:

| Config | LUT % | FF % | DSP | f_clk | Power | Latency | Note |
|---|---|---|---|---|---|---|---|
| Full (hiện tại) | 62.1 | 33.0 | 142 | 100 MHz (+0.918) | 2.308 W | — | ✅ build này |
| – reliability (no ECC/TMR) | | | | | | | đo overhead RAS |
| – autonomy (no 2c) | | | | | | | đo cost autonomy |
| baseline (chỉ WS array) | | | | | | | reference |

---

## Tóm tắt: đã điền được **~60%** không cần board

✅ **Đầy đủ ngay:** Resource (#3), Timing (#4), Power-estimate (#5), Peak GOPS/W, MAC, accuracy FP32+RTL-bit-exact, PE-util lý thuyết, LoC, firmware size, speedup-cũ.

🟡 **Chờ board:** latency/power thực, throughput, on-board accuracy, DDR bandwidth, idle breakdown runtime, 4 resilience curves.

→ Chương Evaluation viết được phần lớn ngay; để trống cột "board" điền sau.
