`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Testbench: post_proc_tb — verifies post_proc + sigmoid_lookup pipeline
//
// Kịch bản chi tiết: hw/accelerator_2_0/tb/post_proc_tb_scenarios.md
//
// 5 case, 25 check:
//   Case 1: bypass mode (5 check)
//   Case 2: ReLU mode (4 check)
//   Case 3: sigmoid mode (7 check, bit-exact pipeline match)
//   Case 4: bias precision (4 check, bypass mode)
//   Case 5: pipeline timing (5 sample back-to-back)
//
// Pass: in "=== ALL POST_PROC TESTS PASSED ===". Fail: in "=== <N> FAILURES ===".
//////////////////////////////////////////////////////////////////////////////////

module post_proc_tb;

    localparam integer CLK_PERIOD = 10;     // 100 MHz

    // -------- DUT signals --------
    reg                 clk = 1'b0;
    reg                 rst_n;
    reg  [39:0]         pi_acc_in;
    reg  [15:0]         pi_bias;
    reg                 pi_valid_in;
    reg  [1:0]          pi_act_mode;
    wire [15:0]         po_data_out;
    wire                po_valid_out;

    integer errs = 0;
    integer total_checks = 0;

    // -------- Clock --------
    always #(CLK_PERIOD/2) clk = ~clk;

    // -------- DUT --------
    post_proc dut (
        .pi_clk        (clk),
        .pi_rst_n      (rst_n),
        .pi_acc_in     (pi_acc_in),
        .pi_bias       (pi_bias),
        .pi_valid_in   (pi_valid_in),
        .pi_act_mode   (pi_act_mode),
        .po_data_out   (po_data_out),
        .po_valid_out  (po_valid_out)
    );

    // -------- Helper: 1 isolated check (drive 1 cycle, wait 3, sample) --------
    task automatic check_one(
        input string         name,
        input [39:0]         acc,
        input [15:0]         bias,
        input [1:0]          mode,
        input [15:0]         expected
    );
        // Drive inputs ở negedge (cách an toàn so với posedge sample)
        @(negedge clk);
        pi_acc_in    = acc;
        pi_bias      = bias;
        pi_act_mode  = mode;
        pi_valid_in  = 1'b1;

        // Deassert ở negedge KẾ TIẾP (sau 1 full cycle valid=1)
        @(negedge clk);
        pi_valid_in  = 1'b0;
        pi_acc_in    = 40'h0;
        pi_bias      = 16'h0;

        // Tại đây đã qua 1 posedge với valid=1 → s1_valid=1.
        // Cần thêm 2 posedge để s2_valid=1 rồi s3_valid=1.
        @(posedge clk);   // S2 latch
        @(posedge clk);   // S3 latch → po_valid_out high
        #1;

        if (po_valid_out !== 1'b1) begin
            $display("[FAIL] %s: po_valid_out=%b (expected 1)", name, po_valid_out);
            errs = errs + 1;
        end else if (po_data_out !== expected) begin
            $display("[FAIL] %s: got=0x%04h (%0d)  exp=0x%04h (%0d)",
                     name, po_data_out, $signed(po_data_out),
                     expected, $signed(expected));
            errs = errs + 1;
        end else begin
            $display("[ OK ] %s: po_data_out=0x%04h", name, po_data_out);
        end
        total_checks = total_checks + 1;

        // Drain 1 cycle để valid_out về 0 trước test kế
        @(posedge clk);
    endtask

    // -------- Helper: pipeline timing test (Case 5) --------
    task automatic check_pipeline_timing();
        integer i;
        reg [15:0] expected [0:4];
        reg [15:0] captured [0:4];
        reg [4:0]  valid_seq;
        integer    n_capt;

        expected[0] = 16'h0800;
        expected[1] = 16'h1000;
        expected[2] = 16'h1800;
        expected[3] = 16'h2000;
        expected[4] = 16'h2800;

        n_capt = 0;
        valid_seq = 5'b0;

        // Make sure pipeline is drained
        @(negedge clk);
        pi_valid_in = 1'b0;
        pi_acc_in   = 40'h0;
        pi_bias     = 16'h0;
        pi_act_mode = 2'b00;
        repeat (4) @(posedge clk);

        // Drive 5 sample valid=1 + capture in parallel
        @(negedge clk);
        for (i = 0; i < 12; i = i + 1) begin
            // Drive: only first 5 cycles
            if (i < 5) begin
                pi_valid_in = 1'b1;
                pi_acc_in   = (i + 1) * 40'd4194304;
            end else begin
                pi_valid_in = 1'b0;
                pi_acc_in   = 40'h0;
            end

            @(posedge clk);
            #1;  // Let outputs settle after edge

            // Capture if valid
            if (po_valid_out && (n_capt < 5)) begin
                captured[n_capt] = po_data_out;
                n_capt = n_capt + 1;
            end

            @(negedge clk);
        end

        pi_valid_in = 1'b0;
        pi_acc_in   = 40'h0;

        // Compare
        if (n_capt !== 5) begin
            $display("[FAIL] Case 5 pipeline: captured %0d samples (expected 5)", n_capt);
            errs = errs + 1;
        end else begin
            for (i = 0; i < 5; i = i + 1) begin
                if (captured[i] !== expected[i]) begin
                    $display("[FAIL] Case 5 sample[%0d]: got=0x%04h exp=0x%04h",
                             i, captured[i], expected[i]);
                    errs = errs + 1;
                end
            end
            if (errs == 0)
                $display("[ OK ] Case 5 pipeline: 5 sample throughput correct");
        end
        total_checks = total_checks + 1;
    endtask

    // -------- Main stimulus --------
    initial begin
        $dumpfile("post_proc_tb.vcd");
        $dumpvars(0, post_proc_tb);

        // Init
        rst_n        = 1'b0;
        pi_acc_in    = 40'h0;
        pi_bias      = 16'h0;
        pi_valid_in  = 1'b0;
        pi_act_mode  = 2'b00;

        // Reset
        repeat (3) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        $display("");
        $display("==== Case 1: Bypass mode ====");
        // 1.1: acc=+1.0, bias=+0.5 → +1.5 → 0x0C00
        check_one("1.1 bypass +1+0.5",  40'h0_0040_0000, 16'h0400, 2'b00, 16'h0C00);
        // 1.2: acc=+10.0, bias=0 → +10 → 0x5000
        check_one("1.2 bypass +10",     40'h0_0280_0000, 16'h0000, 2'b00, 16'h5000);
        // 1.3: acc=+20.0 → sat+
        check_one("1.3 bypass +20 sat", 40'h0_0500_0000, 16'h0000, 2'b00, 16'h7FFF);
        // 1.4: acc=-20.0 → sat- (-20 in 40b 2's comp = 2^40 - 20*2^22 = 0xFFFB000000)
        check_one("1.4 bypass -20 sat", 40'hFFFB000000, 16'h0000, 2'b00, 16'h8000);
        // 1.5: acc=0, bias=+15.999 (raw 0x7FF8). S1 truncate Q*.8.22→Q1.8.7
        // mất 4 LSB → bias còn 0x07FF Q1.8.7. Sau S3 << 4 → 0x7FF0 (NOT 0x7FF8).
        check_one("1.5 bypass bias+15.999", 40'h0, 16'h7FF8, 2'b00, 16'h7FF0);

        $display("");
        $display("==== Case 2: ReLU mode ====");
        // 2.1: acc=+2 → 0x1000
        check_one("2.1 ReLU +2",    40'h0_0080_0000, 16'h0000, 2'b01, 16'h1000);
        // 2.2: acc=-2 → 0
        check_one("2.2 ReLU -2",    40'hFFFF800000, 16'h0000, 2'b01, 16'h0000);
        // 2.3: acc=+2, bias=-3 → -1 → 0
        check_one("2.3 ReLU 2-3",   40'h0_0080_0000, 16'hE800, 2'b01, 16'h0000);
        // 2.4: acc=+20 → sat+
        check_one("2.4 ReLU +20",   40'h0_0500_0000, 16'h0000, 2'b01, 16'h7FFF);

        $display("");
        $display("==== Case 3: Sigmoid mode ====");
        // 3.1: x=0 → addr=0 → ROM=0x100 → sig_q187=0x40 → out=0x0400
        check_one("3.1 sig 0",   40'h0,           16'h0000, 2'b10, 16'h0400);
        // 3.2: x=+1 → addr=0x040 → ROM=0x176 → sig_q187=0x5D → out=0x05D0
        check_one("3.2 sig +1",  40'h0_0040_0000, 16'h0000, 2'b10, 16'h05D0);
        // 3.3: x=-1 → addr=0x3C0 → ROM=0x08A → sig_q187=0x22 → out=0x0220
        check_one("3.3 sig -1",  40'hFFFFC00000, 16'h0000, 2'b10, 16'h0220);
        // 3.4: x=+4 → addr=0x100 → ROM=0x1F7 → sig_q187=0x7D → out=0x07D0
        check_one("3.4 sig +4",  40'h0_0100_0000, 16'h0000, 2'b10, 16'h07D0);
        // 3.5: x=-4 → addr=0x300 → ROM=0x009 → sig_q187=0x02 → out=0x0020
        check_one("3.5 sig -4",  40'hFFFF000000, 16'h0000, 2'b10, 16'h0020);
        // 3.6: x=+8 (sat) → addr=0x1FF → ROM=0x1FF → sig_q187=0x7F → out=0x07F0
        check_one("3.6 sig +8",  40'h0_0200_0000, 16'h0000, 2'b10, 16'h07F0);
        // 3.7: x=-8 (sat) → addr=0x200 → ROM=0x000 → out=0x0000
        check_one("3.7 sig -8",  40'hFFFE000000, 16'h0000, 2'b10, 16'h0000);

        $display("");
        $display("==== Case 4: Bias precision ====");
        // 4.1: acc=0, bias=+1.0 → 0x0800
        check_one("4.1 bias +1",  40'h0, 16'h0800, 2'b00, 16'h0800);
        // 4.2: acc=0, bias=16 LSB Q1.4.11 (=1/128 real = 1 LSB Q1.8.7).
        // Đây là smallest bias survives truncation. raw=0x0010 → out=0x0010.
        check_one("4.2 bias smallest", 40'h0, 16'h0010, 2'b00, 16'h0010);
        // 4.3: acc=+1, bias=-1 → 0
        check_one("4.3 bias cancel", 40'h0_0040_0000, 16'hF800, 2'b00, 16'h0000);
        // 4.4: acc=+0.5, bias=+0.25 → +0.75 → 0x0600
        check_one("4.4 bias 0.5+0.25", 40'h0_0020_0000, 16'h0200, 2'b00, 16'h0600);

        $display("");
        $display("==== Case 5: Pipeline timing (5 back-to-back) ====");
        check_pipeline_timing();

        // -------- Summary --------
        $display("");
        $display("Total checks: %0d", total_checks);
        if (errs == 0)
            $display("=== ALL POST_PROC TESTS PASSED ===");
        else
            $display("=== %0d POST_PROC TEST FAILURES ===", errs);
        $finish;
    end

    // -------- Timeout watchdog --------
    initial begin
        #10000;
        $display("[TIMEOUT] simulation exceeded 10000 ns");
        $finish;
    end

endmodule