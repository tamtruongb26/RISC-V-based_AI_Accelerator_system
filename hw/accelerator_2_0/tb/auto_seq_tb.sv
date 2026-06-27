`timescale 1ns / 1ps
// ===========================================================================
// auto_seq_tb.sv — unit test sequencing cho auto_seq
//   Mock dma_ctrl + mock accelerator (done sau vài cycle). Kiểm: 8 tile của
//   GEMM 2×2×2 đúng thứ tự (n,m,k), flags K-accum, do_s2mm, act, địa chỉ tuyến.
// ===========================================================================
module auto_seq_tb;
    localparam CW = 10;
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    reg go = 0;
    reg [CW-1:0] m_tiles = 2, k_tiles = 2, n_tiles = 2;
    reg [31:0] in_base = 32'd0, out_base = 32'd0;
    reg [25:0] in_blk = 26'd272, out_blk = 26'd128;
    reg [9:0]  tile_m = 8, tile_k = 8, tile_n = 8;
    reg [1:0]  act = 2'b01;   // RELU

    wire busy, done;
    wire dma_start, dma_do_s2mm;
    wire [31:0] dma_mm2s_addr, dma_s2mm_addr;
    wire [25:0] dma_mm2s_len, dma_s2mm_len;
    wire accel_start;
    wire [9:0] o_tile_m, o_tile_k, o_tile_n;
    wire [1:0] o_act, o_slot;
    wire acc_accum, post_skip, skip_w, skip_in;

    reg dma_done = 0, accel_done = 0;

    auto_seq #(.TILE_CW(CW)) dut (
        .pi_clk(clk), .pi_rst_n(rst_n),
        .pi_go(go), .pi_m_tiles(m_tiles), .pi_k_tiles(k_tiles), .pi_n_tiles(n_tiles),
        .pi_in_base(in_base), .pi_in_blk_bytes(in_blk),
        .pi_out_base(out_base), .pi_out_blk_bytes(out_blk),
        .pi_tile_m(tile_m), .pi_tile_k(tile_k), .pi_tile_n(tile_n), .pi_act_mode(act),
        .po_busy(busy), .po_done(done),
        .po_dma_start(dma_start), .po_dma_do_s2mm(dma_do_s2mm),
        .po_dma_mm2s_addr(dma_mm2s_addr), .po_dma_mm2s_len(dma_mm2s_len),
        .po_dma_s2mm_addr(dma_s2mm_addr), .po_dma_s2mm_len(dma_s2mm_len),
        .pi_dma_done(dma_done),
        .po_accel_start(accel_start),
        .po_tile_m(o_tile_m), .po_tile_k(o_tile_k), .po_tile_n(o_tile_n),
        .po_act_mode(o_act), .po_acc_accum(acc_accum), .po_post_skip(post_skip),
        .po_skip_w_load(skip_w), .po_acc_slot(o_slot), .po_skip_in_load(skip_in),
        .pi_accel_done(accel_done)
    );

    // Mock dma + accel: done 3 cycle sau start
    integer dma_cd = 0, acc_cd = 0;
    always @(posedge clk) begin
        dma_done <= 1'b0; accel_done <= 1'b0;
        if (dma_start) dma_cd <= 3; else if (dma_cd > 0) begin dma_cd <= dma_cd-1; if (dma_cd==1) dma_done <= 1'b1; end
        if (accel_start) acc_cd <= 4; else if (acc_cd > 0) begin acc_cd <= acc_cd-1; if (acc_cd==1) accel_done <= 1'b1; end
    end

    // Bắt tham số mỗi tile khi accel_start pulse
    integer ti = 0;
    reg [31:0] cap_in   [0:7];
    reg [31:0] cap_out  [0:7];
    reg        cap_s2mm [0:7];
    reg        cap_accum[0:7];
    reg        cap_skip [0:7];
    reg [1:0]  cap_act  [0:7];
    always @(posedge clk) begin
        if (accel_start && ti < 8) begin
            cap_in[ti]    <= dma_mm2s_addr;
            cap_out[ti]   <= dma_s2mm_addr;
            cap_s2mm[ti]  <= dma_do_s2mm;
            cap_accum[ti] <= acc_accum;
            cap_skip[ti]  <= post_skip;
            cap_act[ti]   <= o_act;
            ti <= ti + 1;
        end
    end

    integer errs = 0, i;
    // kỳ vọng: thứ tự (n,m,k), 8 tile
    reg [31:0] e_in   [0:7];
    reg [31:0] e_out  [0:7];
    reg        e_s2mm [0:7];
    reg        e_accum[0:7];
    reg        e_skip [0:7];

    task chk(input [31:0] g, input [31:0] e, input [127:0] nm, input integer idx);
        if (g !== e) begin $display("[FAIL] %0s tile%0d: got=%0d exp=%0d", nm, idx, g, e); errs=errs+1; end
    endtask

    initial begin
        // in_addr tuyến tính 0..7 × 272
        for (i = 0; i < 8; i = i + 1) e_in[i] = i * 272;
        // out_addr tăng mỗi last_k (idx lẻ): 0,128,256,384 cho tile 1,3,5,7
        e_out[0]=0;   e_out[1]=0;
        e_out[2]=128; e_out[3]=128;
        e_out[4]=256; e_out[5]=256;
        e_out[6]=384; e_out[7]=384;
        // k=0 (idx chẵn): accum0 skip1 s2mm0 ; k=1 (idx lẻ): accum1 skip0 s2mm1
        for (i = 0; i < 8; i = i + 1) begin
            e_accum[i] = (i % 2);          // k index = i%2
            e_skip[i]  = (i % 2) ? 1'b0 : 1'b1;
            e_s2mm[i]  = (i % 2) ? 1'b1 : 1'b0;
        end

        repeat (4) @(posedge clk); rst_n = 1; @(posedge clk);
        @(negedge clk); go = 1; @(negedge clk); go = 0;
        wait (done == 1'b1);
        @(posedge clk);

        if (ti !== 8) begin $display("[FAIL] số tile=%0d ≠ 8", ti); errs=errs+1; end
        for (i = 0; i < 8; i = i + 1) begin
            chk(cap_in[i],   e_in[i],   "in_addr",  i);
            chk(cap_accum[i],{31'd0,e_accum[i]}, "acc_accum",i);
            chk(cap_skip[i], {31'd0,e_skip[i]},  "post_skip",i);
            chk(cap_s2mm[i], {31'd0,e_s2mm[i]},  "do_s2mm",  i);
            if (e_s2mm[i]) chk(cap_out[i], e_out[i], "out_addr", i);
            // act: last_k → RELU(1), else bypass(0)
            chk({30'd0,cap_act[i]}, e_s2mm[i] ? 32'd1 : 32'd0, "act", i);
        end

        if (errs == 0) $display("=== AUTO_SEQ TEST PASSED (8 tile 2x2x2 đúng seq+flags+addr) ===");
        else           $display("=== AUTO_SEQ FAILED: %0d errors ===", errs);
        $finish;
    end
    initial begin #50000; $display("[FAIL] TIMEOUT"); $finish; end
endmodule
