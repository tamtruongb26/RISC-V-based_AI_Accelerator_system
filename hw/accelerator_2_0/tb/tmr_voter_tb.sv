`timescale 1ns / 1ps

// ===========================================================================
// tmr_voter_tb.sv — Unit test cho tmr_voter.v (Phase 5b)
//
// Kiểm: 3 giống → voted=giá trị, mismatch=0; 1 bản lỗi (2 giống) → voted=majority,
//       mismatch=1; per-bit majority đúng; 3 khác nhau → bit-wise majority.
//
// Pass: "=== ALL TMR_VOTER TESTS PASSED ===".
// ===========================================================================
module tmr_voter_tb;

    localparam integer W = 4;
    reg  [W-1:0] a, b, c;
    wire [W-1:0] voted;
    wire         mismatch;
    integer errs = 0;

    tmr_voter #(.WIDTH(W)) dut (
        .pi_a(a), .pi_b(b), .pi_c(c),
        .po_voted(voted), .po_mismatch(mismatch)
    );

    task automatic chk(input string tag, input [W-1:0] va, vb, vc,
                       input [W-1:0] exp_v, input exp_m);
        a = va; b = vb; c = vc;
        #1;
        if (voted !== exp_v || mismatch !== exp_m) begin
            $display("[FAIL] %s a=%b b=%b c=%b: voted=%b(exp %b) mm=%b(exp %b)",
                     tag, va, vb, vc, voted, exp_v, mismatch, exp_m);
            errs = errs + 1;
        end else
            $display("[ OK ] %s a=%b b=%b c=%b → voted=%b mm=%b", tag, va, vb, vc, voted, mismatch);
    endtask

    initial begin
        $display("---- tmr_voter cases ----");
        chk("c1.all_agree",  4'b1010, 4'b1010, 4'b1010, 4'b1010, 1'b0);
        chk("c2.a_fault",    4'b1011, 4'b1010, 4'b1010, 4'b1010, 1'b1); // a sai 1 bit
        chk("c3.b_fault",    4'b0110, 4'b0010, 4'b0110, 4'b0110, 1'b1);
        chk("c4.c_fault",    4'b1111, 4'b1111, 4'b0111, 4'b1111, 1'b1);
        chk("c5.all_zero",   4'b0000, 4'b0000, 4'b0000, 4'b0000, 1'b0);
        // 3 khác nhau: per-bit majority. a=1100 b=1010 c=1001
        //   bit3: 1,1,1→1  bit2:1,0,0→0  bit1:0,1,0→0  bit0:0,0,1→0  → 1000
        chk("c6.all_diff",   4'b1100, 4'b1010, 4'b1001, 4'b1000, 1'b1);

        $display("");
        if (errs == 0) $display("=== ALL TMR_VOTER TESTS PASSED ===");
        else           $display("=== %0d TMR_VOTER TEST FAILURES ===", errs);
        $finish;
    end

endmodule
