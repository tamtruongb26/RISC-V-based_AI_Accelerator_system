`timescale 1ns / 1ps

// ===========================================================================
// ecc_secded.v — Hamming SECDED encoder + decoder (Phase 5c, Vấn đề 7c)
//
// Single Error Correct, Double Error Detect. Bảo vệ scratchpad weight bus khỏi
// SEU. Systematic Hamming + 1 overall parity.
//
//   check = { overall_parity[1], hamming_parity[PARITY_WIDTH] }
//   Codeword = DATA_WIDTH + PARITY_WIDTH + 1 bit.
//   Ràng buộc: 2^PARITY_WIDTH >= DATA_WIDTH + PARITY_WIDTH + 1.
//
// Combinational. Dùng generate + assign (mask hằng số tính ở elaboration) thay
// function-trong-always → robust cho cả synth lẫn sim optimizer.
// ===========================================================================
module ecc_secded #(
    parameter integer DATA_WIDTH   = 8,
    parameter integer PARITY_WIDTH = 4
)(
    // ── Encode: data → check ──
    input  wire [DATA_WIDTH-1:0]     pi_enc_data,
    output wire [PARITY_WIDTH:0]     po_enc_check,

    // ── Decode: (data, check) có thể lỗi → corrected + flags ──
    input  wire [DATA_WIDTH-1:0]     pi_dec_data,
    input  wire [PARITY_WIDTH:0]     pi_dec_check,
    output wire [DATA_WIDTH-1:0]     po_dec_data,
    output wire                      po_corrected,
    output wire                      po_double_error
);

    // dcode(i) = vị trí codeword (1-indexed) của data bit thứ i = số non-luỹ-thừa-2
    // thứ i. pmask(k) = DATA_WIDTH-bit mask các data bit mà parity k phủ.
    function integer dcode(input integer di);
        integer pos, cnt;
        begin
            cnt = -1; dcode = 0;
            for (pos = 1; pos <= (1 << PARITY_WIDTH); pos = pos + 1)
                if ((pos & (pos - 1)) != 0) begin
                    cnt = cnt + 1;
                    if (cnt == di) dcode = pos;
                end
        end
    endfunction

    function [DATA_WIDTH-1:0] pmask(input integer k);
        integer i;
        begin
            pmask = {DATA_WIDTH{1'b0}};
            for (i = 0; i < DATA_WIDTH; i = i + 1)
                if ((dcode(i) >> k) & 1) pmask[i] = 1'b1;
        end
    endfunction

    genvar gk, gi;

    // ── Encoder ── parity[k] = XOR(data & mask_k); overall = parity toàn bộ.
    wire [PARITY_WIDTH-1:0] enc_ham;
    generate
        for (gk = 0; gk < PARITY_WIDTH; gk = gk + 1) begin : gen_enc
            assign enc_ham[gk] = ^(pi_enc_data & pmask(gk));
        end
    endgenerate
    assign po_enc_check[PARITY_WIDTH-1:0] = enc_ham;
    assign po_enc_check[PARITY_WIDTH]     = (^pi_enc_data) ^ (^enc_ham);

    // ── Decoder ──
    wire [PARITY_WIDTH-1:0] rec_ham;
    generate
        for (gk = 0; gk < PARITY_WIDTH; gk = gk + 1) begin : gen_dec
            assign rec_ham[gk] = ^(pi_dec_data & pmask(gk));
        end
    endgenerate

    wire [PARITY_WIDTH-1:0] syndrome = pi_dec_check[PARITY_WIDTH-1:0] ^ rec_ham;
    wire                    oc = (^pi_dec_data) ^ (^pi_dec_check);   // 1 = số lỗi lẻ

    // Sửa: data bit i lật nếu single error (oc) và syndrome trùng vị trí dcode(i).
    generate
        for (gi = 0; gi < DATA_WIDTH; gi = gi + 1) begin : gen_fix
            assign po_dec_data[gi] = pi_dec_data[gi] ^
                (oc && ({{(32-PARITY_WIDTH){1'b0}}, syndrome} == dcode(gi)));
        end
    endgenerate

    assign po_corrected    = oc;                                // 1 lỗi (sửa được)
    assign po_double_error = (syndrome != 0) && (oc == 1'b0);   // 2 lỗi: detect-only

endmodule
