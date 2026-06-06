`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module:  accelerator_master_stream_v2_0_M00_AXIS
// Project: accelerator_2_0
//
// AXI4-Stream master: control_unit → DMA (kết quả output).
// Spec: hw/accelerator_2_0/hdl/axi_shim_spec.md §4.
//
// TLAST=1 ở word cuối (= po_num_out_transfers - 1).
// po_write_done = pulse khi handshake (TVALID & TREADY).
//////////////////////////////////////////////////////////////////////////////////

module accelerator_master_stream_v2_0_M00_AXIS #(
    parameter integer C_M_AXIS_TDATA_WIDTH = 32
)(
    // ── User-side (từ control_unit) ──
    input  wire [C_M_AXIS_TDATA_WIDTH-1:0]   pi_data,
    input  wire                              pi_write_req,
    input  wire [15:0]                       pi_num_transfers,
    output wire                              po_write_done,

    // ── AXI4-Stream master ──
    input  wire                              M_AXIS_ACLK,
    input  wire                              M_AXIS_ARESETN,
    output wire                              M_AXIS_TVALID,
    output wire [C_M_AXIS_TDATA_WIDTH-1:0]   M_AXIS_TDATA,
    output wire [(C_M_AXIS_TDATA_WIDTH/8)-1:0] M_AXIS_TSTRB,
    output wire                              M_AXIS_TLAST,
    input  wire                              M_AXIS_TREADY
);

    // ─────────────────────────────────────────────────────────
    // Transfer counter (đếm số word đã handshake)
    // ─────────────────────────────────────────────────────────
    reg [15:0] tx_count;
    wire      handshake = M_AXIS_TVALID & M_AXIS_TREADY;
    wire      is_last   = (tx_count == pi_num_transfers - 16'd1) & handshake;

    always @(posedge M_AXIS_ACLK) begin
        if (!M_AXIS_ARESETN) begin
            tx_count <= 16'd0;
        end else if (handshake) begin
            if (tx_count == pi_num_transfers - 16'd1)
                tx_count <= 16'd0;            // wrap về 0 cho tile kế
            else
                tx_count <= tx_count + 16'd1;
        end
    end

    // ─────────────────────────────────────────────────────────
    // Output assignments
    // ─────────────────────────────────────────────────────────
    assign M_AXIS_TVALID = pi_write_req;
    assign M_AXIS_TDATA  = pi_data;
    assign M_AXIS_TSTRB  = {(C_M_AXIS_TDATA_WIDTH/8){1'b1}};   // all bytes valid
    assign M_AXIS_TLAST  = (tx_count == pi_num_transfers - 16'd1) & M_AXIS_TVALID;

    // Báo control_unit đã gửi xong 1 word (advance counter)
    assign po_write_done = handshake;

endmodule
