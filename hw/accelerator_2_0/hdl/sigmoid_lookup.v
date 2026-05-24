`timescale 1ns / 1ps

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