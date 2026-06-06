`timescale 1ns / 1ps

// ===========================================================================
// maxpool2x2_tb.sv — Unit test cho maxpool2x2.v (Phase 2b)
//
// FM = memory registered-read; output ghi ra out_mem. So với golden (signed max
// 2×2) tính trong TB. Case: 4×4×1, 4×4×2 (multi-channel), 6×6×1; có giá trị âm.
//
// Pass: "=== ALL MAXPOOL TESTS PASSED ===".
// ===========================================================================
module maxpool2x2_tb;

    localparam integer DW = 16;
    localparam integer AW = 16;
    localparam integer CLK = 10;

    reg                clk = 1'b0;
    reg                rst_n, start;
    wire               busy, done;
    reg  [7:0]         H, W, C;
    wire               fm_rd_en;
    wire [AW-1:0]      fm_rd_addr;
    reg  signed [DW-1:0] fm_rd_data;
    wire               out_wr_en;
    wire [AW-1:0]      out_wr_addr;
    wire signed [DW-1:0] out_wr_data;

    integer errs = 0;

    reg signed [DW-1:0] fm_mem  [0:1023];
    reg signed [DW-1:0] out_mem [0:1023];
    reg signed [DW-1:0] gold    [0:1023];

    maxpool2x2 #(.DATA_WIDTH(DW), .ADDR_WIDTH(AW), .DIM_WIDTH(8)) dut (
        .pi_clk(clk), .pi_rst_n(rst_n), .pi_start(start),
        .po_busy(busy), .po_done(done),
        .pi_H(H), .pi_W(W), .pi_C(C),
        .po_fm_rd_en(fm_rd_en), .po_fm_rd_addr(fm_rd_addr), .pi_fm_rd_data(fm_rd_data),
        .po_out_wr_en(out_wr_en), .po_out_wr_addr(out_wr_addr), .po_out_wr_data(out_wr_data)
    );

    always #(CLK/2) clk = ~clk;
    always @(posedge clk) if (fm_rd_en)  fm_rd_data <= fm_mem[fm_rd_addr];
    always @(posedge clk) if (out_wr_en) out_mem[out_wr_addr] <= out_wr_data;

    function signed [DW-1:0] smax(input signed [DW-1:0] a, b);
        smax = (a > b) ? a : b;
    endfunction

    task automatic run_pool(input string name, input integer h, w, c);
        integer hout, wout, i, cc, ho, wo, oi, timeout;
        reg signed [DW-1:0] e0,e1,e2,e3;
        hout = h/2; wout = w/2;
        // FM data: trộn dương/âm
        for (i=0;i<1024;i=i+1) begin fm_mem[i]=0; out_mem[i]=16'shXXXX; end
        for (i=0;i<c*h*w;i=i+1)
            fm_mem[i] = (i % 5) - 2 + (i * 3);   // distinct, có âm

        // golden
        oi = 0;
        for (cc=0;cc<c;cc=cc+1)
        for (ho=0;ho<hout;ho=ho+1)
        for (wo=0;wo<wout;wo=wo+1) begin
            e0 = fm_mem[cc*h*w + (2*ho)*w   + (2*wo)];
            e1 = fm_mem[cc*h*w + (2*ho)*w   + (2*wo+1)];
            e2 = fm_mem[cc*h*w + (2*ho+1)*w + (2*wo)];
            e3 = fm_mem[cc*h*w + (2*ho+1)*w + (2*wo+1)];
            gold[oi] = smax(smax(e0,e1), smax(e2,e3));
            oi = oi + 1;
        end

        @(negedge clk); H=h; W=w; C=c; start=1'b1; @(negedge clk); start=1'b0;
        timeout=0;
        while (!done && timeout<100000) begin @(posedge clk); timeout=timeout+1; end
        @(negedge clk);
        if (timeout>=100000) begin $display("[FAIL] %s TIMEOUT", name); errs=errs+1; return; end

        for (i=0;i<c*hout*wout;i=i+1)
            if (out_mem[i] !== gold[i]) begin
                if (errs<6) $display("[FAIL] %s out[%0d]: got=%0d exp=%0d", name, i, out_mem[i], gold[i]);
                errs = errs + 1;
            end
        $display("[ OK ] %s (%0dx%0dx%0d → %0dx%0dx%0d)", name, h, w, c, hout, wout, c);
    endtask

    initial begin
        rst_n=0; start=0; H=0;W=0;C=0; fm_rd_data=0;
        repeat (3) @(posedge clk); @(negedge clk); rst_n=1; @(posedge clk);

        $display("---- maxpool cases ----");
        run_pool("c1.4x4x1", 4, 4, 1);
        run_pool("c2.4x4x2", 4, 4, 2);
        run_pool("c3.6x6x1", 6, 6, 1);
        run_pool("c4.8x8x3", 8, 8, 3);

        $display("");
        if (errs==0) $display("=== ALL MAXPOOL TESTS PASSED ===");
        else         $display("=== %0d MAXPOOL TEST FAILURES ===", errs);
        $finish;
    end

    initial begin #2000000; $display("[TIMEOUT]"); $finish; end

endmodule
