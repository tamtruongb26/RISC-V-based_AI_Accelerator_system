`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Testbench: pe_tb — verifies PE TPU canonical (hw/accelerator_2_0/hdl/pe.v)
//
// Kịch bản chi tiết: hw/accelerator_2_0/tb/pe_tb_scenarios.md
//
// Tổng số check: 17
//   Case 1: Reset clears all registers       (3 check)
//   Case 2: weight_load clears pipeline      (3 check)
//   Case 3: a/valid pass-through 1-cycle     (3 check)
//   Case 4: MAC khi valid_in=1               (1 check)
//   Case 5: Pass-through psum khi valid_in=0 (1 check)
//   Case 6: Signed multiply 4 sub-case       (4 check)
//   Case 7: Boundary Q1.4.11 max × max       (2 check)
//
// Pass: in "=== ALL PE TESTS PASSED ===". Fail: in "=== <N> FAILURES ===".
//////////////////////////////////////////////////////////////////////////////////

module pe_tb;

    // -------- Tham số --------
    localparam integer DW = 16;
    localparam integer AW = 40;
    localparam integer CLK_PERIOD = 10;   // 100 MHz

    // -------- DUT signals --------
    reg                       clk = 1'b0;
    reg                       rst_n;
    reg                       weight_load;
    reg signed [DW-1:0]       w_in;
    reg signed [DW-1:0]       a_in;
    reg                       valid_in;
    reg signed [AW-1:0]       psum_in;

    wire signed [DW-1:0]      a_out;
    wire                      valid_out;
    wire signed [AW-1:0]      psum_out;

    integer errs = 0;

    // -------- Clock --------
    always #(CLK_PERIOD/2) clk = ~clk;

    // -------- DUT instance --------
    pe #(.DATA_WIDTH(DW), .ACC_WIDTH(AW)) dut (
        .pi_clk         (clk),
        .pi_rst_n       (rst_n),
        .pi_weight_load (weight_load),
        .pi_w_in        (w_in),
        .pi_os_mode     (1'b0),
        .pi_os_init     (1'b0),
        .pi_a_in        (a_in),
        .pi_valid_in    (valid_in),
        .po_a_out       (a_out),
        .po_valid_out   (valid_out),
        .pi_psum_in     (psum_in),
        .po_psum_out    (psum_out)
    );

    // -------- Helper check tasks --------
    task automatic check_a(input string name,
                           input signed [DW-1:0] got,
                           input signed [DW-1:0] exp);
        if (got !== exp) begin
            $display("[FAIL] %s: a_out got=%0d exp=%0d (hex %h vs %h)",
                     name, got, exp, got, exp);
            errs = errs + 1;
        end else begin
            $display("[ OK ] %s: a_out=%0d", name, got);
        end
    endtask

    task automatic check_v(input string name,
                           input got, input exp);
        if (got !== exp) begin
            $display("[FAIL] %s: valid got=%b exp=%b", name, got, exp);
            errs = errs + 1;
        end else begin
            $display("[ OK ] %s: valid=%b", name, got);
        end
    endtask

    task automatic check_p(input string name,
                           input signed [AW-1:0] got,
                           input signed [AW-1:0] exp);
        if (got !== exp) begin
            $display("[FAIL] %s: psum_out got=%0d exp=%0d (hex %h vs %h)",
                     name, got, exp, got, exp);
            errs = errs + 1;
        end else begin
            $display("[ OK ] %s: psum_out=%0d (0x%h)", name, got, got);
        end
    endtask

    // -------- Task: pulse weight_load 1 cycle --------
    // Sau khi return, weight_load=0, w_reg đã được latch w mới,
    // pipeline (a_reg, valid_reg, psum_reg) được clear.
    task automatic pulse_weight(input signed [DW-1:0] w);
        @(negedge clk);
        weight_load = 1'b1;
        w_in        = w;
        a_in        = 0;
        valid_in    = 1'b0;
        psum_in     = 0;
        @(posedge clk);              // ← w_reg <= w, pipeline cleared
        @(negedge clk);
        weight_load = 1'b0;
        w_in        = 0;
    endtask

    // -------- Main stimulus --------
    initial begin
        $dumpfile("pe_tb.vcd");
        $dumpvars(0, pe_tb);

        // ========== Init ==========
        rst_n       = 1'b0;
        weight_load = 1'b0;
        w_in        = 0;
        a_in        = 0;
        valid_in    = 1'b0;
        psum_in     = 0;

        // ========== CASE 1: Reset clear all registers ==========
        $display("");
        $display("---- Case 1: Reset clears all registers ----");
        repeat(3) @(posedge clk); #1;
        check_a("c1.a_out_reset",     a_out,     16'sd0);
        check_v("c1.valid_out_reset", valid_out, 1'b0);
        check_p("c1.psum_out_reset",  psum_out,  40'sd0);

        // Release reset
        @(negedge clk);
        rst_n = 1'b1;
        @(posedge clk); #1;

        // ========== CASE 2: weight_load clears pipeline ==========
        $display("");
        $display("---- Case 2: weight_load clears pipeline ----");
        // Bước 2a: bơm giá trị vào pipeline trước
        @(negedge clk);
        a_in     = 16'h0800;   // 1.0
        valid_in = 1'b1;
        psum_in  = 40'sd100;
        @(posedge clk); #1;
        // (Pipeline giờ có a_reg=0x0800, valid_reg=1, psum_reg=100 vì w_reg=0 → 0+1.0*0=0 +100)

        // Bước 2b: pulse weight_load với w mới = 2.0
        @(negedge clk);
        weight_load = 1'b1;
        w_in        = 16'h1000;   // 2.0
        a_in        = 16'h7FFF;   // bất kỳ — phải bị bỏ qua
        valid_in    = 1'b1;
        psum_in     = 40'sd9999;
        @(posedge clk); #1;
        // Sau posedge: w_reg=2.0, a_reg=0, valid_reg=0, psum_reg=0 (do weight_load=1 clear)

        @(negedge clk);
        weight_load = 1'b0;
        w_in        = 0;
        a_in        = 0;
        valid_in    = 1'b0;
        psum_in     = 0;
        @(posedge clk); #1;
        // Check 3 outputs đều = 0
        check_a("c2.a_cleared",     a_out,     16'sd0);
        check_v("c2.valid_cleared", valid_out, 1'b0);
        check_p("c2.psum_cleared",  psum_out,  40'sd0);

        // ========== CASE 3: a/valid pass-through 1 cycle ==========
        $display("");
        $display("---- Case 3: Horizontal a/valid pass-through ----");
        // Để psum check đơn giản (= 0), set w_reg = 0
        pulse_weight(16'sd0);

        @(negedge clk);
        a_in     = 16'sd123;
        valid_in = 1'b1;
        psum_in  = 40'sd0;
        @(posedge clk); #1;
        check_a("c3.a_passthrough",     a_out,     16'sd123);
        check_v("c3.valid_passthrough", valid_out, 1'b1);
        check_p("c3.psum_w_zero",       psum_out,  40'sd0);  // 0 + 123*0 = 0

        // ========== CASE 4: MAC khi valid_in=1 ==========
        $display("");
        $display("---- Case 4: MAC psum_in + a*w ----");
        // Load w_reg = 2.0
        pulse_weight(16'h1000);

        @(negedge clk);
        a_in     = 16'h0800;     // 1.0
        valid_in = 1'b1;
        psum_in  = 40'sd1000;
        @(posedge clk); #1;
        // psum_out = 1000 + (1.0 * 2.0)_Q22 = 1000 + 8388608 = 8389608
        check_p("c4.MAC", psum_out, 40'sd8389608);

        // ========== CASE 5: Pass-through khi valid_in=0 ==========
        $display("");
        $display("---- Case 5: Pass-through (valid_in=0) ----");
        // w_reg vẫn = 2.0 từ case 4
        @(negedge clk);
        a_in     = 16'h0800;       // 1.0 — sẽ bị bỏ qua vì valid=0
        valid_in = 1'b0;
        psum_in  = 40'sd5000;
        @(posedge clk); #1;
        check_p("c5.passthrough", psum_out, 40'sd5000);  // KHÔNG cộng 8388608

        // ========== CASE 6: Signed multiply 4 sub-case ==========
        $display("");
        $display("---- Case 6: Signed multiply ----");

        // 6a: (+1.0) × (+2.0) = +2.0
        pulse_weight(16'h0800);    // w = +1.0
        @(negedge clk);
        a_in     = 16'h1000;       // a = +2.0
        valid_in = 1'b1;
        psum_in  = 40'sd0;
        @(posedge clk); #1;
        check_p("c6a.+x+", psum_out, 40'sd8388608);

        // 6b: (+1.0) × (-2.0) = -2.0  (w_reg vẫn = +1.0)
        @(negedge clk);
        a_in     = 16'hF000;       // a = -2.0 (Q1.4.11)
        valid_in = 1'b1;
        psum_in  = 40'sd0;
        @(posedge clk); #1;
        check_p("c6b.+x-", psum_out, -40'sd8388608);

        // 6c: (-1.0) × (+2.0) = -2.0
        pulse_weight(16'hF800);    // w = -1.0
        @(negedge clk);
        a_in     = 16'h1000;
        valid_in = 1'b1;
        psum_in  = 40'sd0;
        @(posedge clk); #1;
        check_p("c6c.-x+", psum_out, -40'sd8388608);

        // 6d: (-2.0) × (-2.0) = +4.0
        pulse_weight(16'hF000);    // w = -2.0
        @(negedge clk);
        a_in     = 16'hF000;
        valid_in = 1'b1;
        psum_in  = 40'sd0;
        @(posedge clk); #1;
        check_p("c6d.-x-", psum_out, 40'sd16777216);

        // ========== CASE 7: Boundary Q1.4.11 max × max ==========
        $display("");
        $display("---- Case 7: Boundary max × max ----");

        // 7a: 0x7FFF × 0x7FFF = 32767 × 32767 = 1073676289
        pulse_weight(16'h7FFF);
        @(negedge clk);
        a_in     = 16'h7FFF;
        valid_in = 1'b1;
        psum_in  = 40'sd0;
        @(posedge clk); #1;
        check_p("c7a.+max*+max", psum_out, 40'sd1073676289);

        // 7b: 0x8000 × 0x8000 = (-32768) × (-32768) = +1073741824
        pulse_weight(16'h8000);
        @(negedge clk);
        a_in     = 16'h8000;
        valid_in = 1'b1;
        psum_in  = 40'sd0;
        @(posedge clk); #1;
        check_p("c7b.-min*-min", psum_out, 40'sd1073741824);

        // ========== Tổng kết ==========
        $display("");
        if (errs == 0)
            $display("=== ALL PE TESTS PASSED ===");
        else
            $display("=== %0d PE TEST FAILURES ===", errs);
        $finish;
    end

    // -------- Timeout watchdog --------
    initial begin
        #5000;
        $display("[TIMEOUT] simulation exceeded 5000 ns");
        $finish;
    end

endmodule
