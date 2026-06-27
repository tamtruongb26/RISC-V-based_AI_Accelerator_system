`timescale 1ns / 1ps
// ===========================================================================
// dma_ctrl_tb.sv — unit test cho AXI-Lite master dma_ctrl
//   Mock DMA slave: lưu register, model DMASR busy→IDLE sau khi LENGTH ghi.
//   Kiểm: thứ tự ghi register đúng + poll tới IDLE + po_done.
// ===========================================================================
module dma_ctrl_tb;
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    // DUT cmd
    reg        start = 0, do_s2mm = 0;
    reg [31:0] mm2s_addr, s2mm_addr;
    reg [25:0] mm2s_len, s2mm_len;
    wire       busy, done;

    // AXI-Lite master wires
    wire [31:0] awaddr;  wire awvalid;  reg awready;
    wire [31:0] wdata;   wire [3:0] wstrb; wire wvalid; reg wready;
    reg  [1:0]  bresp;   reg bvalid;    wire bready;
    wire [31:0] araddr;  wire arvalid;  reg arready;
    reg  [31:0] rdata;   reg [1:0] rresp; reg rvalid; wire rready;

    dma_ctrl dut (
        .pi_clk(clk), .pi_rst_n(rst_n),
        .pi_start(start), .pi_do_s2mm(do_s2mm),
        .pi_mm2s_addr(mm2s_addr), .pi_mm2s_len(mm2s_len),
        .pi_s2mm_addr(s2mm_addr), .pi_s2mm_len(s2mm_len),
        .po_busy(busy), .po_done(done),
        .po_awaddr(awaddr), .po_awvalid(awvalid), .pi_awready(awready),
        .po_wdata(wdata), .po_wstrb(wstrb), .po_wvalid(wvalid), .pi_wready(wready),
        .pi_bresp(bresp), .pi_bvalid(bvalid), .po_bready(bready),
        .po_araddr(araddr), .po_arvalid(arvalid), .pi_arready(arready),
        .pi_rdata(rdata), .pi_rresp(rresp), .pi_rvalid(rvalid), .po_rready(rready)
    );

    // ── Mock DMA slave ──
    reg [31:0] regs [0:31];          // 32 word (0x00..0x7C)
    integer mm2s_busy, s2mm_busy;    // countdown sau khi LENGTH ghi
    localparam MM2S_DMASR = 8'h04, S2MM_DMASR = 8'h34;
    localparam MM2S_LEN = 8'h28, S2MM_LEN = 8'h58;

    // ghi log thứ tự
    reg [7:0] wr_log [0:31];
    integer   wr_n;
    integer   rd_mm2s_n, rd_s2mm_n;

    // Write channel: accept AW+W cùng lúc, trả B
    always @(posedge clk) begin
        awready <= 1'b0; wready <= 1'b0;
        if (!rst_n) begin
            bvalid <= 1'b0; bresp <= 2'b0;
        end else begin
            // bắt tay AW/W (1 cycle, đồng thời)
            if (awvalid && wvalid && !awready) begin
                awready <= 1'b1; wready <= 1'b1;
                regs[awaddr[6:2]] <= wdata;
                wr_log[wr_n] <= awaddr[7:0]; wr_n <= wr_n + 1;
                if (awaddr[7:0] == MM2S_LEN) mm2s_busy <= 6;
                if (awaddr[7:0] == S2MM_LEN) s2mm_busy <= 6;
                bvalid <= 1'b1; bresp <= 2'b00;
            end else if (bvalid && bready) begin
                bvalid <= 1'b0;
            end
        end
    end

    // Read channel: trả DMASR với IDLE bit theo countdown
    always @(posedge clk) begin
        arready <= 1'b0;
        if (!rst_n) begin
            rvalid <= 1'b0; rdata <= 32'd0; rresp <= 2'b0;
        end else begin
            if (mm2s_busy > 0) mm2s_busy <= mm2s_busy - 1;
            if (s2mm_busy > 0) s2mm_busy <= s2mm_busy - 1;
            if (arvalid && !arready && !rvalid) begin
                arready <= 1'b1;
                rvalid  <= 1'b1;
                rresp   <= 2'b00;
                if (araddr[7:0] == MM2S_DMASR) begin
                    rdata <= (mm2s_busy == 0) ? 32'h2 : 32'h0;  // bit1=IDLE
                    rd_mm2s_n <= rd_mm2s_n + 1;
                end else if (araddr[7:0] == S2MM_DMASR) begin
                    rdata <= (s2mm_busy == 0) ? 32'h2 : 32'h0;
                    rd_s2mm_n <= rd_s2mm_n + 1;
                end else
                    rdata <= 32'd0;
            end else if (rvalid && rready) begin
                rvalid <= 1'b0;
            end
        end
    end

    integer errs = 0;
    integer i;
    task check_seq(input [7:0] exp [0:5], input integer n);
        integer j;
        begin
            if (wr_n !== n) begin
                $display("[FAIL] số write=%0d, kỳ vọng %0d", wr_n, n); errs=errs+1;
            end
            for (j = 0; j < n; j = j + 1)
                if (wr_log[j] !== exp[j]) begin
                    $display("[FAIL] write[%0d]=0x%02h, kỳ vọng 0x%02h", j, wr_log[j], exp[j]);
                    errs = errs + 1;
                end
        end
    endtask

    reg [7:0] exp_full [0:5];
    initial begin
        mm2s_busy = 0; s2mm_busy = 0; wr_n = 0; rd_mm2s_n = 0; rd_s2mm_n = 0;
        for (i = 0; i < 32; i = i + 1) regs[i] = 0;
        mm2s_addr = 32'h1000_0000; mm2s_len = 26'd512;
        s2mm_addr = 32'h2000_0000; s2mm_len = 26'd128;
        repeat (4) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        // ── Test 1: transfer có cả S2MM ──
        wr_n = 0; rd_mm2s_n = 0; rd_s2mm_n = 0;
        do_s2mm = 1;
        @(negedge clk); start = 1; @(negedge clk); start = 0;
        wait (done == 1'b1);
        @(posedge clk);

        // thứ tự ghi kỳ vọng: S2_CR,S2_DA,S2_LEN,MM_CR,MM_SA,MM_LEN
        exp_full[0]=8'h30; exp_full[1]=8'h48; exp_full[2]=8'h58;
        exp_full[3]=8'h00; exp_full[4]=8'h18; exp_full[5]=8'h28;
        check_seq(exp_full, 6);
        // kiểm giá trị địa chỉ/length ghi đúng
        if (regs[8'h48>>2]  !== 32'h2000_0000) begin $display("[FAIL] S2MM_DA sai"); errs=errs+1; end
        if (regs[8'h58>>2]  !== 32'd128)        begin $display("[FAIL] S2MM_LEN sai"); errs=errs+1; end
        if (regs[8'h18>>2]  !== 32'h1000_0000) begin $display("[FAIL] MM2S_SA sai"); errs=errs+1; end
        if (regs[8'h28>>2]  !== 32'd512)        begin $display("[FAIL] MM2S_LEN sai"); errs=errs+1; end
        // phải poll ≥2 lần mỗi kênh (busy rồi idle)
        // MM2S poll ≥2 (busy→idle, chứng minh poll-loop); S2MM có thể đã idle khi
        // poll MM2S xong → chỉ cần ≥1.
        if (rd_mm2s_n < 2) begin $display("[FAIL] MM2S poll %0d lần (<2)", rd_mm2s_n); errs=errs+1; end
        if (rd_s2mm_n < 1) begin $display("[FAIL] S2MM poll %0d lần (<1)", rd_s2mm_n); errs=errs+1; end
        if (errs == 0) $display("[ OK ] dma_ctrl full transfer: seq+addr+poll đúng");

        // ── Test 2: transfer chỉ MM2S (do_s2mm=0) ──
        wr_n = 0; rd_mm2s_n = 0; rd_s2mm_n = 0;
        do_s2mm = 0; mm2s_addr = 32'h1800_0000; mm2s_len = 26'd64;
        @(negedge clk); start = 1; @(negedge clk); start = 0;
        wait (done == 1'b1);
        @(posedge clk);
        // chỉ MM_CR,MM_SA,MM_LEN
        if (wr_n !== 3) begin $display("[FAIL] MM2S-only số write=%0d ≠3", wr_n); errs=errs+1; end
        if (wr_log[0]!==8'h00 || wr_log[1]!==8'h18 || wr_log[2]!==8'h28) begin
            $display("[FAIL] MM2S-only seq sai"); errs=errs+1; end
        if (rd_s2mm_n != 0) begin $display("[FAIL] MM2S-only không nên poll S2MM"); errs=errs+1; end
        if (errs == 0) $display("[ OK ] dma_ctrl MM2S-only: seq đúng, bỏ S2MM");

        if (errs == 0) $display("=== ALL DMA_CTRL TESTS PASSED ===");
        else           $display("=== DMA_CTRL FAILED: %0d errors ===", errs);
        $finish;
    end

    initial begin #20000; $display("[FAIL] TIMEOUT"); $finish; end
endmodule
