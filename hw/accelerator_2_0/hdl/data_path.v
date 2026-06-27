`timescale 1ns / 1ps

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
    output wire [SA_N-1:0]                po_valid_bottom,

    // ── Chế độ Output-Stationary (OS) ──
    //   pi_os_mode=1: a broadcast theo hàng (pi_a_left[r] → mọi cột), PE cộng dồn
    //   cục bộ; po_os_c[n] = Σ_k psum_reg[k][n] (adder tree tap psum chain, 0 DSP).
    input  wire                           pi_os_mode,
    input  wire                           pi_os_init,
    input  wire                           pi_os_valid,
    output wire [SA_N*ACC_WIDTH-1:0]      po_os_c,

    // ── Bộ đếm chu kỳ hoạt động của PE (PE-active cycle counter) ───────────
    //   Mỗi cycle có ≥1 hàng input (pi_a_left[r] ≠ 0 AND pi_valid_left[r])
    //   → cnt_pe_active += 1. Dùng làm baseline cho phân tích độ thưa (sparsity).
    //   Khi bật zero-skip, counter này sẽ giảm theo tỉ lệ thưa của activation.
    //   pi_cnt_clear = 1 cycle pulse → clear về 0.
    input  wire                           pi_cnt_clear,
    output wire [31:0]                    po_cnt_pe_active,
    // ── Phase 4: bộ đếm row-feed bị cô lập do thưa (operand isolation) ──────
    //   Mỗi cycle cộng số hàng valid nhưng a==0 (multiplier giữ operand cũ →
    //   tiết kiệm power). skip_rate ≈ cnt/(SA_N×cnt_compute). Gồm cả zero hữu
    //   ích (ReLU) lẫn zero cấu trúc của skew ramp.
    output wire [31:0]                    po_cnt_sparsity_skip
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

                    // Chế độ OS: phát (broadcast) dữ liệu a (pi_a_left[r] tới mọi cột);
                    // WS: truyền nối tiếp PE(r,c-1)→PE(r,c)→PE(r,c+1).
                    .pi_os_mode    (pi_os_mode),
                    .pi_os_init    (pi_os_init),
                    .pi_a_in       (pi_os_mode ? pi_a_left[r*DATA_WIDTH +: DATA_WIDTH]
                                               : a_h[r][c]),
                    .pi_valid_in   (pi_os_mode ? pi_os_valid : valid_h[r][c]),
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

    // ---------------------------------------------------------------------
    // Chế độ OS: Thu gọn cột (column reduce) — po_os_c[n] = Σ_k psum_reg[k][n].
    //   psum_v[r+1][n] = PE(r,n).po_psum_out = PE(r,n).psum_reg (tap sẵn có).
    //   Bộ cộng tổ hợp (không dùng DSP) — thay thế 64 bộ nhân của cấu trúc cũ.
    // ---------------------------------------------------------------------
    genvar oc2, sr;
    generate
        for (oc2 = 0; oc2 < SA_N; oc2 = oc2 + 1) begin : gen_os_reduce
            wire [ACC_WIDTH-1:0] os_sum [0:SA_N];
            assign os_sum[0] = {ACC_WIDTH{1'b0}};
            for (sr = 0; sr < SA_N; sr = sr + 1) begin : gen_os_acc
                assign os_sum[sr+1] = os_sum[sr] + psum_v[sr+1][oc2];
            end
            assign po_os_c[oc2*ACC_WIDTH +: ACC_WIDTH] = os_sum[SA_N];
        end
    endgenerate

    // ---------------------------------------------------------------------
    // Bộ đếm hiệu năng: Đếm số chu kỳ PE hoạt động thực sự
    //   active_row[r] = pi_valid_left[r] AND (pi_a_left[r] != 0)
    //   any_active    = |active_row → cycle này có ≥1 PE đang nhận
    //                   activation hữu ích (khác không).
    //
    // Trước khi tối ưu sparsity: kỳ vọng counter ≈ cnt_compute (vì
    // valid_left[r]=1 mọi chu kỳ tính toán và đa số activation khác không).
    // Sau khi tối ưu sparsity và kích hoạt ReLU: bộ đếm sẽ giảm tương ứng với tỷ lệ thưa.
    // ---------------------------------------------------------------------
    reg [31:0] cnt_pe_active;
    assign po_cnt_pe_active = cnt_pe_active;

    wire [SA_N-1:0] active_row;
    genvar ar;
    generate
        for (ar = 0; ar < SA_N; ar = ar + 1) begin : gen_active
            assign active_row[ar] = pi_valid_left[ar] &&
                                    (pi_a_left[ar*DATA_WIDTH +: DATA_WIDTH] !=
                                     {DATA_WIDTH{1'b0}});
        end
    endgenerate

    wire any_active = |active_row;

    always @(posedge pi_clk or negedge pi_rst_n) begin : pe_active_cnt
        if (!pi_rst_n)
            cnt_pe_active <= 32'd0;
        else if (pi_cnt_clear)
            cnt_pe_active <= 32'd0;
        else if (any_active)
            cnt_pe_active <= cnt_pe_active + 32'd1;
    end

    // ── Phase 4: đếm row-feed thưa (valid && a==0) — popcount mỗi cycle ──────
    reg [31:0] cnt_sparsity_skip;
    assign po_cnt_sparsity_skip = cnt_sparsity_skip;

    wire [SA_N-1:0] skip_row;
    genvar sk;
    generate
        for (sk = 0; sk < SA_N; sk = sk + 1) begin : gen_skip
            assign skip_row[sk] = pi_valid_left[sk] &&
                                  (pi_a_left[sk*DATA_WIDTH +: DATA_WIDTH] ==
                                   {DATA_WIDTH{1'b0}});
        end
    endgenerate

    reg [3:0] skip_pop;
    integer si;
    always @(*) begin
        skip_pop = 4'd0;
        for (si = 0; si < SA_N; si = si + 1)
            skip_pop = skip_pop + {3'd0, skip_row[si]};
    end

    always @(posedge pi_clk or negedge pi_rst_n) begin : sparsity_cnt
        if (!pi_rst_n)
            cnt_sparsity_skip <= 32'd0;
        else if (pi_cnt_clear)
            cnt_sparsity_skip <= 32'd0;
        else
            cnt_sparsity_skip <= cnt_sparsity_skip + {28'd0, skip_pop};
    end

endmodule
