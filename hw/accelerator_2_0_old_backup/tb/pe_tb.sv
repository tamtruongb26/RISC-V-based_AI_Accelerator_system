`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Testbench: pe_tb — verifies the new TPU-like systolic PE (pe.v)
//
// Checks:
//   1. Reset clears all registers.
//   2. weight_load latches w_in and clears a/valid/psum.
//   3. Horizontal pass-through: a_in → po_a_out (1-cycle delay).
//   4. Valid pass-through: pi_valid_in → po_valid_out (1-cycle delay).
//   5. MAC: po_psum_out = pi_psum_in + a_in × w_reg when valid_in=1.
//   6. Pass-through: po_psum_out = pi_psum_in when valid_in=0.
//   7. Negative weight × negative activation produces correct signed sum.
//////////////////////////////////////////////////////////////////////////////////

module pe_tb;
    localparam integer DW = 16;
    localparam integer AW = 40;

    reg clk = 0;
    reg rst_n = 0;
    always #5 clk = ~clk;   // 100 MHz

    reg                       weight_load;
    reg signed [DW-1:0]       w_in;
    reg signed [DW-1:0]       a_in;
    reg                       valid_in;
    wire signed [DW-1:0]      a_out;
    wire                      valid_out;
    reg signed [AW-1:0]       psum_in;
    wire signed [AW-1:0]      psum_out;

    pe #(.DATA_WIDTH(DW), .ACC_WIDTH(AW)) dut (
        .pi_clk         (clk),
        .pi_rst_n       (rst_n),
        .pi_weight_load (weight_load),
        .pi_w_in        (w_in),
        .pi_a_in        (a_in),
        .pi_valid_in    (valid_in),
        .po_a_out       (a_out),
        .po_valid_out   (valid_out),
        .pi_psum_in     (psum_in),
        .po_psum_out    (psum_out)
    );

    integer errs = 0;

    task check(input string label, input integer got, input integer exp);
        if (got !== exp) begin
            $display("[FAIL] %s: got=%0d exp=%0d", label, got, exp);
            errs = errs + 1;
        end else begin
            $display("[ OK ] %s: %0d", label, got);
        end
    endtask

    initial begin
        $dumpfile("pe_tb.vcd"); $dumpvars(0, pe_tb);

        weight_load = 0; w_in = 0; a_in = 0; valid_in = 0; psum_in = 0;
        #20 rst_n = 1; @(posedge clk);

        // 1. After reset: psum_out=0, a_out=0, valid_out=0
        check("reset psum_out", psum_out, 0);
        check("reset a_out",    a_out,    0);
        check("reset valid_out",valid_out,0);

        // 2. Load weight = 4 (Q1.4.11 = integer 4 has fractional zero, so raw 16'd? )
        //    Use raw integer values, ignore Q-format scaling for unit tests.
        @(negedge clk); weight_load = 1; w_in = 16'sd4;
        @(posedge clk); @(negedge clk); weight_load = 0;
        check("after wload psum_out", psum_out, 0);

        // 3. MAC: psum_in=10, a_in=3, w_reg=4 → expect psum_out=10+3*4=22 next cycle
        a_in = 16'sd3; valid_in = 1; psum_in = 40'sd10;
        @(posedge clk); @(negedge clk);
        check("MAC1 psum_out", psum_out, 22);
        check("MAC1 a_out",    a_out,    3);
        check("MAC1 valid_out",valid_out,1);

        // 4. valid_in=0 → psum_out passes through psum_in (no MAC)
        a_in = 16'sd99; valid_in = 0; psum_in = 40'sd55;
        @(posedge clk); @(negedge clk);
        check("hold psum_out (passthru)", psum_out, 55);
        check("hold valid_out",           valid_out, 0);

        // 5. Resume MAC: psum_in=100, a_in=2, w_reg=4 → 100+8=108
        a_in = 16'sd2; valid_in = 1; psum_in = 40'sd100;
        @(posedge clk); @(negedge clk);
        check("MAC2 psum_out", psum_out, 108);

        // 6. Negative weight: load -3, a_in=5, psum_in=20 → 20+5*(-3)=5
        @(negedge clk); weight_load = 1; w_in = -16'sd3;
        @(posedge clk); @(negedge clk); weight_load = 0;
        a_in = 16'sd5; valid_in = 1; psum_in = 40'sd20;
        @(posedge clk); @(negedge clk);
        check("MAC neg weight", psum_out, 5);

        // 7. Negative × negative: w=-3, a=-7, psum=0 → 21
        a_in = -16'sd7; valid_in = 1; psum_in = 40'sd0;
        @(posedge clk); @(negedge clk);
        check("MAC neg×neg", psum_out, 21);

        if (errs == 0) $display("=== ALL PE TESTS PASSED ===");
        else            $display("=== %0d FAILURES ===", errs);
        $finish;
    end

    initial begin
        #2000 $display("TIMEOUT"); $finish;
    end
endmodule
