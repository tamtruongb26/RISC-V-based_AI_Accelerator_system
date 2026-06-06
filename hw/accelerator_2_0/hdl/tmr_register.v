`timescale 1ns / 1ps

// ===========================================================================
// tmr_register.v — TMR-hardened register + fault injection (Phase 5 integration)
//
// Kết hợp 3 primitive reliability thành 1 khối dùng được: register quan trọng
// (vd FSM state) được triple hóa + voter + fault injector (để characterize).
//
//   3 copy ra/rb/rc load giống nhau. fault_injector lật 1 bit của copy được chọn
//   (mô phỏng SEU) → voter outvote → po_q vẫn đúng (chịu được 1 lỗi). mismatch
//   counter đếm số lần lệch (đo SEU rate).
//
// Đây là building block cho TMR FSM state. fault_injector embedded cho phép
// sweep (copy, bit, cycle) → resilience curve.
// ===========================================================================
module tmr_register #(
    parameter integer WIDTH    = 4,
    parameter integer BITSEL_W = (WIDTH <= 1) ? 1 : $clog2(WIDTH)
)(
    input  wire                 pi_clk,
    input  wire                 pi_rst_n,

    // ── Register ──
    input  wire                 pi_en,
    input  wire [WIDTH-1:0]     pi_d,
    output wire [WIDTH-1:0]     po_q,          // voted output (dùng cái này)

    // ── Fault injection (characterization) ──
    input  wire                 pi_fi_enable,
    input  wire                 pi_fi_clear,
    input  wire [BITSEL_W-1:0]  pi_fi_bit_pos,
    input  wire [31:0]          pi_fi_trigger_cycle,
    input  wire [1:0]           pi_fi_copy_sel, // 0=a, 1=b, 2=c

    // ── Status ──
    output wire                 po_mismatch,
    output reg  [31:0]          po_mismatch_cnt
);

    // 3 copy load giống nhau.
    reg [WIDTH-1:0] ra, rb, rc;
    always @(posedge pi_clk or negedge pi_rst_n) begin
        if (!pi_rst_n) begin
            ra <= {WIDTH{1'b0}}; rb <= {WIDTH{1'b0}}; rc <= {WIDTH{1'b0}};
        end else if (pi_en) begin
            ra <= pi_d; rb <= pi_d; rc <= pi_d;
        end
    end

    // fault injector trên đường mỗi copy → voter (chỉ copy được chọn enable).
    wire [WIDTH-1:0] fa, fb, fc;

    fault_injector #(.DATA_WIDTH(WIDTH)) fi_a (
        .pi_clk(pi_clk), .pi_rst_n(pi_rst_n),
        .pi_fi_enable(pi_fi_enable && pi_fi_copy_sel == 2'd0),
        .pi_fi_clear(pi_fi_clear), .pi_fi_bit_pos(pi_fi_bit_pos),
        .pi_fi_trigger_cycle(pi_fi_trigger_cycle),
        .pi_data_in(ra), .po_data_out(fa), .po_fi_injected()
    );
    fault_injector #(.DATA_WIDTH(WIDTH)) fi_b (
        .pi_clk(pi_clk), .pi_rst_n(pi_rst_n),
        .pi_fi_enable(pi_fi_enable && pi_fi_copy_sel == 2'd1),
        .pi_fi_clear(pi_fi_clear), .pi_fi_bit_pos(pi_fi_bit_pos),
        .pi_fi_trigger_cycle(pi_fi_trigger_cycle),
        .pi_data_in(rb), .po_data_out(fb), .po_fi_injected()
    );
    fault_injector #(.DATA_WIDTH(WIDTH)) fi_c (
        .pi_clk(pi_clk), .pi_rst_n(pi_rst_n),
        .pi_fi_enable(pi_fi_enable && pi_fi_copy_sel == 2'd2),
        .pi_fi_clear(pi_fi_clear), .pi_fi_bit_pos(pi_fi_bit_pos),
        .pi_fi_trigger_cycle(pi_fi_trigger_cycle),
        .pi_data_in(rc), .po_data_out(fc), .po_fi_injected()
    );

    // Voter: majority của 3 copy (đã có thể bị tiêm lỗi).
    tmr_voter #(.WIDTH(WIDTH)) u_voter (
        .pi_a(fa), .pi_b(fb), .pi_c(fc),
        .po_voted(po_q), .po_mismatch(po_mismatch)
    );

    // Mismatch counter (đo số lần lệch = số SEU bị mask).
    always @(posedge pi_clk or negedge pi_rst_n) begin
        if (!pi_rst_n)        po_mismatch_cnt <= 32'd0;
        else if (pi_fi_clear) po_mismatch_cnt <= 32'd0;
        else if (po_mismatch) po_mismatch_cnt <= po_mismatch_cnt + 32'd1;
    end

endmodule
