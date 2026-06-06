`timescale 1ns / 1ps

// ===========================================================================
// os_array.v — Output-Stationary GEMM engine cho FC layer (Phase 3a, Vấn đề 1)
//
// WS array để M=1 (FC) → chỉ 1/8 hàng PE active (12.5%). OS mode: map K→hàng,
// N→cột; PE[k][n] tính a[k]·w[k][n] → 64 MAC SONG SONG/cycle (100% util), reduce
// dọc cột → c[n] = Σ_k a[k]·w[k][n]. Cộng dồn qua K-tile (psum[n] in-place).
//
// Mỗi cycle valid: nạp a[0..7] (1 K-tile) + weight tile [8×8] → 64 product →
// 8 column-sum → cộng vào 8 psum. accumulate=0 khởi tạo (K-tile 0), =1 cộng dồn.
//
// psum 40-bit (Q2.8.22): 32-bit tích + headroom Σ K. post_proc scale >>11 sau.
// ===========================================================================
module os_array #(
    parameter integer SA_N       = 8,
    parameter integer DATA_WIDTH = 16,
    parameter integer ACC_WIDTH  = 40
)(
    input  wire                              pi_clk,
    input  wire                              pi_rst_n,

    input  wire                              pi_valid,        // xử lý 1 K-tile
    input  wire                              pi_accumulate,   // 0=khởi tạo, 1=cộng dồn
    input  wire [SA_N*DATA_WIDTH-1:0]        pi_a,            // a[0..7]
    input  wire [SA_N*SA_N*DATA_WIDTH-1:0]   pi_w,            // w[k][n] (k=row, n=col)

    output wire [SA_N*ACC_WIDTH-1:0]         po_c,            // psum[n]
    output reg                               po_valid
);

    // 64 product (signed, sign-extend lên ACC_WIDTH).
    wire signed [ACC_WIDTH-1:0] prod [0:SA_N-1][0:SA_N-1];
    genvar gk, gn;
    generate
        for (gk = 0; gk < SA_N; gk = gk + 1) begin : gen_row
            for (gn = 0; gn < SA_N; gn = gn + 1) begin : gen_col
                wire signed [DATA_WIDTH-1:0] a_k =
                    pi_a[gk*DATA_WIDTH +: DATA_WIDTH];
                wire signed [DATA_WIDTH-1:0] w_kn =
                    pi_w[(gk*SA_N + gn)*DATA_WIDTH +: DATA_WIDTH];
                wire signed [2*DATA_WIDTH-1:0] p = a_k * w_kn;
                assign prod[gk][gn] =
                    {{(ACC_WIDTH-2*DATA_WIDTH){p[2*DATA_WIDTH-1]}}, p};
            end
        end
    endgenerate

    // Column sum (reduce dọc K) + accumulate vào psum[n].
    reg signed [ACC_WIDTH-1:0] psum [0:SA_N-1];
    integer n, k;
    reg signed [ACC_WIDTH-1:0] colsum;

    always @(posedge pi_clk or negedge pi_rst_n) begin
        if (!pi_rst_n) begin
            po_valid <= 1'b0;
            for (n = 0; n < SA_N; n = n + 1) psum[n] <= {ACC_WIDTH{1'b0}};
        end else begin
            po_valid <= pi_valid;
            if (pi_valid) begin
                for (n = 0; n < SA_N; n = n + 1) begin
                    colsum = {ACC_WIDTH{1'b0}};
                    for (k = 0; k < SA_N; k = k + 1)
                        colsum = colsum + prod[k][n];
                    psum[n] <= (pi_accumulate ? psum[n] : {ACC_WIDTH{1'b0}}) + colsum;
                end
            end
        end
    end

    genvar go;
    generate
        for (go = 0; go < SA_N; go = go + 1) begin : gen_out
            assign po_c[go*ACC_WIDTH +: ACC_WIDTH] = psum[go];
        end
    endgenerate

endmodule
