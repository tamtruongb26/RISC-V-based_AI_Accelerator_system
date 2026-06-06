# Implementation Plan — RAAS (Tier 3, ~22 tuần)

> Execution timeline để triển khai 8 giải pháp trong [limitations_solutions.md](limitations_solutions.md).
> Đo lường theo [evaluation_metrics.md](evaluation_metrics.md).
> Tên đề tài giữ nguyên: *RISC-V-based AI Accelerator System*.

## Context & Contribution Framing

Đồ án RAAS hiện tại bị đánh giá "cũ, không đổi mới" vì workload (LeNet-5/MNIST) và kiến trúc (8×8 weight-stationary systolic, fixed-point Q1.4.11) đã quá quen thuộc từ 2015-2017.

Plan này triển khai **3 trụ contribution** trên nền hệ thống hiện có:

1. **Memory hierarchy + preprocessing offload** (Gemmini-inspired): scratchpad + accumulator SRAM, double-buffering, hardware im2col + pool, CISC loop descriptor.
2. **Sparsity exploitation + dataflow flexibility**: operand isolation ở PE, Output-Stationary mode cho FC layers.
3. **Reliability hardening** (matches "RAS" in project name): fault injection framework, TMR control FSM, ECC SECDED scratchpad.

→ Câu chuyện luận văn: "RISC-V-based AI Accelerator System — compact, sparsity-aware, **and reliable** edge inference on commodity FPGA".

## Progress Status

Cập nhật: **2026-06-06**. Tag git: `v-baseline` (P0), `v-phase1a`, `v-phase2a` (đã push).
Cách làm: **incremental + simulation** (không board → verify chức năng bằng xsim,
area/timing bằng OOC synth; firmware compile-verify). Chi tiết: `docs/innovations_summary.md`,
`docs/phase1a_design.md`, `docs/synth_results.md`, `docs/autonomous_accel_design.md`.

### Đã hoàn thành (verify sim + synth; runtime cần board)

- [x] **Phase 1a — Scratchpad + Accumulator + Data reuse** (tag `v-phase1a`)
  - [x] `scratchpad.v`, `accumulator.v` + unit testbench (sim PASS)
  - [x] 1a-i: HW K-accumulation (Vấn đề 3a) — CFG spare bit, full-precision 40-bit
  - [x] 1a-ii A-D: weight reuse (SKIP_W_LOAD), multi-slot accumulator (blocking),
        SKIP_IN_LOAD — control qua CFG[15:20], không thêm register/không đụng BD
  - [x] Firmware `gemm_tile.c` dùng HW K-acc (compile pass)
  - [x] OOC synth: LUT 17%, FF 12%, DSP 67, WNS @100MHz +8.68ns
- [x] **Phase 2a — HW im2col** (tag `v-phase2a`, Vấn đề 3b)
  - [x] `im2col.v` (sliding-window FSM) + unit testbench (padding/multi-channel/stride)
  - [x] Tích hợp vào accelerator: chế độ IM2COL (CFG[21]) — FM→scratchpad→im2col→A→SEND
  - [x] **Blocking**: load FM 1 lần, lặp nội bộ ho-block, A real-scale (num_transfers 16-bit)
  - [x] Firmware `im2col_hw()` + lenet.c (compile pass)
  - [x] OOC synth: LUT 20%, FF 12.6%, DSP 72, WNS +8.39ns
- [x] **Phase 1b foundation** — tách scratchpad FM/A (nền double-buffer; overlap 2-lane chưa làm)
- [x] **Phase 4 — Sparsity operand isolation** (Vấn đề 5) — `pe.v`: khi a/w=0 giữ
      operand cũ (no toggle → power), functional preserved (pe_tb pass). Mở trụ 2.
- [x] **Phase 5 — Reliability primitives** (trụ novel) — 3 module verified sim:
  - [x] 5a `fault_injector.v` — SEU bit-flip injection (Vấn đề 7a)
  - [x] 5b `tmr_voter.v` — 3-input majority voter (Vấn đề 7b)
  - [x] 5c `ecc_secded.v` — Hamming SECDED, test vét cạn 1-bit correct + 2-bit detect (Vấn đề 7c)
  - [x] `tmr_register.v` — register chịu lỗi (TMR + fault inj), demo voter mask SEU
  - [x] `ecc_scratchpad.v` — memory chịu lỗi (ECC encode/decode + fault inj), tự sửa
  - [x] Area OOC: hardening <0.5% LUT ZU3EG (xem `synth_results.md`) → vượt tiêu chí
  - [ ] Integration vào accelerator thật (FSM state TMR, scratchpad ECC) + `fault_sweep.py` → 4 resilience curve
- [x] **Phase 2b — HW maxpool** (`maxpool2x2.v`, Vấn đề 3c) — module verified sim
      (4 case signed, multi-channel); integration (POOL mode) chưa

### Phase 0 — Đã hoàn thành

- [x] **Phase 0a — HDL instrumentation + register pack** (HDL only)

- [x] **Phase 0a — HDL instrumentation + register pack** (HDL only)
  - [x] Per-state cycle counters trong `control_unit.v` (9 counters)
  - [x] PE-active counter trong `data_path.v`
  - [x] Register pack + indirect counter readback trong `slave_lite.v`
  - [x] Counter mux 10-to-1 trong `accelerator.v`
  - [x] Register map mới trong `raas_map.h` (CFG_PACKED + CNT_*)
- [x] **Phase 0b — Vivado BD + bitstream**
  - [x] Re-package accelerator IP
  - [x] Thêm AXI Timer IP vào BD
  - [x] Thêm AXI Performance Monitor (APM) IP vào BD
  - [x] Validate Design pass clean (chỉ còn BD 41-1347 warning pre-existing acceptable)
  - [x] Synthesis + Implementation thành công
  - [x] Bitstream + XSA generated (`fpga/RAS_wrapper.xsa`, `RAS_wrapper.bit`)
  - [x] Timing: WNS +3.714ns @ 100MHz, 0 failing endpoints
  - [x] DRC: 0 errors, 0 critical warnings
  - [x] Utilization: LUT 34.5%, FF 24%, DSP 19.7%, BRAM 9.0%
- [x] **Phase 0c — Firmware update**
  - [x] `accel.h` + `accel.c` API mới (configure_and_start, counters_clear/read/snapshot)
  - [x] `lenet.c` per-layer `lstamp()` + accelerator counter snapshot
  - [x] `io.h` thêm `pico_rdcycle()` helper
  - [x] Constant rename (`RAAS_CTRL_ACT_*` → `RAAS_CFG_ACT_*`) ở mọi file firmware + 3 Vitis copies
  - [x] `make lenet` build pass (không lỗi compile)

### Đang chờ

- [ ] **Phase 0d — Vitis app update + board run**
  - [ ] Import XSA mới (`RAS_wrapper.xsa`) vào Vitis workspace
  - [ ] Rebuild PS app
  - [ ] Flash bitstream + run firmware trên Ultra96-v2
  - [ ] Đọc mailbox dump → điền số liệu vào `docs/baseline_metrics.md`

### Phase 0 còn lại (next increments, không block bước trên)

- [ ] IRQ output (`po_irq_done` trong HDL + AXI Intc trong BD) — task 3d (interrupt-driven sync)
- [ ] Operator library refactor (tách `main_lenet.c` thành `ops.c` + `ops.h`) — task 8a
- [ ] Simulation testbench cho counter verification
- [ ] `scripts/report_all.tcl` (Vivado auto-report)
- [ ] `tools/post_process.py` (parse mailbox dump → bảng + plot)

### Chưa bắt đầu

- [ ] Phase 1b — Double buffering (overlap 2-lane; foundation đã xong)
- [ ] Phase 2b — HW pool (cần line-buffer cửa sổ 2×2)
- [ ] Phase 2c — CISC loop descriptor (autonomy — T2, đụng block design)
- [ ] Phase 3a — OS dataflow mode (FC 12.5%→80%)
- [ ] Phase 5 integration — wire reliability primitives vào accelerator → 4 resilience curve
- [ ] Sparsity skip counter (data_path + SPARSITY_SKIPPED reg) + SAIF power measure
- [ ] Phase 6 — Generic firmware + model descriptor
- [ ] Phase 7 — Final evaluation + writeup
- [ ] Đo board (latency/power/accuracy + data reuse APM) — mọi số hiệu năng

## Timeline tổng quan

| Phase | Tuần | Module | Status |
|---|---|---|---|
| 0 — Baseline + Instrumentation + Cleanup | 1-2 | Counter, APM, register pack (6a) | **HDL/BD/FW xong** (chờ board measurement; IRQ/ops refactor/scripts còn nợ) |
| 1a — Scratchpad + Accumulator | 3-5 | `scratchpad.v`, `accumulator.v` | **✅ DONE** (sim+synth, `v-phase1a`) |
| 1b — Double buffering | 6 | Ping-pong banks | **Foundation xong** (tách SP); overlap 2-lane chưa |
| 2a — HW im2col | 7-8 | `im2col.v` | **✅ DONE** (sim+synth+firmware, blocking, `v-phase2a`) |
| 2b — HW pool | 9 | `maxpool2x2.v` | **✅ module** (sim 4 case signed); integration chưa |
| 2c — CISC loop descriptor | 10-11 | Outer loop FSM | Chưa bắt đầu (autonomy — đụng BD) |
| 3a — OS dataflow mode | 12-14 | `pe.v`, `data_path.v` dual-mode | Chưa bắt đầu |
| 4 — Sparsity zero-skip | 15 | `pe.v` operand isolation | **✅ DONE** (functional preserved; power cần SAIF) |
| 5a — Fault injection framework | 16 | `fault_injector.v` | **✅ module** (sim); integration chưa |
| 5b — TMR control FSM | 17 | `tmr_voter.v` | **✅ module** (sim); integration chưa |
| 5c — ECC scratchpad | 18-19 | `ecc_secded.v` | **✅ module** (sim vét cạn); integration chưa |
| 6 — Generic firmware + model descriptor | 20 | `ops.c`, `main_generic.c` | Chưa bắt đầu |
| 7 — Final evaluation + writeup | 21-22 | Ablation, comparison, luận văn | Chưa bắt đầu |

---

## Phase 0 — Baseline + Instrumentation + Cleanup (Tuần 1-2)

### Mục tiêu
Có đủ số liệu baseline trước khi đụng vào code optimization. Đồng thời clean up firmware structure để dễ scale sau này.

### Công việc

**Instrumentation (HDL + block design)**:
- Thêm AXI Timer IP vào block design (cycle counting).
- Thêm AXI Performance Monitor (APM) IP — đo DDR bandwidth, AXI transaction count.
- Mở rộng `control_unit.v` thêm counter per-state: cycles trong IDLE / LOAD_W / LOAD_B / LOAD_IN / COMPUTE / DRAIN / POST_PROC / SEND.
- Thêm counter `pe_active_cycles` trong `data_path.v` — đếm cycles có ít nhất 1 PE active (sau này dùng cho sparsity utilization).
- Mở rộng `LAYER_DBG` trong DDR mailbox: Pico ghi cycle count sau mỗi layer.

**Cleanup**:
- 3d (Interrupt-driven sync): Wire `irq_done` từ `accelerator.v` → AXI IRQ Controller → PicoRV32 IRQ. Pico ISR set flag thay polling.
- 6a (Register pack): Gộp 5 register `TILE_M/K/N/CONTROL/STATUS` thành 1 register packed trong `slave_lite`.
- 8a (Generic operator library): Tách `main_lenet.c` thành `ops.c` (`op_gemm`, `op_im2col`, `op_pool`) + `main_lenet.c` (gọi ops). Header `ops.h`.

**Tooling**:
- Python script `tools/post_process.py` — gom log Vivado + Pico log → bảng + plot (roofline, latency breakdown).
- Vivado TCL script `scripts/report_all.tcl` — auto generate utilization + timing + power report.

### Files đụng vào
- Sửa: `hw/accelerator_2_0/hdl/control_unit.v`, `data_path.v`, `accelerator.v`, `accelerator_slave_lite_v2_0_S00_AXI.v`, block design Vivado.
- Sửa: `sw/picorv32/src/main_lenet.c` → tách + thêm `ops.c`, `ops.h`.
- Mới: `tools/post_process.py`, `scripts/report_all.tcl`.
- Mới: `docs/baseline_metrics.md` (output).

### Success criteria
- Tất cả metrics trong [evaluation_metrics.md](evaluation_metrics.md) section "Ưu tiên Vàng" có baseline number.
- Firmware tổ chức theo `ops.c` + `main_lenet.c` riêng biệt.
- LeNet vẫn pass accuracy ≥ 98.0% trên board sau cleanup.
- Interrupt working: Pico ISR fire khi accelerator DONE (verify bằng GPIO debug pin).

---

## Phase 1 — Memory Hierarchy (Tuần 3-6)

### Phase 1a (Tuần 3-5): Scratchpad + Accumulator

**Thiết kế**:

| Component | Specs |
|---|---|
| Scratchpad | 2 banks ping-pong, dual-port BRAM, 128-bit/row × 1024 row = 16 KB. 4 BRAM 36Kb tiles. |
| Accumulator | Single bank, 256-bit/row × 128 row = 4 KB. 2 BRAM 36Kb tiles. Có adder column, hỗ trợ in-place add. |

**Control flow mới**:
1. DMA MM2S load weights → SP bank A.
2. DMA MM2S load inputs → SP bank A.
3. EXEC: read SP bank A → PE → write accumulator (overwrite for K-tile=0, accumulate for K-tile>0).
4. Sau K-tile cuối: read accumulator → post_proc → DMA S2MM out.

**Files đụng vào**:
- Mới: `hw/accelerator_2_0/hdl/scratchpad.v` (banked BRAM wrapper, bank_select).
- Mới: `hw/accelerator_2_0/hdl/accumulator.v` (SRAM + adder column + overwrite/accumulate mode).
- Sửa: `control_unit.v` — state mới `LOAD_SP_W`, `LOAD_SP_IN`, `EXEC_FROM_SP`, `WRITE_ACC`, `READ_ACC_TO_DMA`.
- Sửa: `accelerator.v` — wire SP/ACC vào datapath.
- Sửa: `accelerator_slave_lite_v2_0_S00_AXI.v` — registers `SP_BASE_W`, `SP_BASE_A`, `ACC_BASE`, `ACC_OVERWRITE_EN`.
- Sửa: `sw/common/raas_map.h` — register map + DDR layout (giữ nguyên IM2COL_BUF cho Phase 1, sẽ remove ở Phase 2a).
- Sửa: firmware — bỏ vòng K-accumulation SW, set ACC_OVERWRITE_EN đúng theo K-tile index.

### Phase 1b (Tuần 6): Double Buffering

**Thiết kế**: Tận dụng 2 banks của scratchpad đã có. Load FSM và Exec FSM chạy song song với handshake `bank_ready`.

**Files đụng vào**:
- Sửa: `scratchpad.v` — bit `bank_active`.
- Sửa: `control_unit.v` — tách Load lane và Exec lane, toggle bank mỗi tile.
- Firmware — fire-and-forget descriptor.

### Success criteria Phase 1
- FC1 latency giảm ≥ 30% (vì giảm DDR reload).
- Conv2 latency giảm ≥ 20% sau khi thêm double buffer.
- Data reuse factor tăng từ ~1× lên ≥ 10× (đo bằng APM: MAC count / DDR bytes read).
- HW vs SW time breakdown: SW < 30% (giảm từ > 50% baseline).
- Accuracy unchanged.
- Vivado timing close 100 MHz (nếu fail, pipeline thêm 1 stage trong scratchpad path).

---

## Phase 2 — Hardware Preprocessing + Compaction (Tuần 7-11)

### Phase 2a (Tuần 7-8): HW im2col

**Thiết kế**: Module FSM sliding window đọc SP feature map `[H×W×C]`, ghi SP ma trận `[H_out·W_out × C·kH·kW]`. Tham số runtime.

**Files đụng vào**:
- Mới: `hw/accelerator_2_0/hdl/im2col.v`.
- Sửa: `control_unit.v` — state `IM2COL_RUN`.
- Sửa: `slave_lite` — registers `IM2COL_H_IN`, `IM2COL_W_IN`, `IM2COL_C_IN`, `IM2COL_K`, `IM2COL_STRIDE`, `IM2COL_PAD`.
- Sửa: `sw/common/raas_map.h` — **xóa `IM2COL_BUF` 28 KB khỏi DDR layout**.
- Sửa: firmware — thay `im2col_sw()` bằng HW call + wait IRQ.

### Phase 2b (Tuần 9): HW pool

**Thiết kế**: Thêm stage 4 trong `post_proc.v`: compare-and-select 4 phần tử khi `POOL_EN=1`.

**Files đụng vào**:
- Sửa: `post_proc.v` — stage S4 compare-select 2×2 (mở rộng 3×3 nếu time permits).
- Sửa: `slave_lite` — bits `CONTROL.POOL_EN`, `POOL_WIN`, `POOL_STRIDE`.
- Sửa: firmware — bỏ `maxpool_sw()`, set POOL_EN trên output Conv layers.

### Phase 2c (Tuần 10-11): CISC loop descriptor

**Thiết kế**: Thêm outer loop FSM trong `control_unit.v`. Pico setup descriptor (M_total, K_total, N_total, A_base, W_base, C_base, act_mode) + 1 START → HW tự tile, double-buffer, DMA.

**Files đụng vào**:
- Sửa: `control_unit.v` — outer loop FSM (đếm tile_idx_m/k/n, gọi inner FSM).
- Sửa: `accelerator.v` — DMA initiation logic (HW write DMA descriptor registers thay vì Pico).
- Sửa: `slave_lite` — registers descriptor.
- Sửa: firmware `ops.c` — `op_gemm` chỉ setup descriptor + wait IRQ thay vì loop tile-by-tile.

### Success criteria Phase 2
- Conv1 + Conv2 layer latency giảm ≥ 25% (vì HW im2col + double buffer pipeline).
- 2 SW passes (Pool1, Pool2) eliminated → firmware nhỏ hơn ~1 KB.
- AXI-Lite transaction count giảm ≥ 80% (đo APM): 1259 tiles × 5 writes → ~10 descriptors × 7 writes.
- `IM2COL_BUF` 28 KB removed khỏi DDR.
- LeNet accuracy unchanged.

---

## Phase 3 — Dataflow Flexibility (Tuần 12-14)

### Phase 3a: OS Dataflow Mode

**Thiết kế**: PE dual-mode (WS/OS). OS mode: PE giữ psum in-place, broadcast `a` theo hàng + `w` theo cột. Reduce dọc cột sau K phases.

**Files đụng vào**:
- Sửa: `pe.v` — mode bit `dataflow_mode`. OS: `psum += a × w` in-place, no shift. WS: behavior hiện tại.
- Sửa: `data_path.v` — broadcast network. Reuse wire hiện tại nhiều nhất có thể.
- Sửa: `control_unit.v` — state `OS_LOAD_AB`, `OS_DRAIN`.
- Sửa: `slave_lite` — bit `CONTROL[3] = DATAFLOW_OS`.
- Sửa: firmware — Conv layers WS, FC layers OS.

### Success criteria
- FC1 PE utilization tăng từ 12.5% lên ≥ 80% (đo `pe_active_cycles` counter).
- FC1 latency giảm thêm ≥ 50% so với Phase 2 (cộng dồn).
- Accuracy unchanged.

### Risk
Đụng PE và datapath core — medium risk. Nếu trượt timing hoặc bug khó: drop và thừa nhận FC underutilization trong luận văn.

---

## Phase 4 — Sparsity Zero-Skip (Tuần 15)

**Thiết kế**: Trong `pe.v`: `wire is_zero = (a_in == 0) || (w_reg == 0)`. Gate multiplier inputs qua `is_zero ? old_val : new_val` (operand isolation). Optional: clock gate psum register.

**Files đụng vào**:
- Sửa: `pe.v` — operand isolation logic.
- Sửa: `data_path.v` — counter `sparsity_skip_cnt`.
- Sửa: `slave_lite` — read-only register `SPARSITY_SKIPPED`.

**Đo**:
- SAIF dump từ post-synth simulation với **MNIST activation thực** (chạy 100 samples) → Vivado Power Report.

### Success criteria
- Dynamic power giảm ≥ 15%.
- Sparsity skip count phù hợp ReLU profile: 40-60% middle layers, 0-20% input/output layers.
- Latency unchanged (chỉ tiết kiệm energy, không speedup).
- Accuracy unchanged.

---

## Phase 5 — Reliability (Tuần 16-19)

### Phase 5a (Tuần 16): Fault Injection Framework

**Thiết kế**: Module `fault_injector.v` AXI-Lite controllable. Registers: `FI_TARGET` (0:weight reg, 1:psum reg, 2:FSM state, 3:scratchpad), `FI_BIT_POS`, `FI_ADDR`, `FI_TRIGGER_CYCLE`, `FI_ENABLE`. Khi enable + counter trigger: XOR target tại BIT_POS.

**Files đụng vào**:
- Mới: `hw/accelerator_2_0/hdl/fault_injector.v`.
- Sửa: `slave_lite` — register set fault injection.
- Sửa: `accelerator.v` — wire injector vào weight reg, psum reg, FSM state, scratchpad data.
- Mới: `tools/fault_sweep.py` — Python loop qua (target, bit, layer, sample) → run inference → đo accuracy.

**Deliverable**: Baseline resilience curve (accuracy vs fault rate cho 4 target types).

### Phase 5b (Tuần 17): TMR Control FSM

**Thiết kế**: Triple state register, 3-input majority voter. Mismatch counter.

**Files đụng vào**:
- Mới: `hw/accelerator_2_0/hdl/tmr_voter.v` (3-input majority).
- Sửa: `control_unit.v` — triple state `state_a/b/c`, voter chọn majority, counter `tmr_mismatch_cnt`.
- Sửa: `slave_lite` — read-only register `TMR_MISMATCH_CNT`.

**Verify**: Inject fault vào `state_a` → check voter chọn đúng + counter tăng.

### Phase 5c (Tuần 18-19): ECC SECDED Scratchpad

**Thiết kế**: Hamming(72,64) — 64-bit data + 8-bit ECC. Weight bus 128-bit = 2 codewords. Encoder on write, decoder on read. Single-bit correct, double-bit detect.

**Files đụng vào**:
- Mới: `hw/accelerator_2_0/hdl/ecc_encoder.v` (Hamming SECDED encode).
- Mới: `hw/accelerator_2_0/hdl/ecc_decoder.v` (decode + correct + double-detect flag).
- Sửa: `scratchpad.v` — width 128 → 144 bit, encoder ở write port, decoder ở read port.
- Sửa: `slave_lite` — counters `ECC_CORRECTED_CNT`, `ECC_UNCORRECTABLE_CNT`.

**Verify**: Inject single-bit → corrected, counter tăng. Inject double-bit → uncorrectable flag, error logged.

### Success criteria Phase 5
- 4 resilience curves đo được (no-harden / TMR-only / ECC-only / TMR+ECC).
- Hardening overhead: < 20% LUT total, < 10% power, không degrade f_clk.
- Critical bits identified (top 10% bits gây misclassification cao nhất).
- Mismatch + correction counters working under fault injection.

---

## Phase 6 — Generic Firmware + Model Descriptor (Tuần 20)

**Thiết kế**: Model descriptor binary trong DDR. Structure: `[N_layers (4B)] [layer_desc_0 (32B)] ... [layer_desc_N (32B)]`. Layer descriptor = `{op_type, in_H, in_W, in_C, out_H, out_W, out_C, weight_addr, bias_addr, act_mode}`.

PS load descriptor + weights. Pico `main_generic.c` đọc descriptor → dispatch op tương ứng từ `ops.c`.

**Demo**: Chạy 2 model trên cùng firmware: LeNet gốc + LeNet variant (3 conv layers) — không recompile firmware.

**Files đụng vào**:
- Mới: `sw/picorv32/src/model_descriptor.h` (struct definitions).
- Mới: `sw/picorv32/src/main_generic.c` (loop dispatcher).
- Mới: `tools/model_to_descriptor.py` (sinh descriptor binary từ PyTorch model).
- Sửa: PS Vitis app — load descriptor + weights cho 2 model.

### Success criteria
- Cùng 1 binary firmware chạy 2 model, switch bằng cách thay descriptor + weights trong DDR.
- LeNet variant accuracy đo được (cho thấy generality).

---

## Phase 7 — Final Evaluation + Writeup (Tuần 21-22)

### Tuần 21 — Ablation Study + Comparison

**Ablation table** (chạy mỗi config độc lập trên LeNet):

| Config | Latency | Power | GOPS/W | Accuracy | PE util | Note |
|---|---|---|---|---|---|---|
| Baseline (original) | | | | | | |
| + SP + Acc (1a) | | | | | | |
| + Double buffer (1b) | | | | | | |
| + HW im2col (2a) | | | | | | |
| + HW pool (2b) | | | | | | |
| + CISC loop (2c) | | | | | | |
| + OS dataflow (3a) | | | | | | |
| + Sparsity (4) | | | | | | |
| + Reliability hardened (5) | | | | | | |

**Comparison**:
- vs PicoRV32-only software baseline (no accelerator) — speedup ×.
- vs ARM A53 software baseline (PS only) — energy efficiency comparison.
- vs ≥ 1 prior FPGA NN paper trên LeNet/MNIST hoặc workload tương đương (cite + bảng).

**Reliability section**:
- 4 resilience curves (accuracy vs fault rate).
- Bảng overhead: area / power / latency cho TMR / ECC / TMR+ECC.

### Tuần 22 — Luận văn

Cấu trúc đề xuất:
1. Introduction (động lực, contribution, 3 trụ)
2. Background (RISC-V soft-core, systolic array, dataflow, fault tolerance)
3. System architecture (block diagram, address map, ISA, descriptor format)
4. Memory hierarchy design (scratchpad + accumulator + double buffer)
5. Hardware preprocessing + CISC loop
6. Dataflow flexibility (WS/OS dual mode)
7. Sparsity exploitation
8. Reliability features (fault injection methodology + hardening)
9. Evaluation (performance + energy + reliability)
10. Related work (Gemmini, Eyeriss, fault-tolerant DNN accelerators)
11. Conclusion + future work (ONNX compiler, mixed-precision, larger workloads)

---

## Risk Management

| Rủi ro | Phase | Mitigation |
|---|---|---|
| Scratchpad timing fail 100 MHz | 1a | Pipeline +1 stage, chấp nhận f_clk 80 MHz |
| OS dataflow phức tạp / bug khó | 3a | Drop nếu trượt; FC underutilization tự thừa nhận trong luận văn |
| HW im2col edge cases (padding, stride > 1) khó | 2a | Giữ fallback `im2col_sw()` trong firmware |
| Fault injection methodology bị critique | 5a | Cite paper SELSE/DSN cho fault model (e.g., Sundaresan et al. 2023) |
| ECC overhead lớn hơn dự kiến | 5c | Fallback xuống parity-only (single-detect, no correct) |
| Trượt 2+ tuần | bất kỳ | Drop order: Phase 6 → 5c → 3a → 2b. Giữ chắc Phase 0-2a, 4, 5a-b. |

## Success Criteria toàn cục (cho defense)

Khi bảo vệ, phải trả lời 3 câu hỏi sau bằng **số liệu cụ thể**:

1. **"Tốt hơn baseline bao nhiêu?"**
   - Latency ↓ ≥ 50% end-to-end LeNet.
   - Energy/inference ↓ ≥ 50%.
   - GOPS/W ↑ ≥ 2×.
   - PE utilization FC layers ↑ từ 12.5% lên ≥ 80%.

2. **"Có novel gì so với prior work?"**
   - 3-trụ contribution: memory hierarchy + sparsity-aware + reliability hardening cho **compact edge FPGA**.
   - Positioning vs Gemmini: target soft-core RISC-V trên commodity Zynq, không phải Rocket/BOOM datacenter.
   - Reliability angle: ít prior work trên FPGA NN accelerator có fault injection + selective hardening.

3. **"Hệ thống chịu fault thế nào?"**
   - 4 resilience curves đo được.
   - Hardening overhead < 20% area, < 10% power.
   - MTTF estimate (theoretical) trên SEU rate giả định.

→ Trả lời được cả 3 câu này bằng bảng số liệu định lượng = bảo vệ qua.

---

## Cross-references

- Per-limitation diagnosis và solution detail: [limitations_solutions.md](limitations_solutions.md)
- Methodology đo lường (12 nhóm metrics, instrumentation): [evaluation_metrics.md](evaluation_metrics.md)
- Kiến trúc hiện tại trước khi sửa: [system_description.md](system_description.md)
