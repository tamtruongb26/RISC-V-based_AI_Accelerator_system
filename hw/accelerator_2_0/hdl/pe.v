`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module:  pe - Processing Element (TPU-like Weight-Stationary Systolic)
// Project: accelerator_2_0
//
// ============================================================================
// REWRITE từ phiên bản BROADCAST (fpga/Accelerator_v2_tb.srcs/sources_1/new/pe.v)
// → TPU CANONICAL.
//
// Cái GIỮ NGUYÊN từ broadcast PE:
//   - Weight register `w_reg` cố định (weight stationary).
//   - Multiply signed Q1.4.11 × Q1.4.11 = Q2.8.22 (32-bit), sign-extend lên 40-bit.
//   - Synchronous reset, flow control bằng valid signals.
//
// Cái ĐỔI để thành TPU systolic (a chảy ngang):
//   1. THÊM port `pi_a_in` + `po_a_out`. Trong tile compute, activation chảy
//      từ trái sang phải, mỗi PE delay 1 cycle (registered).
//      → Thay thế broadcast bus: trước đây cùng `d_in` đến mọi cột của row.
//   2. ĐỔI 2 valid (`pi_valid_d` + `pi_valid_acc`) thành 1 valid duy nhất
//      (`pi_valid_in` → `po_valid_out`). Valid chảy NGANG cùng a, không còn
//      vertical valid chain. Lý do: trong TPU systolic, valid của 1 phép MAC
//      gắn với data đang đi qua, không gắn với psum (psum luôn pipeline).
//   3. ĐỔI điều kiện MAC:
//        valid_in=1 : psum_out = psum_in + a_in*w_reg   (cộng dồn)
//        valid_in=0 : psum_out = psum_in                (pass-through)
//      Vì input feed bị skewed (xem control_unit.v), một số PE trên đường
//      chéo sẽ chưa có activation hợp lệ - phải pass psum qua chứ không clear.
//   4. weight_load=1 còn CLEAR thêm `a_reg` và `valid_reg` (không chỉ psum).
//      Đảm bảo tile mới bắt đầu sạch hoàn toàn.
//
// Đổi tên port để thống nhất convention:
//   d_in / acc_in / acc_out → pi_a_in / pi_psum_in / po_psum_out
//   (tất cả input có prefix `pi_`, output có prefix `po_`)
//
// Dataflow trong 8x8 grid (xem data_path.v):
//   - a chảy ngang  : pi_a_in[0,c] = pi_a_left[c], pi_a_in[r+1,c] = po_a_out[r,c]
//   - psum chảy dọc : pi_psum_in[r,0] = 0, pi_psum_in[r,c+1] = po_psum_out[r,c]
//   - weight đứng yên: nạp 1 lần đầu tile, dùng cả tile
//
// Latency 1 PE: 1 cycle (a register), 1 cycle (psum register) - cùng nhịp.
//////////////////////////////////////////////////////////////////////////////////

module pe #(
    parameter integer DATA_WIDTH = 16,
    parameter integer ACC_WIDTH  = 40
)(
    input  wire                          pi_clk,
    input  wire                          pi_rst_n,

    // Weight load control:
    //   1 = nạp pi_w_in vào w_reg, đồng thời clear pipeline (a_reg, valid_reg, psum_reg)
    //   0 = compute mode (pipeline registers chạy bình thường)
    input  wire                          pi_weight_load,
    input  wire signed [DATA_WIDTH-1:0]  pi_w_in,

    // Horizontal: activation chảy left → right (1-cycle register delay).
    // Single valid signal đi cùng a
    // pi_valid_in == 1: po_psum_out = pi_psum_in + mult_ext
    // pi_valid_in == 0: po_psum_out = pi_psum_in
    input  wire signed [DATA_WIDTH-1:0]  pi_a_in,
    input  wire                          pi_valid_in,
    output wire signed [DATA_WIDTH-1:0]  po_a_out,
    output wire                          po_valid_out,

    // Vertical: partial-sum chảy top → bottom (1-cycle register delay).
    input  wire signed [ACC_WIDTH-1:0]   pi_psum_in,
    output wire signed [ACC_WIDTH-1:0]   po_psum_out
);

    // ----- Internal pipeline registers -----
    reg signed [DATA_WIDTH-1:0] w_reg;       // weight register
    reg signed [DATA_WIDTH-1:0] a_reg;       // activation data register
    reg                         valid_reg;   // valid register
    reg signed [ACC_WIDTH-1:0]  psum_reg;    // accumulate register

    // ----- Combinational multiply (sign-extend Q2.8.22 → 40-bit) -----
    wire signed [2*DATA_WIDTH-1:0] mult_raw;
    wire signed [ACC_WIDTH-1:0]    mult_ext;

    assign mult_raw = $signed(pi_a_in) * $signed(w_reg);
    assign mult_ext = {{(ACC_WIDTH - 2*DATA_WIDTH){mult_raw[2*DATA_WIDTH-1]}},
                       mult_raw};

    // ----- Sequential -----
    always @(posedge pi_clk or negedge pi_rst_n) begin
        if (!pi_rst_n) begin
            w_reg     <= {DATA_WIDTH{1'b0}};
            a_reg     <= {DATA_WIDTH{1'b0}};
            valid_reg <= 1'b0;
            psum_reg  <= {ACC_WIDTH{1'b0}};
        end else if (pi_weight_load) begin
            // Nạp weight + clear toàn bộ pipeline để tile mới bắt đầu sạch.
            w_reg     <= pi_w_in;
            a_reg     <= {DATA_WIDTH{1'b0}};
            valid_reg <= 1'b0;
            psum_reg  <= {ACC_WIDTH{1'b0}};
        end else begin
            // Compute mode: cả 3 pipeline reg đều luôn advance.
            a_reg     <= pi_a_in;
            valid_reg <= pi_valid_in;
            if (pi_valid_in)
                psum_reg <= pi_psum_in + mult_ext;     // accumulate
            else
                psum_reg <= pi_psum_in;                // pass through (KHÔNG clear)
        end
    end

    // ----- Combinational outputs từ register -----
    assign po_a_out     = a_reg;
    assign po_valid_out = valid_reg;
    assign po_psum_out  = psum_reg;

endmodule
