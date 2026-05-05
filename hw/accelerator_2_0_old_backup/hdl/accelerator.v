`timescale 1 ns / 1 ps
//////////////////////////////////////////////////////////////////////////////////
// Module:  accelerator — accelerator_2_0 top wrapper (TPU-like systolic 8x8)
// Project: accelerator_2_0
//
// ============================================================================
// REWRITTEN — wires the new systolic-array core (pe.v / data_path.v /
// control_unit.v) into the existing AXI shim files, which are reused unchanged:
//   - accelerator_slave_lite_v2_0_S00_AXI.v   (config + status registers)
//   - accelerator_slave_stream_v2_0_S00_AXIS.v (DMA → accelerator)
//   - accelerator_master_stream_v2_0_M00_AXIS.v (accelerator → DMA)
//
// Address map (S00_AXI, 32-bit registers, 4-byte stride):
//   0x00  TILE_M_SIZE   slv_reg0  R/W
//   0x04  TILE_K_SIZE   slv_reg1  R/W
//   0x08  TILE_N_SIZE   slv_reg2  R/W
//   0x0C  CONTROL       slv_reg3  R/W   bit[0]=START, bit[2:1]=ACT_MODE
//   0x10  STATUS        slv_reg4  R     bit[0]=BUSY,  bit[1]=DONE
//
// Activation modes (CONTROL[2:1]): 00=bypass, 01=ReLU, 10=sigmoid
//////////////////////////////////////////////////////////////////////////////////

module accelerator #
(
    // ── Systolic array geometry ──
    parameter integer SA_N                    = 8,
    parameter integer DATA_WIDTH              = 16,
    parameter integer ACC_WIDTH               = 40,

    // ── AXI parameters ──
    parameter integer C_S00_AXI_DATA_WIDTH    = 32,
    parameter integer C_S00_AXI_ADDR_WIDTH    = 5,
    parameter integer C_S00_AXIS_TDATA_WIDTH  = 32,
    parameter integer C_M00_AXIS_TDATA_WIDTH  = 32,
    parameter integer C_M00_AXIS_START_COUNT  = 32
)
(
    // ── AXI-Lite slave (S00_AXI) — config/status from PicoRV32 ──
    input  wire                                   s00_axi_aclk,
    input  wire                                   s00_axi_aresetn,
    input  wire [C_S00_AXI_ADDR_WIDTH-1 : 0]      s00_axi_awaddr,
    input  wire [2 : 0]                           s00_axi_awprot,
    input  wire                                   s00_axi_awvalid,
    output wire                                   s00_axi_awready,
    input  wire [C_S00_AXI_DATA_WIDTH-1 : 0]      s00_axi_wdata,
    input  wire [(C_S00_AXI_DATA_WIDTH/8)-1 : 0]  s00_axi_wstrb,
    input  wire                                   s00_axi_wvalid,
    output wire                                   s00_axi_wready,
    output wire [1 : 0]                           s00_axi_bresp,
    output wire                                   s00_axi_bvalid,
    input  wire                                   s00_axi_bready,
    input  wire [C_S00_AXI_ADDR_WIDTH-1 : 0]      s00_axi_araddr,
    input  wire [2 : 0]                           s00_axi_arprot,
    input  wire                                   s00_axi_arvalid,
    output wire                                   s00_axi_arready,
    output wire [C_S00_AXI_DATA_WIDTH-1 : 0]      s00_axi_rdata,
    output wire [1 : 0]                           s00_axi_rresp,
    output wire                                   s00_axi_rvalid,
    input  wire                                   s00_axi_rready,

    // ── AXI-Stream slave (S00_AXIS) — DMA MM2S → accelerator ──
    input  wire                                    s00_axis_aclk,
    input  wire                                    s00_axis_aresetn,
    output wire                                    s00_axis_tready,
    input  wire [C_S00_AXIS_TDATA_WIDTH-1 : 0]     s00_axis_tdata,
    input  wire [(C_S00_AXIS_TDATA_WIDTH/8)-1 : 0] s00_axis_tstrb,
    input  wire                                    s00_axis_tlast,
    input  wire                                    s00_axis_tvalid,

    // ── AXI-Stream master (M00_AXIS) — accelerator → DMA S2MM ──
    input  wire                                    m00_axis_aclk,
    input  wire                                    m00_axis_aresetn,
    output wire                                    m00_axis_tvalid,
    output wire [C_M00_AXIS_TDATA_WIDTH-1 : 0]     m00_axis_tdata,
    output wire [(C_M00_AXIS_TDATA_WIDTH/8)-1 : 0] m00_axis_tstrb,
    output wire                                    m00_axis_tlast,
    input  wire                                    m00_axis_tready
);

    // ─────────────────────────────────────────────────────────────────
    // Internal clock/reset (single clock domain assumption)
    // ─────────────────────────────────────────────────────────────────
    wire sys_clk   = s00_axi_aclk;
    wire sys_rst_n = s00_axi_aresetn;

    // ─────────────────────────────────────────────────────────────────
    // AXI-Lite ↔ control_unit
    // ─────────────────────────────────────────────────────────────────
    wire [31:0] w_tile_m_size;
    wire [31:0] w_tile_k_size;
    wire [31:0] w_tile_n_size;
    wire [31:0] w_control;
    wire [31:0] w_status;
    wire        w_busy;
    wire        w_done;

    assign w_status      = {30'd0, w_done, w_busy};
    wire   w_start       = w_control[0];
    wire [1:0] w_act_mode = w_control[2:1];

    // ─────────────────────────────────────────────────────────────────
    // AXI-Stream slave ↔ control_unit
    // ─────────────────────────────────────────────────────────────────
    wire        w_stream_ready;
    wire        w_stream_valid;
    wire [31:0] w_stream_data;

    // ─────────────────────────────────────────────────────────────────
    // AXI-Stream master ↔ control_unit
    // ─────────────────────────────────────────────────────────────────
    wire [9:0]  w_num_out_transfers;
    wire [31:0] w_out_data;
    wire        w_out_write_req;
    wire        w_out_write_done;

    // ─────────────────────────────────────────────────────────────────
    // control_unit ↔ data_path
    // ─────────────────────────────────────────────────────────────────
    wire                          w_dp_weight_load;
    wire [2:0]                    w_dp_weight_row_sel;
    wire [SA_N*DATA_WIDTH-1:0]    w_dp_weight_data;
    wire [SA_N*DATA_WIDTH-1:0]    w_dp_a_left;
    wire [SA_N-1:0]               w_dp_valid_left;
    wire [SA_N*ACC_WIDTH-1:0]     w_dp_psum_bottom;
    wire [SA_N-1:0]               w_dp_valid_bottom;

    // ─────────────────────────────────────────────────────────────────
    // control_unit ↔ post_proc
    // ─────────────────────────────────────────────────────────────────
    wire [ACC_WIDTH-1:0]   w_pp_acc_in;
    wire [DATA_WIDTH-1:0]  w_pp_bias;
    wire                   w_pp_valid_in;
    wire [1:0]             w_pp_act_mode;
    wire [DATA_WIDTH-1:0]  w_pp_data_out;
    wire                   w_pp_valid_out;

    // ═════════════════════════════════════════════════════════════════
    // AXI-Lite slave (config + status registers)
    // ═════════════════════════════════════════════════════════════════
    accelerator_slave_lite_v2_0_S00_AXI #(
        .C_S_AXI_DATA_WIDTH (C_S00_AXI_DATA_WIDTH),
        .C_S_AXI_ADDR_WIDTH (C_S00_AXI_ADDR_WIDTH),
        .SA_N               (SA_N)
    ) axi_lite_inst (
        .S_AXI_ACLK     (s00_axi_aclk),
        .S_AXI_ARESETN  (s00_axi_aresetn),
        .S_AXI_AWADDR   (s00_axi_awaddr),
        .S_AXI_AWPROT   (s00_axi_awprot),
        .S_AXI_AWVALID  (s00_axi_awvalid),
        .S_AXI_AWREADY  (s00_axi_awready),
        .S_AXI_WDATA    (s00_axi_wdata),
        .S_AXI_WSTRB    (s00_axi_wstrb),
        .S_AXI_WVALID   (s00_axi_wvalid),
        .S_AXI_WREADY   (s00_axi_wready),
        .S_AXI_BRESP    (s00_axi_bresp),
        .S_AXI_BVALID   (s00_axi_bvalid),
        .S_AXI_BREADY   (s00_axi_bready),
        .S_AXI_ARADDR   (s00_axi_araddr),
        .S_AXI_ARPROT   (s00_axi_arprot),
        .S_AXI_ARVALID  (s00_axi_arvalid),
        .S_AXI_ARREADY  (s00_axi_arready),
        .S_AXI_RDATA    (s00_axi_rdata),
        .S_AXI_RRESP    (s00_axi_rresp),
        .S_AXI_RVALID   (s00_axi_rvalid),
        .S_AXI_RREADY   (s00_axi_rready),

        .po_tile_m_size (w_tile_m_size),
        .po_tile_k_size (w_tile_k_size),
        .po_tile_n_size (w_tile_n_size),
        .po_control     (w_control),
        .pi_status      (w_status),
        .pi_wren_status (1'b1)              // status always observable
    );

    // ═════════════════════════════════════════════════════════════════
    // AXI-Stream slave (DMA → accelerator)
    // ═════════════════════════════════════════════════════════════════
    accelerator_slave_stream_v2_0_S00_AXIS #(
        .C_S_AXIS_TDATA_WIDTH (C_S00_AXIS_TDATA_WIDTH)
    ) axi_stream_slave_inst (
        .S_AXIS_ACLK     (s00_axis_aclk),
        .S_AXIS_ARESETN  (s00_axis_aresetn),
        .S_AXIS_TREADY   (s00_axis_tready),
        .S_AXIS_TDATA    (s00_axis_tdata),
        .S_AXIS_TSTRB    (s00_axis_tstrb),
        .S_AXIS_TLAST    (s00_axis_tlast),
        .S_AXIS_TVALID   (s00_axis_tvalid),

        .pi_data_read       (w_stream_ready),
        .po_mlp_data_valid  (w_stream_valid),
        .po_mlp_data        (w_stream_data)
    );

    // ═════════════════════════════════════════════════════════════════
    // AXI-Stream master (accelerator → DMA)
    // ═════════════════════════════════════════════════════════════════
    accelerator_master_stream_v2_0_M00_AXIS #(
        .C_M_AXIS_TDATA_WIDTH (C_M00_AXIS_TDATA_WIDTH),
        .C_M_START_COUNT      (C_M00_AXIS_START_COUNT)
    ) axi_stream_master_inst (
        .M_AXIS_ACLK     (m00_axis_aclk),
        .M_AXIS_ARESETN  (m00_axis_aresetn),
        .M_AXIS_TVALID   (m00_axis_tvalid),
        .M_AXIS_TDATA    (m00_axis_tdata),
        .M_AXIS_TSTRB    (m00_axis_tstrb),
        .M_AXIS_TLAST    (m00_axis_tlast),
        .M_AXIS_TREADY   (m00_axis_tready),

        .pi_num_transfers (w_num_out_transfers),
        .pi_mlp_data      (w_out_data),
        .pi_write_req     (w_out_write_req),
        .po_write_done    (w_out_write_done)
    );

    // ═════════════════════════════════════════════════════════════════
    // Control Unit (FSM)
    // ═════════════════════════════════════════════════════════════════
    control_unit #(
        .SA_N       (SA_N),
        .DATA_WIDTH (DATA_WIDTH),
        .ACC_WIDTH  (ACC_WIDTH)
    ) ctrl_inst (
        .pi_clk            (sys_clk),
        .pi_rst_n          (sys_rst_n),

        // AXI-Lite cfg
        .pi_tile_m_size    (w_tile_m_size[9:0]),
        .pi_tile_k_size    (w_tile_k_size[9:0]),
        .pi_tile_n_size    (w_tile_n_size[9:0]),
        .pi_act_mode       (w_act_mode),
        .pi_start          (w_start),
        .po_busy           (w_busy),
        .po_done           (w_done),

        // AXI-Stream slave
        .pi_stream_data    (w_stream_data),
        .pi_stream_valid   (w_stream_valid),
        .po_stream_ready   (w_stream_ready),

        // AXI-Stream master
        .po_num_out_transfers (w_num_out_transfers),
        .po_out_data          (w_out_data),
        .po_out_write_req     (w_out_write_req),
        .pi_out_write_done    (w_out_write_done),

        // Datapath: weight
        .po_dp_weight_load    (w_dp_weight_load),
        .po_dp_weight_row_sel (w_dp_weight_row_sel),
        .po_dp_weight_data    (w_dp_weight_data),

        // Datapath: left edge activation
        .po_dp_a_left         (w_dp_a_left),
        .po_dp_valid_left     (w_dp_valid_left),

        // Datapath: bottom edge psum
        .pi_dp_psum_bottom    (w_dp_psum_bottom),
        .pi_dp_valid_bottom   (w_dp_valid_bottom),

        // Post-proc
        .po_pp_acc_in         (w_pp_acc_in),
        .po_pp_bias           (w_pp_bias),
        .po_pp_valid_in       (w_pp_valid_in),
        .po_pp_act_mode       (w_pp_act_mode),
        .pi_pp_data_out       (w_pp_data_out),
        .pi_pp_valid_out      (w_pp_valid_out)
    );

    // ═════════════════════════════════════════════════════════════════
    // Datapath — 8x8 systolic array
    // ═════════════════════════════════════════════════════════════════
    data_path #(
        .SA_N       (SA_N),
        .DATA_WIDTH (DATA_WIDTH),
        .ACC_WIDTH  (ACC_WIDTH)
    ) dp_inst (
        .pi_clk             (sys_clk),
        .pi_rst_n           (sys_rst_n),

        // Weight loading
        .pi_weight_load     (w_dp_weight_load),
        .pi_weight_row_sel  (w_dp_weight_row_sel),
        .pi_weight_data     (w_dp_weight_data),

        // Left-edge activation feed (already skewed)
        .pi_a_left          (w_dp_a_left),
        .pi_valid_left      (w_dp_valid_left),

        // Bottom-edge psum results
        .po_psum_bottom     (w_dp_psum_bottom),
        .po_valid_bottom    (w_dp_valid_bottom)
    );

    // ═════════════════════════════════════════════════════════════════
    // Post-Processing (bias + activation + saturate)
    // ═════════════════════════════════════════════════════════════════
    post_proc #(
        .DATA_WIDTH (DATA_WIDTH),
        .ACC_WIDTH  (ACC_WIDTH)
    ) pp_inst (
        .pi_clk        (sys_clk),
        .pi_rst_n      (sys_rst_n),

        .pi_acc_in     (w_pp_acc_in),
        .pi_bias       (w_pp_bias),
        .pi_valid_in   (w_pp_valid_in),
        .pi_act_mode   (w_pp_act_mode),

        .po_data_out   (w_pp_data_out),
        .po_valid_out  (w_pp_valid_out)
    );

endmodule
