# post_proc_tb — Test Scenarios

Tham chiếu RTL: [hw/accelerator_2_0/hdl/post_proc.v](../hdl/post_proc.v)
Tham chiếu spec: [hw/accelerator_2_0/hdl/post_proc_spec.md](../hdl/post_proc_spec.md)

## Khái quát

5 case, ~25 check. TB test cả `post_proc` + `sigmoid_lookup` (instance bên trong) — không có TB riêng cho sigmoid LUT.

**Pipeline latency** = 3 cycle: drive `pi_valid_in=1` ở cycle `t` → `po_valid_out=1` ở cycle `t+3`.

**Reset xóa pipeline** → cần cycle gap nếu test ngắt quãng.

**Q-format conversions** (raw integer ↔ real):
- Q1.4.11: raw = real × 2048
- Q1.8.7: raw = real × 128
- Q1.3.6: raw = real × 64
- Q1.0.9: raw = real × 512
- Q*.8.22 (40b): raw = real × 4194304

Pass: in `=== ALL POST_PROC TESTS PASSED ===`. Fail: in `=== N FAILURES ===` cộng chi tiết từng case.

---

## Case 1 — Bypass mode (5 check)

Mode `2'b00`. Output = saturate(acc + bias) → Q1.4.11.

| Sub | acc (real) | bias (real) | sum | Expected po_data_out | Note |
|---|---|---|---|---|---|
| 1.1 | +1.0 | +0.5 | +1.5 | `0x0C00` | sum=1.5 → 1.5×2048=3072 |
| 1.2 | +10.0 | 0 | +10 | `0x5000` | =10×2048=20480 |
| 1.3 | +20.0 | 0 | +20 → sat+ | `0x7FFF` | overflow Q1.4.11 max |
| 1.4 | −20.0 | 0 | −20 → sat− | `0x8000` | underflow Q1.4.11 min |
| 1.5 | +0 | +15.999 (raw `0x7FF8`) | +15.999 | `0x7FF0` | S1 truncate Q*.8.22→Q1.8.7 mất 4 LSB → bias `0x7FF8`→`0x07FF` Q1.8.7 → S3 `<<4`= `0x7FF0` |

---

## Case 2 — ReLU mode (4 check)

Mode `2'b01`. Output = saturate(max(acc + bias, 0)) → Q1.4.11.

| Sub | acc | bias | Sum | Expected | Note |
|---|---|---|---|---|---|
| 2.1 | +2.0 | 0 | +2 | `0x1000` | positive pass-through |
| 2.2 | −2.0 | 0 | −2 | `0x0000` | negative → 0 |
| 2.3 | +2.0 | −3.0 | −1 | `0x0000` | sum negative → 0 |
| 2.4 | +20 | 0 | +20 → sat+ | `0x7FFF` | saturation through ReLU |

---

## Case 3 — Sigmoid mode (7 check)

Mode `2'b10`. Output computed bit-exact qua pipeline:
- `s1_reg = sat_q187(acc + bias)` (Q1.8.7)
- `sig_addr = sat_q187_to_q136(s1_reg)` (Q1.3.6)
- `sig_data = ROM[sig_addr]` (Q1.0.9)
- `sig_q187 = {8'b0, sig_data[9:2]}` (Q1.8.7, raw = sig_data >> 2)
- `s3_reg = sig_q187 << 4` (Q1.4.11)

Expected = pipeline-exact (KHÔNG so với float sigmoid). LUT giá trị từ `hw/accelerator_2_0/hdl/sigmoid_rom.mem`.

| Sub | x = acc | sig_addr | ROM[addr] (Q1.0.9) | sig_q187 | Expected po_data_out | sigmoid(x) ref |
|---|---|---|---|---|---|---|
| 3.1 | 0       | `0x000` | 256 (`0x100`) | `0x0040` | `0x0400` (= 0.5)        | 0.5000 |
| 3.2 | +1.0    | `0x040` | 374 (`0x176`) | `0x005D` | `0x05D0` (≈ 0.727)      | 0.7311 |
| 3.3 | −1.0    | `0x3C0` | 138 (`0x08A`) | `0x0022` | `0x0220` (≈ 0.266)      | 0.2689 |
| 3.4 | +4.0    | `0x100` | 503 (`0x1F7`) | `0x007D` | `0x07D0` (≈ 0.977)      | 0.9820 |
| 3.5 | −4.0    | `0x300` |   9 (`0x009`) | `0x0002` | `0x0020` (≈ 0.0156)     | 0.0180 |
| 3.6 | +8.0 → sat+ | `0x1FF` | 511 (`0x1FF`) | `0x007F` | `0x07F0` (≈ 0.992)  | 0.99966 |
| 3.7 | −8.0    | `0x200` |   0 (`0x000`) | `0x0000` | `0x0000` (= 0)          | 0.000335 |

**Tolerance**: bit-exact (so với pipeline simulation, không float).

Note: sai số tối đa ~15 LSB Q1.4.11 so với float sigmoid (do mất 2 LSB ở Q1.0.9 → Q1.8.7 conversion).

---

## Case 4 — Bias precision (4 check, mode bypass)

Verify bias upcast Q1.4.11 → Q*.8.22 KHÔNG mất precision LSB.

| Sub | acc | bias (Q1.4.11) | bias raw | Expected po_data_out |
|---|---|---|---|---|
| 4.1 | 0 | +1.0 | `0x0800` | `0x0800` (= 1.0) |
| 4.2 | 0 | smallest survives (`0x0010` = 1/128) | `0x0010` | `0x0010` |
| 4.3 | +1.0 | −1.0 | `0xF800` | `0x0000` (sum cancel) |
| 4.4 | +0.5 | +0.25 | `0x0200` | `0x0600` (= 0.75) |

**Precision floor**: bias < `0x0010` (= 1 LSB Q1.8.7 = 16 LSB Q1.4.11 = 1/128 real) **mất hoàn toàn** ở S1 truncation. Đây là design constraint do internal pipeline Q1.8.7 chỉ có 7 frac bits (vs Q1.4.11 11 frac bits → mất 4 LSB precision).

---

## Case 5 — Pipeline timing (5 check, mode bypass)

Drive 5 sample liên tiếp với `pi_valid_in=1` mỗi cycle, verify:
- Cycle 0–4: `pi_valid_in=1`, drive 5 acc khác nhau
- Cycle 3: `po_valid_out` lần đầu = 1 (3-cycle latency)
- Cycle 3–7: `po_valid_out=1` 5 lần liên tiếp (no stall)
- Cycle 8+: `po_valid_out=0`

| Cycle | pi_valid_in | acc | po_valid_out | po_data_out |
|---|---|---|---|---|
| 0 | 1 | +1 | 0 | x |
| 1 | 1 | +2 | 0 | x |
| 2 | 1 | +3 | 0 | x |
| 3 | 1 | +4 | 1 | `0x0800` (= +1) |
| 4 | 1 | +5 | 1 | `0x1000` (= +2) |
| 5 | 0 | x | 1 | `0x1800` (= +3) |
| 6 | 0 | x | 1 | `0x2000` (= +4) |
| 7 | 0 | x | 1 | `0x2800` (= +5) |
| 8 | 0 | x | 0 | x |

→ Verify throughput 1 sample/cycle.

---

## Cấu trúc TB

```sv
module post_proc_tb;
    // Tham số
    localparam CLK_PERIOD = 10;
    
    // Signals
    reg clk = 0; reg rst_n; ...
    wire [15:0] po_data_out; wire po_valid_out;
    
    // DUT
    post_proc dut (...);
    
    // Helper task
    task automatic check_one(
        input string  name,
        input [39:0]  acc,
        input [15:0]  bias,
        input [1:0]   mode,
        input [15:0]  expected
    );
        // Wait negedge, drive inputs, valid=1
        // Wait 3 cycles (latency)
        // Capture po_data_out, compare with expected
        // Print [OK]/[FAIL]
    endtask
    
    // Helper task: drive 5 back-to-back (Case 5)
    task automatic check_pipeline_timing();
        // Drive 5 samples, monitor po_valid_out cycle by cycle
    endtask
    
    initial begin
        // Reset
        // Case 1: 5 calls to check_one (bypass)
        // Case 2: 4 calls (ReLU)
        // Case 3: 7 calls (sigmoid, with reset between to clear pipeline)
        // Case 4: 4 calls (bias precision, bypass)
        // Case 5: check_pipeline_timing()
        // Summary
    end
    
    // Timeout watchdog
endmodule
```

**Reset between cases**: Mỗi case khởi đầu bằng 1 cycle `pi_valid_in=0` để pipeline drain. Không cần `rst_n` toggle.

**File deliverables Bước 8**:
- `hw/accelerator_2_0/tb/post_proc_tb.sv`
- `hw/accelerator_2_0/scripts/run_post_proc_tb.tcl`
- (`hw/accelerator_2_0/tb/post_proc_tb_scenarios.md` — file này)

Sigmoid LUT load tự động via `$readmemh("sigmoid_rom.mem", rom)` initial trong `sigmoid_lookup.v` — TB không cần load thủ công.