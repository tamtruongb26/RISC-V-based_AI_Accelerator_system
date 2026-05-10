`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module:  sigmoid_lookup - single-port sigmoid LUT
// Project: accelerator_2_0
//
// Spec: hw/accelerator_2_0/hdl/sigmoid_spec.md
// ROM:  hw/accelerator_2_0/hdl/sigmoid_rom.mem (1024 entries, Q1.0.9)
//
// Address: Q1.3.6 (10-bit signed, range ±8, step 1/64).
// Data:    Q1.0.9 (10-bit unsigned, range [0, 0.998...], step 1/512).
// Latency: 1 cycle (output registered).
// Storage: 1 BRAM 18Kb (rom_style=block).
//
// Caller (post_proc) PHẢI saturate input từ Q1.8.7 → Q1.3.6 trước khi
// driving pi_addr. Module này KHÔNG handle out-of-range.
//////////////////////////////////////////////////////////////////////////////////

module sigmoid_lookup (
    input  wire        pi_clk,
    input  wire        pi_ena,        // clock enable
    input  wire [9:0]  pi_addr,       // Q1.3.6 input
    output reg  [9:0]  po_data        // Q1.0.9 output, 1-cycle registered
);

    (* rom_style = "block" *) reg [9:0] rom [0:1023];

    initial begin
        $readmemh("sigmoid_rom.mem", rom);
    end

    always @(posedge pi_clk) begin
        if (pi_ena) begin
            po_data <= rom[pi_addr];
        end
    end

endmodule