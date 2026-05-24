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
