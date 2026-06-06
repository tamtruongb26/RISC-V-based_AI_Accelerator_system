`timescale 1ns / 1ps

// ===========================================================================
// ecc_secded.v — Hamming SECDED encoder + decoder (Phase 5c, Vấn đề 7c)
//
// Single Error Correct, Double Error Detect. Bảo vệ scratchpad weight bus khỏi
// SEU: encode khi write (data → check bits), decode khi read (sửa 1-bit, phát
// hiện 2-bit). Systematic Hamming + 1 overall parity.
//
//   check = { overall_parity[1], hamming_parity[PARITY_WIDTH] }
//   Tổng codeword = DATA_WIDTH + PARITY_WIDTH + 1 bit.
//   Ràng buộc: 2^PARITY_WIDTH >= DATA_WIDTH + PARITY_WIDTH + 1.
//
// Combinational (encode + decode path). Vị trí codeword 1-indexed; bit ở vị trí
// luỹ thừa 2 là parity, còn lại là data (systematic mapping qua dcode()).
// ===========================================================================
module ecc_secded #(
    parameter integer DATA_WIDTH   = 8,
    parameter integer PARITY_WIDTH = 4    // D=8→4, D=16→5, D=32→6, D=64→7
)(
    // ── Encode: data → check ──
    input  wire [DATA_WIDTH-1:0]     pi_enc_data,
    output reg  [PARITY_WIDTH:0]     po_enc_check,    // [P]=overall, [P-1:0]=hamming

    // ── Decode: (data, check) có thể lỗi → corrected + flags ──
    input  wire [DATA_WIDTH-1:0]     pi_dec_data,
    input  wire [PARITY_WIDTH:0]     pi_dec_check,
    output reg  [DATA_WIDTH-1:0]     po_dec_data,     // đã sửa
    output reg                       po_corrected,    // 1 = single error đã sửa
    output reg                       po_double_error  // 1 = double error (uncorrectable)
);

    // dcode(i) = vị trí codeword (1-indexed) của data bit thứ i = số non-luỹ-thừa-2
    // thứ i (đếm từ 3). Vị trí luỹ thừa 2 dành cho parity.
    function integer dcode(input integer di);
        integer pos, cnt;
        begin
            cnt = -1; dcode = 0;
            for (pos = 1; pos <= (1 << PARITY_WIDTH); pos = pos + 1)
                if ((pos & (pos - 1)) != 0) begin   // pos không phải luỹ thừa 2
                    cnt = cnt + 1;
                    if (cnt == di) dcode = pos;
                end
        end
    endfunction

    integer i, k;

    // ── Encoder ──
    reg [PARITY_WIDTH-1:0] enc_ham;
    always @(*) begin
        enc_ham = {PARITY_WIDTH{1'b0}};
        for (k = 0; k < PARITY_WIDTH; k = k + 1)
            for (i = 0; i < DATA_WIDTH; i = i + 1)
                if ((dcode(i) >> k) & 1)
                    enc_ham[k] = enc_ham[k] ^ pi_enc_data[i];
        // overall parity = XOR mọi bit (data + hamming) → tổng chẵn
        po_enc_check[PARITY_WIDTH-1:0] = enc_ham;
        po_enc_check[PARITY_WIDTH]     = (^pi_enc_data) ^ (^enc_ham);
    end

    // ── Decoder ──
    reg [PARITY_WIDTH-1:0] rec_ham;        // hamming tính lại từ data nhận
    reg [PARITY_WIDTH-1:0] syndrome;
    reg                    oc;             // overall parity check (1 = số lỗi lẻ)
    reg [DATA_WIDTH-1:0]   fixed;
    always @(*) begin
        rec_ham = {PARITY_WIDTH{1'b0}};
        for (k = 0; k < PARITY_WIDTH; k = k + 1)
            for (i = 0; i < DATA_WIDTH; i = i + 1)
                if ((dcode(i) >> k) & 1)
                    rec_ham[k] = rec_ham[k] ^ pi_dec_data[i];

        // syndrome = vị trí lỗi (1-indexed); = hamming nhận XOR hamming tính lại
        syndrome = pi_dec_check[PARITY_WIDTH-1:0] ^ rec_ham;
        // overall: XOR tất cả bit nhận (data + check) — 0 nếu số lỗi chẵn
        oc = (^pi_dec_data) ^ (^pi_dec_check);

        // Sửa: nếu single error (oc=1) và syndrome trùng vị trí 1 data bit → lật.
        fixed = pi_dec_data;
        if (oc)
            for (i = 0; i < DATA_WIDTH; i = i + 1)
                if ({{(32-PARITY_WIDTH){1'b0}}, syndrome} == dcode(i))
                    fixed[i] = ~pi_dec_data[i];

        po_dec_data     = fixed;
        po_corrected    = oc;                              // 1 lỗi (sửa được)
        po_double_error = (syndrome != 0) && (oc == 1'b0); // 2 lỗi: detect-only
    end

endmodule
