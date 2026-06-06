`timescale 1ns / 1ps

// ===========================================================================
// fault_injector.v — SEU fault injection point (Phase 5a, trụ Reliability)
//
// Một điểm tiêm lỗi: XOR 1 bit của data tại 1 cycle định trước → mô phỏng
// Single Event Upset (bit flip). Đặt TRƯỚC 1 register → register latch giá trị
// lỗi và giữ → mô phỏng upset bền (stored-bit). Đặt trên wire → transient 1 cycle.
//
// Điều khiển (AXI-Lite map ở integration):
//   pi_fi_enable        : bật injection (đồng thời cho phép counter chạy)
//   pi_fi_clear         : reset counter + injected flag (gọi trước mỗi inference)
//   pi_fi_bit_pos       : vị trí bit cần lật (0..DATA_WIDTH-1)
//   pi_fi_trigger_cycle : cycle (kể từ clear) sẽ lật bit
//
// Mỗi target (weight reg / psum / FSM state / scratchpad) đặt 1 injector riêng;
// FI_TARGET ở integration chọn injector nào enable. Module này = 1 điểm tiêm.
//
// Methodology: sweep (target, bit, trigger_cycle) qua tools/fault_sweep.py →
// đường resilience curve (accuracy vs fault rate). Đây là đóng góp định lượng
// chính của trụ Reliability.
// ===========================================================================
module fault_injector #(
    parameter integer DATA_WIDTH = 40,
    parameter integer BITSEL_W   = (DATA_WIDTH <= 1) ? 1 : $clog2(DATA_WIDTH)
)(
    input  wire                    pi_clk,
    input  wire                    pi_rst_n,

    // ── Control ──
    input  wire                    pi_fi_enable,
    input  wire                    pi_fi_clear,
    input  wire [BITSEL_W-1:0]     pi_fi_bit_pos,
    input  wire [31:0]             pi_fi_trigger_cycle,

    // ── Data path: data_in → (có thể lật 1 bit) → data_out ──
    input  wire [DATA_WIDTH-1:0]   pi_data_in,
    output wire [DATA_WIDTH-1:0]   po_data_out,

    // ── Status ──
    output reg                     po_fi_injected   // sticky: 1 sau khi đã tiêm
);

    // Cycle counter — chỉ chạy khi enable (đếm từ lúc clear).
    reg [31:0] cyc;
    always @(posedge pi_clk or negedge pi_rst_n) begin
        if (!pi_rst_n)         cyc <= 32'd0;
        else if (pi_fi_clear)  cyc <= 32'd0;
        else if (pi_fi_enable) cyc <= cyc + 32'd1;
    end

    // Trigger: enable + đúng cycle.
    wire trigger = pi_fi_enable && (cyc == pi_fi_trigger_cycle);

    // Mask 1-bit tại bit_pos.
    wire [DATA_WIDTH-1:0] mask =
        ({{(DATA_WIDTH-1){1'b0}}, 1'b1} << pi_fi_bit_pos);

    // Lật bit khi trigger; còn lại pass-through.
    assign po_data_out = trigger ? (pi_data_in ^ mask) : pi_data_in;

    // Sticky injected flag (cho readback / counter ở integration).
    always @(posedge pi_clk or negedge pi_rst_n) begin
        if (!pi_rst_n)         po_fi_injected <= 1'b0;
        else if (pi_fi_clear)  po_fi_injected <= 1'b0;
        else if (trigger)      po_fi_injected <= 1'b1;
    end

endmodule
