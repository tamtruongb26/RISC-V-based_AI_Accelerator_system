`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 04/29/2026 03:33:23 PM
// Design Name: 
// Module Name: post_proc
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


module post_proc #(
    parameter integer DATA_WIDTH = 16,
    parameter integer ACC_WIDTH  = 40
)(
    input  wire                    pi_clk,
    input  wire                    pi_rst_n,

    // ── Input ──
    input  wire [ACC_WIDTH-1:0]    pi_acc_in,       // Raw accumulator from PE
    input  wire [DATA_WIDTH-1:0]   pi_bias,         // Bias in Q1.4.11
    input  wire                    pi_valid_in,

    // ── Configuration ──
    input  wire [1:0]              pi_act_mode,     // 00=bypass, 01=ReLU, 10=sigmoid

    // ── Output ──
    output reg  [DATA_WIDTH-1:0]   po_data_out,     // Final Q1.4.11 result
    output reg                     po_valid_out
);

    //==========================================================================
    // Stage 1: Truncate accumulator to Q1.8.7 and add bias
    //==========================================================================
    // Accumulator is in Q2.8.22 (result of Q1.4.11 × Q1.4.11 summed over K)
    // Truncate: take sign + bits[29:15] → Q1.8.7 (16-bit signed)
    //   acc[31] = sign (of 32-bit product; for 40-bit, sign is at [39])
    //   For 40-bit acc after K accumulations: meaningful bits shift up
    //   Each multiply: Q1.4.11 × Q1.4.11 = Q2.8.22 (32 bits significant)
    //   After K additions: up to Q2.8.22 + log2(K) bits
    //   Truncate to Q1.8.7: take acc[39] (sign), acc[29:15]

    wire signed [15:0] acc_truncated;
    assign acc_truncated = {pi_acc_in[39], pi_acc_in[29:15]};

    // Convert bias from Q1.4.11 to Q1.8.7
    // Q1.4.11: S IIII FFFFFFFFFFF
    // Q1.8.7:  S IIIIIIII FFFFFFF
    // Sign-extend 4-bit integer to 8-bit, truncate 11-bit frac to 7-bit
    wire signed [15:0] bias_q187;
    assign bias_q187 = {{5{pi_bias[15]}}, pi_bias[14:11], pi_bias[10:4]};

    // Sum
    wire signed [15:0] sum_s1;
    assign sum_s1 = acc_truncated + bias_q187;

    // Pipeline register stage 1
    reg signed [15:0] s1_sum;
    reg               s1_valid;
    reg [1:0]         s1_act_mode;

    always @(posedge pi_clk or negedge pi_rst_n) begin
        if (!pi_rst_n) begin
            s1_sum      <= 16'sd0;
            s1_valid    <= 1'b0;
            s1_act_mode <= 2'b00;
        end else begin
            s1_sum      <= sum_s1;
            s1_valid    <= pi_valid_in;
            s1_act_mode <= pi_act_mode;
        end
    end

    //==========================================================================
    // Stage 2: Activation
    //==========================================================================
    // Bypass: pass s1_sum straight through
    // ReLU:   max(0, s1_sum) → if s1_sum < 0, output 0
    // Sigmoid: saturate s1_sum to Q1.4.5 (10-bit) → LUT → 10-bit output

    // ── ReLU ──
    wire signed [15:0] relu_out;
    assign relu_out = (s1_sum[15]) ? 16'sd0 : s1_sum;

    // ── Sigmoid address generation (same as neuron.sv in accelerator_1_0) ──
    // Saturate Q1.8.7 → Q1.4.5 (10-bit address for sigmoid LUT)
    reg [9:0] sig_addr;
    reg       sig_en;

    always @(*) begin
        sig_en = (s1_act_mode == 2'b10) && s1_valid;

        if (s1_sum[15] == 1'b0 && s1_sum[14:11] != 4'b0000) begin
            sig_addr = 10'b01_1111_1111; // Positive saturation: max 511
        end
        else if (s1_sum[15] == 1'b1 && s1_sum[14:11] != 4'b1111) begin
            sig_addr = 10'b10_0000_0000; // Negative saturation: -512
        end
        else begin
            sig_addr = {s1_sum[15], s1_sum[10:7], s1_sum[6:2]};
        end
    end

    // Sigmoid LUT (dual-port, only using port A)
    wire [9:0] sig_data;
    wire [9:0] unused_sig_dob;

    sigmoid_lookup sigmoid_lut (
        .pi_clk  (pi_clk),
        .pi_ena  (sig_en),
        .pi_addra(sig_addr),
        .po_doa  (sig_data),
        .pi_enb  (1'b0),
        .pi_addrb(10'd0),
        .po_dob  (unused_sig_dob)
    );

    // Pipeline register stage 2 (wait for sigmoid LUT read latency = 1 cycle)
    reg signed [15:0] s2_relu;
    reg signed [15:0] s2_bypass;
    reg               s2_valid;
    reg [1:0]         s2_act_mode;

    always @(posedge pi_clk or negedge pi_rst_n) begin
        if (!pi_rst_n) begin
            s2_relu     <= 16'sd0;
            s2_bypass   <= 16'sd0;
            s2_valid    <= 1'b0;
            s2_act_mode <= 2'b00;
        end else begin
            s2_relu     <= relu_out;
            s2_bypass   <= s1_sum;
            s2_valid    <= s1_valid;
            s2_act_mode <= s1_act_mode;
        end
    end

    //==========================================================================
    // Stage 3: Output Mux + Saturation to Q1.4.11
    //==========================================================================

    // Select activation output
    reg signed [15:0] act_result; // Still Q1.8.7 for bypass/ReLU, or special for sigmoid

    always @(*) begin
        case (s2_act_mode)
            2'b00:   act_result = s2_bypass;                        // Bypass
            2'b01:   act_result = s2_relu;                          // ReLU
            2'b10:   act_result = {4'b0000, sig_data, 2'b00};      // Sigmoid → Q1.4.11 directly
            default: act_result = s2_bypass;
        endcase
    end

    // Saturate to Q1.4.11 (for bypass and ReLU, which are in Q1.8.7)
    // Sigmoid output is already in Q1.4.11 format, no saturation needed
    reg [DATA_WIDTH-1:0] saturated;

    always @(*) begin
        if (s2_act_mode == 2'b10) begin
            // Sigmoid: already Q1.4.11
            saturated = act_result;
        end else begin
            // Q1.8.7 → Q1.4.11: check for overflow in integer part
            // Q1.8.7: S IIIIIIII FFFFFFF
            // Q1.4.11: S IIII FFFFFFFFFFF
            // Need to check if upper 4 integer bits cause overflow
            if (act_result[15] == 1'b0 && act_result[14:11] != 4'b0000) begin
                // Positive overflow → max positive Q1.4.11
                saturated = 16'h7FFF;
            end
            else if (act_result[15] == 1'b1 && act_result[14:11] != 4'b1111) begin
                // Negative overflow → min negative Q1.4.11
                saturated = 16'h8000;
            end
            else begin
                // No overflow: S + 4-bit int + extend 7-bit frac to 11-bit
                saturated = {act_result[15], act_result[10:7], act_result[6:0], 4'b0000};
            end
        end
    end

    // Output register
    always @(posedge pi_clk or negedge pi_rst_n) begin
        if (!pi_rst_n) begin
            po_data_out  <= {DATA_WIDTH{1'b0}};
            po_valid_out <= 1'b0;
        end else begin
            po_data_out  <= saturated;
            po_valid_out <= s2_valid;
        end
    end

endmodule
