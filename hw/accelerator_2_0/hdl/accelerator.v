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
    input  wire                                  m00_axis_tready,

    // ═══════════════════════════════════════════════════════════
    // Phase 2c: AXI4-Lite MASTER tới DMA S_AXI_LITE (autonomy)
    //   accelerator tự lập trình DMA. BD: nối qua interconnect tới DMA control.
    //   Clock RIÊNG m_axi_dma_aclk (cùng tiền tố interface) → Vivado TỰ gán clock
    //   khi package → hết DRC "not associated to clock". BD nối = net 100MHz.
    // ═══════════════════════════════════════════════════════════
    input  wire                                  m_axi_dma_aclk,
    input  wire                                  m_axi_dma_aresetn,
    output wire [31:0]                           m_axi_dma_awaddr,
    output wire [2:0]                            m_axi_dma_awprot,
    output wire                                  m_axi_dma_awvalid,
    input  wire                                  m_axi_dma_awready,
    output wire [31:0]                           m_axi_dma_wdata,
    output wire [3:0]                            m_axi_dma_wstrb,
    output wire                                  m_axi_dma_wvalid,
    input  wire                                  m_axi_dma_wready,
    input  wire [1:0]                            m_axi_dma_bresp,
    input  wire                                  m_axi_dma_bvalid,
    output wire                                  m_axi_dma_bready,
    output wire [31:0]                           m_axi_dma_araddr,
    output wire [2:0]                            m_axi_dma_arprot,
    output wire                                  m_axi_dma_arvalid,
    input  wire                                  m_axi_dma_arready,
    input  wire [31:0]                           m_axi_dma_rdata,
    input  wire [1:0]                            m_axi_dma_rresp,
    input  wire                                  m_axi_dma_rvalid,
    output wire                                  m_axi_dma_rready
);
    // AXI-Lite master PROT (constant — autonomy không phân quyền)
    assign m_axi_dma_awprot = 3'b000;
    assign m_axi_dma_arprot = 3'b000;

    // ═══════════════════════════════════════════════════════════
    // Internal wires (shim ↔ control_unit ↔ data_path ↔ post_proc)
    // ═══════════════════════════════════════════════════════════

    // ── Cấu hình từ AXI-Lite shim sang control_unit (unpack gói dữ liệu) ──
    wire [3:0] tile_m_4, tile_k_4, tile_n_4;
    wire [9:0] tile_m_size = {6'd0, tile_m_4};
    wire [9:0] tile_k_size = {6'd0, tile_k_4};
    wire [9:0] tile_n_size = {6'd0, tile_n_4};
    wire [1:0] act_mode;
    wire       start;
    wire       busy, done;
    // ── Điều khiển cộng dồn phần tử K phần cứng ──
    wire       acc_accum;
    wire       post_skip;
    // ── Chế độ im2col phần cứng ──
    wire       im2col_mode;
    wire [31:0] im2col_cfg0;
    wire [31:0] im2col_cfg1;
    wire       os_mode;          // Luồng dữ liệu Output-Stationary (cho lớp Fully-Connected)
    wire       pool_mode;        // Chế độ Max-Pooling phần cứng
    // ── Điều khiển tái sử dụng dữ liệu (data reuse) ──
    wire       skip_w_load;
    wire [1:0] acc_slot;
    wire       skip_in_load;

    // ── Điều khiển và đọc lại bộ đếm hiệu năng (Performance Counter) ──
    wire        cnt_clear;
    wire [3:0]  cnt_sel;
    wire [31:0] cnt_idle, cnt_load_w, cnt_load_b, cnt_load_in;
    wire [31:0] cnt_compute, cnt_post_proc, cnt_send, cnt_done;
    wire [31:0] cnt_total, cnt_pe_active, cnt_sparsity_skip;
    reg  [31:0] cnt_val_mux;

    // 11-to-1 counter mux - chọn counter dựa vào cnt_sel.
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
            4'd10: cnt_val_mux = cnt_sparsity_skip;
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
    wire [15:0] num_out_transfers;

    // ── control_unit ↔ data_path ──
    wire                          dp_weight_load;
    wire [2:0]                    dp_weight_row_sel;
    wire [SA_N*DATA_WIDTH-1:0]    dp_weight_data;
    wire [SA_N*DATA_WIDTH-1:0]    dp_a_left;
    wire [SA_N-1:0]               dp_valid_left;
    wire [SA_N*ACC_WIDTH-1:0]     dp_psum_bottom;
    wire [SA_N-1:0]               dp_valid_bottom;
    // Điều khiển chế độ Output-Stationary (control_unit ↔ data_path)
    wire                          dp_os_mode, dp_os_init, dp_os_valid;
    wire [SA_N*ACC_WIDTH-1:0]     dp_os_c;

    // ── control_unit ↔ post_proc ──
    wire [ACC_WIDTH-1:0]          pp_acc_in;
    wire [DATA_WIDTH-1:0]         pp_bias;
    wire                          pp_valid_in;
    wire [1:0]                    pp_act_mode;
    wire [DATA_WIDTH-1:0]         pp_data_out;
    wire                          pp_valid_out;

    // ═══════════════════════════════════════════════════════════
    // Phase 2c autonomy: slave descriptor + auto_seq + dma_ctrl + mux
    // ═══════════════════════════════════════════════════════════
    wire        auto_go;            // slv_reg0[24] pulse
    wire [31:0] out_base;           // slv_reg7
    // auto_seq → (mux) → control_unit config
    wire        auto_busy, auto_done, auto_accel_start;
    wire [9:0]  auto_tile_m, auto_tile_k, auto_tile_n;
    wire [1:0]  auto_act, auto_acc_slot;
    wire        auto_acc_accum, auto_post_skip, auto_skip_w, auto_skip_in;
    // auto_seq ↔ dma_ctrl
    wire        as_dma_start, as_do_s2mm, dma_done_w;
    wire [31:0] as_mm2s_addr, as_s2mm_addr;
    wire [25:0] as_mm2s_len, as_s2mm_len;

    // auto_mode_l: cao từ auto_go tới khi auto_done (giữ qua cycle done)
    reg auto_mode_l;
    always @(posedge s00_axi_aclk or negedge s00_axi_aresetn) begin
        if (!s00_axi_aresetn)   auto_mode_l <= 1'b0;
        else if (auto_go)       auto_mode_l <= 1'b1;
        else if (auto_done)     auto_mode_l <= 1'b0;
    end

    // Mux config control_unit: auto_seq khi auto_mode_l, else slave (Pico)
    wire [9:0] ctrl_tile_m = auto_mode_l ? auto_tile_m : tile_m_size;
    wire [9:0] ctrl_tile_k = auto_mode_l ? auto_tile_k : tile_k_size;
    wire [9:0] ctrl_tile_n = auto_mode_l ? auto_tile_n : tile_n_size;
    wire [1:0] ctrl_act    = auto_mode_l ? auto_act    : act_mode;
    wire       ctrl_start  = auto_mode_l ? auto_accel_start : start;
    wire       ctrl_accum  = auto_mode_l ? auto_acc_accum   : acc_accum;
    wire       ctrl_pskip  = auto_mode_l ? auto_post_skip   : post_skip;
    wire       ctrl_skipw  = auto_mode_l ? auto_skip_w      : skip_w_load;
    wire [1:0] ctrl_slot   = auto_mode_l ? auto_acc_slot    : acc_slot;
    wire       ctrl_skipin = auto_mode_l ? auto_skip_in     : skip_in_load;
    // STATUS tới Pico: auto thì phản ánh auto_seq (cả GEMM), else control_unit
    wire slave_busy = auto_mode_l ? auto_busy : busy;
    wire slave_done = auto_mode_l ? auto_done : done;

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
        .po_acc_slot     (acc_slot),
        .po_skip_in_load (skip_in_load),
        .po_im2col_mode  (im2col_mode),
        .po_im2col_cfg0  (im2col_cfg0),
        .po_im2col_cfg1  (im2col_cfg1),
        .po_os_mode      (os_mode),
        .po_pool_mode    (pool_mode),
        .po_auto_go      (auto_go),
        .po_out_base     (out_base),
        .po_cnt_clear    (cnt_clear),
        .po_cnt_sel      (cnt_sel),
        .pi_busy         (slave_busy),
        .pi_done         (slave_done),
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
        .pi_tile_m_size       (ctrl_tile_m),
        .pi_tile_k_size       (ctrl_tile_k),
        .pi_tile_n_size       (ctrl_tile_n),
        .pi_act_mode          (ctrl_act),
        .pi_start             (ctrl_start),
        .pi_acc_accum         (ctrl_accum),
        .pi_post_skip         (ctrl_pskip),
        .pi_skip_w_load       (ctrl_skipw),
        .pi_acc_slot          (ctrl_slot),
        .pi_skip_in_load      (ctrl_skipin),
        .pi_im2col_mode       (im2col_mode),
        .pi_im2col_cfg0       (im2col_cfg0),
        .pi_im2col_cfg1       (im2col_cfg1),
        .pi_os_mode           (os_mode),
        .pi_pool_mode         (pool_mode),
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
        .po_dp_os_mode        (dp_os_mode),
        .po_dp_os_init        (dp_os_init),
        .po_dp_os_valid       (dp_os_valid),
        .pi_dp_os_c           (dp_os_c),
        .pi_dp_psum_bottom    (dp_psum_bottom),
        .pi_dp_valid_bottom   (dp_valid_bottom),
        .po_pp_acc_in         (pp_acc_in),
        .po_pp_bias           (pp_bias),
        .po_pp_valid_in       (pp_valid_in),
        .po_pp_act_mode       (pp_act_mode),
        .pi_pp_data_out       (pp_data_out),
        .pi_pp_valid_out      (pp_valid_out),
        // Bộ đếm hiệu năng hệ thống
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
    // Phase 2c: outer-loop sequencer + DMA AXI-Lite master (autonomy)
    //   Descriptor (reuse im2col regs): cfg0={n_tiles,m_tiles,k_tiles}, cfg1=in_base.
    //   Block liền mạch (PS stage): in 272B (W32+bias4+A32 word), out 128B.
    // ═══════════════════════════════════════════════════════════
    auto_seq #(.TILE_CW(10)) u_auto_seq (
        .pi_clk           (s00_axi_aclk),
        .pi_rst_n         (s00_axi_aresetn),
        .pi_go            (auto_go),
        .pi_m_tiles       (im2col_cfg0[19:10]),
        .pi_k_tiles       (im2col_cfg0[9:0]),
        .pi_n_tiles       (im2col_cfg0[29:20]),
        .pi_in_base       (im2col_cfg1),
        .pi_in_blk_bytes  (26'd272),
        .pi_out_base      (out_base),
        .pi_out_blk_bytes (26'd128),
        .pi_tile_m        (10'd8),
        .pi_tile_k        (10'd8),
        .pi_tile_n        (10'd8),
        .pi_act_mode      (act_mode),
        .po_busy          (auto_busy),
        .po_done          (auto_done),
        .po_dma_start     (as_dma_start),
        .po_dma_do_s2mm   (as_do_s2mm),
        .po_dma_mm2s_addr (as_mm2s_addr),
        .po_dma_mm2s_len  (as_mm2s_len),
        .po_dma_s2mm_addr (as_s2mm_addr),
        .po_dma_s2mm_len  (as_s2mm_len),
        .pi_dma_done      (dma_done_w),
        .po_accel_start   (auto_accel_start),
        .po_tile_m        (auto_tile_m),
        .po_tile_k        (auto_tile_k),
        .po_tile_n        (auto_tile_n),
        .po_act_mode      (auto_act),
        .po_acc_accum     (auto_acc_accum),
        .po_post_skip     (auto_post_skip),
        .po_skip_w_load   (auto_skip_w),
        .po_acc_slot      (auto_acc_slot),
        .po_skip_in_load  (auto_skip_in),
        .pi_accel_done    (done)
    );

    dma_ctrl u_dma_ctrl (
        .pi_clk        (s00_axi_aclk),
        .pi_rst_n      (s00_axi_aresetn),
        .pi_start      (as_dma_start),
        .pi_do_s2mm    (as_do_s2mm),
        .pi_mm2s_addr  (as_mm2s_addr),
        .pi_mm2s_len   (as_mm2s_len),
        .pi_s2mm_addr  (as_s2mm_addr),
        .pi_s2mm_len   (as_s2mm_len),
        .po_busy       (),
        .po_done       (dma_done_w),
        .po_awaddr     (m_axi_dma_awaddr),
        .po_awvalid    (m_axi_dma_awvalid),
        .pi_awready    (m_axi_dma_awready),
        .po_wdata      (m_axi_dma_wdata),
        .po_wstrb      (m_axi_dma_wstrb),
        .po_wvalid     (m_axi_dma_wvalid),
        .pi_wready     (m_axi_dma_wready),
        .pi_bresp      (m_axi_dma_bresp),
        .pi_bvalid     (m_axi_dma_bvalid),
        .po_bready     (m_axi_dma_bready),
        .po_araddr     (m_axi_dma_araddr),
        .po_arvalid    (m_axi_dma_arvalid),
        .pi_arready    (m_axi_dma_arready),
        .pi_rdata      (m_axi_dma_rdata),
        .pi_rresp      (m_axi_dma_rresp),
        .pi_rvalid     (m_axi_dma_rvalid),
        .po_rready     (m_axi_dma_rready)
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
        // Chế độ Output-Stationary
        .pi_os_mode         (dp_os_mode),
        .pi_os_init         (dp_os_init),
        .pi_os_valid        (dp_os_valid),
        .po_os_c            (dp_os_c),
        // Bộ đếm chu kỳ hiệu năng
        .pi_cnt_clear       (cnt_clear),
        .po_cnt_pe_active   (cnt_pe_active),
        .po_cnt_sparsity_skip (cnt_sparsity_skip)
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
