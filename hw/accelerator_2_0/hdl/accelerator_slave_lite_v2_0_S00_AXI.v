`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module:  accelerator_slave_lite_v2_0_S00_AXI
// Project: accelerator_2_0
//
// AXI4-Lite slave register file (5 regs, post-Phase 0).
// Spec đầy đủ: hw/accelerator_2_0/hdl/axi_shim_spec.md §2.
//
// Address map (Phase 0 - packed config + indirect counter readback):
//   0x00 CONFIG_PACKED  R/W  [3:0]=M, [7:4]=K, [11:8]=N, [13:12]=ACT, [14]=START
//                            START là one-shot pulse (auto-clear sau 1 cycle).
//   0x04 CNT_CLEAR      R/W  [0]=PULSE (auto-clear) - reset toàn bộ counter
//   0x08 CNT_SEL        R/W  [3:0]=counter index (xem mapping ở accelerator.v)
//   0x0C STATUS         R    [0]=BUSY, [1]=DONE  (HW-written, DONE sticky)
//   0x10 CNT_VAL        R    32-bit value của counter[cnt_sel]  (HW mux)
//
// Counter index mapping (xem accelerator.v cho mux logic):
//   0 = cnt_idle       1 = cnt_load_w     2 = cnt_load_b     3 = cnt_load_in
//   4 = cnt_compute    5 = cnt_post_proc  6 = cnt_send       7 = cnt_done
//   8 = cnt_total      9 = cnt_pe_active  10..15 = reserved (returns 0)
//////////////////////////////////////////////////////////////////////////////////

module accelerator_slave_lite_v2_0_S00_AXI #(
    parameter integer C_S_AXI_DATA_WIDTH = 32,
    parameter integer C_S_AXI_ADDR_WIDTH = 5
)(
    // ── User-side outputs (tới control_unit) ──
    output wire [3:0]   po_tile_m_size,
    output wire [3:0]   po_tile_k_size,
    output wire [3:0]   po_tile_n_size,
    output wire         po_start,
    output wire [1:0]   po_act_mode,
    output wire         po_cnt_clear,
    output wire [3:0]   po_cnt_sel,
    // ── Phase 1a-i: HW K-accumulation control (CFG spare bits) ──
    output wire         po_acc_accum,   // slv_reg0[15] 1=cộng dồn, 0=ghi đè
    output wire         po_post_skip,   // slv_reg0[16] 1=bỏ post_proc+send
    // ── Phase 1a-ii: data reuse control ──
    output wire         po_skip_w_load, // slv_reg0[17] 1=giữ weight cũ (bỏ LOAD_W)
    output wire [1:0]   po_acc_slot,    // slv_reg0[19:18] output-tile slot (blocking)
    // ── User-side inputs (từ control_unit/data_path) ──
    input  wire         pi_busy,
    input  wire         pi_done,
    input  wire [31:0]  pi_cnt_val,

    // ── AXI4-Lite slave ──
    input  wire                                S_AXI_ACLK,
    input  wire                                S_AXI_ARESETN,
    input  wire [C_S_AXI_ADDR_WIDTH-1:0]       S_AXI_AWADDR,
    input  wire [2:0]                          S_AXI_AWPROT,
    input  wire                                S_AXI_AWVALID,
    output wire                                S_AXI_AWREADY,
    input  wire [C_S_AXI_DATA_WIDTH-1:0]       S_AXI_WDATA,
    input  wire [(C_S_AXI_DATA_WIDTH/8)-1:0]   S_AXI_WSTRB,
    input  wire                                S_AXI_WVALID,
    output wire                                S_AXI_WREADY,
    output wire [1:0]                          S_AXI_BRESP,
    output wire                                S_AXI_BVALID,
    input  wire                                S_AXI_BREADY,
    input  wire [C_S_AXI_ADDR_WIDTH-1:0]       S_AXI_ARADDR,
    input  wire [2:0]                          S_AXI_ARPROT,
    input  wire                                S_AXI_ARVALID,
    output wire                                S_AXI_ARREADY,
    output wire [C_S_AXI_DATA_WIDTH-1:0]       S_AXI_RDATA,
    output wire [1:0]                          S_AXI_RRESP,
    output wire                                S_AXI_RVALID,
    input  wire                                S_AXI_RREADY
);

    // ─────────────────────────────────────────────────────────
    // Internal AXI handshake signals
    // ─────────────────────────────────────────────────────────
    reg [C_S_AXI_ADDR_WIDTH-1:0] axi_awaddr;
    reg                          axi_awready;
    reg                          axi_wready;
    reg [1:0]                    axi_bresp;
    reg                          axi_bvalid;
    reg [C_S_AXI_ADDR_WIDTH-1:0] axi_araddr;
    reg                          axi_arready;
    reg [1:0]                    axi_rresp;
    reg                          axi_rvalid;

    localparam integer ADDR_LSB          = 2;   // log2(32/8) = 2 (byte address LSBs)
    localparam integer OPT_MEM_ADDR_BITS = 2;   // 3-bit register select (covers 5 regs)

    // ─────────────────────────────────────────────────────────
    // Registers (Phase 0 layout)
    //   slv_reg0 = CONFIG_PACKED (R/W) - M/K/N/ACT/START
    //   slv_reg1 = CNT_CLEAR     (R/W) - bit[0] one-shot pulse
    //   slv_reg2 = CNT_SEL       (R/W) - bit[3:0] counter index
    //   slv_reg3 = STATUS        (R, HW assembled từ pi_busy + done_sticky)
    //   slv_reg4 = CNT_VAL       (R, HW from pi_cnt_val mux ngoài slave_lite)
    // ─────────────────────────────────────────────────────────
    reg [C_S_AXI_DATA_WIDTH-1:0] slv_reg0;  // CONFIG_PACKED
    reg [C_S_AXI_DATA_WIDTH-1:0] slv_reg1;  // CNT_CLEAR
    reg [C_S_AXI_DATA_WIDTH-1:0] slv_reg2;  // CNT_SEL
    // DONE sticky: latch on pi_done pulse, clear on next START write
    reg                          done_sticky;
    wire [C_S_AXI_DATA_WIDTH-1:0] slv_reg3 = {30'd0, done_sticky, pi_busy};  // STATUS (HW)
    wire [C_S_AXI_DATA_WIDTH-1:0] slv_reg4 = pi_cnt_val;                     // CNT_VAL (HW mux)

    integer byte_index;

    // AXI handshake outputs
    assign S_AXI_AWREADY = axi_awready;
    assign S_AXI_WREADY  = axi_wready;
    assign S_AXI_BRESP   = axi_bresp;
    assign S_AXI_BVALID  = axi_bvalid;
    assign S_AXI_ARREADY = axi_arready;
    assign S_AXI_RRESP   = axi_rresp;
    assign S_AXI_RVALID  = axi_rvalid;

    // ─────────────────────────────────────────────────────────
    // Write FSM
    // ─────────────────────────────────────────────────────────
    reg [1:0] state_write;
    reg [1:0] state_read;
    localparam Idle  = 2'b00;
    localparam Waddr = 2'b10;
    localparam Wdata = 2'b11;
    localparam Raddr = 2'b10;
    localparam Rdata = 2'b11;

    always @(posedge S_AXI_ACLK) begin
        if (!S_AXI_ARESETN) begin
            axi_awready <= 1'b0;
            axi_wready  <= 1'b0;
            axi_bvalid  <= 1'b0;
            axi_bresp   <= 2'b0;
            axi_awaddr  <= {C_S_AXI_ADDR_WIDTH{1'b0}};
            state_write <= Idle;
        end else begin
            case (state_write)
                Idle: begin
                    axi_awready <= 1'b1;
                    axi_wready  <= 1'b1;
                    state_write <= Waddr;
                end
                Waddr: begin
                    if (S_AXI_AWVALID && S_AXI_AWREADY) begin
                        axi_awaddr <= S_AXI_AWADDR;
                        if (S_AXI_WVALID) begin
                            axi_awready <= 1'b1;
                            state_write <= Waddr;
                            axi_bvalid  <= 1'b1;
                        end else begin
                            axi_awready <= 1'b0;
                            state_write <= Wdata;
                            if (S_AXI_BREADY && axi_bvalid) axi_bvalid <= 1'b0;
                        end
                    end else begin
                        if (S_AXI_BREADY && axi_bvalid) axi_bvalid <= 1'b0;
                    end
                end
                Wdata: begin
                    if (S_AXI_WVALID) begin
                        state_write <= Waddr;
                        axi_bvalid  <= 1'b1;
                        axi_awready <= 1'b1;
                    end else begin
                        if (S_AXI_BREADY && axi_bvalid) axi_bvalid <= 1'b0;
                    end
                end
                default: state_write <= Idle;
            endcase
        end
    end

    // ─────────────────────────────────────────────────────────
    // Register write + START/CNT_CLEAR auto-clear
    //   slv_reg0[14] (START) và slv_reg1[0] (CNT_CLEAR_PULSE) là one-shot:
    //   sau khi user ghi 1, HW tự đặt về 0 vào cycle kế tiếp.
    // ─────────────────────────────────────────────────────────
    always @(posedge S_AXI_ACLK) begin
        if (!S_AXI_ARESETN) begin
            slv_reg0 <= {C_S_AXI_DATA_WIDTH{1'b0}};
            slv_reg1 <= {C_S_AXI_DATA_WIDTH{1'b0}};
            slv_reg2 <= {C_S_AXI_DATA_WIDTH{1'b0}};
        end else begin
            // Auto-clear START bit (one-shot pulse) - slv_reg0[14]
            if (slv_reg0[14]) slv_reg0[14] <= 1'b0;
            // Auto-clear CNT_CLEAR pulse - slv_reg1[0]
            if (slv_reg1[0]) slv_reg1[0] <= 1'b0;

            if (S_AXI_WVALID) begin
                case (S_AXI_AWVALID ?
                      S_AXI_AWADDR[ADDR_LSB+OPT_MEM_ADDR_BITS:ADDR_LSB] :
                      axi_awaddr  [ADDR_LSB+OPT_MEM_ADDR_BITS:ADDR_LSB])
                    3'h0: for (byte_index = 0; byte_index < 4; byte_index = byte_index + 1)
                              if (S_AXI_WSTRB[byte_index])
                                  slv_reg0[byte_index*8 +: 8] <= S_AXI_WDATA[byte_index*8 +: 8];
                    3'h1: for (byte_index = 0; byte_index < 4; byte_index = byte_index + 1)
                              if (S_AXI_WSTRB[byte_index])
                                  slv_reg1[byte_index*8 +: 8] <= S_AXI_WDATA[byte_index*8 +: 8];
                    3'h2: for (byte_index = 0; byte_index < 4; byte_index = byte_index + 1)
                              if (S_AXI_WSTRB[byte_index])
                                  slv_reg2[byte_index*8 +: 8] <= S_AXI_WDATA[byte_index*8 +: 8];
                    // 3'h3 = STATUS read-only, 3'h4 = CNT_VAL read-only
                    default: ;
                endcase
            end
        end
    end

    // ─────────────────────────────────────────────────────────
    // DONE sticky logic: latch khi pi_done pulse, clear khi START write
    //   START giờ ở slv_reg0[14] (CONFIG_PACKED).
    // ─────────────────────────────────────────────────────────
    always @(posedge S_AXI_ACLK) begin
        if (!S_AXI_ARESETN) begin
            done_sticky <= 1'b0;
        end else if (slv_reg0[14]) begin
            // START vừa được ghi (1 cycle trước auto-clear) → reset DONE
            done_sticky <= 1'b0;
        end else if (pi_done) begin
            done_sticky <= 1'b1;
        end
    end

    // ─────────────────────────────────────────────────────────
    // Read FSM
    // ─────────────────────────────────────────────────────────
    always @(posedge S_AXI_ACLK) begin
        if (!S_AXI_ARESETN) begin
            axi_arready <= 1'b0;
            axi_rvalid  <= 1'b0;
            axi_rresp   <= 2'b0;
            state_read  <= Idle;
        end else begin
            case (state_read)
                Idle: begin
                    state_read  <= Raddr;
                    axi_arready <= 1'b1;
                end
                Raddr: begin
                    if (S_AXI_ARVALID && S_AXI_ARREADY) begin
                        state_read  <= Rdata;
                        axi_araddr  <= S_AXI_ARADDR;
                        axi_rvalid  <= 1'b1;
                        axi_arready <= 1'b0;
                    end
                end
                Rdata: begin
                    if (S_AXI_RVALID && S_AXI_RREADY) begin
                        axi_rvalid  <= 1'b0;
                        axi_arready <= 1'b1;
                        state_read  <= Raddr;
                    end
                end
                default: state_read <= Idle;
            endcase
        end
    end

    // Read data mux
    assign S_AXI_RDATA =
        (axi_araddr[ADDR_LSB+OPT_MEM_ADDR_BITS:ADDR_LSB] == 3'h0) ? slv_reg0 :
        (axi_araddr[ADDR_LSB+OPT_MEM_ADDR_BITS:ADDR_LSB] == 3'h1) ? slv_reg1 :
        (axi_araddr[ADDR_LSB+OPT_MEM_ADDR_BITS:ADDR_LSB] == 3'h2) ? slv_reg2 :
        (axi_araddr[ADDR_LSB+OPT_MEM_ADDR_BITS:ADDR_LSB] == 3'h3) ? slv_reg3 :
        (axi_araddr[ADDR_LSB+OPT_MEM_ADDR_BITS:ADDR_LSB] == 3'h4) ? slv_reg4 :
        {C_S_AXI_DATA_WIDTH{1'b0}};

    // ─────────────────────────────────────────────────────────
    // User-side outputs - unpack CONFIG_PACKED + counter control
    //   slv_reg0[3:0]  = M_size   (1..8)
    //   slv_reg0[7:4]  = K_size
    //   slv_reg0[11:8] = N_size
    //   slv_reg0[13:12] = ACT_MODE
    //   slv_reg0[14]   = START_pulse
    // ─────────────────────────────────────────────────────────
    assign po_tile_m_size = slv_reg0[3:0];
    assign po_tile_k_size = slv_reg0[7:4];
    assign po_tile_n_size = slv_reg0[11:8];
    assign po_act_mode    = slv_reg0[13:12];
    assign po_start       = slv_reg0[14];
    //   slv_reg0[15] = ACC_ACCUM (1=cộng dồn psum_buf, 0=ghi đè — mặc định cũ)
    //   slv_reg0[16] = POST_SKIP (1=bỏ POST_PROC+SEND, 0=làm — mặc định cũ)
    assign po_acc_accum   = slv_reg0[15];
    assign po_post_skip   = slv_reg0[16];
    //   slv_reg0[17] = SKIP_W_LOAD (1=giữ weight trong array, bỏ LOAD_W)
    //   slv_reg0[19:18] = ACC_SLOT (output-tile slot trong accumulator)
    assign po_skip_w_load = slv_reg0[17];
    assign po_acc_slot    = slv_reg0[19:18];
    assign po_cnt_clear   = slv_reg1[0];
    assign po_cnt_sel     = slv_reg2[3:0];

endmodule
