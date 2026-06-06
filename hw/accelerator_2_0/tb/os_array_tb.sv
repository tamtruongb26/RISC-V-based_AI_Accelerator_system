`timescale 1ns / 1ps

// ===========================================================================
// os_array_tb.sv — Unit test cho os_array.v (Phase 3a, OS dataflow)
//
// Feed các K-tile (a[8] + w[8][8]), cộng dồn → kiểm c[n] = Σ_(mọi K) a[k]·w[k][n]
// (raw Q2.8.22 40-bit, trước scale). Case: 1 tile, nhiều K-tile, signed.
//
// Pass: "=== ALL OS_ARRAY TESTS PASSED ===".
// ===========================================================================
module os_array_tb;

    localparam integer SA = 8;
    localparam integer DW = 16;
    localparam integer AW = 40;
    localparam integer CLK = 10;

    reg                   clk = 1'b0;
    reg                   rst_n;
    reg                   valid, accumulate;
    reg  [SA*DW-1:0]      a_bus;
    reg  [SA*SA*DW-1:0]   w_bus;
    wire [SA*AW-1:0]      c_bus;
    wire                  c_valid;

    integer errs = 0;
    // golden accumulator (rộng để bắt sai)
    reg signed [63:0] gold [0:SA-1];

    os_array #(.SA_N(SA), .DATA_WIDTH(DW), .ACC_WIDTH(AW)) dut (
        .pi_clk(clk), .pi_rst_n(rst_n),
        .pi_valid(valid), .pi_accumulate(accumulate),
        .pi_a(a_bus), .pi_w(w_bus), .po_c(c_bus), .po_valid(c_valid)
    );

    always #(CLK/2) clk = ~clk;

    // Feed 1 K-tile: a[k], w[k][n] cho sẵn qua array tham số; cộng vào golden.
    task automatic feed(input integer seed, input integer acc);
        integer k, n;
        reg signed [DW-1:0] av, wv;
        @(negedge clk);
        for (k=0;k<SA;k=k+1) begin
            av = (seed*7 + k*3) % 17 - 8;          // -8..8 distinct
            a_bus[k*DW +: DW] = av;
            for (n=0;n<SA;n=n+1) begin
                wv = (seed*5 + k*2 + n) % 13 - 6;  // -6..6
                w_bus[(k*SA+n)*DW +: DW] = wv;
                if (acc==0 && k==0) gold[n] = 0;   // reset ở K-tile đầu, hàng đầu
            end
        end
        // cộng vào golden
        for (n=0;n<SA;n=n+1)
            for (k=0;k<SA;k=k+1) begin
                av = (seed*7 + k*3) % 17 - 8;
                wv = (seed*5 + k*2 + n) % 13 - 6;
                gold[n] = gold[n] + av*wv;
            end
        valid = 1'b1; accumulate = acc[0];
        @(negedge clk); valid = 1'b0;
    endtask

    task automatic check(input string tag);
        integer n, le; reg signed [AW-1:0] got, exp;
        @(negedge clk);
        le = 0;
        for (n=0;n<SA;n=n+1) begin
            got = c_bus[n*AW +: AW];
            exp = gold[n][AW-1:0];
            if (got !== exp) begin
                if (le<6) $display("[FAIL] %s c[%0d]: got=%0d exp=%0d", tag, n, got, exp);
                le = le + 1;
            end
        end
        errs = errs + le;
        if (le==0) $display("[ OK ] %s (8 output, util 64/64 PE)", tag);
    endtask

    integer i;
    initial begin
        rst_n=0; valid=0; accumulate=0; a_bus=0; w_bus=0;
        for (i=0;i<SA;i=i+1) gold[i]=0;
        repeat (3) @(posedge clk); @(negedge clk); rst_n=1; @(posedge clk);

        $display("---- os_array cases ----");
        // C1: 1 K-tile
        feed(1, 0);
        check("c1.single");

        // C2: 4 K-tile cộng dồn (FC: K=32 → nhiều K-tile)
        feed(3, 0);            // K-tile 0 (khởi tạo)
        feed(4, 1);            // +
        feed(5, 1);
        feed(6, 1);
        check("c2.4ktile");

        // C3: signed lớn
        feed(11, 0);
        feed(12, 1);
        check("c3.signed");

        $display("");
        if (errs==0) $display("=== ALL OS_ARRAY TESTS PASSED ===");
        else         $display("=== %0d OS_ARRAY TEST FAILURES ===", errs);
        $finish;
    end

    initial begin #500000; $display("[TIMEOUT]"); $finish; end

endmodule
