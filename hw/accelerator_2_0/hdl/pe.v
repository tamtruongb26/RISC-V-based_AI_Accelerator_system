`timescale 1ns / 1ps

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

    // ── Phase 3a-merge: dual-mode Output-Stationary ──
    //   pi_os_mode=1: psum_reg cộng dồn CỤC BỘ (psum_reg += a·w), bỏ qua pi_psum_in;
    //                 a = broadcast (data_path). Reduce cột làm ngoài (adder tree).
    //   pi_os_init=1: K-tile đầu → ghi đè; else cộng dồn. Weight load ở OS GIỮ
    //                 psum_reg (cộng dồn qua K-tile); WS clear như cũ.
    input  wire                          pi_os_mode,
    input  wire                          pi_os_init,

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
    reg signed [ACC_WIDTH-1:0]  psum_reg;    // accumulate register (để DSP làm MACC)

    // ----- Phase 4: sparsity operand isolation -----
    // Khi a hoặc w = 0 → product = 0. Thay vì feed multiplier giá trị mới (tốn
    // dynamic power do toggle), GIỮ operand cũ → multiplier không switch. Output
    // bị bỏ (psum += 0). Functional KHÔNG đổi (0×w = 0). ReLU → 40-60% activation
    // = 0 ở middle layer → tiết kiệm đáng kể (đo bằng SAIF + power report).
    reg signed [DATA_WIDTH-1:0] a_iso, w_iso;
    wire is_zero = (pi_a_in == {DATA_WIDTH{1'b0}}) || (w_reg == {DATA_WIDTH{1'b0}});

    // Operand vào multiplier: thực khi !is_zero, giữ cũ khi is_zero (no toggle).
    wire signed [DATA_WIDTH-1:0] mult_a = is_zero ? a_iso : pi_a_in;
    wire signed [DATA_WIDTH-1:0] mult_w = is_zero ? w_iso : w_reg;

    // ----- Combinational multiply (sign-extend Q2.8.22 → 40-bit) -----
    wire signed [2*DATA_WIDTH-1:0] mult_raw;
    wire signed [ACC_WIDTH-1:0]    mult_ext;

    assign mult_raw = $signed(mult_a) * $signed(mult_w);
    assign mult_ext = {{(ACC_WIDTH - 2*DATA_WIDTH){mult_raw[2*DATA_WIDTH-1]}},
                       mult_raw};

    // Latch operand "thực" gần nhất để giữ cho multiplier khi is_zero.
    always @(posedge pi_clk or negedge pi_rst_n) begin
        if (!pi_rst_n) begin
            a_iso <= {DATA_WIDTH{1'b0}};
            w_iso <= {DATA_WIDTH{1'b0}};
        end else if (!is_zero) begin
            a_iso <= pi_a_in;
            w_iso <= w_reg;
        end
    end

    // ----- Sequential -----
    always @(posedge pi_clk or negedge pi_rst_n) begin
        if (!pi_rst_n) begin
            w_reg     <= {DATA_WIDTH{1'b0}};
            a_reg     <= {DATA_WIDTH{1'b0}};
            valid_reg <= 1'b0;
            psum_reg  <= {ACC_WIDTH{1'b0}};
        end else if (pi_weight_load) begin
            // Nạp weight + clear pipeline. OS: GIỮ psum_reg (cộng dồn qua K-tile).
            w_reg     <= pi_w_in;
            a_reg     <= {DATA_WIDTH{1'b0}};
            valid_reg <= 1'b0;
            psum_reg  <= pi_os_mode ? psum_reg : {ACC_WIDTH{1'b0}};
        end else if (pi_os_mode) begin
            // OS compute: cộng dồn CỤC BỘ. os_init → ghi đè, else cộng dồn.
            a_reg     <= pi_a_in;
            valid_reg <= pi_valid_in;
            if (pi_valid_in && !is_zero)
                psum_reg <= (pi_os_init ? {ACC_WIDTH{1'b0}} : psum_reg) + mult_ext;
            else
                psum_reg <= (pi_os_init ? {ACC_WIDTH{1'b0}} : psum_reg);
        end else begin
            // WS compute mode: cả 3 pipeline reg đều luôn advance.
            a_reg     <= pi_a_in;
            valid_reg <= pi_valid_in;
            // Sparsity: cộng mult chỉ khi valid VÀ !is_zero (is_zero → +0, bỏ qua).
            if (pi_valid_in && !is_zero)
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
