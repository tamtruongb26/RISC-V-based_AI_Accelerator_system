`timescale 1ns / 1ps

// ===========================================================================
// im2col_tb.sv — Unit test cho im2col.v (Phase 2a)
//
// So ma trận A do DUT sinh với golden tính trong TB (cùng công thức im2col,
// padding → 0). FM = memory registered-read 1-cycle; A = memory DUT ghi.
//
// Case: 1) 4×4×1 k2 s1 p0   2) 3×3×1 k3 s1 p1 (padding)
//       3) 3×3×2 k2 s1 p0 (multi-channel)   4) 5×5×1 k3 s2 p0 (stride 2)
//
// Pass: "=== ALL IM2COL TESTS PASSED ===". Fail: "=== <N> FAILURES ===".
// ===========================================================================
module im2col_tb;

    localparam integer DW = 16;
    localparam integer AW = 16;
    localparam integer CLK_PERIOD = 10;

    reg                clk = 1'b0;
    reg                rst_n;
    reg                start;
    wire               busy, done;
    reg  [7:0]         H, W, C, Hout, Wout;
    reg  [3:0]         KH, KW, STR, PAD;
    wire               fm_rd_en;
    wire [AW-1:0]      fm_rd_addr;
    reg  [DW-1:0]      fm_rd_data;
    wire               a_wr_en;
    wire [AW-1:0]      a_wr_addr;
    wire [DW-1:0]      a_wr_data;

    integer errs = 0;

    // Memories
    reg [DW-1:0] fm_mem [0:1023];
    reg [DW-1:0] a_mem  [0:1023];
    reg [DW-1:0] a_gold [0:1023];

    im2col #(.DATA_WIDTH(DW), .ADDR_WIDTH(AW), .DIM_WIDTH(8)) dut (
        .pi_clk(clk), .pi_rst_n(rst_n), .pi_start(start),
        .po_busy(busy), .po_done(done),
        .pi_H(H), .pi_W(W), .pi_C(C),
        .pi_KH(KH), .pi_KW(KW), .pi_stride(STR), .pi_pad(PAD),
        .pi_H_out(Hout), .pi_W_out(Wout),
        .po_fm_rd_en(fm_rd_en), .po_fm_rd_addr(fm_rd_addr), .pi_fm_rd_data(fm_rd_data),
        .po_a_wr_en(a_wr_en), .po_a_wr_addr(a_wr_addr), .po_a_wr_data(a_wr_data)
    );

    always #(CLK_PERIOD/2) clk = ~clk;

    // FM registered read (1-cycle latency)
    always @(posedge clk)
        if (fm_rd_en) fm_rd_data <= fm_mem[fm_rd_addr];

    // A write capture
    always @(posedge clk)
        if (a_wr_en) a_mem[a_wr_addr] <= a_wr_data;

    // ── Tính golden + chạy DUT + so ──
    task automatic run_case(input string name,
                            input integer h, w, c,
                            input integer kh, kw, str, pad);
        integer hout, wout, kk, mm, i;
        integer ho, wo, cc, ih, iw, hin, win, row, col;
        integer timeout;
        hout = (h + 2*pad - kh)/str + 1;
        wout = (w + 2*pad - kw)/str + 1;
        kk   = c*kh*kw;
        mm   = hout*wout;

        // FM data = giá trị duy nhất theo (c,h,w): 1 + addr
        for (i = 0; i < 1024; i = i + 1) begin
            fm_mem[i] = 16'h0; a_mem[i] = 16'hXXXX; a_gold[i] = 16'h0;
        end
        for (cc = 0; cc < c; cc = cc + 1)
            for (ih = 0; ih < h; ih = ih + 1)
                for (iw = 0; iw < w; iw = iw + 1)
                    fm_mem[cc*h*w + ih*w + iw] = 16'h0100 + cc*16'h40 + ih*16'h8 + iw;

        // Golden im2col
        row = 0;
        for (ho = 0; ho < hout; ho = ho + 1)
        for (wo = 0; wo < wout; wo = wo + 1) begin
            col = 0;
            for (cc = 0; cc < c; cc = cc + 1)
            for (i  = 0; i  < kh; i  = i + 1)       // i = kh idx
            for (kk = 0; kk < kw; kk = kk + 1) begin // kk = kw idx (reuse var sau)
                hin = ho*str + i - pad;
                win = wo*str + kk - pad;
                if (hin >= 0 && hin < h && win >= 0 && win < w)
                    a_gold[row*(c*kh*kw) + col] = fm_mem[cc*h*w + hin*w + win];
                else
                    a_gold[row*(c*kh*kw) + col] = 16'h0;
                col = col + 1;
            end
            row = row + 1;
        end

        // Drive config + start
        @(negedge clk);
        H = h; W = w; C = c; KH = kh; KW = kw; STR = str; PAD = pad;
        Hout = hout; Wout = wout;
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;

        // Wait done
        timeout = 0;
        while (!done && timeout < 100000) begin @(posedge clk); timeout = timeout + 1; end
        @(negedge clk);
        if (timeout >= 100000) begin
            $display("[FAIL] %s: TIMEOUT", name); errs = errs + 1; return;
        end

        // Compare M*K phần tử
        kk = c*kh*kw; mm = hout*wout;
        for (i = 0; i < mm*kk; i = i + 1) begin
            if (a_mem[i] !== a_gold[i]) begin
                if (errs < 8)
                    $display("[FAIL] %s A[%0d]: got=0x%h exp=0x%h", name, i, a_mem[i], a_gold[i]);
                errs = errs + 1;
            end
        end
        $display("[ OK ] %s (%0dx%0dx%0d k%0dx%0d s%0d p%0d → A[%0d×%0d])",
                 name, h, w, c, kh, kw, str, pad, mm, kk);
    endtask

    initial begin
        rst_n = 0; start = 0; fm_rd_data = 0;
        H=0;W=0;C=0;KH=0;KW=0;STR=0;PAD=0;Hout=0;Wout=0;
        repeat (3) @(posedge clk);
        @(negedge clk); rst_n = 1; @(posedge clk);

        $display("---- im2col cases ----");
        run_case("c1.basic",   4, 4, 1, 2, 2, 1, 0);
        run_case("c2.pad",     3, 3, 1, 3, 3, 1, 1);
        run_case("c3.chan",    3, 3, 2, 2, 2, 1, 0);
        run_case("c4.stride2", 5, 5, 1, 3, 3, 2, 0);

        $display("");
        if (errs == 0) $display("=== ALL IM2COL TESTS PASSED ===");
        else           $display("=== %0d IM2COL TEST FAILURES ===", errs);
        $finish;
    end

    initial begin
        #5000000; $display("[TIMEOUT] sim exceeded"); $finish;
    end

endmodule
