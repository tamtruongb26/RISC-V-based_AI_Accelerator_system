# post_proc — Design Spec

## 1. Mục đích

Module **post-processing** giữa data_path (40-bit psum Q2.8.22) và AXIS master output (16-bit Q1.4.11). Thực hiện 3 việc:
1. **Cộng bias** vào psum.
2. **Activation**: bypass / ReLU / sigmoid (từ LUT).
3. **Saturate** kết quả về Q1.4.11 chuẩn output.

Pipeline 3 cycle, 1 mẫu/cycle (no stall).

---

## 2. Q-format pipeline

```
   pi_acc_in (40b Q*.8.22)──┐
   pi_bias   (16b Q1.4.11) ─┴─► [S1 add+truncate+sat] ──► s1_reg (16b Q1.8.7)
                                                              │
                                                              ▼
                                                  ┌── s1_reg ─┴──┐
                                                  │              │
                                          [S2 ReLU/bypass]   [S2 sigmoid_lookup]
                                                  │              │ (1-cycle ROM)
                                                  ▼              ▼
                                               s2_pass_reg     sig_data
                                               (Q1.8.7)        (Q1.0.9)
                                                  └──────┬───────┘
                                                         ▼
                                              [S3 mux + sat to Q1.4.11]
                                                         │
                                                         ▼
                                                   po_data_out (16b Q1.4.11)
```

### Q-format sizes

| Format | Bits | Sign | Int | Frac | Range | Step |
|---|---|---|---|---|---|---|
| `Q1.4.11` (input/output) | 16 | 1 | 4 | 11 | ±16 | 1/2048 ≈ 4.9e-4 |
| `Q1.8.7` (internal pipeline) | 16 | 1 | 8 | 7 | ±256 | 1/128 ≈ 7.8e-3 |
| `Q*.8.22` (psum, "Q2.8.22") | 40 | 1 | 17 | 22 | ±2^17 | 1/2^22 ≈ 2.4e-7 |
| `Q1.3.6` (sigmoid addr) | 10 | 1 | 3 | 6 | ±8 | 1/64 |
| `Q1.0.9` (sigmoid data) | 10 | 0 | 0 | 9 | [0, 1) | 1/512 |

### Lý do internal Q1.8.7

- Đủ headroom (±256) cho psum sau khi cộng bias mà không tràn.
- Vẫn 16-bit (LUT/saturate logic gọn).
- Khi đi qua sigmoid LUT (Q1.3.6), saturate xuống ±8 là chính xác cho vùng "active" của sigmoid.

### ⚠️ Precision floor

S1 truncate Q*.8.22 → Q1.8.7 **mất 4 LSB so với Q1.4.11** (11 frac bits của input/bias → 7 frac bits internal). Hệ quả:
- Bias < `0x0010` Q1.4.11 (= 1/128 real ≈ 0.0078) **mất hoàn toàn** sau truncation.
- Output cuối có 4 LSB Q1.4.11 luôn `0` (do `<<< 4` cuối S3).

→ Firmware nên scale bias ≥ 1/128 để tránh bị truncate về 0.

---

## 3. Module interface

```verilog
module post_proc (
    input  wire         pi_clk,
    input  wire         pi_rst_n,

    // ── Input từ data_path (1 sample/cycle) ──
    input  wire [39:0]  pi_acc_in,         // Q*.8.22 (Q2.8.22)
    input  wire [15:0]  pi_bias,           // Q1.4.11
    input  wire         pi_valid_in,
    input  wire [1:0]   pi_act_mode,       // 00=bypass, 01=ReLU, 10=sigmoid

    // ── Output (1 sample/cycle, 3 cycle sau) ──
    output wire [15:0]  po_data_out,       // Q1.4.11
    output wire         po_valid_out
);
```

- Latency: **3 cycle** từ `pi_valid_in=1` tới `po_valid_out=1`.
- Throughput: **1 sample/cycle** (full pipeline, no stall).
- `pi_act_mode = 2'b11` reserved (dùng làm bypass mặc định nếu firmware ghi sai).

---

## 4. Stage 1 — Add bias + truncate + saturate (combinational, registered ở cuối)

### Logic
```verilog
// Bước 1.1: extend bias từ 16-bit Q1.4.11 → 40-bit Q*.8.22 (full-precision)
wire signed [39:0] bias_q40 = {{13{pi_bias[15]}}, pi_bias, 11'b0};
//   13 sign-extension bits + 16-bit bias + 11 zero LSB

// Bước 1.2: 40-bit signed add (no overflow check — psum đã có 40-bit headroom)
wire signed [39:0] sum_q40 = $signed(pi_acc_in) + bias_q40;

// Bước 1.3: truncate Q*.8.22 → Q*.8.7 (drop 15 LSB), kết quả 25-bit
wire signed [24:0] sum_q187_wide = sum_q40[39:15];
//   Đây là Q1.17.7 (1 sign + 16 int + 7 frac).

// Bước 1.4: saturate Q1.17.7 → Q1.8.7 (16-bit)
//   Fits iff bits [24:15] đều giống nhau (all-0 hoặc all-1).
//   |value| ≥ 256 → saturate.
reg signed [15:0] s1_comb;
always @(*) begin
    if (sum_q187_wide[24:15] == 10'h000)         s1_comb = sum_q187_wide[15:0]; // small positive
    else if (sum_q187_wide[24:15] == 10'h3FF)    s1_comb = sum_q187_wide[15:0]; // small negative
    else if (sum_q187_wide[24] == 1'b0)          s1_comb = 16'h7FFF;            // overflow +
    else                                          s1_comb = 16'h8000;            // overflow −
end

// Bước 1.5: register at end of cycle 1
always @(posedge pi_clk or negedge pi_rst_n) begin
    if (!pi_rst_n) begin
        s1_reg <= 16'h0; s1_valid <= 1'b0; s1_mode <= 2'b00;
    end else begin
        s1_reg   <= s1_comb;
        s1_valid <= pi_valid_in;
        s1_mode  <= pi_act_mode;
    end
end
```

### Sample values
| pi_acc_in (real) | pi_bias (real) | sum (real) | s1_reg (Q1.8.7 hex) |
|---|---|---|---|
| +5.0 | +1.0 | +6.0 | 0x0300 (+6 × 128 = 768) |
| +200 | +100 | +300 → saturate | 0x7FFF (+max ≈ +256) |
| −200 | −100 | −300 → saturate | 0x8000 (−min = −256) |
| +1.5 | −0.5 | +1.0 | 0x0080 (+1 × 128) |

---

## 5. Stage 2 — Activation (1-cycle pipeline, 3 paths song song)

### 5.1 ReLU/bypass path (registered ngay)
```verilog
always @(posedge pi_clk or negedge pi_rst_n) begin
    if (!pi_rst_n) s2_pass_reg <= 16'h0;
    else case (s1_mode)
        2'b00:   s2_pass_reg <= s1_reg;                           // bypass
        2'b01:   s2_pass_reg <= s1_reg[15] ? 16'h0 : s1_reg;      // ReLU (msb=sign)
        default: s2_pass_reg <= 16'h0;                            // sigmoid: dùng sig_data
    endcase
end
```

### 5.2 Sigmoid path (LUT, 1-cycle)
```verilog
// Saturate Q1.8.7 → Q1.3.6 (10-bit) trước khi addr LUT
//   |s1_reg| ≥ 8.0 (= 1024 raw) → saturate
//   raw_q136 = raw_q187 / 2 (vì 64/128 = 1/2)

reg [9:0] sig_addr;
always @(*) begin
    if ($signed(s1_reg) >= $signed(16'sd1024))      sig_addr = 10'h1FF; // +sat
    else if ($signed(s1_reg) < $signed(-16'sd1024)) sig_addr = 10'h200; // −sat
    else                                              sig_addr = s1_reg[10:1]; // arith shift right 1
end

sigmoid_lookup u_sig (
    .pi_clk  (pi_clk),
    .pi_ena  (s1_valid),     // optional power gate
    .pi_addr (sig_addr),
    .po_data (sig_data)      // Q1.0.9, 1-cycle latency
);
```

### 5.3 Pipeline metadata
```verilog
always @(posedge pi_clk or negedge pi_rst_n) begin
    if (!pi_rst_n) begin
        s2_valid <= 1'b0; s2_mode <= 2'b00;
    end else begin
        s2_valid <= s1_valid;
        s2_mode  <= s1_mode;
    end
end
```

### Sample values (Stage 2 outputs)
| s1_reg (Q1.8.7) | mode | s2_pass_reg | sig_data |
|---|---|---|---|
| +1.0 (0x0080) | bypass | 0x0080 | (n/a) |
| −2.0 (0xFF00) | ReLU | 0x0000 (clamped) | (n/a) |
| 0 (0x0000) | sigmoid | 0x0000 (unused) | 0x100 (sig 0=0.5) |
| +1.0 (0x0080) | sigmoid | 0x0000 (unused) | 0x176 (sig 1≈0.731) |
| +50 (0x1900) → saturate Q1.3.6 +max | sigmoid | 0x0000 | 0x1FF (≈1.0) |

---

## 6. Stage 3 — MUX activation + saturate Q1.8.7 → Q1.4.11

### Logic
```verilog
// Convert sigmoid Q1.0.9 → Q1.8.7 (8-bit unsigned trong 16-bit field)
//   raw_q187 = sig_data >> 2 (vì 128/512 = 1/4)
wire signed [15:0] sig_q187 = {8'b0, sig_data[9:2]};

// MUX activation
wire signed [15:0] act_q187 = (s2_mode == 2'b10) ? sig_q187 : s2_pass_reg;

// Saturate Q1.8.7 → Q1.4.11
//   |act_q187| ≥ 16.0 (= 2048 raw) → saturate
//   raw_q1411 = raw_q187 << 4 (vì 2048/128 = 16)
always @(posedge pi_clk or negedge pi_rst_n) begin
    if (!pi_rst_n) begin
        s3_reg <= 16'h0; s3_valid <= 1'b0;
    end else begin
        if ($signed(act_q187) >= $signed(16'sd2048))         s3_reg <= 16'h7FFF; // +sat
        else if ($signed(act_q187) < $signed(-16'sd2048))    s3_reg <= 16'h8000; // −sat
        else                                                  s3_reg <= act_q187 <<< 4;
        s3_valid <= s2_valid;
    end
end

assign po_data_out = s3_reg;
assign po_valid_out = s3_valid;
```

### Sample values
| act_q187 | mode | s3_reg (Q1.4.11) |
|---|---|---|
| +1.0 (0x0080) | bypass | +1.0 (0x0800) — `0x0080 << 4` |
| −1.0 (0xFF80) | bypass | −1.0 (0xF800) |
| +20 (0x0A00) → saturate | ReLU | +max (0x7FFF, ≈ +16) |
| sig 0.5 (sig_data=0x100 → sig_q187=0x040) | sigmoid | +0.5 (0x0400, = `0x040 << 4`) |
| sig 0.731 (sig_data=0x176 → sig_q187=0x05D) | sigmoid | +0.7295 (0x05D0) |

---

## 7. Pipeline timeline

```
cycle:        1            2            3            4
              ──────────  ──────────  ──────────  ──────────
input edge:   pi_valid_in  s1_reg      s2_*_reg    s3_reg
              =1           latched     latched     latched
                           (S1 done)   (S2 done)   (S3 done)
                                                   │
                                                   ▼
                                       po_valid_out=1 ở cycle 4
```

Edge cases:
- Reset (`pi_rst_n=0`): tất cả reg về 0, valid chain xóa sạch.
- 2 sample liên tiếp: pipelined hoàn toàn (`po_valid_out=1` cả 2 cycle ở cuối).
- Input gap (pi_valid_in=0 giữa 2 sample): valid chain truyền 0 đúng cycle, output gap 1 cycle.

---

## 8. Synthesis target

- **DSP**: 0 (toàn bộ là add/sat, không có multiply).
- **BRAM**: 1 (sigmoid LUT, đã verify ở Bước 6).
- **LUT**: ~50 (saturate combinational + MUX).
- **FF**: ~70 (s1_reg 16, s1_valid 1, s1_mode 2, s2_pass_reg 16, s2_valid 1, s2_mode 2, sig_data 10, s3_reg 16, s3_valid 1, ≈ 65).

---

## 9. Test plan (Bước 8)

`tb/post_proc_tb.sv` test 5 case (gộp cả sigmoid):

| Case | Mode | Input range | Verify |
|---|---|---|---|
| 1 | bypass | [-100, +100] sweep | output saturate đúng ±15.999 |
| 2 | ReLU | sweep | âm → 0, dương → giữ |
| 3 | sigmoid | x ∈ {-8,-4,-1,0,+1,+4,+8} | error ≤ ±2 LSB Q1.4.11 vs float |
| 4 | bypass | acc + bias đa dạng | bias add đúng (4 sub-case) |
| 5 | bypass | drive 5 sample liên tiếp | latency = 3, throughput = 1/cycle |

Pass: `=== ALL POST_PROC TESTS PASSED ===`.

---

## 10. File deliverables Bước 7

| File | Mục đích |
|---|---|
| `hw/accelerator_2_0/hdl/post_proc.v` | RTL module |
| `hw/accelerator_2_0/hdl/post_proc_spec.md` | Tài liệu này |

(`sigmoid_lookup.v` đã có ở Bước 6; post_proc instance nó như child module.)