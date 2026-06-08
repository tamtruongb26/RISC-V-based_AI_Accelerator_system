`timescale 1ns / 1ps
// ===========================================================================
// auto_seq.v — Outer-loop sequencer (Phase 2c full autonomy)
//
// "PicoRV32 bằng phần cứng": nhận 1 descriptor (số tile m/k/n + base địa chỉ)
// → tự duyệt tile, mỗi tile ra lệnh dma_ctrl chuyển dữ liệu + set CFG/start cho
// accelerator. Bỏ ~1000 lần Pico lập trình DMA + poll.
//
// Tiền đề (Stage 3): input đã được PS/Pico stage thành các BLOCK liền mạch theo
// đúng thứ tự duyệt — mỗi block = [W(32w)][bias(4w)][A(tile_m·⌈k/2⌉ w)]. auto_seq
// chỉ tăng địa chỉ tuyến tính (in_addr += in_blk_bytes), không cần gather strided.
//
// Thứ tự duyệt (khớp gemm_tiled): for n: for m: for k  (k trong cùng → K-accum).
//   k==0      → ghi đè psum (acc_accum=0);  k>0 → cộng dồn (acc_accum=1)
//   k<last    → post_skip=1 (không POST/SEND, không S2MM)
//   k==last   → post_skip=0, act=act_mode, S2MM ghi tile output
// ===========================================================================
module auto_seq #(
    parameter integer TILE_CW = 10   // bề rộng đếm tile mỗi chiều
)(
    input  wire        pi_clk,
    input  wire        pi_rst_n,

    // ── Descriptor (từ slave_lite, hoặc TB drive) ──
    input  wire        pi_go,                 // pulse: bắt đầu GEMM tự hành
    input  wire [TILE_CW-1:0] pi_m_tiles,     // số m-tile (≥1)
    input  wire [TILE_CW-1:0] pi_k_tiles,     // số k-tile (≥1)
    input  wire [TILE_CW-1:0] pi_n_tiles,     // số n-tile (≥1)
    input  wire [31:0] pi_in_base,            // base block input liền mạch
    input  wire [25:0] pi_in_blk_bytes,       // byte/1 block input (W+bias+A)
    input  wire [31:0] pi_out_base,           // base tile output
    input  wire [25:0] pi_out_blk_bytes,      // byte/1 tile output
    input  wire [9:0]  pi_tile_m,             // kích thước tile (thường 8)
    input  wire [9:0]  pi_tile_k,
    input  wire [9:0]  pi_tile_n,
    input  wire [1:0]  pi_act_mode,

    output reg         po_busy,
    output reg         po_done,               // 1 pulse khi cả GEMM xong

    // ── Tới dma_ctrl ──
    output reg         po_dma_start,
    output reg         po_dma_do_s2mm,
    output reg  [31:0] po_dma_mm2s_addr,
    output reg  [25:0] po_dma_mm2s_len,
    output reg  [31:0] po_dma_s2mm_addr,
    output reg  [25:0] po_dma_s2mm_len,
    input  wire        pi_dma_done,

    // ── Tới accelerator config (mux 'auto' chọn các tín hiệu này) ──
    output reg         po_accel_start,
    output reg  [9:0]  po_tile_m,
    output reg  [9:0]  po_tile_k,
    output reg  [9:0]  po_tile_n,
    output reg  [1:0]  po_act_mode,
    output reg         po_acc_accum,
    output reg         po_post_skip,
    output reg         po_skip_w_load,
    output reg  [1:0]  po_acc_slot,
    output reg         po_skip_in_load,
    input  wire        pi_accel_done
);
    localparam [2:0] S_IDLE   = 3'd0,
                     S_SETUP  = 3'd1,
                     S_LAUNCH = 3'd2,
                     S_WAIT   = 3'd3,
                     S_NEXT   = 3'd4,
                     S_DONE   = 3'd5;
    reg [2:0] state;

    reg [TILE_CW-1:0] kc, mc, nc;
    reg [31:0] in_addr, out_addr;
    reg        accel_done_l, dma_done_l;

    wire last_k = (kc + {{(TILE_CW-1){1'b0}},1'b1} >= pi_k_tiles);

    always @(posedge pi_clk or negedge pi_rst_n) begin
        if (!pi_rst_n) begin
            state          <= S_IDLE;
            po_busy        <= 1'b0;
            po_done        <= 1'b0;
            po_dma_start   <= 1'b0;
            po_accel_start <= 1'b0;
            kc <= 0; mc <= 0; nc <= 0;
            in_addr  <= 32'd0;
            out_addr <= 32'd0;
            accel_done_l <= 1'b0;
            dma_done_l   <= 1'b0;
            po_dma_do_s2mm   <= 1'b0;
            po_dma_mm2s_addr <= 32'd0; po_dma_mm2s_len <= 26'd0;
            po_dma_s2mm_addr <= 32'd0; po_dma_s2mm_len <= 26'd0;
            po_tile_m <= 10'd0; po_tile_k <= 10'd0; po_tile_n <= 10'd0;
            po_act_mode <= 2'd0; po_acc_accum <= 1'b0; po_post_skip <= 1'b0;
            po_skip_w_load <= 1'b0; po_acc_slot <= 2'd0; po_skip_in_load <= 1'b0;
        end else begin
            po_dma_start   <= 1'b0;
            po_accel_start <= 1'b0;
            po_done        <= 1'b0;

            case (state)
            S_IDLE: begin
                po_busy <= 1'b0;
                if (pi_go) begin
                    po_busy  <= 1'b1;
                    kc <= 0; mc <= 0; nc <= 0;
                    in_addr  <= pi_in_base;
                    out_addr <= pi_out_base;
                    state    <= S_SETUP;
                end
            end

            // Chuẩn bị CFG accel + tham số dma cho tile hiện tại
            S_SETUP: begin
                po_tile_m    <= pi_tile_m;
                po_tile_k    <= pi_tile_k;
                po_tile_n    <= pi_tile_n;
                po_acc_accum    <= (kc != 0);          // k>0 cộng dồn
                po_post_skip    <= !last_k;            // chưa last → không POST/SEND
                po_act_mode     <= last_k ? pi_act_mode : 2'b00;  // bypass tới last
                po_skip_w_load  <= 1'b0;               // mỗi tile nạp W riêng
                po_acc_slot     <= 2'd0;
                po_skip_in_load <= 1'b0;
                // dma: MM2S đọc block input liền mạch; S2MM chỉ khi last_k
                po_dma_mm2s_addr <= in_addr;
                po_dma_mm2s_len  <= pi_in_blk_bytes;
                po_dma_do_s2mm   <= last_k;
                po_dma_s2mm_addr <= out_addr;
                po_dma_s2mm_len  <= pi_out_blk_bytes;
                accel_done_l <= 1'b0;
                dma_done_l   <= 1'b0;
                state        <= S_LAUNCH;
            end

            // Khởi động đồng thời accel + dma (accel backpressure chờ AXIS)
            S_LAUNCH: begin
                po_accel_start <= 1'b1;
                po_dma_start   <= 1'b1;
                state          <= S_WAIT;
            end

            // Chờ cả accel DONE và dma done
            S_WAIT: begin
                if (pi_accel_done) accel_done_l <= 1'b1;
                if (pi_dma_done)   dma_done_l   <= 1'b1;
                if ((accel_done_l || pi_accel_done) &&
                    (dma_done_l   || pi_dma_done)) begin
                    state <= S_NEXT;
                end
            end

            // Tăng địa chỉ + đếm vòng (k → m → n)
            S_NEXT: begin
                in_addr <= in_addr + {6'd0, pi_in_blk_bytes};
                if (last_k) out_addr <= out_addr + {6'd0, pi_out_blk_bytes};

                if (last_k) begin
                    kc <= 0;
                    if (mc + 1 >= pi_m_tiles) begin
                        mc <= 0;
                        if (nc + 1 >= pi_n_tiles) begin
                            state <= S_DONE;          // hết toàn bộ GEMM
                        end else begin
                            nc <= nc + 1; state <= S_SETUP;
                        end
                    end else begin
                        mc <= mc + 1; state <= S_SETUP;
                    end
                end else begin
                    kc <= kc + 1; state <= S_SETUP;
                end
            end

            S_DONE: begin
                po_done <= 1'b1;
                po_busy <= 1'b0;
                state   <= S_IDLE;
            end

            default: state <= S_IDLE;
            endcase
        end
    end
endmodule
