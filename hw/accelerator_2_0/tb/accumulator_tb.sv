`timescale 1ns / 1ps

// ===========================================================================
// accumulator_tb.sv — Unit test cho accumulator.v (Phase 1a)
//
// Kiểm:
//   C1. Overwrite: ghi đè → đọc ra đúng giá trị.
//   C2. K-accumulation: overwrite (K0) rồi accumulate (K1..K3) → đọc = tổng.
//   C3. Độc lập: cộng dồn ở addr X không đụng addr Y.
//   C4. Signed: cộng dồn giá trị âm ra đúng (psum signed).
//   C5. Overflow headroom: cộng dồn nhiều tích lớn, 40-bit không tràn.
//
// Pass: "=== ALL ACCUMULATOR TESTS PASSED ===". Fail: "=== <N> FAILURES ===".
// ===========================================================================
module accumulator_tb;

    localparam integer DATA_WIDTH = 40;
    localparam integer DEPTH      = 1024;
    localparam integer ADDR_WIDTH = $clog2(DEPTH);
    localparam integer CLK_PERIOD = 10;

    reg                          clk = 1'b0;
    reg                          wr_en;
    reg                          overwrite;
    reg  [ADDR_WIDTH-1:0]        wr_addr;
    reg  signed [DATA_WIDTH-1:0] wr_data;
    reg                          rd_en;
    reg  [ADDR_WIDTH-1:0]        rd_addr;
    wire signed [DATA_WIDTH-1:0] rd_data;

    integer errs = 0;

    // Reference model (rộng hơn để bắt tràn nếu DUT tràn mà ref không)
    reg signed [63:0] ref_mem [0:DEPTH-1];

    accumulator #(
        .DATA_WIDTH(DATA_WIDTH),
        .DEPTH     (DEPTH)
    ) dut (
        .pi_clk      (clk),
        .pi_wr_en    (wr_en),
        .pi_overwrite(overwrite),
        .pi_wr_addr  (wr_addr),
        .pi_wr_data  (wr_data),
        .pi_rd_en    (rd_en),
        .pi_rd_addr  (rd_addr),
        .po_rd_data  (rd_data)
    );

    always #(CLK_PERIOD/2) clk = ~clk;

    // ── 1 lần write (overwrite hoặc accumulate) ──
    task automatic do_wr(input bit ov, input integer a, input signed [DATA_WIDTH-1:0] d);
        @(negedge clk);
        wr_en     = 1'b1;
        overwrite = ov;
        wr_addr   = a[ADDR_WIDTH-1:0];
        wr_data   = d;
        @(negedge clk);
        wr_en     = 1'b0;
        if (ov) ref_mem[a] = d;
        else    ref_mem[a] = ref_mem[a] + d;
    endtask

    // ── Đọc + so với ref (cắt ref về 40-bit để so đúng kiểu) ──
    task automatic do_rd_check(input string tag, input integer a);
        reg signed [DATA_WIDTH-1:0] expv;
        @(negedge clk);
        rd_en   = 1'b1;
        rd_addr = a[ADDR_WIDTH-1:0];
        @(negedge clk);
        rd_en   = 1'b0;
        expv = ref_mem[a][DATA_WIDTH-1:0];
        if (rd_data === expv)
            $display("[OK]   %s addr=%0d val=%0d", tag, a, rd_data);
        else begin
            $display("[FAIL] %s addr=%0d: got=%0d (0x%h) exp=%0d (0x%h)",
                     tag, a, rd_data, rd_data, expv, expv);
            errs = errs + 1;
        end
    endtask

    integer i;

    initial begin
        wr_en = 0; overwrite = 0; wr_addr = 0; wr_data = 0;
        rd_en = 0; rd_addr = 0;
        @(negedge clk);

        // ── C1: overwrite ──
        $display("---- Case 1: overwrite ----");
        do_wr(1'b1, 5, 40'sd12345);
        do_rd_check("c1", 5);
        do_wr(1'b1, 5, -40'sd999);     // ghi đè lần 2
        do_rd_check("c1.again", 5);

        // ── C2: K-accumulation (overwrite rồi cộng dồn) ──
        $display("---- Case 2: K-accumulation ----");
        do_wr(1'b1, 10, 40'sd100);     // K0: overwrite
        do_wr(1'b0, 10, 40'sd200);     // K1: +200
        do_wr(1'b0, 10, 40'sd50);      // K2: +50
        do_wr(1'b0, 10, 40'sd1000);    // K3: +1000  → 1350
        do_rd_check("c2.sum", 10);

        // ── C3: độc lập giữa các addr ──
        $display("---- Case 3: address independence ----");
        do_wr(1'b1, 20, 40'sd7);
        do_wr(1'b1, 21, 40'sd9);
        do_wr(1'b0, 20, 40'sd3);       // addr20 = 10
        do_rd_check("c3.a20", 20);     // 10
        do_rd_check("c3.a21", 21);     // 9, không đụng

        // ── C4: signed (cộng dồn âm) ──
        $display("---- Case 4: signed accumulate ----");
        do_wr(1'b1, 30, 40'sd500);
        do_wr(1'b0, 30, -40'sd800);    // 500 - 800 = -300
        do_wr(1'b0, 30, -40'sd200);    // -500
        do_rd_check("c4.neg", 30);

        // ── C5: overflow headroom — cộng dồn 256 tích lớn ──
        $display("---- Case 5: 40-bit headroom (256 large accumulates) ----");
        // Mỗi tích lớn ~ 2^30; cộng 256 lần ~ 2^38 < 2^39 (signed 40-bit) → OK
        do_wr(1'b1, 40, 40'sd1073741824);   // 2^30
        for (i = 0; i < 255; i = i + 1)
            do_wr(1'b0, 40, 40'sd1073741824);
        do_rd_check("c5.bigsum", 40);        // 256 × 2^30 = 2^38

        // ── Tổng kết ──
        $display("");
        if (errs == 0)
            $display("=== ALL ACCUMULATOR TESTS PASSED ===");
        else
            $display("=== %0d ACCUMULATOR TEST FAILURES ===", errs);
        $finish;
    end

endmodule
