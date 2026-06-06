`timescale 1ns / 1ps

// ===========================================================================
// tmr_register_tb.sv — Unit test cho tmr_register.v (Phase 5 integration)
//
// Demo chịu lỗi: nạp giá trị V vào register (3 copy), tiêm 1 bit-flip vào 1 copy
// → voter outvote → po_q VẪN = V (chịu được 1 lỗi); mismatch=1 cycle đó, counter++.
// Không lỗi → po_q=V, mismatch_cnt=0.
//
// Pass: "=== ALL TMR_REGISTER TESTS PASSED ===".
// ===========================================================================
module tmr_register_tb;

    localparam integer W = 4;
    localparam integer CLK = 10;

    reg            clk = 1'b0;
    reg            rst_n;
    reg            en;
    reg  [W-1:0]   d;
    wire [W-1:0]   q;
    reg            fi_enable, fi_clear;
    reg  [1:0]     fi_bit_pos;
    reg  [31:0]    fi_trigger_cycle;
    reg  [1:0]     fi_copy_sel;
    wire           mismatch;
    wire [31:0]    mismatch_cnt;

    integer errs = 0;
    localparam [W-1:0] V = 4'b1010;

    tmr_register #(.WIDTH(W)) dut (
        .pi_clk(clk), .pi_rst_n(rst_n),
        .pi_en(en), .pi_d(d), .po_q(q),
        .pi_fi_enable(fi_enable), .pi_fi_clear(fi_clear),
        .pi_fi_bit_pos(fi_bit_pos), .pi_fi_trigger_cycle(fi_trigger_cycle),
        .pi_fi_copy_sel(fi_copy_sel),
        .po_mismatch(mismatch), .po_mismatch_cnt(mismatch_cnt)
    );

    always #(CLK/2) clk = ~clk;

    // Nạp V → 3 copy; tiêm lỗi vào copy sel; kiểm po_q==V suốt + mismatch_cnt.
    task automatic run_test(input string tag, input integer copy_sel,
                            input integer bitpos, input integer trig,
                            input integer ncyc, input integer en_fi);
        integer t, exp_cnt;
        // nạp V
        @(negedge clk); en = 1'b1; d = V;
        @(negedge clk); en = 1'b0;        // ra=rb=rc=V (latch ở posedge giữa)
        // config + clear injector
        fi_enable = en_fi[0]; fi_copy_sel = copy_sel[1:0];
        fi_bit_pos = bitpos[1:0]; fi_trigger_cycle = trig;
        fi_clear = 1'b1;
        @(negedge clk); fi_clear = 1'b0;

        for (t = 0; t < ncyc; t = t + 1) begin
            #1;
            if (q !== V) begin   // TMR phải giữ output đúng dù có lỗi
                $display("[FAIL] %s cyc=%0d: q=%b (exp %b)", tag, t, q, V);
                errs = errs + 1;
            end
            @(negedge clk);
        end

        exp_cnt = (en_fi[0] && trig < ncyc) ? 1 : 0;
        if (mismatch_cnt !== exp_cnt) begin
            $display("[FAIL] %s mismatch_cnt=%0d (exp %0d)", tag, mismatch_cnt, exp_cnt);
            errs = errs + 1;
        end else
            $display("[ OK ] %s (copy=%0d bit=%0d trig=%0d en=%0d) q giữ %b, mm_cnt=%0d",
                     tag, copy_sel, bitpos, trig, en_fi, V, mismatch_cnt);
    endtask

    initial begin
        rst_n=0; en=0; d=0; fi_enable=0; fi_clear=0;
        fi_bit_pos=0; fi_trigger_cycle=0; fi_copy_sel=0;
        repeat (3) @(posedge clk);
        @(negedge clk); rst_n=1; @(posedge clk);

        $display("---- tmr_register cases ----");
        run_test("c1.no_fault",   0, 1, 3, 10, 0);   // không tiêm → mm_cnt=0
        run_test("c2.fault_a",    0, 1, 3, 10, 1);   // lỗi copy a → masked
        run_test("c3.fault_b",    1, 2, 4, 10, 1);   // lỗi copy b
        run_test("c4.fault_c",    2, 0, 5, 10, 1);   // lỗi copy c
        run_test("c5.fault_a_b3", 0, 3, 2, 10, 1);   // bit cao

        $display("");
        if (errs == 0) $display("=== ALL TMR_REGISTER TESTS PASSED ===");
        else           $display("=== %0d TMR_REGISTER TEST FAILURES ===", errs);
        $finish;
    end

    initial begin #500000; $display("[TIMEOUT]"); $finish; end

endmodule
