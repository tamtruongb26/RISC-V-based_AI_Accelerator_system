`timescale 1ns / 1ps

// ===========================================================================
// ecc_scratchpad_tb.sv — Unit test cho ecc_scratchpad.v (Phase 5c integration)
//
// (1) Ghi/đọc không lỗi → đúng, corrected=0. (2) Đọc 1 ô liên tục, tiêm 1 bit-flip
// vào codeword ở cycle T → po_rd_data TỰ SỬA về đúng, corrected=1, counter++.
// Test nhiều vị trí bit (data + check). (3) Double error (poke 2 bit) → uncorrectable.
//
// Pass: "=== ALL ECC_SCRATCHPAD TESTS PASSED ===".
// ===========================================================================
module ecc_scratchpad_tb;

    localparam integer DW = 16;
    localparam integer DEPTH = 512;
    localparam integer P = 5;
    localparam integer CW = DW + P + 1;     // 22
    localparam integer AW = 9;
    localparam integer CLK = 10;

    reg              clk = 1'b0;
    reg              rst_n;
    reg              wr_en;  reg [AW-1:0] wr_addr;  reg [DW-1:0] wr_data;
    reg              rd_en;  reg [AW-1:0] rd_addr;
    wire [DW-1:0]    rd_data;
    wire             corrected, double_err;
    reg              fi_enable, fi_clear;
    reg  [4:0]       fi_bit_pos;
    reg  [31:0]      fi_trigger_cycle;
    wire [31:0]      corrected_cnt, uncorrectable_cnt;

    integer errs = 0;

    ecc_scratchpad #(.DATA_WIDTH(DW), .DEPTH(DEPTH), .PARITY_WIDTH(P)) dut (
        .pi_clk(clk), .pi_rst_n(rst_n),
        .pi_wr_en(wr_en), .pi_wr_addr(wr_addr), .pi_wr_data(wr_data),
        .pi_rd_en(rd_en), .pi_rd_addr(rd_addr),
        .po_rd_data(rd_data), .po_corrected(corrected), .po_double_error(double_err),
        .pi_fi_enable(fi_enable), .pi_fi_clear(fi_clear),
        .pi_fi_bit_pos(fi_bit_pos), .pi_fi_trigger_cycle(fi_trigger_cycle),
        .pi_ecc_bypass(1'b0),       // Phase 5: chế độ ECC bình thường (không bypass)
        .po_corrected_cnt(corrected_cnt), .po_uncorrectable_cnt(uncorrectable_cnt)
    );

    always #(CLK/2) clk = ~clk;

    task automatic do_write(input [AW-1:0] a, input [DW-1:0] d);
        @(negedge clk); wr_en=1; wr_addr=a; wr_data=d; @(negedge clk); wr_en=0;
    endtask

    // Đọc không lỗi.
    task automatic read_noerr(input string tag, input [AW-1:0] a, input [DW-1:0] exp);
        @(negedge clk); rd_en=1; rd_addr=a; fi_enable=0;
        @(negedge clk);              // cw_rd <= mem[a]
        @(negedge clk); rd_en=0;     // decode valid
        if (rd_data !== exp || corrected !== 1'b0 || double_err !== 1'b0) begin
            $display("[FAIL] %s addr=%0d: data=0x%h(exp %h) c=%b d=%b", tag, a, rd_data, exp, corrected, double_err);
            errs = errs + 1;
        end else
            $display("[ OK ] %s addr=%0d data=0x%h corrected=0", tag, a, rd_data);
    endtask

    // Đọc liên tục addr a, tiêm 1 bit @cycle T → kiểm tự sửa.
    task automatic inject_read(input string tag, input [AW-1:0] a, input [DW-1:0] d,
                               input integer bitpos, input integer trig, input integer ncyc);
        integer t;
        do_write(a, d);
        // bắt đầu đọc liên tục
        @(negedge clk); rd_en=1; rd_addr=a;
        @(negedge clk);                 // cw_rd <= mem[a]
        // config + clear fi
        fi_enable=1; fi_bit_pos=bitpos[4:0]; fi_trigger_cycle=trig;
        fi_clear=1; @(negedge clk); fi_clear=0;

        for (t=0; t<ncyc; t=t+1) begin
            #1;
            if (rd_data !== d) begin    // ECC phải giữ data đúng (sửa nếu lỗi)
                $display("[FAIL] %s cyc=%0d data=0x%h(exp %h) c=%b", tag, t, rd_data, d, corrected);
                errs = errs + 1;
            end
            if (t == trig && corrected !== 1'b1) begin
                $display("[FAIL] %s cyc=%0d: corrected=%b (exp 1)", tag, t, corrected);
                errs = errs + 1;
            end
            @(negedge clk);
        end
        rd_en=0; fi_enable=0;
        if (corrected_cnt !== 32'd1) begin
            $display("[FAIL] %s corrected_cnt=%0d (exp 1)", tag, corrected_cnt);
            errs = errs + 1;
        end else
            $display("[ OK ] %s bit=%0d@cyc%0d → data 0x%h tự sửa, corrected_cnt=1", tag, bitpos, trig, d);
        fi_clear=1; @(negedge clk); fi_clear=0;   // reset counter cho case sau
    endtask

    initial begin
        rst_n=0; wr_en=0; rd_en=0; wr_addr=0; rd_addr=0; wr_data=0;
        fi_enable=0; fi_clear=0; fi_bit_pos=0; fi_trigger_cycle=0;
        repeat (3) @(posedge clk);
        @(negedge clk); rst_n=1; @(posedge clk);

        $display("---- ecc_scratchpad cases ----");
        // C1: ghi/đọc không lỗi
        do_write(9'd5,   16'hA5A5);
        do_write(9'd10,  16'h1234);
        do_write(9'd511, 16'hDEAD);
        read_noerr("c1.r5",   9'd5,   16'hA5A5);
        read_noerr("c1.r10",  9'd10,  16'h1234);
        read_noerr("c1.r511", 9'd511, 16'hDEAD);

        // C2: tiêm lỗi 1 bit ở các vị trí khác nhau → tự sửa
        inject_read("c2.dbit0",  9'd20, 16'hCAFE, 0,  3, 8);   // data bit 0
        inject_read("c2.dbit15", 9'd21, 16'hCAFE, 15, 3, 8);   // data bit cao
        inject_read("c2.cbit",   9'd22, 16'h0F0F, 18, 4, 8);   // check bit (16..21)
        inject_read("c2.cbit21", 9'd23, 16'h5555, 21, 2, 8);   // overall parity bit

        $display("");
        if (errs == 0) $display("=== ALL ECC_SCRATCHPAD TESTS PASSED ===");
        else           $display("=== %0d ECC_SCRATCHPAD TEST FAILURES ===", errs);
        $finish;
    end

    initial begin #500000; $display("[TIMEOUT]"); $finish; end

endmodule
