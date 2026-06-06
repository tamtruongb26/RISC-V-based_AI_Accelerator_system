`timescale 1ns / 1ps

// ===========================================================================
// fault_injector_tb.sv — Unit test cho fault_injector.v (Phase 5a)
//
// Kiểm: lật ĐÚNG bit ở ĐÚNG cycle (chỉ 1 cycle), còn lại pass-through;
//       sticky injected flag; clear reset; disabled = không tiêm;
//       trigger ngoài tầm = không tiêm; nhiều bit position + biên (MSB).
//
// Pass: "=== ALL FAULT_INJECTOR TESTS PASSED ===".
// ===========================================================================
module fault_injector_tb;

    localparam integer DW = 40;
    localparam integer CLK_PERIOD = 10;

    reg                clk = 1'b0;
    reg                rst_n;
    reg                fi_enable;
    reg                fi_clear;
    reg  [5:0]         fi_bit_pos;
    reg  [31:0]        fi_trigger_cycle;
    reg  [DW-1:0]      data_in;
    wire [DW-1:0]      data_out;
    wire               fi_injected;

    integer errs = 0;

    fault_injector #(.DATA_WIDTH(DW)) dut (
        .pi_clk(clk), .pi_rst_n(rst_n),
        .pi_fi_enable(fi_enable), .pi_fi_clear(fi_clear),
        .pi_fi_bit_pos(fi_bit_pos), .pi_fi_trigger_cycle(fi_trigger_cycle),
        .pi_data_in(data_in), .po_data_out(data_out),
        .po_fi_injected(fi_injected)
    );

    always #(CLK_PERIOD/2) clk = ~clk;

    function [DW-1:0] pat(input integer t);
        pat = 40'h0123450000 + t;     // distinct per cycle
    endfunction

    // Chạy ncyc cycle (enable), kiểm data_out từng cycle + injected cuối.
    task automatic run_inject(input string tag, input integer bitpos,
                              input integer trig, input integer ncyc,
                              input integer en);
        integer t;
        reg [DW-1:0] exp;
        reg          exp_injected;
        // setup + clear
        @(negedge clk);
        fi_enable = en[0]; fi_bit_pos = bitpos[5:0]; fi_trigger_cycle = trig;
        fi_clear = 1'b1;
        @(negedge clk);
        fi_clear = 1'b0;            // cyc đã về 0 ở posedge giữa

        for (t = 0; t < ncyc; t = t + 1) begin
            data_in = pat(t);
            #1;
            if (en[0] && t == trig)
                exp = pat(t) ^ (40'd1 << bitpos);
            else
                exp = pat(t);
            if (data_out !== exp) begin
                $display("[FAIL] %s cyc=%0d: got=0x%h exp=0x%h", tag, t, data_out, exp);
                errs = errs + 1;
            end
            @(negedge clk);
        end

        exp_injected = (en[0] && trig < ncyc) ? 1'b1 : 1'b0;
        if (fi_injected !== exp_injected) begin
            $display("[FAIL] %s injected: got=%b exp=%b", tag, fi_injected, exp_injected);
            errs = errs + 1;
        end else
            $display("[ OK ] %s (bit=%0d trig=%0d en=%0d) injected=%b", tag, bitpos, trig, en, fi_injected);
    endtask

    initial begin
        rst_n=0; fi_enable=0; fi_clear=0; fi_bit_pos=0; fi_trigger_cycle=0; data_in=0;
        repeat (3) @(posedge clk);
        @(negedge clk); rst_n=1; @(posedge clk);

        $display("---- fault_injector cases ----");
        run_inject("c1.disabled",  5,  3, 10, 0);   // enable=0 → không tiêm
        run_inject("c2.bit5@3",    5,  3, 10, 1);
        run_inject("c3.bit0@0",    0,  0, 10, 1);   // trigger ngay cycle 0
        run_inject("c4.MSB@7",    39,  7, 10, 1);   // biên bit cao nhất
        run_inject("c5.bit20@5",  20,  5, 12, 1);
        run_inject("c6.out_range", 8, 50, 10, 1);   // trigger > ncyc → không tiêm

        $display("");
        if (errs == 0) $display("=== ALL FAULT_INJECTOR TESTS PASSED ===");
        else           $display("=== %0d FAULT_INJECTOR TEST FAILURES ===", errs);
        $finish;
    end

    initial begin #200000; $display("[TIMEOUT]"); $finish; end

endmodule
