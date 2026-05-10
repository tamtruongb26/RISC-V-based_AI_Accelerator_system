`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module:  accelerator_slave_lite_v2_0_S00_AXI
// Project: accelerator_2_0
//
// AXI4-Lite slave register file (5 regs).
// Spec đầy đủ: hw/accelerator_2_0/hdl/axi_shim_spec.md §2.
//
// Address map:
//   0x00 TILE_M_SIZE  R/W  [9:0]   M dim (1..8)
//   0x04 TILE_K_SIZE  R/W  [9:0]   K dim
//   0x08 TILE_N_SIZE  R/W  [9:0]   N dim
//   0x0C CONTROL      R/W  [0]=START (one-shot), [2:1]=ACT_MODE
//   0x10 STATUS       R    [0]=BUSY, [1]=DONE  (HW-written)
//
// START auto-clear: bit[0] tự về 0 sau 1 cycle để thành pulse.
//////////////////////////////////////////////////////////////////////////////////

module accelerator_slave_lite_v2_0_S00_AXI #(
    parameter integer C_S_AXI_DATA_WIDTH = 32,
    parameter integer C_S_AXI_ADDR_WIDTH = 5
)(
    // ── User-side outputs (tới control_unit) ──
    output wire [9:0]   po_tile_m_size,
    output wire [9:0]   po_tile_k_size,
    output wire [9:0]   po_tile_n_size,
    output wire         po_start,
    output wire [1:0]   po_act_mode,
    // ── User-side inputs (từ control_unit) ──
    input  wire         pi_busy,
    input  wire         pi_done,

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
    // Registers
    // ─────────────────────────────────────────────────────────
    reg [C_S_AXI_DATA_WIDTH-1:0] slv_reg0;  // TILE_M_SIZE
    reg [C_S_AXI_DATA_WIDTH-1:0] slv_reg1;  // TILE_K_SIZE
    reg [C_S_AXI_DATA_WIDTH-1:0] slv_reg2;  // TILE_N_SIZE
    reg [C_S_AXI_DATA_WIDTH-1:0] slv_reg3;  // CONTROL
    // DONE sticky: latch on pi_done pulse, clear on next START write
    reg                          done_sticky;
    wire [C_S_AXI_DATA_WIDTH-1:0] slv_reg4 = {30'd0, done_sticky, pi_busy};  // STATUS (HW)

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
    // Register write + START auto-clear
    // ─────────────────────────────────────────────────────────
    always @(posedge S_AXI_ACLK) begin
        if (!S_AXI_ARESETN) begin
            slv_reg0 <= {C_S_AXI_DATA_WIDTH{1'b0}};
            slv_reg1 <= {C_S_AXI_DATA_WIDTH{1'b0}};
            slv_reg2 <= {C_S_AXI_DATA_WIDTH{1'b0}};
            slv_reg3 <= {C_S_AXI_DATA_WIDTH{1'b0}};
        end else begin
            // Auto-clear START bit (one-shot pulse)
            if (slv_reg3[0]) slv_reg3[0] <= 1'b0;

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
                    3'h3: for (byte_index = 0; byte_index < 4; byte_index = byte_index + 1)
                              if (S_AXI_WSTRB[byte_index])
                                  slv_reg3[byte_index*8 +: 8] <= S_AXI_WDATA[byte_index*8 +: 8];
                    // 3'h4 = STATUS read-only, ignore writes
                    default: ;
                endcase
            end
        end
    end

    // ─────────────────────────────────────────────────────────
    // DONE sticky logic: latch khi pi_done pulse, clear khi START write
    // ─────────────────────────────────────────────────────────
    always @(posedge S_AXI_ACLK) begin
        if (!S_AXI_ARESETN) begin
            done_sticky <= 1'b0;
        end else if (slv_reg3[0]) begin
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
    // User-side outputs (truncate 32→10 bit cho tile sizes)
    // ─────────────────────────────────────────────────────────
    assign po_tile_m_size = slv_reg0[9:0];
    assign po_tile_k_size = slv_reg1[9:0];
    assign po_tile_n_size = slv_reg2[9:0];
    assign po_start       = slv_reg3[0];
    assign po_act_mode    = slv_reg3[2:1];

endmodule
