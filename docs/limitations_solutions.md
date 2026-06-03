# Limitations & Solutions — RAAS

> 8 hạn chế cốt lõi của hệ thống hiện tại và cách xử lý từng cái.
> Tham khảo trong khi triển khai. Mọi file mới/sửa được liệt kê dưới đây.
> Đo lường theo phương pháp trong [evaluation_metrics.md](evaluation_metrics.md).
> Timeline triển khai chi tiết: [implementation_plan.md](implementation_plan.md).

## Tóm tắt 8 hạn chế cốt lõi

| # | Hạn chế | Bottleneck thuộc nhóm |
|---|---|---|
| 1 | PE trống ở lớp FC (M=1 → 1/8 hàng active, 87.5% idle) | Underutilization |
| 2 | Memory wall — đọc DDR mỗi tile, data reuse ≈ 1× | Memory bandwidth |
| 3 | PicoRV32 làm SW preprocessing (im2col, pool, K-acc, polling) → accel idle | Underutilization + Latency |
| 4 | Không double-buffering — DMA và compute serialize | Memory bandwidth + Latency |
| 5 | Không khai thác sparsity — ReLU `0 × W` vẫn tốn cycle + power | Energy |
| 6 | Interface CPU↔Accel chậm — AXI-Lite MMIO × 1259 tile | Latency |
| 7 | Không có cơ chế tin cậy — vulnerable to SEU | Reliability |
| 8 | Bonded với LeNet-5 — firmware hardcoded, không reusable | Programmability |

---

## 1. PE underutilization ở lớp FC (M=1)

### Chẩn đoán
FC1 (1×256×120), FC2 (1×120×84), FC3 (1×84×10) có `M=1`. Systolic array 8×8 weight-stationary feed A-matrix theo hàng → chỉ 1/8 hàng PE nhận dữ liệu thực, 7/8 còn lại idle. Hiệu suất = 12.5%. Hơn 60% MAC của LeNet nằm ở FC1 → đây là phần lãng phí nặng nhất.

### Giải pháp: Output-Stationary (OS) dataflow mode cho FC

Idea: map K dimension lên hàng PE, N dimension lên cột PE. Mỗi PE giữ 1 partial sum `psum[k_row][n_col]`. Mỗi cycle: broadcast `a[k_row]` theo hàng × `w[k_row][n_col]` theo cột → 64 MACs song song. Sau K/8 lần feed, reduce dọc cột → 8 outputs.

Với FC1 (K=256, N=120): 8 K-rows × 8 N-cols = 64 PE active = 100% utilization.

### File đụng vào
- `hw/accelerator_2_0/hdl/pe.v` — thêm mode bit `dataflow_mode`. OS: `psum += a × w` in-place. WS: behavior hiện tại.
- `hw/accelerator_2_0/hdl/data_path.v` — broadcast network cho `a` (theo hàng) và `w` (theo cột) khi OS.
- `hw/accelerator_2_0/hdl/control_unit.v` — state mới `OS_LOAD_AB`, `OS_DRAIN`.
- `hw/accelerator_2_0/hdl/accelerator_slave_lite_v2_0_S00_AXI.v` — bit `CONTROL[3] = DATAFLOW_OS`.
- Firmware — Conv layers set WS, FC layers set OS.

### Effort & Phase
2-3 tuần. Phase 3a.

### Lưu ý
- Đây là cái Gemmini làm runtime (`config_ex`).
- Risk medium (đụng PE core). Nếu trượt: drop và thừa nhận FC underutilization trong luận văn.

---

## 2. Memory wall (DDR reload mỗi tile)

### Chẩn đoán
Không có on-chip storage. Mỗi tile DMA toàn bộ weight + bias + input từ DDR qua AXIS. FC1 (K=256, 32 K-tiles) → cùng 8 cột weight đọc lại 32 lần. Data reuse ≈ 1×, trong khi Gemmini-class đạt 10-30×.

### Giải pháp: Scratchpad + Accumulator SRAM (Gemmini-style)

| Component | Thiết kế | BRAM |
|---|---|---|
| Scratchpad (weights + inputs) | 2 banks ping-pong, 128 bit/row × 1024 row = 16 KB | 4 tiles 36Kb |
| Accumulator (psum) | 1 bank, 256 bit/row × 128 row = 4 KB, có adder column | 2 tiles 36Kb |

Accumulator hỗ trợ in-place add (như Gemmini bit 30): address có bit `ACC_OVERWRITE`. Nếu 0 → ghi đè, nếu 1 → cộng dồn. Cho phép HW K-accumulation: K-tile đầu set OVERWRITE=0, các K-tile sau set OVERWRITE=1.

### File đụng vào
- `hw/accelerator_2_0/hdl/scratchpad.v` (mới) — dual-port BRAM wrapper với bank select.
- `hw/accelerator_2_0/hdl/accumulator.v` (mới) — SRAM + adder column + accumulate mode logic.
- `hw/accelerator_2_0/hdl/control_unit.v` — state mới `LOAD_SP`, `EXEC_FROM_SP`, `WRITE_ACC`, `READ_ACC_TO_DMA`.
- `hw/accelerator_2_0/hdl/accelerator.v` — wire SP/ACC vào datapath.
- AXI-Lite registers mới — `SP_BASE_A`, `SP_BASE_W`, `ACC_BASE`, `ACC_OVERWRITE_EN`.
- `sw/common/raas_map.h` — register map mới.
- Firmware — bỏ vòng K-accumulation SW, chỉ set `ACC_OVERWRITE_EN` đúng.

### Effort & Phase
3-4 tuần. Phase 1a. **Foundation, không thể bỏ.**

---

## 3. SW preprocessing trên PicoRV32

### Chẩn đoán
Pico phải: im2col (28 KB scratch DDR), maxpool 2×2, K-accumulation cộng dồn psum, polling DMA + DONE, copy weight tile-by-tile. Khi Pico chạy SW, accelerator idle. HW vs SW time breakdown khả năng > 50% là Pico SW.

### Giải pháp: Tách 4 sub-problems

#### 3a. SW K-accumulation
**Cover bởi Hạn chế 2** (Accumulator SRAM với in-place add). Không cần module riêng.

#### 3b. SW im2col → HW im2col module
Module mới `hw/accelerator_2_0/hdl/im2col.v`. Input: feature map ở SP `[H×W×C]`. Output: matrix ở SP `[H_out·W_out × C·kH·kW]`. Tham số runtime: `H, W, C, kH, kW, stride, padding`. Internal FSM sliding window.

- File mới: `im2col.v`.
- File sửa: `control_unit.v` (state `IM2COL_RUN`), slave_lite (registers `IM2COL_H/W/C/K/STRIDE`), firmware (bỏ `im2col_sw()`), `raas_map.h` (bỏ `IM2COL_BUF` 28KB).
- Effort: 2 tuần. Phase 2a.

#### 3c. SW MaxPool → HW pool stage
Thêm stage 4 trong `post_proc.v`: compare-and-select 4 phần tử khi `POOL_EN=1`.

- File sửa: `post_proc.v` (stage S4), slave_lite (bits `CONTROL.POOL_EN`, `POOL_WIN`, `POOL_STRIDE`), firmware (bỏ `maxpool_sw()`).
- Effort: 1 tuần. Phase 2b.

#### 3d. SW polling → Interrupt-driven
Wire `DONE` từ accelerator → IRQ line PicoRV32 (qua AXI-Intc nếu cần). Pico ISR set flag, main loop check flag. Cho phép Pico làm việc khác khi đợi DONE.

- File sửa: `accelerator.v` (output `irq_done`), block design Vivado (wire IRQ controller), firmware (ISR handler).
- Effort: 0.5 tuần. Phase 0 (low-hanging fruit, làm sớm).

---

## 4. Không double-buffering

### Chẩn đoán
Sequence cứng: DMA load → COMPUTE → DMA store → next tile. DMA và compute không overlap → gap idle ở mỗi giao thời.

### Giải pháp: Ping-pong scratchpad banks
Sau khi có scratchpad (Hạn chế 2), chia làm 2 bank A và B. Tile N COMPUTE đọc bank A; cùng lúc DMA load tile N+1 vào bank B. Tile N+1 swap.

### File đụng vào
- `scratchpad.v` (mở rộng) — 2 banks với select line `bank_active`.
- `control_unit.v` — bit `bank_select` toggle; tách Load FSM và Exec FSM thành 2 lane song song; handshake `bank_ready`.
- Firmware — fire-and-forget descriptor cho tile tiếp theo.

### Effort & Phase
1 tuần. Phase 1b.

### Lưu ý
Hiệu quả tối đa khi `DMA_load_time ≈ compute_time`. Đo trước để biết bottleneck nằm đâu.

---

## 5. Không khai thác sparsity

### Chẩn đoán
ReLU activation có 40-60% giá trị = 0. PE vẫn tính `0×W` rồi cộng 0 vào psum → tốn cycle + power vô ích.

### Giải pháp: Operand isolation + clock gating (Tier A)
Trong PE: detect `is_zero = (a == 0) || (w_reg == 0)`. Khi true: drive multiplier inputs bằng giá trị cũ (operand isolation) → multiplier không toggle → dynamic power giảm. Optional: clock gate psum register cycle đó.

**Không** làm full compressed-sparse format (RLE/CSR) — quá phức tạp, scope creep.

### File đụng vào
- `pe.v` — thêm `wire is_zero` + gate multiplier inputs.
- `data_path.v` — counter `sparsity_skip_cnt` (cho evaluation).
- slave_lite — read-only register `SPARSITY_SKIPPED`.

### Đo
- SAIF dump từ post-synth simulation với MNIST activation thực → Vivado Power Report.
- Tỉ lệ skip kỳ vọng: 40-60% middle layers, 0-20% input/output layers.

### Effort & Phase
1 tuần. Phase 4.

---

## 6. MMIO overhead

### Chẩn đoán
Mỗi tile cần 4-5 AXI-Lite writes (M, K, N, ACT, CONTROL) + 2-3 polls STATUS. Mỗi access ~10-15 cycle qua SmartConnect. × 1259 tiles = ~50k-90k cycles overhead.

### Giải pháp: 2 phần kết hợp

#### 6a. Register pack
Gộp 5 register riêng vào 1 register 32-bit: `[3:0]=M, [7:4]=K, [11:8]=N, [13:12]=ACT, [14]=START`. 1 AXI-Lite write thay 5.

- File: `accelerator_slave_lite_v2_0_S00_AXI.v`.
- Effort: 0.5 tuần. Phase 0.

#### 6b. CISC loop descriptor
Thêm register set: `LOOP_M_TOTAL`, `LOOP_K_TOTAL`, `LOOP_N_TOTAL`, `LOOP_A_BASE`, `LOOP_W_BASE`, `LOOP_C_BASE`, `LOOP_ACT_MODE`. 1 lần setup descriptor + 1 lần START → HW tự loop, tự tile, tự double-buffer, tự DMA. Pico fire-and-forget.

- File sửa: `control_unit.v` (outer loop FSM), `accelerator.v` (DMA initiation logic), slave_lite (descriptor registers).
- Effort: 2 tuần. Phase 2c.

### Lưu ý
Không làm PCPI custom instruction (PicoRV32 không support RoCC; PCPI cần đụng toolchain). Out of scope.

---

## 7. Không có cơ chế tin cậy

### Chẩn đoán
Không ECC trên weight bus, không TMR FSM, không fault detection. Một bit flip trong control register hoặc weight memory → silent corruption. Vulnerable to SEU — vấn đề thực với edge AI ở môi trường năng lượng cao (auto, aerospace, medical).

### Giải pháp: 3 phần tuần tự

#### 7a. Fault Injection Framework (làm ĐẦU TIÊN — để characterize)
Module mới `hw/accelerator_2_0/hdl/fault_injector.v`. AXI-Lite controllable.

Registers: `FI_TARGET` (0:weight reg, 1:psum reg, 2:FSM state, 3:scratchpad data), `FI_BIT_POS`, `FI_ADDR`, `FI_TRIGGER_CYCLE`, `FI_ENABLE`. Khi `FI_ENABLE=1` và counter = `FI_TRIGGER_CYCLE`: XOR target tại `BIT_POS`.

Python script `tools/fault_sweep.py` — loop qua (target, bit, layer, sample) → run inference → đo accuracy. Output baseline resilience curve.

- Effort: 1 tuần. Phase 5a.

#### 7b. TMR Control FSM
Triple state register, majority voter. FSM là single point of failure → high return-on-overhead.

- File mới: `tmr_voter.v` (3-input majority).
- File sửa: `control_unit.v` (triple state `state_a/b/c`, voter chọn majority), counter mismatch.
- Overhead: ~3× area cho FSM register (rất nhỏ so với tổng), ~0% latency.
- Effort: 1 tuần. Phase 5b.

#### 7c. ECC SECDED Scratchpad
Hamming(72,64) hoặc parity per element. Weight bus 128 bit/row → +16 bit ECC = 144 bit (12.5% overhead BRAM). Encoder ở write path, decoder ở read path.

- File mới: `ecc_encoder.v`, `ecc_decoder.v`.
- File sửa: `scratchpad.v` (width 128 → 144, encoder/decoder wrap), counter `ECC_CORRECTED_CNT`, `ECC_UNCORRECTABLE_CNT`.
- Overhead: +12% BRAM, +1 cycle read latency, ~5% LUT.
- Effort: 1.5 tuần. Phase 5c.

### Đo
4 configurations × Python fault sweep → 4 resilience curves (accuracy vs fault rate):
1. Baseline (no harden)
2. TMR-only
3. ECC-only
4. TMR + ECC

Đây là **đóng góp định lượng chính** của trụ Reliability.

---

## 8. Bonded với LeNet-5

### Chẩn đoán
Firmware Pico (`main_lenet.c`) hardcode tuần tự gọi từng layer. Đổi model = viết lại firmware. Không có "model descriptor" runtime.

### Giải pháp: 2 phần

#### 8a. Generic operator library (refactor sớm)
Tách firmware: operator library + model script.

```c
// sw/picorv32/src/ops.c
void op_gemm(uint32_t M, K, N, a_addr, w_addr, b_addr, c_addr, act_mode);
void op_im2col(uint32_t H, W, C, kH, kW, stride, src, dst);
void op_pool(uint32_t H, W, C, win, stride, src, dst);

// sw/picorv32/src/main_lenet.c
void run_lenet() {
    op_im2col(28, 28, 1, 5, 5, 1, IMG, IM2COL);
    op_gemm(576, 25, 6, IM2COL, CONV1_W, CONV1_B, FMAP_A, ACT_RELU);
    op_pool(24, 24, 6, 2, 2, FMAP_A, FMAP_B);
    // ...
}
```

- File mới: `sw/picorv32/src/ops.c`, `ops.h`.
- File sửa: `main_lenet.c` (refactor gọi ops).
- Effort: 2 tuần. Phase 0 (làm sớm, cleaner foundation).

#### 8b. Model descriptor runtime
Structure trong DDR mailbox: `[N_layers (4B)] [layer_0_desc (32B)] [layer_1_desc (32B)] ...`. Layer descriptor = `{op_type, in_shape, out_shape, weight_addr, bias_addr, act_mode}`.

PS load descriptor + weights vào DDR. Pico đọc descriptor, dispatch op. Cùng 1 firmware chạy nhiều model không recompile.

- File mới: `sw/picorv32/src/model_descriptor.h`, `main_generic.c`.
- File mới (tools): `tools/model_to_descriptor.py` — sinh descriptor binary từ PyTorch model.
- Effort: 2 tuần. Phase 6.

#### 8c. ONNX → descriptor compiler
**OUT OF SCOPE.** Future work, mention in luận văn.

### Demo
Chạy 2 model trên cùng firmware: LeNet + 1 variant (ví dụ LeNet với 3 conv layers, hoặc tiny CIFAR-10 grayscale variant). Chứng minh "reconfigurable inference at runtime".

---

## Mapping table tổng kết

| # | Hạn chế | Giải pháp | File chính | Effort | Phase |
|---|---|---|---|---|---|
| 1 | FC underutilization | OS dataflow mode | `pe.v`, `data_path.v`, `control_unit.v` | 2-3 tuần | 3a |
| 2 | Memory wall | Scratchpad + Accumulator | `scratchpad.v`, `accumulator.v` (mới) | 3-4 tuần | 1a |
| 3a | SW K-acc | (bởi #2) | — | — | 1a |
| 3b | SW im2col | HW im2col module | `im2col.v` (mới) | 2 tuần | 2a |
| 3c | SW pool | HW pool stage | `post_proc.v` | 1 tuần | 2b |
| 3d | SW polling | Interrupt-driven | `accelerator.v`, block design | 0.5 tuần | 0 |
| 4 | No double buffer | Ping-pong banks | `scratchpad.v`, `control_unit.v` | 1 tuần | 1b |
| 5 | No sparsity | Operand isolation | `pe.v` | 1 tuần | 4 |
| 6a | MMIO 5 reg/tile | Register pack | `slave_lite` | 0.5 tuần | 0 |
| 6b | MMIO overhead | CISC loop descriptor | `control_unit.v`, `accelerator.v` | 2 tuần | 2c |
| 7a | No fault visibility | Fault injector | `fault_injector.v` (mới) | 1 tuần | 5a |
| 7b | FSM SEU | TMR FSM | `tmr_voter.v` (mới), `control_unit.v` | 1 tuần | 5b |
| 7c | Weight SEU | ECC SECDED | `ecc_*.v` (mới), `scratchpad.v` | 1.5 tuần | 5c |
| 8a | Hardcoded firmware | Operator library | `sw/picorv32/src/ops.c` (mới) | 2 tuần | 0 |
| 8b | Single model | Model descriptor | `model_descriptor.h`, `main_generic.c` | 2 tuần | 6 |

**Tổng effort: ~22 tuần (Tier 3).**

---

## Cross-references

- Phương pháp đo cho mỗi giải pháp: [evaluation_metrics.md](evaluation_metrics.md)
- Timeline triển khai chi tiết và success criteria: [implementation_plan.md](implementation_plan.md)
- Kiến trúc hiện tại (để biết "before" state): [system_description.md](system_description.md)
