`timescale 1ns / 1ps

module control_unit #(
    parameter integer SA_N       = 8,
    parameter integer DATA_WIDTH = 16,
    parameter integer ACC_WIDTH  = 40,
    // Phase 1a-ii-B: số output-tile slot trong accumulator (blocking).
    // psum_buf[NUM_SLOTS][8][8] register → reuse = NUM_SLOTS× (cắt DDR weight).
    parameter integer NUM_SLOTS  = 4
)(
    input  wire                          pi_clk,
    input  wire                          pi_rst_n,

    // ── AXI-Lite config ──────────────────────────────────────────
    input  wire [9:0]                    pi_tile_m_size,
    input  wire [9:0]                    pi_tile_k_size,
    input  wire [9:0]                    pi_tile_n_size,
    input  wire [1:0]                    pi_act_mode,
    input  wire                          pi_start,
    // ── Phase 1a-i: HW K-accumulation control ──
    //   pi_acc_accum = 1 : COMPUTE cộng dồn vào psum_buf (K-tile > 0)
    //                = 0 : ghi đè psum_buf (K-tile 0 / single-tile — mặc định cũ)
    //   pi_post_skip = 1 : sau COMPUTE bỏ POST_PROC+SEND, về DONE (K-tile giữa)
    //                = 0 : chạy POST_PROC+SEND như cũ (K-tile cuối / single)
    input  wire                          pi_acc_accum,
    input  wire                          pi_post_skip,
    // ── Phase 1a-ii: data reuse ──
    //   pi_skip_w_load = 1 : bỏ LOAD_W, giữ weight cũ trong array (reuse).
    input  wire                          pi_skip_w_load,
    //   pi_acc_slot : chọn output-tile slot trong accumulator (blocking).
    input  wire [1:0]                    pi_acc_slot,
    //   pi_skip_in_load = 1 : bỏ LOAD_IN, giữ input cũ trong input_buf (reuse).
    input  wire                          pi_skip_in_load,
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
    input  wire                          pi_pp_valid_out,

    // ── Phase 0 instrumentation: per-state cycle counters ──────────
    //   pi_cnt_clear = 1 cycle pulse → reset all counters to 0.
    //   Counters wrap modulo 2^32. Read các po_cnt_* qua AXI-Lite.
    input  wire                          pi_cnt_clear,
    output wire [31:0]                   po_cnt_idle,
    output wire [31:0]                   po_cnt_load_w,
    output wire [31:0]                   po_cnt_load_b,
    output wire [31:0]                   po_cnt_load_in,
    output wire [31:0]                   po_cnt_compute,
    output wire [31:0]                   po_cnt_post_proc,
    output wire [31:0]                   po_cnt_send,
    output wire [31:0]                   po_cnt_done,
    output wire [31:0]                   po_cnt_total
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
    // psum_buf[slot][m][n] — NUM_SLOTS output tile (Phase 1a-ii-B blocking)
    reg [ACC_WIDTH-1:0]   psum_buf       [0:NUM_SLOTS-1][0:SA_N-1][0:SA_N-1];
    reg [DATA_WIDTH-1:0]  out_buf        [0:SA_N-1][0:SA_N-1];

    // ─────────────────────────────────────────────────────────────
    // Phase 0 instrumentation: per-state cycle counters
    // ─────────────────────────────────────────────────────────────
    reg [31:0] cnt_idle;
    reg [31:0] cnt_load_w;
    reg [31:0] cnt_load_b;
    reg [31:0] cnt_load_in;
    reg [31:0] cnt_compute;
    reg [31:0] cnt_post_proc;
    reg [31:0] cnt_send;
    reg [31:0] cnt_done;
    reg [31:0] cnt_total;

    assign po_cnt_idle      = cnt_idle;
    assign po_cnt_load_w    = cnt_load_w;
    assign po_cnt_load_b    = cnt_load_b;
    assign po_cnt_load_in   = cnt_load_in;
    assign po_cnt_compute   = cnt_compute;
    assign po_cnt_post_proc = cnt_post_proc;
    assign po_cnt_send      = cnt_send;
    assign po_cnt_done      = cnt_done;
    assign po_cnt_total     = cnt_total;

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
                    po_busy <= 1'b1;
                    if (pi_skip_w_load) begin
                        // 1a-ii: giữ weight cũ trong array → bỏ thẳng sang LOAD_BIAS.
                        state     <= ST_LOAD_BIAS;
                        bias_pair <= 4'd0;
                    end else begin
                        state   <= ST_LOAD_W_RECV;
                        w_row   <= 4'd0;
                        w_pair  <= 4'd0;
                    end
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
                        // 1a-ii-D: skip_in_load → giữ input cũ, vào thẳng COMPUTE.
                        if (pi_skip_in_load) begin
                            state <= ST_COMPUTE;
                            cmp_t <= 10'd0;
                        end else begin
                            state    <= ST_LOAD_IN;
                            in_m     <= 4'd0;
                            in_kpair <= 4'd0;
                        end
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
                            // Phase 1a-i: cộng dồn (K>0) hoặc ghi đè (K=0).
                            // Phase 1a-ii-B: vào slot pi_acc_slot (blocking).
                            if (pi_acc_accum)
                                psum_buf[pi_acc_slot][m_capture[2:0]][ni[2:0]] <=
                                    psum_buf[pi_acc_slot][m_capture[2:0]][ni[2:0]] +
                                    pi_dp_psum_bottom[ni*ACC_WIDTH +: ACC_WIDTH];
                            else
                                psum_buf[pi_acc_slot][m_capture[2:0]][ni[2:0]] <=
                                    pi_dp_psum_bottom[ni*ACC_WIDTH +: ACC_WIDTH];
                        end
                    end
                end

                // Transition khi cycle cuối
                if (cmp_t == (pi_tile_m_size + pi_tile_n_size + (SA_N - 2))) begin
                    // Phase 1a-i: K-tile giữa (post_skip) chỉ cộng dồn → về DONE,
                    // không POST_PROC/SEND. K-tile cuối (hoặc single) → POST_PROC.
                    if (pi_post_skip) begin
                        state <= ST_DONE;
                    end else begin
                        state      <= ST_POST_PROC;
                        pp_in_m    <= 4'd0;
                        pp_in_n    <= 4'd0;
                        pp_in_cnt  <= 10'd0;
                        pp_out_m   <= 4'd0;
                        pp_out_n   <= 4'd0;
                        pp_out_cnt <= 10'd0;
                    end
                end else begin
                    cmp_t <= cmp_t + 10'd1;
                end
            end

            // ─────────────── POST_PROC - Feed + Capture (3-cycle pipeline) ───
            ST_POST_PROC: begin
                // ── Feed phase ──
                if (pp_in_cnt < pi_tile_m_size * pi_tile_n_size) begin
                    po_pp_valid_in <= 1'b1;
                    po_pp_acc_in   <= psum_buf[pi_acc_slot][pp_in_m[2:0]][pp_in_n[2:0]];
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

    // ─────────────────────────────────────────────────────────────
    // Phase 0 instrumentation: counter update logic
    //   Mỗi cycle increment counter của state hiện tại + cnt_total.
    //   pi_cnt_clear pulse → tất cả counter về 0 (đè reset).
    //   Counter wrap modulo 2^32 nếu không clear.
    // ─────────────────────────────────────────────────────────────
    always @(posedge pi_clk or negedge pi_rst_n) begin : cnt_logic
        if (!pi_rst_n) begin
            cnt_idle      <= 32'd0;
            cnt_load_w    <= 32'd0;
            cnt_load_b    <= 32'd0;
            cnt_load_in   <= 32'd0;
            cnt_compute   <= 32'd0;
            cnt_post_proc <= 32'd0;
            cnt_send      <= 32'd0;
            cnt_done      <= 32'd0;
            cnt_total     <= 32'd0;
        end else if (pi_cnt_clear) begin
            cnt_idle      <= 32'd0;
            cnt_load_w    <= 32'd0;
            cnt_load_b    <= 32'd0;
            cnt_load_in   <= 32'd0;
            cnt_compute   <= 32'd0;
            cnt_post_proc <= 32'd0;
            cnt_send      <= 32'd0;
            cnt_done      <= 32'd0;
            cnt_total     <= 32'd0;
        end else begin
            cnt_total <= cnt_total + 32'd1;
            case (state)
                ST_IDLE:          cnt_idle      <= cnt_idle      + 32'd1;
                ST_LOAD_W_RECV,
                ST_LOAD_W_PULSE:  cnt_load_w    <= cnt_load_w    + 32'd1;
                ST_LOAD_BIAS:     cnt_load_b    <= cnt_load_b    + 32'd1;
                ST_LOAD_IN:       cnt_load_in   <= cnt_load_in   + 32'd1;
                ST_COMPUTE:       cnt_compute   <= cnt_compute   + 32'd1;
                ST_POST_PROC:     cnt_post_proc <= cnt_post_proc + 32'd1;
                ST_SEND_OUT:      cnt_send      <= cnt_send      + 32'd1;
                ST_DONE:          cnt_done      <= cnt_done      + 32'd1;
                default: ;
            endcase
        end
    end

endmodule
