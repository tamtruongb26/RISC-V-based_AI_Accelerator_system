`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 04/09/2026 01:26:30 PM
// Design Name: 
// Module Name: bram
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


module bram#(
    parameter integer WADDR = 11,
    parameter integer WDATA = 16
)(   
    // PORT A
    input               pi_clka,
    input               pi_ena,
    input               pi_wea,
    input   [WADDR-1:0] pi_addra,
    input   [WDATA-1:0] pi_dia,
    output  reg     [WDATA-1:0] po_doa,
    
    // PORT B
    input               pi_clkb,
    input               pi_enb,
    input               pi_web,
    input   [WADDR-1:0] pi_addrb,
    input   [WDATA-1:0] pi_dib,
    output  reg     [WDATA-1:0] po_dob
    
);
    // reg array + synchronous read/write → BRAM
    localparam RAM_DEPTH = 2**WADDR;
    reg [WDATA-1:0] ram [0:RAM_DEPTH-1];
    
    // ---------------------
    // PORT A
    // ena = 1, wea = 1 -> write
    // ena = 1, wea = 0 -> read
    // ena = 0 -> do nothing
    // ----------------------
    always @(posedge pi_clka) begin
        if (pi_ena) begin
            if (pi_wea) begin
                ram[pi_addra] <= pi_dia;
                po_doa <= pi_dia;
            end else begin
                po_doa <= ram[pi_addra];
            end
        end  
    end
    
    // ---------------------
    // PORT B
    // ena = 1, wea = 1 -> write
    // ena = 1, wea = 0 -> read
    // ena = 0 -> do nothing
    // ----------------------
    always @(posedge pi_clkb) begin
        if (pi_enb) begin
            if (pi_web) begin
                ram[pi_addrb] <= pi_dib;
                po_dob <= pi_dib;
            end else begin
                po_dob <= ram[pi_addrb];
            end
        end  
    end
endmodule
