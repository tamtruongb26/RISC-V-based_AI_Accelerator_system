`timescale 1ns / 1ps

// ===========================================================================
// scratchpad_tb.sv — Unit test cho scratchpad.v (Phase 1a)
//
// Kiểm:
//   C1. Ghi bank A nhiều địa chỉ → đọc lại đúng (gồm biên 0 và DEPTH-1).
//   C2. Ghi bank B → bank A KHÔNG bị đụng (2 bank độc lập); bank B đọc đúng.
//   C3. Ping-pong: cùng 1 cycle ghi bank B trong khi đọc bank A → cả hai đúng.
//   C4. Ghi đè bank A địa chỉ cũ → đọc ra giá trị mới.
//
// Pass: in "=== ALL SCRATCHPAD TESTS PASSED ===". Fail: "=== <N> FAILURES ===".
// ===========================================================================
module scratchpad_tb;

    localparam integer DATA_WIDTH = 128;
    localparam integer DEPTH      = 512;
    localparam integer ADDR_WIDTH = $clog2(DEPTH);
    localparam integer CLK_PERIOD = 10;   // 100 MHz

    reg                       clk = 1'b0;
    reg                       wr_en;
    reg                       wr_bank;
    reg  [ADDR_WIDTH-1:0]     wr_addr;
    reg  [DATA_WIDTH-1:0]     wr_data;
    reg                       rd_en;
    reg                       rd_bank;
    reg  [ADDR_WIDTH-1:0]     rd_addr;
    wire [DATA_WIDTH-1:0]     rd_data;

    integer errs = 0;

    // Reference mirror để so sánh
    reg [DATA_WIDTH-1:0] ref_a [0:DEPTH-1];
    reg [DATA_WIDTH-1:0] ref_b [0:DEPTH-1];

    // DUT
    scratchpad #(
        .DATA_WIDTH(DATA_WIDTH),
        .DEPTH     (DEPTH)
    ) dut (
        .pi_clk    (clk),
        .pi_wr_en  (wr_en),
        .pi_wr_bank(wr_bank),
        .pi_wr_addr(wr_addr),
        .pi_wr_data(wr_data),
        .pi_rd_en  (rd_en),
        .pi_rd_bank(rd_bank),
        .pi_rd_addr(rd_addr),
        .po_rd_data(rd_data)
    );

    always #(CLK_PERIOD/2) clk = ~clk;

    // Pattern duy nhất theo (bank, addr)
    function [DATA_WIDTH-1:0] mkpat(input bit b, input integer a);
        mkpat = { (32'(a) ^ (b ? 32'hFFFFFFFF : 32'h00000000)),
                  (32'h11110000 + 32'(a)),
                  (32'(a) * 32'h00000007),
                  (b ? 32'hB0B0B0B0 : 32'hA0A0A0A0) };
    endfunction

    // ── Ghi 1 ô ──
    task automatic do_write(input bit b, input integer a, input [DATA_WIDTH-1:0] d);
        @(negedge clk);
        wr_en   = 1'b1;
        wr_bank = b;
        wr_addr = a[ADDR_WIDTH-1:0];
        wr_data = d;
        @(negedge clk);
        wr_en   = 1'b0;
        if (b) ref_b[a] = d; else ref_a[a] = d;
    endtask

    // ── Đọc 1 ô + so với mirror (read latency 1 cycle) ──
    task automatic do_read_check(input string tag, input bit b, input integer a);
        reg [DATA_WIDTH-1:0] expv;
        @(negedge clk);
        rd_en   = 1'b1;
        rd_bank = b;
        rd_addr = a[ADDR_WIDTH-1:0];
        @(negedge clk);          // qua 1 posedge → po_rd_data đã latch
        rd_en   = 1'b0;
        expv = b ? ref_b[a] : ref_a[a];
        if (rd_data === expv)
            $display("[OK]   %s bank%0d addr=%0d", tag, b, a);
        else begin
            $display("[FAIL] %s bank%0d addr=%0d: got=0x%h exp=0x%h", tag, b, a, rd_data, expv);
            errs = errs + 1;
        end
    endtask

    integer idx;
    integer test_addr [0:7];

    initial begin
        wr_en = 0; wr_bank = 0; wr_addr = 0; wr_data = 0;
        rd_en = 0; rd_bank = 0; rd_addr = 0;
        test_addr[0]=0;   test_addr[1]=1;   test_addr[2]=2;   test_addr[3]=7;
        test_addr[4]=255; test_addr[5]=256; test_addr[6]=510; test_addr[7]=DEPTH-1;

        @(negedge clk);

        // ── C1: ghi bank A → đọc lại ──
        $display("---- Case 1: write/read bank A ----");
        for (idx = 0; idx < 8; idx = idx + 1)
            do_write(1'b0, test_addr[idx], mkpat(1'b0, test_addr[idx]));
        for (idx = 0; idx < 8; idx = idx + 1)
            do_read_check("c1", 1'b0, test_addr[idx]);

        // ── C2: ghi bank B → bank A không đụng ──
        $display("---- Case 2: write bank B, bank A independent ----");
        for (idx = 0; idx < 8; idx = idx + 1)
            do_write(1'b1, test_addr[idx], mkpat(1'b1, test_addr[idx]));
        for (idx = 0; idx < 8; idx = idx + 1) begin
            do_read_check("c2.B", 1'b1, test_addr[idx]);   // bank B đúng
            do_read_check("c2.A", 1'b0, test_addr[idx]);   // bank A vẫn nguyên
        end

        // ── C3: ping-pong — ghi B addr 100 trong khi đọc A addr 7 cùng cycle ──
        $display("---- Case 3: simultaneous write B / read A ----");
        @(negedge clk);
        wr_en = 1'b1; wr_bank = 1'b1; wr_addr = 100; wr_data = mkpat(1'b1, 100);
        rd_en = 1'b1; rd_bank = 1'b0; rd_addr = 7;
        @(negedge clk);
        wr_en = 1'b0; rd_en = 1'b0;
        ref_b[100] = mkpat(1'b1, 100);
        if (rd_data === ref_a[7])
            $display("[OK]   c3.readA-while-writeB: got=0x%h", rd_data);
        else begin
            $display("[FAIL] c3.readA: got=0x%h exp=0x%h", rd_data, ref_a[7]);
            errs = errs + 1;
        end
        do_read_check("c3.B-written", 1'b1, 100);   // verify B addr 100 đã ghi

        // ── C4: ghi đè bank A addr 1 ──
        $display("---- Case 4: overwrite bank A ----");
        do_write(1'b0, 1, 128'hFFFF_FFFF_0000_0000_DEAD_BEEF_CAFE_F00D);
        do_read_check("c4.overwrite", 1'b0, 1);

        // ── Tổng kết ──
        $display("");
        if (errs == 0)
            $display("=== ALL SCRATCHPAD TESTS PASSED ===");
        else
            $display("=== %0d SCRATCHPAD TEST FAILURES ===", errs);
        $finish;
    end

endmodule
