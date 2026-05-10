`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module:  accelerator_slave_stream_v2_0_S00_AXIS
// Project: accelerator_2_0
//
// AXI4-Stream slave: DMA → control_unit (weight, bias, input load).
// Spec: hw/accelerator_2_0/hdl/axi_shim_spec.md §3.
//
// Pure passthrough + TREADY gating bằng po_loading.
// Lý do gating: tránh stray TVALID giữa 2 tile khi FSM về IDLE.
//////////////////////////////////////////////////////////////////////////////////

module accelerator_slave_stream_v2_0_S00_AXIS #(
    parameter integer C_S_AXIS_TDATA_WIDTH = 32
)(
    // ── User-side (tới control_unit) ──
    output wire [C_S_AXIS_TDATA_WIDTH-1:0]   po_stream_data,
    output wire                              po_stream_valid,
    input  wire                              pi_stream_ready,
    input  wire                              pi_loading,    // gate signal từ control_unit FSM

    // ── AXI4-Stream slave ──
    input  wire                              S_AXIS_ACLK,
    input  wire                              S_AXIS_ARESETN,
    input  wire                              S_AXIS_TVALID,
    input  wire [C_S_AXIS_TDATA_WIDTH-1:0]   S_AXIS_TDATA,
    input  wire [(C_S_AXIS_TDATA_WIDTH/8)-1:0] S_AXIS_TSTRB,
    input  wire                              S_AXIS_TLAST,
    output wire                              S_AXIS_TREADY
);

    // TREADY chỉ assert khi:
    //   1. control_unit đang ở LOAD state (pi_loading=1).
    //   2. control_unit sẵn sàng nhận (pi_stream_ready=1).
    // Cả 2 điều kiện = AND.
    assign S_AXIS_TREADY = pi_loading & pi_stream_ready;

    // Pass-through data
    assign po_stream_data  = S_AXIS_TDATA;

    // Forward TVALID gated bằng pi_loading để control_unit chỉ thấy
    // valid khi đúng state load.
    assign po_stream_valid = S_AXIS_TVALID & pi_loading;

    // TLAST + TSTRB không dùng (control_unit count word qua TILE_*_SIZE).
    // ARESETN ignore: shim thuần combinational, control_unit có reset riêng.

endmodule
