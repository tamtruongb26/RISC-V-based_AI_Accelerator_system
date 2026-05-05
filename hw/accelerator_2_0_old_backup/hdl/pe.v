`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module:  pe (Processing Element) — TPU-like Weight-Stationary Systolic PE
// Project: accelerator_2_0
//
// ============================================================================
// REWRITE NOTE — based on fpga/Accelerator_v2_tb.srcs/sources_1/new/pe.v
// ----------------------------------------------------------------------------
// What was kept from the original:
//   - Weight register loaded by `pi_weight_load`
//   - Signed multiply, sign-extension to ACC_WIDTH
//   - Synchronous reset, fixed-point Q1.4.11 × Q1.4.11 → Q2.8.22 → 40b
// What was CHANGED to make this a real systolic PE (Direction B):
//   1. ADDED horizontal activation pass-through (pi_a_in → po_a_out via a_reg).
//      A true 2D systolic array NEEDS this so an activation entered at column 0
//      propagates 1 PE/cycle to the right (the original commented this out).
//   2. ADDED horizontal valid pass-through. Replaces the old separate
//      pi_valid_d / pi_valid_acc pair. In a systolic array the valid travels
//      with the activation horizontally; the psum chain just keeps pipelining.
//   3. The MAC is now CONDITIONAL on pi_valid_in only:
//        valid=1 : psum_out = psum_in + a_in * w_reg
//        valid=0 : psum_out = psum_in (pass through, no contribution)
//      Essential for skewed input flow — invalid cells must propagate psum
//      unchanged so the K-deep accumulator chain stays consistent.
//   4. `pi_weight_load` now also CLEARS a_reg / valid_reg / psum_reg, ensuring
//      a clean start for every new tile.
//
// Dataflow (TPU weight-stationary):
//   - a flows LEFT → RIGHT, 1-cycle delay per PE.
//   - psum flows TOP → BOTTOM, 1-cycle delay per PE.
//   - weight is stationary: loaded once per tile, held in w_reg.
//   - Skewed activation feed at left edge guarantees that the K MACs along
//     a column all contribute to the same C[m][n].
//////////////////////////////////////////////////////////////////////////////////

module pe #(
    parameter integer DATA_WIDTH = 16,
    parameter integer ACC_WIDTH  = 40
)(
    input  wire                          pi_clk,
    input  wire                          pi_rst_n,

    // Weight load: 1 = load weight from pi_w_in (and clear datapath regs)
    //              0 = compute mode (full pipeline running)
    input  wire                          pi_weight_load,
    input  wire signed [DATA_WIDTH-1:0]  pi_w_in,

    // Horizontal: activation flows left → right (1-cycle delay)
    input  wire signed [DATA_WIDTH-1:0]  pi_a_in,
    input  wire                          pi_valid_in,
    output wire signed [DATA_WIDTH-1:0]  po_a_out,
    output wire                          po_valid_out,

    // Vertical: partial-sum flows top → bottom (1-cycle delay)
    input  wire signed [ACC_WIDTH-1:0]   pi_psum_in,
    output wire signed [ACC_WIDTH-1:0]   po_psum_out
);

    // ----- Internal registers -----
    reg signed [DATA_WIDTH-1:0] w_reg;       // weight (stationary)
    reg signed [DATA_WIDTH-1:0] a_reg;       // horizontal pipeline reg
    reg                         valid_reg;   // valid pipeline reg
    reg signed [ACC_WIDTH-1:0]  psum_reg;    // vertical pipeline reg

    // ----- Combinational multiply (sign-extend product to ACC_WIDTH) -----
    wire signed [2*DATA_WIDTH-1:0] mult_raw;
    wire signed [ACC_WIDTH-1:0]    mult_ext;

    assign mult_raw = $signed(pi_a_in) * $signed(w_reg);
    assign mult_ext = {{(ACC_WIDTH - 2*DATA_WIDTH){mult_raw[2*DATA_WIDTH-1]}},
                       mult_raw};

    // ----- Sequential update -----
    always @(posedge pi_clk or negedge pi_rst_n) begin
        if (!pi_rst_n) begin
            w_reg     <= {DATA_WIDTH{1'b0}};
            a_reg     <= {DATA_WIDTH{1'b0}};
            valid_reg <= 1'b0;
            psum_reg  <= {ACC_WIDTH{1'b0}};
        end else if (pi_weight_load) begin
            // Latch weight; reset pipeline so next tile starts clean
            w_reg     <= pi_w_in;
            a_reg     <= {DATA_WIDTH{1'b0}};
            valid_reg <= 1'b0;
            psum_reg  <= {ACC_WIDTH{1'b0}};
        end else begin
            // Compute mode: ALL pipeline registers always advance
            a_reg     <= pi_a_in;
            valid_reg <= pi_valid_in;
            if (pi_valid_in)
                psum_reg <= pi_psum_in + mult_ext;     // accumulate
            else
                psum_reg <= pi_psum_in;                // pass through
        end
    end

    assign po_a_out     = a_reg;
    assign po_valid_out = valid_reg;
    assign po_psum_out  = psum_reg;

endmodule
