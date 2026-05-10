`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module:  control_unit - accelerator_2_0 FSM lập lịch 1 tile GEMM
// Project: accelerator_2_0
//
// Spec đầy đủ: hw/accelerator_2_0/hdl/control_unit_spec.md
//
// 9-state FSM:
//   IDLE → LOAD_W_RECV ↔ LOAD_W_PULSE → LOAD_BIAS → LOAD_IN
//        → COMPUTE → POST_PROC → SEND_OUT → DONE → IDLE
//
// Số cycle/tile 8×8×8: ~199 = ~2µs @ 100 MHz
//
// Word packing AXIS (32-bit):
//   word[15:0]  = element index chẵn (2*pair + 0)
//   word[31:16] = element index lẻ   (2*pair + 1)
//////////////////////////////////////////////////////////////////////////////////

module control_unit #(
    parameter integer SA_N       = 8,
    parameter integer DATA_WIDTH = 16,
    parameter integer ACC_WIDTH  = 40
)(
    input  wire                          pi_clk,
    input  wire                          pi_rst_n,

    // ── AXI-Lite config ──────────────────────────────────────────
    input  wire [9:0]                    pi_tile_m_size,
    input  wire [9:0]                    pi_tile_k_size,
    input  wire [9:0]                    pi_tile_n_size,
    input  wire [1:0]                    pi_act_mode,
    input  wire                          pi_start,
    output reg                           po_busy,
    output reg                           po_done,

    // ── AXIS slave (DMA → accelerator) ───────────────────────────
    input  wire [31:0]                   pi_stream_data,
    input  wire                          pi_stream_valid,
    output wire                          po_stream_ready,
    output wire                          po_loading,

    // ── AXIS master (accelerator → DMA) ──────────────────────────
    output wire [9:0]                    po_num_out_transfers,
    output wire [31:0]                   po_out_data,
    output wire                          po_out_write_req,
    input  wire                          pi_out_write_done,

    // ── Tới data_path: weight load ───────────────────────────────
    output reg                           po_dp_weight_load,
    output reg  [2:0]                    po_dp_weight_row_sel,
    output wire [SA_N*DATA_WIDTH-1:0]    po_dp_weight_data,

    // ── Tới data_path: skewed input feed ─────────────────────────
    output reg  [SA_N*DATA_WIDTH-1:0]    po_dp_a_left,
    output reg  [SA_N-1:0]               po_dp_valid_left,

    // ── Từ data_path: bottom psum capture ────────────────────────
    input  wire [SA_N*ACC_WIDTH-1:0]     pi_dp_psum_bottom,
    input  wire [SA_N-1:0]               pi_dp_valid_bottom,

    // ── Tới post_proc ────────────────────────────────────────────
    output reg  [ACC_WIDTH-1:0]          po_pp_acc_in,
    output reg  [DATA_WIDTH-1:0]         po_pp_bias,
    output reg                           po_pp_valid_in,
    output wire [1:0]                    po_pp_act_mode,

    // ── Từ post_proc ─────────────────────────────────────────────
    input  wire [DATA_WIDTH-1:0]         pi_pp_data_out,
    input  wire                          pi_pp_valid_out
);

    // ─────────────────────────────────────────────────────────────
    // FSM states
    // ─────────────────────────────────────────────────────────────
    localparam [3:0] ST_IDLE         = 4'd0;
    localparam [3:0] ST_LOAD_W_RECV  = 4'd1;
    localparam [3:0] ST_LOAD_W_PULSE = 4'd2;
    localparam [3:0] ST_LOAD_BIAS    = 4'd3;
    localparam [3:0] ST_LOAD_IN      = 4'd4;
    localparam [3:0] ST_COMPUTE      = 4'd5;
    localparam [3:0] ST_POST_PROC    = 4'd6;
    localparam [3:0] ST_SEND_OUT     = 4'd7;
    localparam [3:0] ST_DONE         = 4'd8;

    localparam integer WORDS_PER_ROW = SA_N / 2;   // 4 cho SA_N=8

    reg [3:0] state;

    // ─────────────────────────────────────────────────────────────
    // Counters
    // ─────────────────────────────────────────────────────────────
    reg [3:0] w_row;
    reg [3:0] w_pair;
    reg [3:0] bias_pair;
    reg [3:0] in_m;
    reg [3:0] in_kpair;
    reg [9:0] cmp_t;
    reg [3:0] pp_in_m, pp_in_n;
    reg [9:0] pp_in_cnt;
    reg [3:0] pp_out_m, pp_out_n;
    reg [9:0] pp_out_cnt;
    reg [3:0] send_row, send_pair;

    // ─────────────────────────────────────────────────────────────
    // Buffers
    // ─────────────────────────────────────────────────────────────
    reg [DATA_WIDTH-1:0]  weight_row_buf [0:SA_N-1];
    reg [DATA_WIDTH-1:0]  bias_buf       [0:SA_N-1];
    reg [DATA_WIDTH-1:0]  input_buf      [0:SA_N-1][0:SA_N-1];
    reg [ACC_WIDTH-1:0]   psum_buf       [0:SA_N-1][0:SA_N-1];
    reg [DATA_WIDTH-1:0]  out_buf        [0:SA_N-1][0:SA_N-1];

    // ─────────────────────────────────────────────────────────────
    // Combinational outputs
    // ─────────────────────────────────────────────────────────────
    assign po_pp_act_mode       = pi_act_mode;
    assign po_loading           = (state == ST_LOAD_W_RECV) ||
                                  (state == ST_LOAD_BIAS)   ||
                                  (state == ST_LOAD_IN);
    assign po_stream_ready      = po_loading;
    assign po_out_write_req     = (state == ST_SEND_OUT);
    assign po_num_out_transfers = pi_tile_m_size *
                                  ((pi_tile_n_size + 10'd1) >> 1);
    assign po_out_data          = {out_buf[send_row[2:0]][{send_pair[2:0], 1'b1}],
                                   out_buf[send_row[2:0]][{send_pair[2:0], 1'b0}]};

    // Flatten weight_row_buf → bus tới data_path
    genvar gi;
    generate
        for (gi = 0; gi < SA_N; gi = gi + 1) begin : gen_w_pack
            assign po_dp_weight_data[gi*DATA_WIDTH +: DATA_WIDTH] = weight_row_buf[gi];
        end
    endgenerate

    // ─────────────────────────────────────────────────────────────
    // Skewed input feed (combinational từ cmp_t + input_buf)
    //   r < K_used and 0 ≤ cmp_t-r < M_used: a_left[r] = A[cmp_t-r][r]
    //   ngược lại: a_left[r] = 0
    //   valid_left[r] = 1 cho TẤT CẢ r trong COMPUTE (xem data_path TB note)
    // ─────────────────────────────────────────────────────────────
    always @(*) begin : skew_drive
        integer ri;
        reg [9:0] m_ri;
        po_dp_a_left     = {(SA_N*DATA_WIDTH){1'b0}};
        po_dp_valid_left = {SA_N{1'b0}};
        if (state == ST_COMPUTE) begin
            for (ri = 0; ri < SA_N; ri = ri + 1) begin
                if (ri < pi_tile_k_size && cmp_t >= ri[9:0] &&
                    (cmp_t - ri[9:0]) < pi_tile_m_size) begin
                    m_ri = cmp_t - ri[9:0];
                    po_dp_a_left[ri*DATA_WIDTH +: DATA_WIDTH] =
                        input_buf[m_ri[2:0]][ri[2:0]];
                end else begin
                    po_dp_a_left[ri*DATA_WIDTH +: DATA_WIDTH] = {DATA_WIDTH{1'b0}};
                end
                po_dp_valid_left[ri] = 1'b1;
            end
        end
    end

    // ─────────────────────────────────────────────────────────────
    // Main FSM (sequential)
    // ─────────────────────────────────────────────────────────────
    always @(posedge pi_clk or negedge pi_rst_n) begin : fsm_main
        integer ni;
        integer m_capture;
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
            pp_in_cnt             <= 10'd0;
            pp_out_m              <= 4'd0;
            pp_out_n              <= 4'd0;
            pp_out_cnt            <= 10'd0;
            send_row              <= 4'd0;
            send_pair             <= 4'd0;
        end else begin
            // ── Default deassertions (chỉ pulse khi cần) ──
            po_dp_weight_load <= 1'b0;
            po_done           <= 1'b0;
            po_pp_valid_in    <= 1'b0;

            case (state)

            // ───────────────── IDLE ─────────────────
            ST_IDLE: begin
                po_busy <= 1'b0;
                if (pi_start) begin
                    state   <= ST_LOAD_W_RECV;
                    po_busy <= 1'b1;
                    w_row   <= 4'd0;
                    w_pair  <= 4'd0;
                end
            end

            // ─────────── LOAD WEIGHTS - RECEIVE ────────────
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

            // ─────────── LOAD WEIGHTS - PULSE 1 cycle ──────────
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

            // ───────────────── LOAD BIAS ─────────────────
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

            // ─────────────── LOAD INPUT MATRIX ─────────────────
            // Tổng số word: M × ⌈K/2⌉
            ST_LOAD_IN: begin
                if (pi_stream_valid) begin
                    input_buf[in_m[2:0]][{in_kpair[2:0], 1'b0}] <= pi_stream_data[15:0];
                    input_buf[in_m[2:0]][{in_kpair[2:0], 1'b1}] <= pi_stream_data[31:16];
                    if (in_kpair == ((pi_tile_k_size[3:0] + 4'd1) >> 1) - 4'd1) begin
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

            // ─────────────── COMPUTE - Skewed feed + capture ───────
            ST_COMPUTE: begin
                // Capture po_psum_bottom vào psum_buf
                // Note: po_psum_bottom là registered output → đọc được giá trị từ
                // drive cycle TRƯỚC. Nên formula = cmp_t - ni - SA_N (không phải SA_N-1).
                for (ni = 0; ni < SA_N; ni = ni + 1) begin
                    if (pi_dp_valid_bottom[ni] && (ni < pi_tile_n_size)) begin
                        m_capture = cmp_t - ni - SA_N;
                        if (m_capture >= 0 && m_capture < pi_tile_m_size) begin
                            psum_buf[m_capture[2:0]][ni[2:0]] <=
                                pi_dp_psum_bottom[ni*ACC_WIDTH +: ACC_WIDTH];
                        end
                    end
                end

                // Transition khi cycle cuối
                if (cmp_t == (pi_tile_m_size + pi_tile_n_size + (SA_N - 2))) begin
                    state      <= ST_POST_PROC;
                    pp_in_m    <= 4'd0;
                    pp_in_n    <= 4'd0;
                    pp_in_cnt  <= 10'd0;
                    pp_out_m   <= 4'd0;
                    pp_out_n   <= 4'd0;
                    pp_out_cnt <= 10'd0;
                end else begin
                    cmp_t <= cmp_t + 10'd1;
                end
            end

            // ─────────────── POST_PROC - Feed + Capture (3-cycle pipeline) ───
            ST_POST_PROC: begin
                // ── Feed phase ──
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

                // ── Capture phase ──
                if (pi_pp_valid_out) begin
                    out_buf[pp_out_m[2:0]][pp_out_n[2:0]] <= pi_pp_data_out;
                    if (pp_out_n == pi_tile_n_size[3:0] - 4'd1) begin
                        pp_out_n <= 4'd0;
                        pp_out_m <= pp_out_m + 4'd1;
                    end else begin
                        pp_out_n <= pp_out_n + 4'd1;
                    end
                    pp_out_cnt <= pp_out_cnt + 10'd1;
                    if (pp_out_cnt == pi_tile_m_size * pi_tile_n_size - 10'd1) begin
                        state     <= ST_SEND_OUT;
                        send_row  <= 4'd0;
                        send_pair <= 4'd0;
                    end
                end
            end

            // ─────────────── SEND_OUT - AXIS master ───────────────
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

            // ─────────────── DONE ───────────────
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
