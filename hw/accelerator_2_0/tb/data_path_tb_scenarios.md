# `data_path_tb.sv` — Test Scenarios

**DUT**: [hw/accelerator_2_0/hdl/data_path.v](../hdl/data_path.v) — TPU canonical SA_N×SA_N grid, instance với `SA_N=8, DATA_WIDTH=16, ACC_WIDTH=40`.

**Mục tiêu**: verify dataflow systolic — a chảy ngang, psum chảy dọc, valid chain đồng bộ — qua 3 case GEMM với golden từ Python.

---

## 1. Hiểu timing trước khi test

### Skewed input feed (firmware drive vào `pi_a_left`):

Với SA_N=8, tại cycle `cmp_t` (đếm từ 0 sau khi load weight xong):
```
for r in 0..SA_N-1:
    if r < K_used and 0 ≤ cmp_t - r < M_used:
        pi_a_left[r] = A[cmp_t - r][r]
        pi_valid_left[r] = 1            ← driven valid
    else:
        pi_a_left[r] = 0
        pi_valid_left[r] = 1            ← VẪN driven valid (xem note dưới)
```

**Note quan trọng**: `pi_valid_left[r]` phải = 1 cho TẤT CẢ `r` trong COMPUTE state, kể cả `r >= K_used`. Lý do:
- `po_valid_bottom[c] = valid_h[SA_N-1][c+1]` lấy valid từ row đáy SA_N-1.
- Nếu chỉ drive valid cho `r < K_used`, valid không tới được row đáy → `po_valid_bottom` không bao giờ = 1.
- Khi `r >= K_used`, `pi_a_left[r]=0` nên MAC contribution = 0 (vì weight ở row đó cũng = 0 do firmware zero-pad).

### Output capture timing:

`C[m][n]` xuất hiện tại `psum_v[SA_N][n]` (= `po_psum_bottom[n]`) tại cycle:
```
cmp_t_capture = m + n + SA_N - 1
```

Lý do: psum chain có **SA_N register stages** (luôn cố định), không phải K_used. Hoạt động như sau:
- `A[m][r]` vào `PE(r, 0)` tại `cmp_t = m + r`.
- MAC tại `PE(r, n)` tại `cmp_t = m + r + n`.
- Sau hàng PE thứ K-1 (row có weight thật), psum đã = `C[m][n]`.
- Pass qua thêm `SA_N - K_used` row (rows ≥ K) — toàn passthrough vì `weight=0` nên `mult=0`.
- Tới `psum_v[SA_N][n]` tại `cmp_t = m + (SA_N-1) + n = m + n + SA_N - 1`.

`po_valid_bottom[n]` đồng pha 1:1 với `po_psum_bottom[n]`.

### Tổng số cycle 1 tile M×K×N (sau khi load weight xong):
```
total_cycles = M + N + SA_N - 1
```

Với 8×8×8: `8 + 8 + 8 - 1 = 23` cycle.

---

## 2. Khung TB

```
DUT data_path #(SA_N=8, DATA_WIDTH=16, ACC_WIDTH=40)
  ├─ pi_clk
  ├─ pi_rst_n
  ├─ pi_weight_load
  ├─ pi_weight_row_sel  [3:0]      ← chọn row 0..7
  ├─ pi_weight_data     [127:0]    ← 8 weight × 16 bit = 128 bit
  ├─ pi_a_left          [127:0]    ← 8 activation × 16 bit
  ├─ pi_valid_left      [7:0]
  ├─ po_psum_bottom     [319:0]    → 8 column × 40 bit = 320 bit
  └─ po_valid_bottom    [7:0]
```

**Helper task / function**:
- `reset_dut()` — toggle rst_n
- `load_weight_row(row, w[8])` — pulse weight_load 1 cycle với row_sel + weight_data packed
- `load_all_weights(W[8][8])` — gọi `load_weight_row` 8 lần, sau đó 1 cycle weight_load=0
- `drive_skewed_compute(A[8][8], M, K)` — drive pi_a_left + valid skewed feed cho M+N+SA_N-1 cycle, trong khi capture `po_psum_bottom[c]` mỗi cycle có `po_valid_bottom[c]==1`
- `compare_C(C_got[8][8], C_exp[8][8], M, N)` — check từng phần tử với golden

**Format file golden** (sinh bằng `tools/gen_gemm_golden.py`):
- `A.hex` — `M*K` dòng hex 16-bit (Q1.4.11), row-major.
- `W.hex` — `K*N` dòng hex 16-bit, row-major (W[r][c] thứ tự: row 0 col 0..N-1, row 1 col 0..N-1, ...).
- `C.hex` — `M*N` dòng hex 40-bit (Q2.8.22), row-major.

---

## 3. Test cases

### Case 1 — Sanity 2×2×2 GEMM lồng trong 8×8 grid

**Mục đích**: verify dataflow trên ví dụ tay-tính được.

**Input**:
- A (8×8, Q1.4.11 raw integer):
  ```
  [[1, 2, 0, 0, 0, 0, 0, 0],
   [3, 4, 0, 0, 0, 0, 0, 0],
   [0, 0, ...],   ← rows 2-7 zero-pad (không drive vì M=2)
  ]
  ```
- W (8×8, Q1.4.11 raw integer):
  ```
  [[5, 6, 0, 0, 0, 0, 0, 0],
   [7, 8, 0, 0, 0, 0, 0, 0],
   [0, 0, ...],   ← rows 2-7 zero-pad
  ]
  ```

**Expected C** (8×8, raw integer trong domain Q1.4.11×Q1.4.11 = Q2.8.22):
```
C[0][0] = 1*5 + 2*7 = 19
C[0][1] = 1*6 + 2*8 = 22
C[1][0] = 3*5 + 4*7 = 43
C[1][1] = 3*6 + 4*8 = 50
C[m][n] = 0 cho mọi cell khác (do zero-pad)
```

**Sequence**:
1. Reset DUT.
2. Load 8 weight rows. Row 0 = `{0,0,0,0,0,0,6,5}` (col 0=LSB), row 1 = `{0,0,0,0,0,0,8,7}`, row 2-7 = all 0.
3. Compute phase: 23 cycle (= M+N+SA_N-1 = 2+2+8-2 = 10? Hmm với M=2, N=2 thì M+N+SA_N-1 = 11).
   - Wait formula: M+N+SA_N-1. Nhưng SA_N=8 cố định, M_used=2, N_used=2. Last C[1][1] tại `cmp_t = m+n+SA_N-1 = 1+1+7 = 9`. Cần chạy ≥ 10 cycle.
4. Capture `po_psum_bottom[c]` tại các cycle có `po_valid_bottom[c]==1`. Theo formula:
   - cycle 7: (m+0+7=7 → m=0, n=0) → C[0][0] = 19 trên column 0
   - cycle 8: m=1, n=0 → C[1][0] = 43 trên column 0; m=0, n=1 → C[0][1] = 22 trên column 1
   - cycle 9: m=1, n=1 → C[1][1] = 50 trên column 1
   - Các column khác (n=2..7): vì N_used=2, weight cột 2..7 = 0 → psum = 0. Vẫn capture nhưng expect = 0.

**Pass criteria**: 4 cell (M*N=4) khớp golden. Các cell khác = 0.

---

### Case 2 — Random 8×8×8 GEMM

**Mục đích**: verify đầy đủ dataflow với ma trận random, golden Python.

**Input**:
- `A_q11.hex` (64 dòng): A 8×8 random ∈ [-1.5, +1.5], quantized Q1.4.11. Seed = 42.
- `W_q11.hex` (64 dòng): W 8×8 random tương tự. Seed = 43.

**Expected**:
- `C_q22.hex` (64 dòng, mỗi 40-bit): `C = A_q @ W_q` integer multiply, không saturate, không truncate.
- Computed in Python: `C[m][n] = sum_k A_q[m][k] * W_q[k][n]`, k=0..7.

**Sequence**:
1. Reset DUT.
2. Load 8 weight rows.
3. Compute phase: 23 cycle (M+N+SA_N-1 = 8+8+8-1).
4. Capture toàn bộ output trong 64 cycle (an toàn) — store vào `C_got[8][8]`.

**Pass criteria**: 64 phần tử khớp golden Python (exact match, không tolerance vì integer arithmetic).

---

### Case 3 — Back-to-back 2 tile (verify clear giữa tile)

**Mục đích**: load tile mới ngay sau tile cũ, đảm bảo `weight_load` clear pipeline → kết quả tile 2 không bị "leak" từ tile 1.

**Sequence**:
1. Tile 1: load A1, W1, compute, capture C1. Verify C1.
2. KHÔNG reset DUT giữa 2 tile.
3. Tile 2: load A2 (khác A1), W2 (khác W1), compute, capture C2. Verify C2.

**Pass criteria**: cả C1 và C2 đều khớp golden tương ứng.

---

## 4. Tổng số check

- Case 1: 4 cell golden khớp (C[0..1][0..1]) + 60 cell zero (C[m][n] còn lại) = **64 check**.
- Case 2: **64 check**.
- Case 3: **64 + 64 = 128 check** (tile 1 + tile 2).

**Tổng**: **256 check**.

TB sẽ in `[OK]/[FAIL]` rút gọn dạng "case <N>: <pass>/<total>". In chi tiết FAIL nếu có. Cuối:
- `=== ALL DATA_PATH TESTS PASSED ===` nếu errs=0.
- `=== <N> DATA_PATH FAILURES ===` nếu errs>0.

**Timeout**: 20 µs (đủ cho 3 tile × ~30 cycle/tile + margin).

---

## 5. Files cần tạo

1. **`tools/gen_gemm_golden.py`** — sinh A, W, C hex files cho từng case:
   - Args: `--M --K --N --seed --out_dir --case_name`.
   - Output: `<out_dir>/case<N>_A.hex`, `_W.hex`, `_C.hex`.

2. **`hw/accelerator_2_0/tb/data_path_tb.sv`** — TB code đọc 3 cặp file (case 1 hardcoded, case 2 từ file, case 3 từ 2 cặp file).

3. **`hw/accelerator_2_0/scripts/run_data_path_tb.tcl`** — TCL runner tạo project + add files + launch sim, giống `run_pe_tb.tcl`.

4. **Generated test data** trong `hw/accelerator_2_0/tb/data/`:
   - `case1_A.hex`, `case1_W.hex`, `case1_C.hex` (small 2×2×2 in 8×8 frame)
   - `case2_A.hex`, `case2_W.hex`, `case2_C.hex` (8×8×8 random seed=42)
   - `case3a_A.hex`, ..., `case3b_A.hex`, ... (2 tile back-to-back, different seeds)

---

## 6. Notes triển khai

**Đọc hex files trong TB**:
```sv
reg [DATA_WIDTH-1:0]  A_q [0:SA_N*SA_N-1];   // flatten row-major
reg [ACC_WIDTH-1:0]   C_exp [0:SA_N*SA_N-1];
initial $readmemh("case2_A.hex", A_q);
initial $readmemh("case2_C.hex", C_exp);
```

Path file hex: dùng đường tương đối từ thư mục launch sim (`sim_projects/data_path_tb_proj/...sim/sim_1/behav/xsim/`). Trick là copy hex vào thư mục đó hoặc dùng đường tuyệt đối trong `$readmemh`. Plan dùng đường **tuyệt đối** trong TB hoặc set `xsim.simulate.xsim.more_options` → `-sv_root` cho đỡ phụ thuộc.

Đơn giản nhất: hardcode đường tuyệt đối trong TB:
```sv
$readmemh("/home/tam/Documents/RAAS/hw/accelerator_2_0/tb/data/case2_A.hex", A_q);
```

**Skewed feed driver** (pseudo-code):
```sv
for (cmp_t = 0; cmp_t < M_used + K_used + SA_N - 1; cmp_t++) begin
    @(negedge clk);
    pi_valid_left = 8'hFF;   // luôn valid khi compute
    for (r = 0; r < SA_N; r++) begin
        if (r < K_used && cmp_t >= r && (cmp_t - r) < M_used)
            pi_a_left[r*16 +: 16] = A_q[(cmp_t-r)*SA_N + r];  // A[cmp_t-r][r]
        else
            pi_a_left[r*16 +: 16] = 16'd0;
    end
    @(posedge clk);
    #1;
    // capture
    for (n = 0; n < SA_N; n++) begin
        if (po_valid_bottom[n]) begin
            // m = cmp_t - n - (SA_N-1)
            integer m_cap;
            m_cap = cmp_t - n - (SA_N - 1);
            if (m_cap >= 0 && m_cap < M_used && n < N_used)
                C_got[m_cap*SA_N + n] = po_psum_bottom[n*40 +: 40];
        end
    end
end
```

---

## 7. Pass criteria tổng

- 256 check pass.
- Tcl Console in `=== ALL DATA_PATH TESTS PASSED ===`.
- Sim time < 20 µs (timeout watchdog).
