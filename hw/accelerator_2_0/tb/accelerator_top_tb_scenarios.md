# accelerator_top_tb — Test Scenarios

Tham chiếu RTL: [hw/accelerator_2_0/hdl/accelerator.v](../hdl/accelerator.v)

End-to-end TB cho `accelerator` top wrapper. Drive 3 AXI interface (Lite + AXIS slave + AXIS master), so kết quả với Python golden.

---

## 1. AXI driver tasks (TB tự viết, không cần Vivado VIP)

### 1.1 AXI4-Lite master
```sv
task automatic axi_lite_write(input [31:0] addr, input [31:0] data);
    @(negedge clk);
    s00_axi_awvalid = 1; s00_axi_awaddr = addr[4:0]; s00_axi_awprot = 0;
    s00_axi_wvalid  = 1; s00_axi_wdata  = data; s00_axi_wstrb = 4'hF;
    @(posedge clk); while (!(s00_axi_awready && s00_axi_wready)) @(posedge clk);
    @(negedge clk);
    s00_axi_awvalid = 0; s00_axi_wvalid = 0;
    s00_axi_bready = 1;
    @(posedge clk); while (!s00_axi_bvalid) @(posedge clk);
    @(negedge clk); s00_axi_bready = 0;
endtask

task automatic axi_lite_read(input [31:0] addr, output [31:0] data);
    @(negedge clk);
    s00_axi_arvalid = 1; s00_axi_araddr = addr[4:0]; s00_axi_arprot = 0;
    s00_axi_rready  = 1;
    @(posedge clk); while (!s00_axi_arready) @(posedge clk);
    @(negedge clk); s00_axi_arvalid = 0;
    @(posedge clk); while (!s00_axi_rvalid)  @(posedge clk);
    data = s00_axi_rdata;
    @(negedge clk); s00_axi_rready = 0;
endtask
```

### 1.2 AXIS slave-side driver (= ta đóng vai DMA push data)
```sv
task automatic axis_push(input [31:0] data);
    @(negedge clk);
    s00_axis_tvalid = 1; s00_axis_tdata = data;
    s00_axis_tstrb  = 4'hF; s00_axis_tlast = 0;
    @(posedge clk); while (!s00_axis_tready) @(posedge clk);
    @(negedge clk); s00_axis_tvalid = 0;
endtask
```

### 1.3 AXIS master-side capture (= ta đóng vai DMA receive)
- Luôn assert `m00_axis_tready = 1` (no backpressure) để đơn giản.
- Process song song captures words khi `m00_axis_tvalid` cao.

```sv
initial m00_axis_tready = 1;

always @(posedge clk) begin
    if (m00_axis_tvalid && m00_axis_tready) begin
        captured_buf[capture_count] <= m00_axis_tdata;
        capture_count <= capture_count + 1;
        if (m00_axis_tlast) capture_done <= 1;
    end
end
```

---

## 2. Per-tile drive sequence

```
1. axi_lite_write(0x00, M);     // TILE_M_SIZE
2. axi_lite_write(0x04, K);     // TILE_K_SIZE
3. axi_lite_write(0x08, N);     // TILE_N_SIZE
4. axi_lite_write(0x0C, {ACT_MODE[1:0], 1'b1});  // CONTROL: START + ACT_MODE
5. // Drive AXIS slave: 32 weight word (8 rows × 4 word) + ⌈SA_N/2⌉=4 bias word + M×⌈K/2⌉ input word
   foreach pair in W_pairs: axis_push({W_odd, W_even});
   foreach pair in bias_pairs: axis_push({bias_odd, bias_even});
   foreach pair in A_pairs: axis_push({A_odd, A_even});
6. // Capture M × ⌈N/2⌉ output words via AXIS master.
7. wait STATUS.DONE = 1 via axi_lite_read(0x10).
8. unpack captured → 16-bit Q1.4.11 results.
9. compare with Python golden.
```

**LƯU Ý**: Weight luôn gửi full SA_N×SA_N = 32 word, zero-pad nếu K<8 hoặc N<8. Bias gửi full SA_N=8 element = 4 word.

---

## 3. Python golden generator extension

Cần file mới `tools/gen_top_tile.py` mở rộng từ `gen_gemm_golden.py`:
- Input: M, K, N, seed, ACT_MODE (0=bypass, 1=ReLU, 2=sigmoid), bias_seed.
- Compute: psum = A × W + bias (Q*.8.22), pipeline truncate/saturate y hệt RTL post_proc, apply activation (bypass/ReLU/sigmoid via reading sigmoid_rom.mem), saturate Q1.4.11.
- Output: A.hex, W.hex, bias.hex, golden.hex (Q1.4.11 output).

→ Bit-exact comparison với DUT.

---

## 4. Test cases

### Case 1 — Sanity 2×2×2 bypass (hardcoded)

A = `[[1, 2], [3, 4]]`, W = `[[5, 6], [7, 8]]` (Q1.4.11 raw integers cho gọn).

Bias = 0, ACT_MODE = bypass.

Expected (no truncate concerns vì values nhỏ):
- C[0][0] = 1×5 + 2×7 = 19
- C[0][1] = 1×6 + 2×8 = 22
- C[1][0] = 3×5 + 4×7 = 43
- C[1][1] = 3×6 + 4×8 = 50

(Q1.4.11 nhân Q1.4.11 → Q2.8.22 raw = 19×4194304 cho cell [0][0]. Sau truncate Q1.8.7 = 19×128 = 2432. Sau S3 <<<4 = 2432<<4 = 38912 = 0x9800 — NHƯNG vượt Q1.4.11 max → saturate 0x7FFF.)

→ Hmm, integer 19 quá lớn cho Q1.4.11 chuẩn (max 16). Nên dùng Q1.4.11 fractional values: A=[[0.1, 0.2],[0.3, 0.4]] real → raw [[204, 409],[614, 819]].

Pass criteria: 4/4 cell match exact.

### Case 2 — 3 ACT_MODE same input (4×4×4)

Cùng A, W, bias, run 3 lần với ACT_MODE = {bypass, ReLU, sigmoid}.

Verify:
- Bypass: C output = post_proc bypass result.
- ReLU: cells âm → 0, cells dương → giữ nguyên.
- Sigmoid: bit-exact với pipeline (sat Q1.3.6 → LUT → << 4).

Pass criteria: 16 cell × 3 mode = 48 check.

### Case 3 — Random sweep 50 tile (bypass)

50 cases với (M, K, N) random ∈ [1..8], seed = 42, ACT = bypass.

Generate qua `tools/gen_top_tile.py --M m --K k --N n --seed s --act 0`.

Pass criteria: 50/50 tile, mỗi tile M×N cell match.

### Case 4 — Back-to-back 2 tile (no re-init giữa 2 tile)

Tile A: 8×8×8 random seed 100, bypass.
Tile B: 8×8×8 random seed 101, bypass.

Sequence:
- Run tile A, đợi DONE.
- KHÔNG reset DUT.
- Re-write TILE_*_SIZE và CONTROL.
- Drive tile B data.
- Capture tile B output.

Pass criteria: tile A pass + tile B pass (verify no state leak từ tile A → tile B).

---

## 5. Tổng số check

| Case | Cells | Modes | Total |
|---|---|---|---|
| 1 | 4 (2×2) | 1 | 4 |
| 2 | 16 (4×4) | 3 | 48 |
| 3 | varies (1..64) per tile | 1 | ~50 tiles, ~1500 cells |
| 4 | 64 × 2 | 1 | 128 |
| **Total** | | | **~1700 check** |

Pass: `=== ALL ACCELERATOR TOP TESTS PASSED ===`. Fail: `=== N FAILURES ===`.

---

## 6. TB infrastructure

**Timeout watchdog**: 1ms (khá rộng vì 50 tile × ~200 cycle/tile = 10000 cycle = 100us). Đặt 2ms để an toàn.

**Race condition prevention**: Áp dụng kinh nghiệm từ post_proc_tb — drive/deassert ở **negedge**, không sau `@(posedge clk)`.

**Reset between cases**: Trong Case 1/2/3, reset DUT trước mỗi tile (chỉ Case 4 không reset).

---

## 7. File deliverables Bước 11

| File | Vai trò |
|---|---|
| `hw/accelerator_2_0/tb/accelerator_top_tb_scenarios.md` | Tài liệu này |
| `hw/accelerator_2_0/tb/accelerator_top_tb.sv` | TB code |
| `hw/accelerator_2_0/tb/data/case1_top_*.hex` | Sanity tile data |
| `hw/accelerator_2_0/tb/data/case2_*_top_*.hex` | 3 act mode tiles |
| `hw/accelerator_2_0/tb/data/sweep_NN_*.hex` | 50 random tile data (NN = 0..49) |
| `hw/accelerator_2_0/tb/data/case4_a_*.hex`, `case4_b_*.hex` | Back-to-back tiles |
| `tools/gen_top_tile.py` | Python golden generator (post_proc-aware) |
| `tools/gen_top_sweep.py` | Driver script sinh 50 case |
| `hw/accelerator_2_0/scripts/run_accelerator_top_tb.tcl` | Vivado runner |

---

## 8. Risk

| Vấn đề | Likelihood | Mitigation |
|---|---|---|
| AXI handshake bug (TB driver sai) | Med | Verify trên Case 1 sanity trước khi sweep |
| Sigmoid bit-exact mismatch (rounding) | Low | Đã verify trong Bước 8 — pipeline match exact |
| 50-tile sweep mất quá lâu (sim) | Low | Mỗi tile ~2us @ 100MHz → 50 tile ≈ 100us, OK |
| State leak giữa tile (Case 4 fail) | Med | Plan §6 đã thiết kế weight_load tự clear pipeline |
| Vivado xsim không tìm hex files | Low | Dùng absolute path như post_proc_tb |
