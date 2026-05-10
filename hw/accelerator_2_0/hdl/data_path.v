`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module:  data_path - SA_N × SA_N TPU-like Weight-Stationary Systolic Array
// Project: accelerator_2_0
//
// ============================================================================
// REWRITE từ phiên bản BROADCAST (fpga/Accelerator_v2_tb.srcs/sources_1/new/data_path.v)
// → TPU CANONICAL.
//
// Cái GIỮ NGUYÊN:
//   - SA_N × SA_N grid sinh bằng `genvar`.
//   - Weight nạp 1 hàng PE / cycle (broadcast `pi_weight_data` 1→N theo cột,
//     gate bằng `pi_weight_row_sel == r`).
//   - Top edge mỗi cột nối psum=0 (input của PE(0,c)).
//   - Output lấy từ bottom row mỗi cột.
//
// Cái ĐỔI để thành TPU systolic (a chảy ngang):
//   1. THAY broadcast `pi_a_row_data[r]` → mọi cột row r,
//      bằng HORIZONTAL CHAIN: chỉ PE(r,0) nhận từ port `pi_a_left[r]`,
//      các PE còn lại lấy từ PE bên trái: PE(r,c).pi_a_in = PE(r,c-1).po_a_out.
//      → Internal wire 2D `a_h[r][c]` cho a-bus chiều ngang (size N+1 mỗi row,
//      cột 0 là từ port ngoài, cột 1..N là output của PE(r, 0..N-1)).
//   2. ĐỔI `pi_a_row_valid` → `pi_valid_left`, cũng chỉ vào cột 0,
//      sau đó propagate ngang: `valid_h[r][c+1] = PE(r,c).po_valid_out`.
//      Bỏ vertical valid chain `acc_valid_v` (TPU không cần - psum luôn pipeline,
//      validity được đánh dấu bởi `valid_h[r][c]` đi cùng activation).
//   3. ĐỔI tên port output: po_result_data/_valid → po_psum_bottom/po_valid_bottom.
//   4. ĐỔI tên port input: pi_a_row_data/_valid → pi_a_left/pi_valid_left.
//
// Geometry & timing (xem firmware skewed feed trong control_unit.v):
//   - PE(r, c) nắm W[r][c] (r = K-axis, c = N-axis).
//   - Tại cycle t, pi_a_left[r] = A[t-r][r] khi 0 ≤ t-r < M (skewed by r).
//   - C[m][n] xuất hiện tại psum_v[K][n] khi cmp_t = m + n + K.
//   - po_valid_bottom[n] high tại đúng cycle đó (đi cùng po_psum_bottom).
//
// Latency 1 tile M×K×N: M+N+K-1 cycle (sau pipeline fill, throughput 1 row/cycle).
//////////////////////////////////////////////////////////////////////////////////

module data_path #(
    parameter integer SA_N          = 8,
    parameter integer DATA_WIDTH    = 16,
    parameter integer ACC_WIDTH     = 40,
    parameter integer ROW_SEL_WIDTH = (SA_N <= 1) ? 1 : $clog2(SA_N)
)(
    input  wire                           pi_clk,
    input  wire                           pi_rst_n,

    //   pi_weight_load   = 1 cycle pulse, chỉ row được chọn mới latch.
    //   pi_weight_row_sel = 0..SA_N-1, row nào sẽ nhận pi_weight_data.
    //   pi_weight_data   = SA_N weight cho hàng đó (col 0 = LSB, col N-1 = MSB).
    input  wire                           pi_weight_load,
    input  wire [ROW_SEL_WIDTH-1:0]       pi_weight_row_sel,
    input  wire [SA_N*DATA_WIDTH-1:0]     pi_weight_data,

    //   pi_a_left[r] = activation cho PE(r, 0) ở cycle hiện tại.
    //   Tại cycle t, control_unit drive pi_a_left[r] = A[t-r][r] (skewed).
    //   pi_valid_left[r] high khi giá trị này hợp lệ.
    input  wire [SA_N*DATA_WIDTH-1:0]     pi_a_left,
    input  wire [SA_N-1:0]                pi_valid_left,

    //   po_psum_bottom[n] = psum 40-bit của cột n (PE(K-1, n).po_psum_out registered).
    //   po_valid_bottom[n] high khi po_psum_bottom[n] = C[m][n] cho m nào đó.
    output wire [SA_N*ACC_WIDTH-1:0]      po_psum_bottom,
    output wire [SA_N-1:0]                po_valid_bottom
);
    // ---------------------------------------------------------------------
    //   a_h[r][0]   = pi_a_left[r]                  (từ port ngoài)
    //   a_h[r][c+1] = PE(r, c).po_a_out             (registered, +1 cycle)
    //   valid_h[r][*] tương tự
    // ---------------------------------------------------------------------
    wire [DATA_WIDTH-1:0] a_h     [0:SA_N-1][0:SA_N];
    wire                  valid_h [0:SA_N-1][0:SA_N];

    // ---------------------------------------------------------------------
    // Vertical psum chain (giữ nguyên cấu trúc broadcast cũ về psum).
    //   psum_v[0][c]   = 0                          (top edge của mỗi cột)
    //   psum_v[r+1][c] = PE(r, c).po_psum_out       (registered, +1 cycle)
    // ---------------------------------------------------------------------
    wire [ACC_WIDTH-1:0]  psum_v  [0:SA_N][0:SA_N-1];

    // ---------------------------------------------------------------------
    // Drive left edge (cột 0) từ external port.
    // ---------------------------------------------------------------------
    genvar gr;
    generate
        for (gr = 0; gr < SA_N; gr = gr + 1) begin : gen_left_edge
            assign a_h[gr][0]     = pi_a_left[gr*DATA_WIDTH +: DATA_WIDTH];
            assign valid_h[gr][0] = pi_valid_left[gr];
        end
    endgenerate

    // ---------------------------------------------------------------------
    // Drive top edge (row 0) psum = 0 cho mỗi cột.
    // ---------------------------------------------------------------------
    genvar gc;
    generate
        for (gc = 0; gc < SA_N; gc = gc + 1) begin : gen_top_edge
            assign psum_v[0][gc] = {ACC_WIDTH{1'b0}};
        end
    endgenerate

    // ---------------------------------------------------------------------
    genvar r, c;
    generate
        for (r = 0; r < SA_N; r = r + 1) begin : gen_row
            for (c = 0; c < SA_N; c = c + 1) begin : gen_col
                // Weight load enable: chỉ row được chọn mới latch.
                wire pe_wload = pi_weight_load &&
                                (pi_weight_row_sel == r[ROW_SEL_WIDTH-1:0]);

                pe #(
                    .DATA_WIDTH(DATA_WIDTH),
                    .ACC_WIDTH (ACC_WIDTH)
                ) pe_inst (
                    .pi_clk        (pi_clk),
                    .pi_rst_n      (pi_rst_n),

                    // Weight: broadcast cùng column slice tới mọi row,
                    // nhưng pe_wload chỉ true ở row được chọn → chỉ row đó latch.
                    .pi_weight_load(pe_wload),
                    .pi_w_in       (pi_weight_data[c*DATA_WIDTH +: DATA_WIDTH]),

                    // Horizontal: chain PE(r, c-1) → PE(r, c) → PE(r, c+1)
                    .pi_a_in       (a_h[r][c]),
                    .pi_valid_in   (valid_h[r][c]),
                    .po_a_out      (a_h[r][c+1]),
                    .po_valid_out  (valid_h[r][c+1]),

                    // Vertical: chain PE(r-1, c) → PE(r, c) → PE(r+1, c)
                    .pi_psum_in    (psum_v[r][c]),
                    .po_psum_out   (psum_v[r+1][c])
                );
            end
        end
    endgenerate

    // ---------------------------------------------------------------------
    // Bottom-edge outputs.
    // ---------------------------------------------------------------------
    genvar oc;
    generate
        for (oc = 0; oc < SA_N; oc = oc + 1) begin : gen_bottom
            assign po_psum_bottom[oc*ACC_WIDTH +: ACC_WIDTH] = psum_v[SA_N][oc];
            assign po_valid_bottom[oc] = valid_h[SA_N-1][oc+1];
        end
    endgenerate

endmodule
