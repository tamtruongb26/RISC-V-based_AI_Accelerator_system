`timescale 1ns / 1ps

module accelerator #(
    parameter integer SA_N                 = 8,
    parameter integer DATA_WIDTH           = 16,
    parameter integer ACC_WIDTH            = 40,
    parameter integer C_S00_AXI_DATA_WIDTH = 32,
    parameter integer C_S00_AXI_ADDR_WIDTH = 5,
    parameter integer C_S00_AXIS_TDATA_WIDTH = 32,
    parameter integer C_M00_AXIS_TDATA_WIDTH = 32
)(
    // ═══════════════════════════════════════════════════════════
    // AXI4-Lite slave (config registers)
    // ═══════════════════════════════════════════════════════════
    input  wire                                  s00_axi_aclk,
    input  wire                                  s00_axi_aresetn,
    input  wire [C_S00_AXI_ADDR_WIDTH-1:0]       s00_axi_awaddr,
    input  wire [2:0]                            s00_axi_awprot,
    input  wire                                  s00_axi_awvalid,
    output wire                                  s00_axi_awready,
    input  wire [C_S00_AXI_DATA_WIDTH-1:0]       s00_axi_wdata,
    input  wire [(C_S00_AXI_DATA_WIDTH/8)-1:0]   s00_axi_wstrb,
    input  wire                                  s00_axi_wvalid,
    output wire                                  s00_axi_wready,
    output wire [1:0]                            s00_axi_bresp,
    output wire                                  s00_axi_bvalid,
    input  wire                                  s00_axi_bready,
    input  wire [C_S00_AXI_ADDR_WIDTH-1:0]       s00_axi_araddr,
    input  wire [2:0]                            s00_axi_arprot,
    input  wire                                  s00_axi_arvalid,
    output wire                                  s00_axi_arready,
    output wire [C_S00_AXI_DATA_WIDTH-1:0]       s00_axi_rdata,
    output wire [1:0]                            s00_axi_rresp,
    output wire                                  s00_axi_rvalid,
    input  wire                                  s00_axi_rready,

    // ═══════════════════════════════════════════════════════════
    // AXI4-Stream slave (DMA → accelerator)
    // ═══════════════════════════════════════════════════════════
    input  wire                                  s00_axis_aclk,
    input  wire                                  s00_axis_aresetn,
    input  wire                                  s00_axis_tvalid,
    input  wire [C_S00_AXIS_TDATA_WIDTH-1:0]     s00_axis_tdata,
    input  wire [(C_S00_AXIS_TDATA_WIDTH/8)-1:0] s00_axis_tstrb,
    input  wire                                  s00_axis_tlast,
    output wire                                  s00_axis_tready,

    // ═══════════════════════════════════════════════════════════
    // AXI4-Stream master (accelerator → DMA)
    // ═══════════════════════════════════════════════════════════
    input  wire                                  m00_axis_aclk,
    input  wire                                  m00_axis_aresetn,
    output wire                                  m00_axis_tvalid,
    output wire [C_M00_AXIS_TDATA_WIDTH-1:0]     m00_axis_tdata,
    output wire [(C_M00_AXIS_TDATA_WIDTH/8)-1:0] m00_axis_tstrb,
    output wire                                  m00_axis_tlast,
    input  wire                                  m00_axis_tready
);

    // ═══════════════════════════════════════════════════════════
    // Internal wires (shim ↔ control_unit ↔ data_path ↔ post_proc)
    // ═══════════════════════════════════════════════════════════

    // ── AXI-Lite shim → control_unit config (Phase 0: packed → unpack) ──
    wire [3:0] tile_m_4, tile_k_4, tile_n_4;
    wire [9:0] tile_m_size = {6'd0, tile_m_4};
    wire [9:0] tile_k_size = {6'd0, tile_k_4};
    wire [9:0] tile_n_size = {6'd0, tile_n_4};
    wire [1:0] act_mode;
    wire       start;
    wire       busy, done;
    // ── Phase 1a-i: HW K-accumulation control ──
    wire       acc_accum;
    wire       post_skip;
    // ── Phase 1a-ii: data reuse control ──
    wire       skip_w_load;

    // ── Phase 0 instrumentation: counter control + readback ──
    wire        cnt_clear;
    wire [3:0]  cnt_sel;
    wire [31:0] cnt_idle, cnt_load_w, cnt_load_b, cnt_load_in;
    wire [31:0] cnt_compute, cnt_post_proc, cnt_send, cnt_done;
    wire [31:0] cnt_total, cnt_pe_active;
    reg  [31:0] cnt_val_mux;

    // 10-to-1 counter mux - chọn counter dựa vào cnt_sel.
    // Index map khớp với mô tả trong slave_lite.
    always @(*) begin
        case (cnt_sel)
            4'd0:  cnt_val_mux = cnt_idle;
            4'd1:  cnt_val_mux = cnt_load_w;
            4'd2:  cnt_val_mux = cnt_load_b;
            4'd3:  cnt_val_mux = cnt_load_in;
            4'd4:  cnt_val_mux = cnt_compute;
            4'd5:  cnt_val_mux = cnt_post_proc;
            4'd6:  cnt_val_mux = cnt_send;
            4'd7:  cnt_val_mux = cnt_done;
            4'd8:  cnt_val_mux = cnt_total;
            4'd9:  cnt_val_mux = cnt_pe_active;
            default: cnt_val_mux = 32'd0;
        endcase
    end

    // ── AXIS slave shim → control_unit ──
    wire [31:0] stream_data;
    wire        stream_valid;
    wire        stream_ready;
    wire        loading;

    // ── control_unit → AXIS master shim ──
    wire [31:0] out_data;
    wire        out_write_req;
    wire        out_write_done;
    wire [9:0]  num_out_transfers;

    // ── control_unit ↔ data_path ──
    wire                          dp_weight_load;
    wire [2:0]                    dp_weight_row_sel;
    wire [SA_N*DATA_WIDTH-1:0]    dp_weight_data;
    wire [SA_N*DATA_WIDTH-1:0]    dp_a_left;
    wire [SA_N-1:0]               dp_valid_left;
    wire [SA_N*ACC_WIDTH-1:0]     dp_psum_bottom;
    wire [SA_N-1:0]               dp_valid_bottom;

    // ── control_unit ↔ post_proc ──
    wire [ACC_WIDTH-1:0]          pp_acc_in;
    wire [DATA_WIDTH-1:0]         pp_bias;
    wire                          pp_valid_in;
    wire [1:0]                    pp_act_mode;
    wire [DATA_WIDTH-1:0]         pp_data_out;
    wire                          pp_valid_out;

    // ═══════════════════════════════════════════════════════════
    // AXI-Lite slave shim
    // ═══════════════════════════════════════════════════════════
    accelerator_slave_lite_v2_0_S00_AXI #(
        .C_S_AXI_DATA_WIDTH (C_S00_AXI_DATA_WIDTH),
        .C_S_AXI_ADDR_WIDTH (C_S00_AXI_ADDR_WIDTH)
    ) u_axi_lite (
        .po_tile_m_size  (tile_m_4),
        .po_tile_k_size  (tile_k_4),
        .po_tile_n_size  (tile_n_4),
        .po_start        (start),
        .po_act_mode     (act_mode),
        .po_acc_accum    (acc_accum),
        .po_post_skip    (post_skip),
        .po_skip_w_load  (skip_w_load),
        .po_cnt_clear    (cnt_clear),
        .po_cnt_sel      (cnt_sel),
        .pi_busy         (busy),
        .pi_done         (done),
        .pi_cnt_val      (cnt_val_mux),
        .S_AXI_ACLK      (s00_axi_aclk),
        .S_AXI_ARESETN   (s00_axi_aresetn),
        .S_AXI_AWADDR    (s00_axi_awaddr),
        .S_AXI_AWPROT    (s00_axi_awprot),
        .S_AXI_AWVALID   (s00_axi_awvalid),
        .S_AXI_AWREADY   (s00_axi_awready),
        .S_AXI_WDATA     (s00_axi_wdata),
        .S_AXI_WSTRB     (s00_axi_wstrb),
        .S_AXI_WVALID    (s00_axi_wvalid),
        .S_AXI_WREADY    (s00_axi_wready),
        .S_AXI_BRESP     (s00_axi_bresp),
        .S_AXI_BVALID    (s00_axi_bvalid),
        .S_AXI_BREADY    (s00_axi_bready),
        .S_AXI_ARADDR    (s00_axi_araddr),
        .S_AXI_ARPROT    (s00_axi_arprot),
        .S_AXI_ARVALID   (s00_axi_arvalid),
        .S_AXI_ARREADY   (s00_axi_arready),
        .S_AXI_RDATA     (s00_axi_rdata),
        .S_AXI_RRESP     (s00_axi_rresp),
        .S_AXI_RVALID    (s00_axi_rvalid),
        .S_AXI_RREADY    (s00_axi_rready)
    );

    // ═══════════════════════════════════════════════════════════
    // AXIS slave shim (data load: weight, bias, input)
    // ═══════════════════════════════════════════════════════════
    accelerator_slave_stream_v2_0_S00_AXIS #(
        .C_S_AXIS_TDATA_WIDTH (C_S00_AXIS_TDATA_WIDTH)
    ) u_axis_slave (
        .po_stream_data   (stream_data),
        .po_stream_valid  (stream_valid),
        .pi_stream_ready  (stream_ready),
        .pi_loading       (loading),
        .S_AXIS_ACLK      (s00_axis_aclk),
        .S_AXIS_ARESETN   (s00_axis_aresetn),
        .S_AXIS_TVALID    (s00_axis_tvalid),
        .S_AXIS_TDATA     (s00_axis_tdata),
        .S_AXIS_TSTRB     (s00_axis_tstrb),
        .S_AXIS_TLAST     (s00_axis_tlast),
        .S_AXIS_TREADY    (s00_axis_tready)
    );

    // ═══════════════════════════════════════════════════════════
    // AXIS master shim (output data send)
    // ═══════════════════════════════════════════════════════════
    accelerator_master_stream_v2_0_M00_AXIS #(
        .C_M_AXIS_TDATA_WIDTH (C_M00_AXIS_TDATA_WIDTH)
    ) u_axis_master (
        .pi_data            (out_data),
        .pi_write_req       (out_write_req),
        .pi_num_transfers   (num_out_transfers),
        .po_write_done      (out_write_done),
        .M_AXIS_ACLK        (m00_axis_aclk),
        .M_AXIS_ARESETN     (m00_axis_aresetn),
        .M_AXIS_TVALID      (m00_axis_tvalid),
        .M_AXIS_TDATA       (m00_axis_tdata),
        .M_AXIS_TSTRB       (m00_axis_tstrb),
        .M_AXIS_TLAST       (m00_axis_tlast),
        .M_AXIS_TREADY      (m00_axis_tready)
    );

    // ═══════════════════════════════════════════════════════════
    // Control unit (FSM)
    // ═══════════════════════════════════════════════════════════
    control_unit #(
        .SA_N       (SA_N),
        .DATA_WIDTH (DATA_WIDTH),
        .ACC_WIDTH  (ACC_WIDTH)
    ) u_ctrl (
        .pi_clk               (s00_axi_aclk),
        .pi_rst_n             (s00_axi_aresetn),
        .pi_tile_m_size       (tile_m_size),
        .pi_tile_k_size       (tile_k_size),
        .pi_tile_n_size       (tile_n_size),
        .pi_act_mode          (act_mode),
        .pi_start             (start),
        .pi_acc_accum         (acc_accum),
        .pi_post_skip         (post_skip),
        .pi_skip_w_load       (skip_w_load),
        .po_busy              (busy),
        .po_done              (done),
        .pi_stream_data       (stream_data),
        .pi_stream_valid      (stream_valid),
        .po_stream_ready      (stream_ready),
        .po_loading           (loading),
        .po_num_out_transfers (num_out_transfers),
        .po_out_data          (out_data),
        .po_out_write_req     (out_write_req),
        .pi_out_write_done    (out_write_done),
        .po_dp_weight_load    (dp_weight_load),
        .po_dp_weight_row_sel (dp_weight_row_sel),
        .po_dp_weight_data    (dp_weight_data),
        .po_dp_a_left         (dp_a_left),
        .po_dp_valid_left     (dp_valid_left),
        .pi_dp_psum_bottom    (dp_psum_bottom),
        .pi_dp_valid_bottom   (dp_valid_bottom),
        .po_pp_acc_in         (pp_acc_in),
        .po_pp_bias           (pp_bias),
        .po_pp_valid_in       (pp_valid_in),
        .po_pp_act_mode       (pp_act_mode),
        .pi_pp_data_out       (pp_data_out),
        .pi_pp_valid_out      (pp_valid_out),
        // Phase 0 instrumentation
        .pi_cnt_clear         (cnt_clear),
        .po_cnt_idle          (cnt_idle),
        .po_cnt_load_w        (cnt_load_w),
        .po_cnt_load_b        (cnt_load_b),
        .po_cnt_load_in       (cnt_load_in),
        .po_cnt_compute       (cnt_compute),
        .po_cnt_post_proc     (cnt_post_proc),
        .po_cnt_send          (cnt_send),
        .po_cnt_done          (cnt_done),
        .po_cnt_total         (cnt_total)
    );

    // ═══════════════════════════════════════════════════════════
    // Data path (8x8 systolic)
    // ═══════════════════════════════════════════════════════════
    data_path #(
        .SA_N       (SA_N),
        .DATA_WIDTH (DATA_WIDTH),
        .ACC_WIDTH  (ACC_WIDTH)
    ) u_dp (
        .pi_clk             (s00_axi_aclk),
        .pi_rst_n           (s00_axi_aresetn),
        .pi_weight_load     (dp_weight_load),
        .pi_weight_row_sel  (dp_weight_row_sel),
        .pi_weight_data     (dp_weight_data),
        .pi_a_left          (dp_a_left),
        .pi_valid_left      (dp_valid_left),
        .po_psum_bottom     (dp_psum_bottom),
        .po_valid_bottom    (dp_valid_bottom),
        // Phase 0 instrumentation
        .pi_cnt_clear       (cnt_clear),
        .po_cnt_pe_active   (cnt_pe_active)
    );

    // ═══════════════════════════════════════════════════════════
    // Post-processing (bias + activation + saturate)
    //   Module này instance sigmoid_lookup bên trong.
    // ═══════════════════════════════════════════════════════════
    post_proc u_pp (
        .pi_clk        (s00_axi_aclk),
        .pi_rst_n      (s00_axi_aresetn),
        .pi_acc_in     (pp_acc_in),
        .pi_bias       (pp_bias),
        .pi_valid_in   (pp_valid_in),
        .pi_act_mode   (pp_act_mode),
        .po_data_out   (pp_data_out),
        .po_valid_out  (pp_valid_out)
    );

endmodule
