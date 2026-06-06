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
    // ── Phase 2a: HW im2col mode ──
    //   pi_im2col_mode = 1 : accelerator chạy im2col (FM→A) thay GEMM.
    //   cfg0 = {KW[31:28],KH[27:24],C[23:16],W[15:8],H[7:0]}
    //   cfg1 = {pad[23:20],stride[19:16],Wout[15:8],Hout[7:0]}
    input  wire                          pi_im2col_mode,
    input  wire [31:0]                   pi_im2col_cfg0,
    input  wire [31:0]                   pi_im2col_cfg1,
    // ── Phase 3a: OS dataflow (FC) ──
    input  wire                          pi_os_mode,
    output reg                           po_busy,
    output reg                           po_done,

    // ── AXIS slave (DMA → accelerator) ───────────────────────────
    input  wire [31:0]                   pi_stream_data,
    input  wire                          pi_stream_valid,
    output wire                          po_stream_ready,
    output wire                          po_loading,

    // ── AXIS master (accelerator → DMA) ──────────────────────────
    output wire [15:0]                   po_num_out_transfers,
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
    localparam [4:0] ST_IDLE         = 5'd0;
    localparam [4:0] ST_LOAD_W_RECV  = 5'd1;
    localparam [4:0] ST_LOAD_W_PULSE = 5'd2;
    localparam [4:0] ST_LOAD_BIAS    = 5'd3;
    localparam [4:0] ST_LOAD_IN      = 5'd4;
    localparam [4:0] ST_COMPUTE      = 5'd5;
    localparam [4:0] ST_POST_PROC    = 5'd6;
    localparam [4:0] ST_SEND_OUT     = 5'd7;
    localparam [4:0] ST_DONE         = 5'd8;
    // Phase 2a: im2col mode states
    localparam [4:0] ST_LOAD_FM      = 5'd9;
    localparam [4:0] ST_LOAD_FM_HI   = 5'd10;
    localparam [4:0] ST_IM2COL_RUN   = 5'd11;
    localparam [4:0] ST_SEND_A_R0    = 5'd12;
    localparam [4:0] ST_SEND_A_R1    = 5'd13;
    localparam [4:0] ST_SEND_A_TX    = 5'd14;
    // Phase 3a: OS dataflow states (FC)
    localparam [4:0] ST_OS_LOAD_W    = 5'd15;  // AXIS weight tile → w_os_buf
    localparam [4:0] ST_OS_LOAD_A    = 5'd16;  // AXIS a-vector → a_os_buf
    localparam [4:0] ST_OS_FEED      = 5'd17;  // feed os_array (accumulate)
    localparam [4:0] ST_OS_DRAIN     = 5'd18;  // copy c[n] → psum_buf[0][n]

    localparam integer WORDS_PER_ROW = SA_N / 2;   // 4 cho SA_N=8

    reg [4:0] state;

    // ── Phase 2a/1b: im2col datapath ──
    // Blocking: load FM 1 lần; lặp nội bộ từng output-row ho (HO_BLK=1 ho/block),
    // mỗi block im2col sinh Wout hàng A → SEND ra.
    // 1b-a: TÁCH 2 scratchpad — u_sp_fm (FM, im2col đọc) + u_sp_a (A, im2col ghi /
    // SEND đọc). Port riêng → im2col-đọc-FM và SEND-đọc-A chạy đồng thời được
    // (nền cho double-buffer 1b-b). A-scratchpad 2 bank cho ping-pong sau.
    localparam integer SP_FM_DEPTH = 1024;         // FM tối đa (Conv2 864)
    localparam integer SP_A_DEPTH  = 2048;         // 1 block A (Conv2 Wout*K=1200)

    // Unpack config
    wire [7:0] ic_H    = pi_im2col_cfg0[7:0];
    wire [7:0] ic_W    = pi_im2col_cfg0[15:8];
    wire [7:0] ic_C    = pi_im2col_cfg0[23:16];
    wire [3:0] ic_KH   = pi_im2col_cfg0[27:24];
    wire [3:0] ic_KW   = pi_im2col_cfg0[31:28];
    wire [7:0] ic_Hout = pi_im2col_cfg1[7:0];
    wire [7:0] ic_Wout = pi_im2col_cfg1[15:8];
    wire [3:0] ic_str  = pi_im2col_cfg1[19:16];
    wire [3:0] ic_pad  = pi_im2col_cfg1[23:20];
    wire [15:0] fm_total = ic_C * ic_H * ic_W;     // số phần tử feature map

    reg  [15:0] fm_idx;     // index ghi FM linear
    reg  [15:0] fm_hi;      // nửa cao word AXIS đang chờ ghi
    reg         ic_start;
    reg  [11:0] a_word;     // index word trong block khi gửi A ra
    reg  [15:0] send_lo;    // nửa thấp A đang pack
    reg  [7:0]  ho_cur;     // block ho hiện tại

    // 1 block (1 ho-row) = Wout hàng A × K element. a_nwords = word/block.
    wire [15:0] a_k       = ic_C * ic_KH * ic_KW;
    wire [19:0] blk_elems = ic_Wout * a_k;
    wire [15:0] a_nwords  = (blk_elems + 20'd1) >> 1;       // word / block (SEND loop)
    wire [15:0] tot_words = ic_Hout * a_nwords;             // total (TLAST shim)

    // im2col ↔ scratchpad wires
    wire        ic_fm_rd_en;  wire [15:0] ic_fm_rd_addr;
    wire        ic_a_wr_en;   wire [15:0] ic_a_wr_addr;  wire [15:0] ic_a_wr_data;
    wire        ic_busy, ic_done;
    wire [15:0] sp_fm_rd_data;   // u_sp_fm read → im2col
    wire [15:0] sp_a_rd_data;    // u_sp_a read  → SEND

    // ── u_sp_fm (feature map) ──
    // write: FM load (LOAD_FM/_HI). read: im2col fm_rd.
    reg         fm_wr_en;  reg [10:0] fm_wr_addr;  reg [15:0] fm_wr_data;
    always @(*) begin
        if (state == ST_LOAD_FM) begin
            fm_wr_en = pi_stream_valid; fm_wr_addr = fm_idx[10:0]; fm_wr_data = pi_stream_data[15:0];
        end else if (state == ST_LOAD_FM_HI) begin
            fm_wr_en = 1'b1;            fm_wr_addr = fm_idx[10:0]; fm_wr_data = fm_hi;
        end else begin
            fm_wr_en = 1'b0;           fm_wr_addr = 11'd0;        fm_wr_data = 16'd0;
        end
    end
    wire        fm_rd_en   = (state == ST_IM2COL_RUN) && ic_fm_rd_en;
    wire [10:0] fm_rd_addr = ic_fm_rd_addr[10:0];

    // ── u_sp_a (im2col output A) ──
    // write: im2col a_wr. read: SEND R0/R1.
    wire        a_wr_en   = (state == ST_IM2COL_RUN) && ic_a_wr_en;
    wire [10:0] a_wr_addr = ic_a_wr_addr[10:0];
    reg         a_rd_en;  reg [10:0] a_rd_addr;
    always @(*) begin
        if (state == ST_SEND_A_R0) begin
            a_rd_en = 1'b1; a_rd_addr = {a_word[9:0], 1'b0};         // 2w
        end else if (state == ST_SEND_A_R1) begin
            a_rd_en = 1'b1; a_rd_addr = {a_word[9:0], 1'b0} + 11'd1; // 2w+1
        end else begin
            a_rd_en = 1'b0; a_rd_addr = 11'd0;
        end
    end

    scratchpad #(.DATA_WIDTH(16), .DEPTH(SP_FM_DEPTH)) u_sp_fm (
        .pi_clk(pi_clk),
        .pi_wr_en(fm_wr_en), .pi_wr_bank(1'b0), .pi_wr_addr(fm_wr_addr), .pi_wr_data(fm_wr_data),
        .pi_rd_en(fm_rd_en), .pi_rd_bank(1'b0), .pi_rd_addr(fm_rd_addr), .po_rd_data(sp_fm_rd_data)
    );

    scratchpad #(.DATA_WIDTH(16), .DEPTH(SP_A_DEPTH)) u_sp_a (
        .pi_clk(pi_clk),
        .pi_wr_en(a_wr_en), .pi_wr_bank(1'b0), .pi_wr_addr(a_wr_addr), .pi_wr_data(ic_a_wr_data),
        .pi_rd_en(a_rd_en), .pi_rd_bank(1'b0), .pi_rd_addr(a_rd_addr), .po_rd_data(sp_a_rd_data)
    );

    im2col #(.DATA_WIDTH(16), .ADDR_WIDTH(16), .DIM_WIDTH(8)) u_im2col (
        .pi_clk(pi_clk), .pi_rst_n(pi_rst_n), .pi_start(ic_start),
        .po_busy(ic_busy), .po_done(ic_done),
        .pi_H(ic_H), .pi_W(ic_W), .pi_C(ic_C), .pi_KH(ic_KH), .pi_KW(ic_KW),
        .pi_stride(ic_str), .pi_pad(ic_pad),
        .pi_ho_start(ho_cur), .pi_ho_count(8'd1), .pi_W_out(ic_Wout),
        .po_fm_rd_en(ic_fm_rd_en), .po_fm_rd_addr(ic_fm_rd_addr), .pi_fm_rd_data(sp_fm_rd_data),
        .po_a_wr_en(ic_a_wr_en), .po_a_wr_addr(ic_a_wr_addr), .po_a_wr_data(ic_a_wr_data)
    );

    // ── Phase 3a: OS dataflow datapath (FC) ──
    reg  [SA_N*SA_N*DATA_WIDTH-1:0] w_os_buf;   // weight tile [k][n] (1024-bit)
    reg  [SA_N*DATA_WIDTH-1:0]      a_os_buf;    // a vector (128-bit)
    reg  [3:0]                      os_row, os_pair;
    wire [SA_N*ACC_WIDTH-1:0]       os_c;
    wire                            os_c_valid;

    os_array #(.SA_N(SA_N), .DATA_WIDTH(DATA_WIDTH), .ACC_WIDTH(ACC_WIDTH)) u_os (
        .pi_clk(pi_clk), .pi_rst_n(pi_rst_n),
        .pi_valid((state == ST_OS_FEED)), .pi_accumulate(pi_acc_accum),
        .pi_a(a_os_buf), .pi_w(w_os_buf),
        .po_c(os_c), .po_valid(os_c_valid)
    );

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
                                  (state == ST_LOAD_IN)     ||
                                  (state == ST_LOAD_FM)     ||
                                  (state == ST_OS_LOAD_W)   ||
                                  (state == ST_OS_LOAD_A);
    assign po_stream_ready      = po_loading;
    assign po_out_write_req     = (state == ST_SEND_OUT) || (state == ST_SEND_A_TX);
    assign po_num_out_transfers = pi_im2col_mode ? tot_words :
                                  {6'd0, (pi_tile_m_size * ((pi_tile_n_size + 10'd1) >> 1))};
    assign po_out_data          = (state == ST_SEND_A_TX) ?
                                  {sp_a_rd_data, send_lo} :
                                  {out_buf[send_row[2:0]][{send_pair[2:0], 1'b1}],
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
            fm_idx                <= 16'd0;
            fm_hi                 <= 16'd0;
            ic_start              <= 1'b0;
            a_word                <= 12'd0;
            send_lo               <= 16'd0;
            ho_cur                <= 8'd0;
        end else begin
            // ── Default deassertions (chỉ pulse khi cần) ──
            po_dp_weight_load <= 1'b0;
            po_done           <= 1'b0;
            po_pp_valid_in    <= 1'b0;
            ic_start          <= 1'b0;

            case (state)

            // ───────────────── IDLE ─────────────────
            ST_IDLE: begin
                po_busy <= 1'b0;
                if (pi_start) begin
                    po_busy <= 1'b1;
                    if (pi_im2col_mode) begin
                        // Phase 2a: chế độ im2col — nạp feature map → scratchpad.
                        state  <= ST_LOAD_FM;
                        fm_idx <= 16'd0;
                        ho_cur <= 8'd0;
                    end else if (pi_os_mode) begin
                        // Phase 3a: OS dataflow (FC) — nạp weight tile → w_os_buf.
                        state   <= ST_OS_LOAD_W;
                        os_row  <= 4'd0;
                        os_pair <= 4'd0;
                    end else if (pi_skip_w_load) begin
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

            // ─────────── IM2COL: nạp feature map vào scratchpad ──────────
            // AXIS word = {hi16, lo16} → ghi 2 phần tử 16-bit / word.
            ST_LOAD_FM: begin
                if (pi_stream_valid) begin
                    // lo ghi qua sp_wr mux ở cycle này (addr=fm_idx)
                    fm_hi  <= pi_stream_data[31:16];
                    fm_idx <= fm_idx + 16'd1;
                    if (fm_idx + 16'd1 >= fm_total) begin
                        ic_start <= 1'b1;
                        state    <= ST_IM2COL_RUN;
                    end else begin
                        state <= ST_LOAD_FM_HI;
                    end
                end
            end

            ST_LOAD_FM_HI: begin
                // hi ghi qua sp_wr mux ở cycle này (addr=fm_idx)
                fm_idx <= fm_idx + 16'd1;
                if (fm_idx + 16'd1 >= fm_total) begin
                    ic_start <= 1'b1;
                    state    <= ST_IM2COL_RUN;
                end else begin
                    state <= ST_LOAD_FM;
                end
            end

            // ─────────── IM2COL: chạy engine (FM→A trong scratchpad) ──────
            ST_IM2COL_RUN: begin
                if (ic_done) begin
                    a_word <= 12'd0;
                    state  <= ST_SEND_A_R0;
                end
            end

            // ─────────── IM2COL: gửi ma trận A từ scratchpad ra AXIS ──────
            ST_SEND_A_R0: begin           // issue read A[2w] (qua sp_rd mux)
                state <= ST_SEND_A_R1;
            end
            ST_SEND_A_R1: begin           // sp_a_rd_data = A[2w]; issue read A[2w+1]
                send_lo <= sp_a_rd_data;
                state   <= ST_SEND_A_TX;
            end
            ST_SEND_A_TX: begin           // po_out_data={sp_rd_data(=A[2w+1]),send_lo}
                if (pi_out_write_done) begin
                    if (a_word + 12'd1 >= a_nwords[11:0]) begin
                        // hết word của block này → sang block ho kế hoặc xong
                        if (ho_cur + 8'd1 >= ic_Hout) begin
                            state <= ST_DONE;
                        end else begin
                            ho_cur   <= ho_cur + 8'd1;
                            a_word   <= 12'd0;
                            ic_start <= 1'b1;       // im2col block ho kế
                            state    <= ST_IM2COL_RUN;
                        end
                    end else begin
                        a_word <= a_word + 12'd1;
                        state  <= ST_SEND_A_R0;
                    end
                end
            end

            // ─────────── Phase 3a: OS dataflow (FC) ────────────
            ST_OS_LOAD_W: begin              // 32 word → w_os_buf[k][n]
                if (pi_stream_valid) begin
                    w_os_buf[(os_row*SA_N + {os_pair[2:0],1'b0})*DATA_WIDTH +: DATA_WIDTH]
                        <= pi_stream_data[15:0];
                    w_os_buf[(os_row*SA_N + {os_pair[2:0],1'b1})*DATA_WIDTH +: DATA_WIDTH]
                        <= pi_stream_data[31:16];
                    if (os_pair == WORDS_PER_ROW - 1) begin
                        os_pair <= 4'd0;
                        if (os_row == SA_N - 1) begin os_row <= 4'd0; state <= ST_OS_LOAD_A; end
                        else os_row <= os_row + 4'd1;
                    end else os_pair <= os_pair + 4'd1;
                end
            end
            ST_OS_LOAD_A: begin              // 4 word → a_os_buf[k]
                if (pi_stream_valid) begin
                    a_os_buf[{os_pair[2:0],1'b0}*DATA_WIDTH +: DATA_WIDTH] <= pi_stream_data[15:0];
                    a_os_buf[{os_pair[2:0],1'b1}*DATA_WIDTH +: DATA_WIDTH] <= pi_stream_data[31:16];
                    if (os_pair == WORDS_PER_ROW - 1) begin os_pair <= 4'd0; state <= ST_OS_FEED; end
                    else os_pair <= os_pair + 4'd1;
                end
            end
            ST_OS_FEED: begin                // os_array accumulate 1 K-tile (pi_valid)
                if (pi_post_skip) state <= ST_DONE;       // K-tile giữa: chỉ cộng dồn
                else              state <= ST_OS_DRAIN;    // K-tile cuối: → post_proc
            end
            ST_OS_DRAIN: begin               // c[n] → psum_buf[slot][0][n]; bias=0 (SW bias)
                for (ni = 0; ni < SA_N; ni = ni + 1) begin
                    psum_buf[pi_acc_slot][0][ni[2:0]] <= os_c[ni*ACC_WIDTH +: ACC_WIDTH];
                    bias_buf[ni[2:0]] <= {DATA_WIDTH{1'b0}};
                end
                pp_in_m <= 4'd0; pp_in_n <= 4'd0;
                pp_out_m <= 4'd0; pp_out_n <= 4'd0; pp_out_cnt <= 10'd0;
                state <= ST_POST_PROC;
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
