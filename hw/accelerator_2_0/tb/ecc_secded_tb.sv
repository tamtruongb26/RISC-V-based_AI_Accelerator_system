`timescale 1ns / 1ps

// ===========================================================================
// ecc_secded_tb.sv — Unit test cho ecc_secded.v (Phase 5c)
//
// Vét cạn: với nhiều data pattern → encode; (1) no error → giải đúng;
// (2) lật MỖI bit codeword (data+check) → sửa về đúng, corrected=1;
// (3) lật MỌI cặp 2 bit → double_error=1 (detect).
//
// Pass: "=== ALL ECC_SECDED TESTS PASSED ===".
// ===========================================================================
module ecc_secded_tb;

    localparam integer D = 8;
    localparam integer P = 4;
    localparam integer N = D + P + 1;   // 13 bit codeword

    reg  [D-1:0] enc_data;
    wire [P:0]   enc_check;
    reg  [D-1:0] dec_data;
    reg  [P:0]   dec_check;
    wire [D-1:0] dec_out;
    wire         corrected, double_err;

    integer errs = 0;

    ecc_secded #(.DATA_WIDTH(D), .PARITY_WIDTH(P)) dut (
        .pi_enc_data(enc_data), .po_enc_check(enc_check),
        .pi_dec_data(dec_data), .pi_dec_check(dec_check),
        .po_dec_data(dec_out), .po_corrected(corrected), .po_double_error(double_err)
    );

    // Lật bit thứ b của codeword {check, data} (0..D-1 = data, D..D+P = check).
    task automatic apply(input [D-1:0] data, input [P:0] chk,
                         input integer b);   // b<0 = không lật
        reg [D-1:0] dd; reg [P:0] cc;
        dd = data; cc = chk;
        if (b >= 0) begin
            if (b < D) dd = dd ^ (1 << b);
            else       cc = cc ^ (1 << (b - D));
        end
        dec_data = dd; dec_check = cc;
    endtask

    // Single-error: no-error + lật mỗi bit → sửa đúng.
    task automatic test_single(input [D-1:0] data);
        integer b;
        reg [P:0] chk;
        enc_data = data; #1; chk = enc_check;
        apply(data, chk, -1); #1;
        if (dec_out !== data || corrected !== 1'b0 || double_err !== 1'b0) begin
            $display("[FAIL] noerr data=%h: out=%h c=%b d=%b", data, dec_out, corrected, double_err);
            errs = errs + 1;
        end
        for (b = 0; b < N; b = b + 1) begin
            apply(data, chk, b); #1;
            if (dec_out !== data || corrected !== 1'b1 || double_err !== 1'b0) begin
                $display("[FAIL] 1bit@%0d data=%h: out=%h c=%b d=%b", b, data, dec_out, corrected, double_err);
                errs = errs + 1;
            end
        end
    endtask

    // Double-error: mọi cặp (b1<b2) → double_error=1.
    task automatic test_double_all(input [D-1:0] data);
        integer b1, b2;
        reg [P:0] chk;
        reg [D-1:0] dd; reg [P:0] cc;
        enc_data = data; #1; chk = enc_check;
        for (b1 = 0; b1 < N; b1 = b1 + 1)
            for (b2 = b1 + 1; b2 < N; b2 = b2 + 1) begin
                dd = data; cc = chk;
                if (b1 < D) dd = dd ^ (1 << b1);          else cc = cc ^ (1 << (b1 - D));
                if (b2 < D) dd = dd ^ (1 << b2);          else cc = cc ^ (1 << (b2 - D));
                dec_data = dd; dec_check = cc; #1;
                if (double_err !== 1'b1) begin
                    $display("[FAIL] 2bit(%0d,%0d) data=%h: double=%b (exp 1)", b1, b2, data, double_err);
                    errs = errs + 1;
                end
            end
    endtask

    initial begin
        $display("---- ecc_secded cases ----");
        test_single(8'h00);
        test_single(8'hFF);
        test_single(8'hA5);
        test_single(8'h3C);
        test_single(8'h81);
        $display("[ OK ] single-error correct: 5 pattern × %0d position", N);

        test_double_all(8'hA5);
        test_double_all(8'h5A);
        $display("[ OK ] double-error detect: 2 pattern × %0d cặp", (N*(N-1))/2);

        $display("");
        if (errs == 0) $display("=== ALL ECC_SECDED TESTS PASSED ===");
        else           $display("=== %0d ECC_SECDED TEST FAILURES ===", errs);
        $finish;
    end

    initial begin #500000; $display("[TIMEOUT]"); $finish; end

endmodule
