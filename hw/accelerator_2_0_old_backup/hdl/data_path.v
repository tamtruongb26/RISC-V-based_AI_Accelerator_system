`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module:  data_path — 8x8 TPU-like Weight-Stationary Systolic Array
// Project: accelerator_2_0
//
// ============================================================================
// REWRITE NOTE — based on fpga/Accelerator_v2_tb.srcs/sources_1/new/data_path.v
// ----------------------------------------------------------------------------
// What was kept:
//   - SA_N x SA_N grid generated with `genvar`
//   - Weight loading by row-select (1 row per cycle, broadcast column data)
//   - Top edge of every column tied to psum=0
//   - Output taken from the bottom row of each column
// What was CHANGED (this is the heart of the systolic conversion):
//   1. The activation bus is no longer broadcast to all columns of a row.
//      Instead, pi_a_left[r] feeds ONLY column 0 of row r; the activation
//      then propagates column-by-column to the right via the PE's
//      horizontal pass-through (po_a_out → next PE's pi_a_in).
//   2. Per-PE valid is now produced by the PE's HORIZONTAL valid chain
//      (po_valid_out), not a separate vertical valid signal.
//      → Each column's bottom valid is the horizontal-valid coming out of
//        PE(SA_N-1, c), which exactly tracks when psum_v[SA_N][c] holds the
//        K-deep accumulated C[m][c] (per the standard systolic timing).
//   3. Removed the `acc_valid_v` vertical valid plumbing — no longer needed
//      since validity travels with the activation, and the K-deep psum chain
//      always pipelines (PE pass-through when valid=0).
//
// Geometry & timing:
//   - PE(r, c) holds W[r][c] (r = K-dim, c = N-dim).
//   - At cycle t, pi_a_left[r] should be A[t-r][r] (skewed by r). This is
//     the responsibility of the control_unit / skew logic.
//   - C[m][n] emerges at column n's bottom psum at cycle (m + n + K).
//   - Output for column n is valid when po_valid_bottom[n] is high.
//////////////////////////////////////////////////////////////////////////////////

module data_path #(
    parameter integer SA_N          = 8,
    parameter integer DATA_WIDTH    = 16,
    parameter integer ACC_WIDTH     = 40,
    parameter integer ROW_SEL_WIDTH = (SA_N <= 1) ? 1 : $clog2(SA_N)
)(
    input  wire                           pi_clk,
    input  wire                           pi_rst_n,

    // Weight loading: load one PE row per cycle.
    //   pi_weight_load  = 1 only when target row is being loaded
    //   pi_weight_row_sel = which row (0..SA_N-1) gets pi_weight_data
    //   pi_weight_data  = SA_N weights packed (col 0 = LSB)
    input  wire                           pi_weight_load,
    input  wire [ROW_SEL_WIDTH-1:0]       pi_weight_row_sel,
    input  wire [SA_N*DATA_WIDTH-1:0]     pi_weight_data,

    // LEFT-edge activation (one value per row).
    //   At cycle t, row r should receive A[t-r][r] (skewed-by-r).
    //   pi_valid_left[r] is high while a real activation is on the wire.
    input  wire [SA_N*DATA_WIDTH-1:0]     pi_a_left,
    input  wire [SA_N-1:0]                pi_valid_left,

    // BOTTOM-edge result (one accumulator per column).
    //   po_psum_bottom[c] = psum_v[SA_N][c]
    //   po_valid_bottom[c] high → po_psum_bottom[c] = C[m][c] for some m
    output wire [SA_N*ACC_WIDTH-1:0]      po_psum_bottom,
    output wire [SA_N-1:0]                po_valid_bottom
);

    // ---------------------------------------------------------------------
    // Horizontal activation chain (1 extra stage per column)
    //   a_h[r][0]         = pi_a_left[r]               (from outside)
    //   a_h[r][c+1]       = PE(r, c).po_a_out          (registered, +1 cyc)
    //   valid_h analogous
    // ---------------------------------------------------------------------
    wire [DATA_WIDTH-1:0] a_h     [0:SA_N-1][0:SA_N];
    wire                  valid_h [0:SA_N-1][0:SA_N];

    // ---------------------------------------------------------------------
    // Vertical psum chain (1 extra stage per row)
    //   psum_v[0][c]      = 0                          (top edge)
    //   psum_v[r+1][c]    = PE(r, c).po_psum_out       (registered, +1 cyc)
    // ---------------------------------------------------------------------
    wire [ACC_WIDTH-1:0]  psum_v  [0:SA_N][0:SA_N-1];

    // ---------------------------------------------------------------------
    // Drive left edge from external port
    // ---------------------------------------------------------------------
    genvar gr;
    generate
        for (gr = 0; gr < SA_N; gr = gr + 1) begin : gen_left_edge
            assign a_h[gr][0]     = pi_a_left[gr*DATA_WIDTH +: DATA_WIDTH];
            assign valid_h[gr][0] = pi_valid_left[gr];
        end
    endgenerate

    // ---------------------------------------------------------------------
    // Drive top edge to constant zero
    // ---------------------------------------------------------------------
    genvar gc;
    generate
        for (gc = 0; gc < SA_N; gc = gc + 1) begin : gen_top_edge
            assign psum_v[0][gc] = {ACC_WIDTH{1'b0}};
        end
    endgenerate

    // ---------------------------------------------------------------------
    // PE grid
    // ---------------------------------------------------------------------
    genvar r, c;
    generate
        for (r = 0; r < SA_N; r = r + 1) begin : gen_row
            for (c = 0; c < SA_N; c = c + 1) begin : gen_col
                // Weight load enable: only target row sees pi_weight_load=1
                wire pe_wload = pi_weight_load &&
                                (pi_weight_row_sel == r[ROW_SEL_WIDTH-1:0]);

                pe #(
                    .DATA_WIDTH(DATA_WIDTH),
                    .ACC_WIDTH (ACC_WIDTH)
                ) pe_inst (
                    .pi_clk        (pi_clk),
                    .pi_rst_n      (pi_rst_n),

                    // Weight (broadcast same column slice to all rows; gated
                    // by pe_wload so only the target row latches it)
                    .pi_weight_load(pe_wload),
                    .pi_w_in       (pi_weight_data[c*DATA_WIDTH +: DATA_WIDTH]),

                    // Horizontal: chain PE(r,c-1) → PE(r,c) → PE(r,c+1)
                    .pi_a_in       (a_h[r][c]),
                    .pi_valid_in   (valid_h[r][c]),
                    .po_a_out      (a_h[r][c+1]),
                    .po_valid_out  (valid_h[r][c+1]),

                    // Vertical: chain PE(r-1,c) → PE(r,c) → PE(r+1,c)
                    .pi_psum_in    (psum_v[r][c]),
                    .po_psum_out   (psum_v[r+1][c])
                );
            end
        end
    endgenerate

    // ---------------------------------------------------------------------
    // Bottom-edge outputs
    //   psum data: psum_v[SA_N][c]
    //   valid    : valid_h[SA_N-1][c+1] (PE(SA_N-1, c).po_valid_out)
    //              — synchronous with the psum result for this PE.
    // ---------------------------------------------------------------------
    genvar oc;
    generate
        for (oc = 0; oc < SA_N; oc = oc + 1) begin : gen_bottom
            assign po_psum_bottom[oc*ACC_WIDTH +: ACC_WIDTH] = psum_v[SA_N][oc];
            assign po_valid_bottom[oc] = valid_h[SA_N-1][oc+1];
        end
    endgenerate

endmodule
