    # `control_unit.v` — Design Spec

**Mục tiêu**: FSM lập lịch toàn bộ life-cycle 1 tile GEMM 8×8.

**Vai trò**: là "brain" kết nối:
- AXI-Lite slave (cấu hình từ PicoRV32)
- AXIS slave (nhận data từ DMA)
- AXIS master (gửi output ra DMA)
- data_path (drive weight + skewed input, capture psum)
- post_proc (feed psum, capture activated output)

---

## 1. Interface

### 1.1 Tham số

```verilog
parameter SA_N       = 8         // Systolic array size
parameter DATA_WIDTH = 16        // Q1.4.11
parameter ACC_WIDTH  = 40        // Q2.8.22 + log2(SA_N) headroom
```

### 1.2 Port list

```verilog
module control_unit (
    input  wire                          pi_clk,
    input  wire                          pi_rst_n,

    // ----- AXI-Lite config (từ accelerator_slave_lite shim) -----
    input  wire [9:0]                    pi_tile_m_size,    // 1..8
    input  wire [9:0]                    pi_tile_k_size,    // 1..8
    input  wire [9:0]                    pi_tile_n_size,    // 1..8
    input  wire [1:0]                    pi_act_mode,       // 00/01/10
    input  wire                          pi_start,          // 1-cycle pulse từ AXI-Lite
    output reg                           po_busy,
    output reg                           po_done,

    // ----- AXIS slave (từ accelerator_slave_stream shim) -----
    input  wire [31:0]                   pi_stream_data,
    input  wire                          pi_stream_valid,
    output wire                          po_stream_ready,
    output wire                          po_loading,        // = 1 khi ở state LOAD_*

    // ----- AXIS master (tới accelerator_master_stream shim) -----
    output wire [9:0]                    po_num_out_transfers,
    output wire [31:0]                   po_out_data,
    output wire                          po_out_write_req,
    input  wire                          pi_out_write_done,

    // ----- Tới data_path: weight load -----
    output reg                           po_dp_weight_load,
    output reg  [2:0]                    po_dp_weight_row_sel,
    output wire [SA_N*DATA_WIDTH-1:0]    po_dp_weight_data,

    // ----- Tới data_path: skewed input feed -----
    output reg  [SA_N*DATA_WIDTH-1:0]    po_dp_a_left,
    output reg  [SA_N-1:0]               po_dp_valid_left,

    // ----- Từ data_path: bottom psum -----
    input  wire [SA_N*ACC_WIDTH-1:0]     pi_dp_psum_bottom,
    input  wire [SA_N-1:0]               pi_dp_valid_bottom,

    // ----- Tới post_proc -----
    output reg  [ACC_WIDTH-1:0]          po_pp_acc_in,
    output reg  [DATA_WIDTH-1:0]         po_pp_bias,
    output reg                           po_pp_valid_in,
    output wire [1:0]                    po_pp_act_mode,

    // ----- Từ post_proc -----
    input  wire [DATA_WIDTH-1:0]         pi_pp_data_out,
    input  wire                          pi_pp_valid_out
);
```

---

## 2. FSM States (9 trạng thái)

```
ST_IDLE         = 4'd0
ST_LOAD_W_RECV  = 4'd1   // nhận 4 AXIS word = 1 row weight (8 phần tử)
ST_LOAD_W_PULSE = 4'd2   // 1 cycle: assert weight_load + row_sel
ST_LOAD_BIAS    = 4'd3   // nhận 4 AXIS word = 8 bias
ST_LOAD_IN      = 4'd4   // nhận ⌈M*K/2⌉ AXIS word
ST_COMPUTE      = 4'd5   // drive skewed input M+N+SA_N-1 cycle
ST_POST_PROC    = 4'd6   // feed psum_buf → post_proc, M*N + 3 cycle drain
ST_SEND_OUT     = 4'd7   // push out_buf → AXIS master, M*⌈N/2⌉ word
ST_DONE         = 4'd8   // 1 cycle, raise po_done, về IDLE
```

```
        ┌──── pi_start ────┐
        │                  ▼
ST_IDLE                ST_LOAD_W_RECV ◄───┐
                            │             │
                       4 word đầy         │
                            ▼             │
                     ST_LOAD_W_PULSE ─────┘
                            │  (row<7: tiếp recv)
                            │  (row=7: → BIAS)
                            ▼
                       ST_LOAD_BIAS
                            │  (4 word đầy)
                            ▼
                       ST_LOAD_IN
                            │  (M*K/2 word đầy)
                            ▼
                       ST_COMPUTE
                            │  (cmp_t == M+N+SA_N-2)
                            ▼
                       ST_POST_PROC
                            │  (pp_out_cnt == M*N)
                            ▼
                       ST_SEND_OUT
                            │  (send_cnt == M*⌈N/2⌉)
                            ▼
                       ST_DONE → ST_IDLE
```

---

## 3. Buffers nội bộ

```verilog
reg [DW-1:0]  weight_row_buf [0:SA_N-1];          // 1 row weight đang nạp
reg [DW-1:0]  bias_buf       [0:SA_N-1];          // bias cho mỗi cột N
reg [DW-1:0]  input_buf      [0:SA_N-1][0:SA_N-1]; // [m][k]
reg [AW-1:0]  psum_buf       [0:SA_N-1][0:SA_N-1]; // [m][n] capture từ data_path
reg [DW-1:0]  out_buf        [0:SA_N-1][0:SA_N-1]; // [m][n] sau post_proc
```

---

## 4. Counters

```verilog
reg [3:0] w_row;       // 0..SA_N-1 trong LOAD_W
reg [3:0] w_pair;      // 0..SA_N/2-1 = 0..3 (4 word/row)
reg [3:0] bias_pair;   // 0..3
reg [3:0] in_m, in_kpair;
reg [9:0] cmp_t;       // 0..M+N+SA_N-2
reg [3:0] pp_in_m, pp_in_n;
reg [3:0] pp_out_m, pp_out_n;
reg [9:0] pp_in_cnt, pp_out_cnt;
reg [3:0] send_row, send_pair;
```

---

## 5. Quy ước packing AXIS (32-bit word)

```
word[15:0]  = element index chẵn  (2*pair + 0)
word[31:16] = element index lẻ    (2*pair + 1)
```

Áp dụng cho: weight load, bias load, input load, output send.

---

## 6. Logic từng state

### 6.1 ST_IDLE
- `po_busy = 0`, `po_done = 0`.
- Khi `pi_start` = 1 → reset counters, → `ST_LOAD_W_RECV`, `po_busy = 1`.

### 6.2 ST_LOAD_W_RECV
- `po_stream_ready = 1` (qua `po_loading`).
- Khi `pi_stream_valid && po_stream_ready`:
  - `weight_row_buf[2*w_pair    ] <= pi_stream_data[15:0]`
  - `weight_row_buf[2*w_pair + 1] <= pi_stream_data[31:16]`
  - `w_pair++`. Khi `w_pair == 3`, → `ST_LOAD_W_PULSE`.

### 6.3 ST_LOAD_W_PULSE
- `po_dp_weight_load = 1`, `po_dp_weight_row_sel = w_row`.
- `po_dp_weight_data` flatten từ `weight_row_buf` (col 0 = LSB).
- 1 cycle xong:
  - Nếu `w_row < SA_N-1`: `w_row++`, → `ST_LOAD_W_RECV` (nạp row tiếp theo).
  - Nếu `w_row == SA_N-1`: → `ST_LOAD_BIAS`.

### 6.4 ST_LOAD_BIAS
- Tương tự `LOAD_W_RECV` nhưng nạp vào `bias_buf`.
- 4 word (8 bias). Xong → `ST_LOAD_IN`.

### 6.5 ST_LOAD_IN
- Tổng số word: `M × ⌈K/2⌉`.
- `in_m`: 0..M-1, `in_kpair`: 0..⌈K/2⌉-1.
- Mỗi word ghi vào `input_buf[in_m][2*in_kpair]` và `input_buf[in_m][2*in_kpair+1]`.
- Xong → `ST_COMPUTE`, `cmp_t = 0`.

### 6.6 ST_COMPUTE — Skewed input feed + capture psum

**Output (combinational, dựa vào `cmp_t`)**:
```verilog
always @(*) begin
    po_dp_a_left     = '0;
    po_dp_valid_left = '0;
    if (state == ST_COMPUTE) begin
        for (r = 0; r < SA_N; r++) begin
            if (r < pi_tile_k_size && cmp_t >= r &&
                (cmp_t - r) < pi_tile_m_size) begin
                po_dp_a_left[r*DW +: DW] = input_buf[cmp_t - r][r];
                po_dp_valid_left[r] = 1'b1;
            end else begin
                po_dp_a_left[r*DW +: DW] = '0;
                po_dp_valid_left[r] = 1'b1;  // luôn drive valid (xem TB note)
            end
        end
    end
end
```

**Capture (sequential, sau posedge)**:
```verilog
for (n = 0; n < SA_N; n++) begin
    if (pi_dp_valid_bottom[n] && (n < pi_tile_n_size)) begin
        m_cap = cmp_t - n - (SA_N - 1);
        if (m_cap >= 0 && m_cap < pi_tile_m_size)
            psum_buf[m_cap][n] <= pi_dp_psum_bottom[n*AW +: AW];
    end
end
```

**Kết thúc**: khi `cmp_t == M + N + SA_N - 2`, → `ST_POST_PROC`.
- Reset `pp_in_m=0, pp_in_n=0, pp_in_cnt=0, pp_out_m=0, pp_out_n=0, pp_out_cnt=0`.

Không reset `cmp_t` ngay (vì đã hết hạn dùng).

### 6.7 ST_POST_PROC — Feed psum_buf → post_proc, capture out

**Feed phase (mỗi cycle)**:
```verilog
if (pp_in_cnt < M * N) begin
    po_pp_valid_in <= 1'b1;
    po_pp_acc_in   <= psum_buf[pp_in_m][pp_in_n];
    po_pp_bias     <= bias_buf[pp_in_n];
    if (pp_in_n == N - 1) begin
        pp_in_n <= 0;
        pp_in_m <= pp_in_m + 1;
    end else
        pp_in_n <= pp_in_n + 1;
    pp_in_cnt <= pp_in_cnt + 1;
end else
    po_pp_valid_in <= 1'b0;
```

**Capture phase (3 cycle sau khi feed bắt đầu, post_proc latency = 3)**:
```verilog
if (pi_pp_valid_out) begin
    out_buf[pp_out_m][pp_out_n] <= pi_pp_data_out;
    if (pp_out_n == N - 1) begin
        pp_out_n <= 0;
        pp_out_m <= pp_out_m + 1;
    end else
        pp_out_n <= pp_out_n + 1;
    pp_out_cnt <= pp_out_cnt + 1;
end
```

**Kết thúc**: khi `pp_out_cnt == M * N`, → `ST_SEND_OUT`.

### 6.8 ST_SEND_OUT — Stream out_buf qua AXIS master

**Combinational outputs**:
```verilog
po_out_data = {out_buf[send_row][2*send_pair + 1],
               out_buf[send_row][2*send_pair]};
po_out_write_req = (state == ST_SEND_OUT);
```

**Sequential**: khi `pi_out_write_done == 1`:
- `send_pair++`. Khi `send_pair == ⌈N/2⌉ - 1`:
  - `send_pair = 0`, `send_row++`. Khi `send_row == M-1`: → `ST_DONE`.

**Output transfer count** (combinational, gửi tới shim master):
```verilog
po_num_out_transfers = pi_tile_m_size * ((pi_tile_n_size + 1) >> 1);
```

### 6.9 ST_DONE
- `po_done <= 1` (1 cycle pulse).
- `po_busy <= 0`.
- → `ST_IDLE`.

---

## 7. Combinational outputs ngoài

```verilog
assign po_pp_act_mode  = pi_act_mode;     // bypass/relu/sigmoid

// po_loading: gate cho TREADY của AXIS slave shim
assign po_loading = (state == ST_LOAD_W_RECV) ||
                    (state == ST_LOAD_BIAS)   ||
                    (state == ST_LOAD_IN);

// po_stream_ready cho phép TREADY toàn cục ở các state LOAD
assign po_stream_ready = po_loading;

// Flatten weight_row_buf → bus
genvar gi;
generate
    for (gi = 0; gi < SA_N; gi = gi + 1) begin : gen_w_pack
        assign po_dp_weight_data[gi*DW +: DW] = weight_row_buf[gi];
    end
endgenerate
```

---

## 8. Số cycle ước lượng cho 1 tile 8×8×8

| Phase | Cycles |
|---|---|
| LOAD_W_RECV+PULSE | 8 row × (4 word + 1 pulse) = 40 |
| LOAD_BIAS | 4 |
| LOAD_IN | 8 × 4 = 32 |
| COMPUTE | 8+8+8-1 = 23 |
| POST_PROC | 64 + 3 = 67 |
| SEND_OUT | 8 × 4 = 32 |
| DONE | 1 |
| **TỔNG** | **~199 cycle = 1.99 µs @ 100 MHz** |

(Trên thực tế, AXIS DMA có handshake overhead, nên thực tế chạy lâu hơn.)

---

## 9. Files cần tạo/cập nhật

1. **`hw/accelerator_2_0/hdl/control_unit.v`** — RTL (file chính của Bước 4).

2. **Cập nhật README.md** sau khi xong (Bước 4 hoàn tất → tích vào bảng trạng thái).

3. **Cập nhật `data_path.v`** — KHÔNG cần. Giao diện đã đúng từ Bước 1c.

4. **`tb/control_unit_tb.sv`** — sẽ ở Bước 5 (test FSM standalone với mock data_path/post_proc).

---

## 10. Notes triển khai

**State register** dùng `reg [3:0] state` với localparam. Tất cả output `po_*` register hóa (sequential always block) trừ vài combinational liệt kê ở §7.

**`a_left`, `valid_left` combinational** từ `cmp_t` và `input_buf`. Mặc dù bus rộng (128-bit cho 8×16), Vivado sẽ optimise OK.

**`weight_load` chỉ pulse 1 cycle** trong ST_LOAD_W_PULSE. Default deassert ở mọi state khác.

**`po_done` 1-cycle pulse** ở ST_DONE. AXI-Lite shim register hóa thành STATUS.DONE bit (sticky đến khi user clear).

**Reset**: tất cả counter và state về 0/IDLE. Buffer arrays KHÔNG reset (tránh tốn diện tích) — sẽ ghi đè khi nạp tile mới.

---

## 11. Pass criteria (gate cho phép qua Bước 5)

- `control_unit.v` synth pass với `top=control_unit, part=xczu3eg-sbva484-1-i, mode=out_of_context`:
  - 0 error
  - 0 critical warning
  - 0 latch (warning [Synth 8-327] = "inferring latch")
- Resource utilization ước tính < 5% LUT của Ultra96 cho riêng module này.
