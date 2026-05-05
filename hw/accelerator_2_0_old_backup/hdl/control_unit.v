`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module:  control_unit — accelerator_2_0 systolic array (TPU-like) FSM
// Project: accelerator_2_0
//
// ============================================================================
// NEW FILE — written from scratch for the systolic rewrite (Direction B).
// ----------------------------------------------------------------------------
// Lifecycle (per tile):
//   IDLE → LOAD_W_RECV ↔ LOAD_W_PULSE   (8 rows × (4 recv + 1 pulse) = 40 cyc)
//        → LOAD_BIAS                     (4 AXI words)
//        → LOAD_IN                       (M*K/2 AXI words)
//        → COMPUTE                       (M+N+K-1 cycles)
//        → POST_PROC                     (M*N + 3 cycles)
//        → SEND_OUT                      (M * ⌈N/2⌉ AXI words)
//        → DONE → IDLE
//
// ── Skewed dataflow (TPU weight-stationary) ────────────────────────────────
//   PE(r, c) holds W[r][c]   (r = K-axis, c = N-axis).
//   Left edge feed at compute cycle t (= cmp_t):
//     for r in 0..K-1:
//       m = t - r;
//       if m in [0, M-1]: a_left[r] = input_buf[m][r], valid_left[r] = 1
//       else            : a_left[r] = 0,                valid_left[r] = 0
//   Output capture rule:
//     po_psum_bottom[n] holds C[m][n] when cmp_t = m + n + K (RHS in FSM).
//     i.e. m_index = cmp_t - n - K  (3-bit modular when SA_N=8).
//     valid_bottom[n] is high exactly during the cmp_t range that produces a
//     real C[m][n] for that column (it is the horizontal-valid latched at
//     PE(K-1, n).valid_reg, which lines up 1:1 with the K-deep psum result).
//
// ── Word packing convention (all stream-side data) ─────────────────────────
//   stream word[15:0]  = element at even index (2*pair + 0)
//   stream word[31:16] = element at odd  index (2*pair + 1)
//   Output uses the same packing.
//
// ── Firmware contract ──────────────────────────────────────────────────────
//   - Always send full SA_N×SA_N weight matrix (zero-pad if K_size or N_size
//     is smaller than SA_N).
//   - Always send SA_N biases (zero-pad).
//   - Inputs sized M_size × K_size (no padding required by HW).
//   - Output produced is M_size × N_size, packed 2 elements per AXI word.
//////////////////////////////////////////////////////////////////////////////////

module control_unit #(
    parameter integer SA_N       = 8,
    parameter integer DATA_WIDTH = 16,
    parameter integer ACC_WIDTH  = 40
)(
    input  wire                          pi_clk,
    input  wire                          pi_rst_n,

    // ── AXI-Lite configuration ──
    input  wire [9:0]                    pi_tile_m_size,
    input  wire [9:0]                    pi_tile_k_size,
    input  wire [9:0]                    pi_tile_n_size,
    input  wire [1:0]                    pi_act_mode,
    input  wire                          pi_start,
    output reg                           po_busy,
    output reg                           po_done,

    // ── AXI-Stream slave (DMA → accelerator) ──
    input  wire [31:0]                   pi_stream_data,
    input  wire                          pi_stream_valid,
    output wire                          po_stream_ready,

    // ── AXI-Stream master (accelerator → DMA) ──
    output wire [9:0]                    po_num_out_transfers,
    output wire [31:0]                   po_out_data,
    output wire                          po_out_write_req,
    input  wire                          pi_out_write_done,

    // ── Datapath: weight load ──
    output reg                           po_dp_weight_load,
    output reg  [2:0]                    po_dp_weight_row_sel,
    output wire [SA_N*DATA_WIDTH-1:0]    po_dp_weight_data,

    // ── Datapath: left-edge activation feed ──
    output reg  [SA_N*DATA_WIDTH-1:0]    po_dp_a_left,
    output reg  [SA_N-1:0]               po_dp_valid_left,

    // ── Datapath: bottom-edge psum results ──
    input  wire [SA_N*ACC_WIDTH-1:0]     pi_dp_psum_bottom,
    input  wire [SA_N-1:0]               pi_dp_valid_bottom,

    // ── Post-processing ──
    output reg  [ACC_WIDTH-1:0]          po_pp_acc_in,
    output reg  [DATA_WIDTH-1:0]         po_pp_bias,
    output reg                           po_pp_valid_in,
    output wire [1:0]                    po_pp_act_mode,
    input  wire [DATA_WIDTH-1:0]         pi_pp_data_out,
    input  wire                          pi_pp_valid_out
);

    localparam integer WORDS_PER_ROW = SA_N / 2;   // 4 words = 8 elements

    // ── FSM states ──
    localparam [3:0] ST_IDLE         = 4'd0;
    localparam [3:0] ST_LOAD_W_RECV  = 4'd1;
    localparam [3:0] ST_LOAD_W_PULSE = 4'd2;
    localparam [3:0] ST_LOAD_BIAS    = 4'd3;
    localparam [3:0] ST_LOAD_IN      = 4'd4;
    localparam [3:0] ST_COMPUTE      = 4'd5;
    localparam [3:0] ST_POST_PROC    = 4'd6;
    localparam [3:0] ST_SEND_OUT     = 4'd7;
    localparam [3:0] ST_DONE         = 4'd8;

    reg [3:0] state;

    // ── Buffers (registered storage) ──
    reg [DATA_WIDTH-1:0] weight_row_buf [0:SA_N-1];
    reg [DATA_WIDTH-1:0] bias_buf       [0:SA_N-1];
    reg [DATA_WIDTH-1:0] input_buf      [0:SA_N-1][0:SA_N-1]; // [m][k]
    reg [ACC_WIDTH-1:0]  psum_buf       [0:SA_N-1][0:SA_N-1]; // [m][n]
    reg [DATA_WIDTH-1:0] out_buf        [0:SA_N-1][0:SA_N-1]; // [m][n] Q1.4.11

    // ── Counters ──
    reg [3:0]  w_row;       // weight row 0..7
    reg [3:0]  w_pair;      // 0..3 (4 word-pairs per row)
    reg [3:0]  bias_pair;   // 0..3
    reg [3:0]  in_m;        // current row in input load 0..7
    reg [3:0]  in_kpair;    // 0..3
    reg [9:0]  cmp_t;       // compute cycle counter
    reg [3:0]  pp_in_m,  pp_in_n;
    reg [3:0]  pp_out_m, pp_out_n;
    reg [9:0]  pp_in_cnt;
    reg [9:0]  pp_out_cnt;
    reg [3:0]  send_row;
    reg [3:0]  send_pair;

    // ── Flatten weight_row_buf → bus to data_path ──
    genvar gi;
    generate
        for (gi = 0; gi < SA_N; gi = gi + 1) begin : gen_weight_data
            assign po_dp_weight_data[gi*DATA_WIDTH +: DATA_WIDTH] = weight_row_buf[gi];
        end
    endgenerate

    // ── Combinational outputs ──
    assign po_pp_act_mode       = pi_act_mode;
    // Output transfer count: M × ⌈N/2⌉
    assign po_num_out_transfers = pi_tile_m_size * ((pi_tile_n_size + 10'd1) >> 1);

    // Stream ready: only during loading states
    assign po_stream_ready = (state == ST_LOAD_W_RECV) ||
                             (state == ST_LOAD_BIAS)   ||
                             (state == ST_LOAD_IN);

    // Output data: pack 2 × 16-bit / 32-bit word
    assign po_out_data = {out_buf[send_row[2:0]][{send_pair[2:0], 1'b1}],
                          out_buf[send_row[2:0]][{send_pair[2:0], 1'b0}]};
    assign po_out_write_req = (state == ST_SEND_OUT);

    // ─────────────────────────────────────────────────────────────────────
    // Combinational left-edge activation feed (skewed)
    //   For r=0..K-1: a_left[r] = input_buf[(cmp_t-r) & 7][r] when valid.
    // ─────────────────────────────────────────────────────────────────────
    integer ri;
    reg [3:0] m_ri;
    always @(*) begin
        po_dp_a_left     = {SA_N*DATA_WIDTH{1'b0}};
        po_dp_valid_left = {SA_N{1'b0}};
        if (state == ST_COMPUTE) begin
            for (ri = 0; ri < SA_N; ri = ri + 1) begin
                if (ri < pi_tile_k_size) begin
                    if (cmp_t >= ri[9:0] &&
                        (cmp_t - ri[9:0]) < pi_tile_m_size) begin
                        m_ri = (cmp_t[3:0] - ri[3:0]) & 4'h7;
                        po_dp_a_left[ri*DATA_WIDTH +: DATA_WIDTH] =
                            input_buf[m_ri[2:0]][ri[2:0]];
                        po_dp_valid_left[ri] = 1'b1;
                    end
                end
            end
        end
    end

    // ─────────────────────────────────────────────────────────────────────
    // Main FSM
    // ─────────────────────────────────────────────────────────────────────
    integer ni;
    reg [3:0] m_capture;
    integer i_init, j_init;
    always @(posedge pi_clk or negedge pi_rst_n) begin
        if (!pi_rst_n) begin
            state                 <= ST_IDLE;
            po_busy               <= 1'b0;
            po_done               <= 1'b0;
            po_dp_weight_load     <= 1'b0;
            po_dp_weight_row_sel  <= 3'd0;
            po_pp_valid_in        <= 1'b0;
            po_pp_acc_in          <= {ACC_WIDTH{1'b0}};
            po_pp_bias            <= {DATA_WIDTH{1'b0}};
            w_row                 <= 4'd0;
            w_pair                <= 4'd0;
            bias_pair             <= 4'd0;
            in_m                  <= 4'd0;
            in_kpair              <= 4'd0;
            cmp_t                 <= 10'd0;
            pp_in_m               <= 4'd0;
            pp_in_n               <= 4'd0;
            pp_out_m              <= 4'd0;
            pp_out_n              <= 4'd0;
            pp_in_cnt             <= 10'd0;
            pp_out_cnt            <= 10'd0;
            send_row              <= 4'd0;
            send_pair             <= 4'd0;
        end else begin
            // ── Default deassertions ──
            po_dp_weight_load <= 1'b0;
            po_done           <= 1'b0;
            po_pp_valid_in    <= 1'b0;

            case (state)

            // ───────────────────────── IDLE ─────────────────────────
            ST_IDLE: begin
                po_busy <= 1'b0;
                if (pi_start) begin
                    state   <= ST_LOAD_W_RECV;
                    po_busy <= 1'b1;
                    w_row   <= 4'd0;
                    w_pair  <= 4'd0;
                end
            end

            // ─────────────── LOAD WEIGHTS — RECEIVE ─────────────────
            // Receive 4 AXI words per row → fill weight_row_buf[0..7].
            ST_LOAD_W_RECV: begin
                if (pi_stream_valid) begin
                    weight_row_buf[{w_pair[2:0], 1'b0}] <= pi_stream_data[15:0];
                    weight_row_buf[{w_pair[2:0], 1'b1}] <= pi_stream_data[31:16];
                    if (w_pair == WORDS_PER_ROW - 1) begin
                        w_pair <= 4'd0;
                        state  <= ST_LOAD_W_PULSE;
                    end else begin
                        w_pair <= w_pair + 4'd1;
                    end
                end
            end

            // ─────────────── LOAD WEIGHTS — PULSE ───────────────────
            // 1-cycle pulse: assert weight_load with weight_row_buf stable.
            ST_LOAD_W_PULSE: begin
                po_dp_weight_load    <= 1'b1;
                po_dp_weight_row_sel <= w_row[2:0];
                if (w_row == SA_N - 1) begin
                    state     <= ST_LOAD_BIAS;
                    bias_pair <= 4'd0;
                end else begin
                    w_row <= w_row + 4'd1;
                    state <= ST_LOAD_W_RECV;
                end
            end

            // ───────────────────── LOAD BIASES ──────────────────────
            ST_LOAD_BIAS: begin
                if (pi_stream_valid) begin
                    bias_buf[{bias_pair[2:0], 1'b0}] <= pi_stream_data[15:0];
                    bias_buf[{bias_pair[2:0], 1'b1}] <= pi_stream_data[31:16];
                    if (bias_pair == WORDS_PER_ROW - 1) begin
                        state    <= ST_LOAD_IN;
                        in_m     <= 4'd0;
                        in_kpair <= 4'd0;
                    end else begin
                        bias_pair <= bias_pair + 4'd1;
                    end
                end
            end

            // ───────────────── LOAD INPUT MATRIX ────────────────────
            // M_size × K_size activations, packed 2 per word.
            // K_size assumed even (K_size/2 word-pairs per row).
            ST_LOAD_IN: begin
                if (pi_stream_valid) begin
                    input_buf[in_m[2:0]][{in_kpair[2:0], 1'b0}] <= pi_stream_data[15:0];
                    input_buf[in_m[2:0]][{in_kpair[2:0], 1'b1}] <= pi_stream_data[31:16];
                    if (in_kpair == (pi_tile_k_size[3:0] >> 1) - 4'd1) begin
                        in_kpair <= 4'd0;
                        if (in_m == pi_tile_m_size[3:0] - 4'd1) begin
                            state <= ST_COMPUTE;
                            cmp_t <= 10'd0;
                        end else begin
                            in_m <= in_m + 4'd1;
                        end
                    end else begin
                        in_kpair <= in_kpair + 4'd1;
                    end
                end
            end

            // ──────────────────────── COMPUTE ───────────────────────
            // Activation feed driven combinationally from cmp_t (above).
            // Capture: psum_buf[(cmp_t-ni-K)&7][ni] when valid_bottom[ni].
            ST_COMPUTE: begin
                for (ni = 0; ni < SA_N; ni = ni + 1) begin
                    if (pi_dp_valid_bottom[ni] && (ni < pi_tile_n_size)) begin
                        m_capture = (cmp_t[3:0] - ni[3:0] - pi_tile_k_size[3:0]) & 4'h7;
                        psum_buf[m_capture[2:0]][ni[2:0]] <=
                            pi_dp_psum_bottom[ni*ACC_WIDTH +: ACC_WIDTH];
                    end
                end

                if (cmp_t == (pi_tile_m_size + pi_tile_n_size +
                              pi_tile_k_size - 10'd2)) begin
                    state      <= ST_POST_PROC;
                    pp_in_m    <= 4'd0;
                    pp_in_n    <= 4'd0;
                    pp_out_m   <= 4'd0;
                    pp_out_n   <= 4'd0;
                    pp_in_cnt  <= 10'd0;
                    pp_out_cnt <= 10'd0;
                end else begin
                    cmp_t <= cmp_t + 10'd1;
                end
            end

            // ─────────────────────── POST_PROC ──────────────────────
            // Pipeline psum_buf[m][n] + bias_buf[n] → activation → out_buf.
            // post_proc latency = 3 cycles. Feed M*N items back-to-back.
            ST_POST_PROC: begin
                // Feed phase
                if (pp_in_cnt < pi_tile_m_size * pi_tile_n_size) begin
                    po_pp_valid_in <= 1'b1;
                    po_pp_acc_in   <= psum_buf[pp_in_m[2:0]][pp_in_n[2:0]];
                    po_pp_bias     <= bias_buf[pp_in_n[2:0]];
                    if (pp_in_n == pi_tile_n_size[3:0] - 4'd1) begin
                        pp_in_n <= 4'd0;
                        pp_in_m <= pp_in_m + 4'd1;
                    end else begin
                        pp_in_n <= pp_in_n + 4'd1;
                    end
                    pp_in_cnt <= pp_in_cnt + 10'd1;
                end
                // (po_pp_valid_in defaults to 0 when feeding is done)

                // Collect phase
                if (pi_pp_valid_out) begin
                    out_buf[pp_out_m[2:0]][pp_out_n[2:0]] <= pi_pp_data_out;
                    if (pp_out_n == pi_tile_n_size[3:0] - 4'd1) begin
                        pp_out_n <= 4'd0;
                        pp_out_m <= pp_out_m + 4'd1;
                    end else begin
                        pp_out_n <= pp_out_n + 4'd1;
                    end
                    if (pp_out_cnt == pi_tile_m_size * pi_tile_n_size - 10'd1) begin
                        state     <= ST_SEND_OUT;
                        send_row  <= 4'd0;
                        send_pair <= 4'd0;
                    end
                    pp_out_cnt <= pp_out_cnt + 10'd1;
                end
            end

            // ────────────────────── SEND OUTPUT ─────────────────────
            // Stream out_buf via AXIS master, 2 elements per word.
            ST_SEND_OUT: begin
                if (pi_out_write_done) begin
                    if (send_pair == ((pi_tile_n_size[3:0] + 4'd1) >> 1) - 4'd1) begin
                        send_pair <= 4'd0;
                        if (send_row == pi_tile_m_size[3:0] - 4'd1) begin
                            state <= ST_DONE;
                        end else begin
                            send_row <= send_row + 4'd1;
                        end
                    end else begin
                        send_pair <= send_pair + 4'd1;
                    end
                end
            end

            // ──────────────────────── DONE ──────────────────────────
            ST_DONE: begin
                po_done <= 1'b1;
                po_busy <= 1'b0;
                state   <= ST_IDLE;
            end

            default: state <= ST_IDLE;

            endcase
        end
    end

endmodule
