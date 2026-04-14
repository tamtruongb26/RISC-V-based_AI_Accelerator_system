`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 04/11/2026 01:42:09 PM
// Design Name: 
// Module Name: data_path
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


module data_path(
    input  wire        pi_clk,
    input  wire        pi_rst_n,

    // AXI Data Input from AXI-LITE
    input  wire [31:0] pi_axi_data,
    
    // --------------------------------------------------------
    // Control Unit Signals
    // --------------------------------------------------------
    
    // 1. Input BRAM 
    input  wire [10:0] pi_bram_inp_addra,
    input  wire [10:0] pi_bram_inp_addrb,
    input  wire        pi_bram_inp_ena,
    input  wire        pi_bram_inp_enb,
    input  wire        pi_bram_inp_wea,
    input  wire        pi_bram_inp_web,

    // 2. Bias BRAM 
    input  wire [10:0] pi_bram_bia_addra,
    input  wire [10:0] pi_bram_bia_addrb,
    input  wire        pi_bram_bia_ena,
    input  wire        pi_bram_bia_enb,
    input  wire        pi_bram_bia_wea,
    input  wire        pi_bram_bia_web,

    // 3. Weight BRAM 
    input  wire [10:0] pi_bram_wei_addra,
    input  wire [10:0] pi_bram_wei_addrb,
    input  wire        pi_bram_wei_ena,
    input  wire        pi_bram_wei_enb,
    input  wire        pi_bram_wei_wea,
    input  wire        pi_bram_wei_web,

    // 4. Register BRAM 
    input  wire [10:0] pi_bram_reg_addra,
    input  wire [10:0] pi_bram_reg_addrb,
    input  wire        pi_bram_reg_ena,
    input  wire        pi_bram_reg_enb,
    input  wire        pi_bram_reg_wea,
    input  wire        pi_bram_reg_web,

    // 5. Neuron Control Signals
    input  wire        pi_valid,
    input  wire        pi_clc_accumulator,
    input  wire        pi_accumulation_done,

    // --------------------------------------------------------
    // M00_AXIS Data Output 
    // --------------------------------------------------------
    output wire [31:0] po_axi_data
);
    
    // Splitting 32-bit AXI stream write data into 2x16-bit
    wire [15:0] axi_data_0 = pi_axi_data[15:0];
    wire [15:0] axi_data_1 = pi_axi_data[31:16];

    // BRAM Output Data Wires
    wire [15:0] inp_doa, inp_dob;
    wire [15:0] bia_doa, bia_dob;
    wire [15:0] wei_doa, wei_dob;
    wire [15:0] reg_doa, reg_dob;
    
    
    //==========================================================================
    // 1. Storage BRAMs
    //==========================================================================

    // Input BRAM (BRAM 0)
    bram #(
        .WADDR(11), 
        .WDATA(16)
    ) bram_inp (
        .pi_clka(pi_clk),
        .pi_ena(pi_bram_inp_ena),
        .pi_wea(pi_bram_inp_wea),
        .pi_addra(pi_bram_inp_addra),
        .pi_dia(axi_data_0),
        .po_doa(inp_doa),

        .pi_clkb(pi_clk),
        .pi_enb(pi_bram_inp_enb),
        .pi_web(pi_bram_inp_web),
        .pi_addrb(pi_bram_inp_addrb),
        .pi_dib(axi_data_1),
        .po_dob(inp_dob)
    );

    // Bias BRAM (BRAM 1)
    bram #(
        .WADDR(11), 
        .WDATA(16)
    ) bram_bia (
        .pi_clka(pi_clk),
        .pi_ena(pi_bram_bia_ena),
        .pi_wea(pi_bram_bia_wea),
        .pi_addra(pi_bram_bia_addra),
        .pi_dia(axi_data_0),
        .po_doa(bia_doa),

        .pi_clkb(pi_clk),
        .pi_enb(pi_bram_bia_enb),
        .pi_web(pi_bram_bia_web),
        .pi_addrb(pi_bram_bia_addrb),
        .pi_dib(axi_data_1),
        .po_dob(bia_dob)
    );

    // Weight BRAM (BRAM 2)
    bram #(
        .WADDR(11), 
        .WDATA(16)
    ) bram_wei (
        .pi_clka(pi_clk),
        .pi_ena(pi_bram_wei_ena),
        .pi_wea(pi_bram_wei_wea),
        .pi_addra(pi_bram_wei_addra),
        .pi_dia(axi_data_0),
        .po_doa(wei_doa),

        .pi_clkb(pi_clk),
        .pi_enb(pi_bram_wei_enb),
        .pi_web(pi_bram_wei_web),
        .pi_addrb(pi_bram_wei_addrb),
        .pi_dib(axi_data_1),
        .po_dob(wei_dob)
    );
    
    //==========================================================================
    // 2. Neurons (MAC Units)
    //==========================================================================

    // Signals between Neurons and Sigmoid LUT
    wire        sig_en_a, sig_en_b;
    wire [9:0]  sig_addra, sig_addrb;

    // Neuron A
    neuron neuron_a (
        .pi_clk(pi_clk),
        .pi_rst_n(pi_rst_n),
        .pi_valid(pi_valid),
        .pi_clc_accumulator(pi_clc_accumulator),
        .pi_accumulation_done(pi_accumulation_done),
        .pi_inputs(inp_doa),
        .pi_weights(wei_doa),
        .pi_bias(bia_doa),
        .po_BRAM_en(sig_en_a),
        .po_BRAM_add(sig_addra)
    );

    // Neuron B
    neuron neuron_b (
        .pi_clk(pi_clk),
        .pi_rst_n(pi_rst_n),
        .pi_valid(pi_valid),
        .pi_clc_accumulator(pi_clc_accumulator),
        .pi_accumulation_done(pi_accumulation_done),
        .pi_inputs(inp_dob),      // Control unit có thể gán addr này giống với addr của neuron A
        .pi_weights(wei_dob),
        .pi_bias(bia_dob),
        .po_BRAM_en(sig_en_b),
        .po_BRAM_add(sig_addrb)
    );
    
    //==========================================================================
    // 3. Sigmoid ROM (Lookup Table)
    //==========================================================================
    
    wire [9:0] sig_doa, sig_dob;

    sigmoid_lookup sigmoid_lut (
        .pi_clk(pi_clk),
        .pi_ena(sig_en_a),
        .pi_addra(sig_addra),
        .po_doa(sig_doa),
        .pi_enb(sig_en_b),
        .pi_addrb(sig_addrb),
        .po_dob(sig_dob)
    );
    
    //==========================================================================
    // 4. Output Register (BRAM 3)
    //==========================================================================

    // Sigmoid output (Q1.9) is 10-bit [0.0, 1.0] only positive values
    // To fit into Q1.4.11 format: {4'b0000, sig_out[9:0], 2'b00}
    // Resulting format: Sign(1) = 0, Int(4) = 0~1, Frac(11) = mapped sigmoid value
    wire [15:0] reg_dia = {4'b0000, sig_doa, 2'b00};
    wire [15:0] reg_dib = {4'b0000, sig_dob, 2'b00};

    // Output Result BRAM
    bram #(
        .WADDR(11), 
        .WDATA(16)
    ) bram_reg (
        .pi_clka(pi_clk),
        .pi_ena(pi_bram_reg_ena),
        .pi_wea(pi_bram_reg_wea),
        .pi_addra(pi_bram_reg_addra),
        .pi_dia(reg_dia),           
        .po_doa(reg_doa),           

        .pi_clkb(pi_clk),
        .pi_enb(pi_bram_reg_enb),
        .pi_web(pi_bram_reg_web),
        .pi_addrb(pi_bram_reg_addrb),
        .pi_dib(reg_dib),           
        .po_dob(reg_dob)            
    );

    // Output Data to AXI-Stream combine 2 results to 1 word 32-bit
    assign po_axi_data = {reg_dob, reg_doa};
endmodule
