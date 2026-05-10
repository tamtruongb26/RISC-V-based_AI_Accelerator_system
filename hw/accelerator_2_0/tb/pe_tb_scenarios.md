# `pe_tb.sv` — Test Scenarios

**DUT**: [hw/accelerator_2_0/hdl/pe.v](../hdl/pe.v) — TPU canonical Processing Element.

**Mục tiêu**: verify từng hành vi của PE độc lập trước khi tích hợp vào data_path/grid.

**Tham số TB**: `DATA_WIDTH=16`, `ACC_WIDTH=40`, `CLK_PERIOD=10ns` (100 MHz).

**Format Q1.4.11** (16-bit signed): `value × 2^11` thành integer.
- `1.0  = 16'sd2048  = 16'h0800`
- `2.0  = 16'sd4096  = 16'h1000`
- `0.5  = 16'sd1024  = 16'h0400`
- `-1.0 = -16'sd2048 = 16'hF800`
- `-2.0 = -16'sd4096 = 16'hF000`
- `+15.99951 ≈ 16'sd32767 = 16'h7FFF` (max Q1.4.11)
- `-16.0  = -16'sd32768 = 16'h8000` (min Q1.4.11)

**Format Q2.8.22** (32-bit signed, kết quả 1 phép nhân Q1.4.11×Q1.4.11): `value × 2^22`.
- `1.0×1.0 = 1.0   → 32'sd4194304   = 32'h00400000`
- `2.0×2.0 = 4.0   → 32'sd16777216  = 32'h01000000`
- `1.0×(-1.0) = -1 → 32'sh-400000   = 32'hFFC00000`
- Sign-extend 32-bit → 40-bit: prepend 8 bit dấu.

---

## Khung TB

```
DUT pe (DATA_WIDTH=16, ACC_WIDTH=40)
  ├─ pi_clk          ←  TB free-running clock
  ├─ pi_rst_n        ←  TB control
  ├─ pi_weight_load  ←  TB control
  ├─ pi_w_in         ←  TB control (weight Q1.4.11)
  ├─ pi_a_in         ←  TB control (activation Q1.4.11)
  ├─ pi_valid_in     ←  TB control
  ├─ pi_psum_in      ←  TB control (psum 40-bit)
  ├─ po_a_out        →  TB check
  ├─ po_valid_out    →  TB check
  └─ po_psum_out     →  TB check
```

**Helper task**: `check(name, signal, expected)` — in `[OK]/[FAIL]`, đếm `errs`.

**Convention timing**: drive stimulus tại `negedge clk`, check output tại `posedge clk + 1ns delta`.

---

## Case 1 — Reset clear all registers

**Mục đích**: sau reset (`pi_rst_n=0`), tất cả output phải về 0.

| Cycle | Stimulus | Expected output |
|---|---|---|
| t=0 | `rst_n=0`, mọi input = 0 | `po_a_out=0`, `po_valid_out=0`, `po_psum_out=0` |
| t=20ns | giữ `rst_n=0`, qua 2 clock | giữ output = 0 |
| t=22ns | `rst_n=1` ↑ | check output vẫn = 0 |

**Pass criteria**: 3 check `[OK]`.

---

## Case 2 — `weight_load` latches weight và clear pipeline

**Mục đích**: pulse `weight_load=1` 1 cycle phải:
- Latch `pi_w_in` vào `w_reg` (verify gián tiếp qua MAC ở case 4).
- Clear `a_reg`, `valid_reg`, `psum_reg` về 0 (kể cả khi đang có giá trị từ trước).

| Cycle | Stimulus | Expected sau `posedge clk` |
|---|---|---|
| t1 (sau reset) | `pi_a_in=0x0800 (1.0)`, `pi_valid_in=1`, `pi_psum_in=0`, weight_load=0 | (chuẩn bị có giá trị trong pipeline) |
| t2 | giữ stimulus | `po_a_out=0x0800`, `po_valid_out=1`, `po_psum_out=...` (giá trị MAC nhỏ) |
| t3 | `pi_weight_load=1`, `pi_w_in=0x1000 (2.0)`, các input khác giữ | (cycle pulse) |
| t4 | `pi_weight_load=0`, mọi input = 0 | `po_a_out=0`, `po_valid_out=0`, `po_psum_out=0` (đã clear) |

**Pass criteria**: cycle t4 cả 3 output = 0.

---

## Case 3 — Horizontal `a` pass-through (registered, 1-cycle delay)

**Mục đích**: drive `pi_a_in=X` 1 cycle, sau đúng 1 cycle `po_a_out=X`. Tương tự `valid`.

**Cần**: w_reg đã được clear (load weight = 0 ở case 2 mới xong).

| Cycle | Stimulus | Expected sau `posedge clk` |
|---|---|---|
| t1 | `pi_a_in = 16'sd123`, `pi_valid_in=1`, `pi_psum_in=0`, weight_load=0, w_reg=0 | (chưa registered ra outputs) |
| t2 | mọi input = 0 | `po_a_out=123`, `po_valid_out=1`, `po_psum_out = 0+123*0 = 0` |
| t3 | mọi input = 0 | `po_a_out=0`, `po_valid_out=0`, `po_psum_out = 0+0*0 = 0` |

**Pass criteria**: t2 thấy giá trị `123` ở `po_a_out` và `1` ở `po_valid_out`. t3 thấy chúng về 0.

---

## Case 4 — MAC khi `valid_in=1` (cộng dồn 1-cycle latency)

**Mục đích**: load `w_reg=2.0`, drive 1 mẫu MAC, kết quả = `psum_in + a*w`.

**Setup**:
- weight_load 1 cycle: `pi_w_in = 16'sd4096 (2.0 in Q1.4.11)`.

**Sequence**:

| Cycle | Stimulus | Expected sau `posedge clk` |
|---|---|---|
| t1 | weight_load=1, `pi_w_in=4096`, valid_in=0, a_in=0, psum_in=0 | (pulse, không output gì) |
| t2 | weight_load=0, mọi input còn lại = 0 | `po_a_out=0`, `po_valid_out=0`, `po_psum_out=0` |
| t3 | `pi_a_in = 16'sd2048 (1.0)`, `pi_valid_in=1`, `pi_psum_in = 40'sd1000` | (chưa kịp register) |
| t4 | mọi input = 0 | `po_a_out=2048`, `po_valid_out=1`, **`po_psum_out = 1000 + (2048×4096) = 1000 + 8388608 = 8389608`** |

**Tính `2048 × 4096 trong Q2.8.22`**: `1.0 × 2.0 = 2.0` trong Q2.8.22 = `2 × 2^22 = 8388608` ✓.

**Pass criteria**: `po_psum_out == 8389608`.

---

## Case 5 — Pass-through khi `valid_in=0` (KHÔNG cộng MAC)

**Mục đích**: với `pi_valid_in=0`, dù `a_in` và `w_reg` có giá trị, psum chỉ pass `pi_psum_in` qua không cộng.

**Tiếp ngay sau Case 4** (w_reg vẫn = 2.0).

| Cycle | Stimulus | Expected sau `posedge clk` |
|---|---|---|
| t5 | `pi_a_in = 16'sd2048`, `pi_valid_in=0`, `pi_psum_in = 40'sd5000` | (drive) |
| t6 | mọi input = 0 | `po_a_out=2048` (a vẫn advance), `po_valid_out=0`, **`po_psum_out = 5000`** (KHÔNG có MAC) |

**Pass criteria**: `po_psum_out == 5000` (NOT `5000 + 8388608`).

---

## Case 6 — Signed multiply (4 sub-case)

**Mục đích**: kiểm tra dấu của tích đúng trong cả 4 tổ hợp.

**Setup chung**: load `w_reg=W`, drive `a_in=A, valid_in=1, psum_in=0`. Sau 1 cycle check `po_psum_out = A*W` (Q2.8.22 sign-extend 40-bit).

| Sub-case | W (hex / value) | A (hex / value) | Expected po_psum_out |
|---|---|---|---|
| 6a (+×+) | 0x0800 (+1.0) | 0x1000 (+2.0) | `+2.0` Q2.8.22 = `+8388608` |
| 6b (+×−) | 0x0800 (+1.0) | 0xF000 (−2.0) | `−2.0` Q2.8.22 = `−8388608` |
| 6c (−×+) | 0xF800 (−1.0) | 0x1000 (+2.0) | `−2.0` Q2.8.22 = `−8388608` |
| 6d (−×−) | 0xF000 (−2.0) | 0xF000 (−2.0) | `+4.0` Q2.8.22 = `+16777216` |

**Sequence per sub-case**:
1. weight_load=1, pi_w_in=W (1 cycle pulse).
2. weight_load=0, a_in=A, valid_in=1, psum_in=0 (1 cycle).
3. mọi input=0; check po_psum_out = expected.

**Pass criteria**: 4 check `[OK]`.

---

## Case 7 — Boundary Q1.4.11 max × max (overflow check)

**Mục đích**: tích max × max không tràn 40-bit, sign-extend đúng.

**Setup**:
- w_reg = `0x7FFF` (= 32767, gần +16.0 trong Q1.4.11).
- a_in = `0x7FFF` (= 32767).
- psum_in = 0, valid_in = 1.

**Tính**: `32767 × 32767 = 1073676289`. Đây là Q2.8.22 = `1073676289 / 2^22 ≈ 255.99` (≈ +256, gần biên Q2.8.22 max là `+512`).
- 32-bit signed: `0x3FFF0001` (positive, không tràn).
- Sign-extend 40-bit: `0x003FFF0001`.

**Sequence**:
| Cycle | Stimulus | Expected |
|---|---|---|
| t1 | weight_load=1, pi_w_in=0x7FFF | (pulse) |
| t2 | weight_load=0, a_in=0x7FFF, valid_in=1, psum_in=0 | (drive) |
| t3 | mọi input=0 | `po_psum_out = 40'h003FFF0001 = 1073676289` |

**Sub-case 7b** — neg max × neg max:
- w_reg = `0x8000` (-16.0), a_in = `0x8000` (-16.0).
- `(-32768) × (-32768) = +1073741824` → `0x40000000` (32-bit), sign-extend → `0x0040000000`.
- Expected `po_psum_out = 1073741824`.

**Pass criteria**: 2 check `[OK]`. Quan trọng nhất là sign-extend không bị truncate.

---

## Tổng kết

- Tổng số check: 3 (case 1) + 1 (case 2) + 3 (case 3) + 1 (case 4) + 1 (case 5) + 4 (case 6) + 2 (case 7) = **15 check**.
- TB sẽ in `[OK]/[FAIL]` từng check + tổng cuối:
  - `=== ALL PE TESTS PASSED ===` nếu errs=0
  - `=== <N> FAILURES ===` nếu errs>0
- Timeout 2000 ns (200 cycle) — đủ dư.

## File output

- `hw/accelerator_2_0/tb/pe_tb.sv` — TB code SystemVerilog.
- `hw/accelerator_2_0/scripts/run_pe_tb.tcl` — TCL load + launch sim trong Vivado GUI.
