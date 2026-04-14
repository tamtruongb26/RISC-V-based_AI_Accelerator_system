`timescale 1ns / 1ps

module neuron(
    input               pi_clk,
    input               pi_rst_n,

    // Control signals
    input               pi_valid,
    input               pi_clc_accumulator,
    input               pi_accumulation_done,

    // Data inputs (Q1.4.11 format)
    input      [15:0]   pi_inputs,
    input      [15:0]   pi_weights,
    input      [15:0]   pi_bias,

    // Outputs
    output reg          po_BRAM_en,     // Enable for Sigmoid LUT BRAM
    output reg [9:0]    po_BRAM_add     // Address for Sigmoid LUT BRAM (10-bit)
);
    
    //--------------------------------------------------------------------------
    // 1. MAC (Multiply-Accumulate)
    //--------------------------------------------------------------------------
    
    // Multi combinational (Q1.4.11 * Q1.4.11 = Q2.8.22)
    wire signed [31:0] mult_res = $signed(pi_inputs) * $signed(pi_weights);

    // Bộ tích lũy (Accumulator)
    reg signed [31:0] accumulator_value;

    always @(posedge pi_clk or negedge pi_rst_n) begin
        if (!pi_rst_n) begin
            accumulator_value <= 32'sd0;
        end else begin
            if (pi_clc_accumulator) begin
                accumulator_value <= 32'sd0;
            end else if (pi_valid) begin
                accumulator_value <= accumulator_value + mult_res;
            end
        end
    end
    
    //--------------------------------------------------------------------------
    // 2. Reduce, Generate Address & Saturation
    //--------------------------------------------------------------------------

    // a) Reduce accumulator form Q2.8.22 to Q1.8.7
    wire signed [15:0] acc_reduced = {accumulator_value[31], accumulator_value[29:15]};

    // b) Convert Bias from Q1.4.11 to Q1.8.7
    wire signed [15:0] bias_Q1_8_7 = {
        {5{pi_bias[15]}}, pi_bias[14:11], pi_bias[10:4]
    };
    
    // c) Sum Q1.8.7
    wire signed [15:0] sum = acc_reduced + bias_Q1_8_7;

    // d) Saturation & Generate output
    always @(posedge pi_clk or negedge pi_rst_n) begin
        if (!pi_rst_n) begin
            po_BRAM_en  <= 1'b0;
            po_BRAM_add <= 10'd0;
        end else begin
            po_BRAM_en <= pi_accumulation_done;
            
            if (pi_accumulation_done) begin
                // Saturation: Q1.8.7 -> Q1.4.5 (address for Sigmoid)
                if (sum[15] == 1'b0 && sum[14:11] != 4'b0000) begin
                    // Max 511
                    po_BRAM_add <= 10'b01_1111_1111; 
                end 
                else if (sum[15] == 1'b1 && sum[14:11] != 4'b1111) begin
                    // Âm ngoài khoảng → kịch sàn âm: -512
                    po_BRAM_add <= 10'b10_0000_0000; 
                end 
                else begin
                    po_BRAM_add <= {sum[15], sum[10:7], sum[6:2]};
                end
            end
        end
    end
    
endmodule
