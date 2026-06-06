`timescale 1ns / 1ps

// ===========================================================================
// ecc_scratchpad.v — Memory được ECC SECDED bảo vệ (Phase 5c integration)
//
// Ghép ecc_secded + memory: write → encode (lưu data + check), read → decode
// (sửa 1-bit, phát hiện 2-bit). Bảo vệ scratchpad/weight bus khỏi SEU.
// fault_injector trên codeword đọc ra (characterization) → mô phỏng bit upset
// trong ô nhớ. Counter đếm corrected / uncorrectable.
//
//   Mỗi ô nhớ lưu CW = DATA_WIDTH + PARITY_WIDTH + 1 bit (data + check).
//   Read 1-cycle latency (registered). corrected/double valid cùng rd_data.
// ===========================================================================
module ecc_scratchpad #(
    parameter integer DATA_WIDTH   = 16,
    parameter integer DEPTH        = 512,
    parameter integer PARITY_WIDTH = 5,                       // D=16 → P=5
    parameter integer ADDR_WIDTH   = (DEPTH <= 1) ? 1 : $clog2(DEPTH),
    parameter integer CW_WIDTH     = DATA_WIDTH + PARITY_WIDTH + 1,
    parameter integer CWSEL_W      = $clog2(CW_WIDTH)
)(
    input  wire                    pi_clk,
    input  wire                    pi_rst_n,

    // ── Write (encode) ──
    input  wire                    pi_wr_en,
    input  wire [ADDR_WIDTH-1:0]   pi_wr_addr,
    input  wire [DATA_WIDTH-1:0]   pi_wr_data,

    // ── Read (decode + correct), 1-cycle latency ──
    input  wire                    pi_rd_en,
    input  wire [ADDR_WIDTH-1:0]   pi_rd_addr,
    output wire [DATA_WIDTH-1:0]   po_rd_data,       // đã sửa
    output wire                    po_corrected,
    output wire                    po_double_error,

    // ── Fault injection trên codeword đọc (characterization) ──
    input  wire                    pi_fi_enable,
    input  wire                    pi_fi_clear,
    input  wire [CWSEL_W-1:0]      pi_fi_bit_pos,
    input  wire [31:0]             pi_fi_trigger_cycle,

    // ── Counters ──
    output reg  [31:0]             po_corrected_cnt,
    output reg  [31:0]             po_uncorrectable_cnt
);

    // Encode write data → check.
    wire [PARITY_WIDTH:0] enc_check;
    ecc_secded #(.DATA_WIDTH(DATA_WIDTH), .PARITY_WIDTH(PARITY_WIDTH)) u_enc (
        .pi_enc_data(pi_wr_data), .po_enc_check(enc_check),
        .pi_dec_data({DATA_WIDTH{1'b0}}), .pi_dec_check({(PARITY_WIDTH+1){1'b0}}),
        .po_dec_data(), .po_corrected(), .po_double_error()
    );

    // Memory lưu codeword {check, data}.
    reg [CW_WIDTH-1:0] mem [0:DEPTH-1];
    always @(posedge pi_clk)
        if (pi_wr_en)
            mem[pi_wr_addr] <= {enc_check, pi_wr_data};

    // Read registered (1-cycle).
    reg [CW_WIDTH-1:0] cw_rd;
    reg                rd_valid;
    always @(posedge pi_clk) begin
        rd_valid <= pi_rd_en;
        if (pi_rd_en) cw_rd <= mem[pi_rd_addr];
    end

    // Fault injection trên codeword đọc (mô phỏng bit upset trong ô nhớ).
    wire [CW_WIDTH-1:0] cw_faulted;
    fault_injector #(.DATA_WIDTH(CW_WIDTH)) u_fi (
        .pi_clk(pi_clk), .pi_rst_n(pi_rst_n),
        .pi_fi_enable(pi_fi_enable), .pi_fi_clear(pi_fi_clear),
        .pi_fi_bit_pos(pi_fi_bit_pos), .pi_fi_trigger_cycle(pi_fi_trigger_cycle),
        .pi_data_in(cw_rd), .po_data_out(cw_faulted), .po_fi_injected()
    );

    // Decode → sửa.
    ecc_secded #(.DATA_WIDTH(DATA_WIDTH), .PARITY_WIDTH(PARITY_WIDTH)) u_dec (
        .pi_enc_data({DATA_WIDTH{1'b0}}), .po_enc_check(),
        .pi_dec_data (cw_faulted[DATA_WIDTH-1:0]),
        .pi_dec_check(cw_faulted[CW_WIDTH-1:DATA_WIDTH]),
        .po_dec_data (po_rd_data),
        .po_corrected(po_corrected), .po_double_error(po_double_error)
    );

    // Counters (đếm khi có read hợp lệ).
    always @(posedge pi_clk or negedge pi_rst_n) begin
        if (!pi_rst_n) begin
            po_corrected_cnt     <= 32'd0;
            po_uncorrectable_cnt <= 32'd0;
        end else if (pi_fi_clear) begin
            po_corrected_cnt     <= 32'd0;
            po_uncorrectable_cnt <= 32'd0;
        end else if (rd_valid) begin
            if (po_double_error) po_uncorrectable_cnt <= po_uncorrectable_cnt + 32'd1;
            else if (po_corrected) po_corrected_cnt   <= po_corrected_cnt   + 32'd1;
        end
    end

endmodule
