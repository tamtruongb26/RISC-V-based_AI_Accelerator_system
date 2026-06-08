`timescale 1ns / 1ps
// ===========================================================================
// dma_ctrl.v — AXI-Lite MASTER tự lập trình AXI DMA (Phase 2c autonomy)
//
// Thay PicoRV32: outer-loop FSM ra lệnh 1 tile-transfer, module này tự ghi
// các thanh ghi DMA (Direct/Simple mode) qua AXI-Lite master rồi poll DMASR.IDLE.
//
// Trình tự 1 transfer:
//   (nếu do_s2mm) S2MM_DMACR=RUN → S2MM_DA → S2MM_LENGTH (khởi động S2MM)
//   MM2S_DMACR=RUN → MM2S_SA → MM2S_LENGTH (khởi động MM2S)
//   poll MM2S_DMASR.IDLE [+ S2MM_DMASR.IDLE nếu do_s2mm] → po_done (1 pulse)
//
// Lưu ý: KHÔNG reset DMA ở đây (giả định Pico/đầu vào reset 1 lần). Địa chỉ
// 32-bit (SA/DA hi=0, dùng kênh thấp). Length ≤ 26-bit (DMA c_sg_length_width).
// ===========================================================================
module dma_ctrl #(
    // Base địa chỉ DMA S_AXI_LITE trong address-map của master này (BD Address
    // Editor gán segment DMA tại base này). Mặc định = RAAS_PICO_DMA_BASE.
    parameter [31:0] DMA_BASE = 32'h4001_0000
)(
    input  wire        pi_clk,
    input  wire        pi_rst_n,

    // ── Lệnh từ outer-loop FSM ──
    input  wire        pi_start,        // pulse: bắt đầu 1 tile-transfer
    input  wire        pi_do_s2mm,      // 1 = lập trình cả S2MM (tile output)
    input  wire [31:0] pi_mm2s_addr,
    input  wire [25:0] pi_mm2s_len,     // bytes
    input  wire [31:0] pi_s2mm_addr,
    input  wire [25:0] pi_s2mm_len,     // bytes
    output reg         po_busy,
    output reg         po_done,         // 1 pulse khi transfer xong

    // ── AXI-Lite master tới DMA S_AXI_LITE ──
    output reg  [31:0] po_awaddr,
    output reg         po_awvalid,
    input  wire        pi_awready,
    output reg  [31:0] po_wdata,
    output reg  [3:0]  po_wstrb,
    output reg         po_wvalid,
    input  wire        pi_wready,
    input  wire [1:0]  pi_bresp,
    input  wire        pi_bvalid,
    output reg         po_bready,
    output reg  [31:0] po_araddr,
    output reg         po_arvalid,
    input  wire        pi_arready,
    input  wire [31:0] pi_rdata,
    input  wire [1:0]  pi_rresp,
    input  wire        pi_rvalid,
    output reg         po_rready
);
    // ── DMA register offsets (Direct mode) ──
    localparam [7:0] MM2S_DMACR  = 8'h00;
    localparam [7:0] MM2S_DMASR  = 8'h04;
    localparam [7:0] MM2S_SA     = 8'h18;
    localparam [7:0] MM2S_LENGTH = 8'h28;
    localparam [7:0] S2MM_DMACR  = 8'h30;
    localparam [7:0] S2MM_DMASR  = 8'h34;
    localparam [7:0] S2MM_DA     = 8'h48;
    localparam [7:0] S2MM_LENGTH = 8'h58;
    localparam [31:0] DMACR_RUN  = 32'h0000_0001;
    localparam [1:0]  SR_IDLE_BIT = 2'd1;       // DMASR[1] = IDLE

    // ── Transaction sub-FSM (1 write hoặc 1 read AXI-Lite) ──
    localparam [2:0] TXN_IDLE = 3'd0,
                     TXN_AW_W = 3'd1,   // write: AW+W tới khi cả 2 ready
                     TXN_B    = 3'd2,
                     TXN_AR   = 3'd3,   // read: AR tới khi arready
                     TXN_R    = 3'd4,
                     TXN_DONE = 3'd5;
    reg [2:0]  txn_state;
    reg        txn_go;       // pulse từ main FSM
    reg        txn_is_rd;    // 1=read, 0=write
    reg [7:0]  txn_addr;
    reg [31:0] txn_wdata;
    reg [31:0] txn_rdata;
    reg        txn_done;     // 1 pulse khi txn xong
    reg        aw_done, w_done;

    always @(posedge pi_clk or negedge pi_rst_n) begin : txn_fsm
        if (!pi_rst_n) begin
            txn_state  <= TXN_IDLE;
            po_awaddr  <= 32'd0; po_awvalid <= 1'b0;
            po_wdata   <= 32'd0; po_wvalid  <= 1'b0; po_wstrb <= 4'h0;
            po_bready  <= 1'b0;
            po_araddr  <= 32'd0; po_arvalid <= 1'b0;
            po_rready  <= 1'b0;
            txn_rdata  <= 32'd0; txn_done <= 1'b0;
            aw_done    <= 1'b0;  w_done   <= 1'b0;
        end else begin
            txn_done <= 1'b0;
            case (txn_state)
            TXN_IDLE: begin
                if (txn_go) begin
                    if (txn_is_rd) begin
                        po_araddr  <= DMA_BASE | {24'd0, txn_addr};
                        po_arvalid <= 1'b1;
                        txn_state  <= TXN_AR;
                    end else begin
                        po_awaddr  <= DMA_BASE | {24'd0, txn_addr};
                        po_awvalid <= 1'b1;
                        po_wdata   <= txn_wdata;
                        po_wstrb   <= 4'hF;
                        po_wvalid  <= 1'b1;
                        aw_done    <= 1'b0;
                        w_done     <= 1'b0;
                        txn_state  <= TXN_AW_W;
                    end
                end
            end
            // ── Write: AW + W handshake (độc lập) ──
            TXN_AW_W: begin
                if (po_awvalid && pi_awready) begin po_awvalid <= 1'b0; aw_done <= 1'b1; end
                if (po_wvalid  && pi_wready ) begin po_wvalid  <= 1'b0; w_done  <= 1'b1; end
                if ((aw_done || (po_awvalid && pi_awready)) &&
                    (w_done  || (po_wvalid  && pi_wready ))) begin
                    po_bready <= 1'b1;
                    txn_state <= TXN_B;
                end
            end
            TXN_B: begin
                if (pi_bvalid) begin
                    po_bready <= 1'b0;
                    txn_done  <= 1'b1;
                    txn_state <= TXN_IDLE;
                end
            end
            // ── Read: AR then R ──
            TXN_AR: begin
                if (pi_arready) begin
                    po_arvalid <= 1'b0;
                    po_rready  <= 1'b1;
                    txn_state  <= TXN_R;
                end
            end
            TXN_R: begin
                if (pi_rvalid) begin
                    txn_rdata <= pi_rdata;
                    po_rready <= 1'b0;
                    txn_done  <= 1'b1;
                    txn_state <= TXN_IDLE;
                end
            end
            default: txn_state <= TXN_IDLE;
            endcase
        end
    end

    // ── Main sequencer ──
    localparam [3:0] S_IDLE     = 4'd0,
                     S_S2_CR    = 4'd1,   // S2MM_DMACR=RUN
                     S_S2_DA    = 4'd2,
                     S_S2_LEN   = 4'd3,
                     S_MM_CR    = 4'd4,   // MM2S_DMACR=RUN
                     S_MM_SA    = 4'd5,
                     S_MM_LEN   = 4'd6,
                     S_POLL_MM  = 4'd7,   // read MM2S_DMASR, chờ IDLE
                     S_POLL_S2  = 4'd8,   // read S2MM_DMASR, chờ IDLE
                     S_DONE     = 4'd9;
    reg [3:0] mstate;
    reg       do_s2mm_l;
    reg [31:0] mm2s_addr_l, s2mm_addr_l;
    reg [25:0] mm2s_len_l, s2mm_len_l;

    // helper: phát 1 txn (write/read) khi vào state mới
    reg issued;   // đã phát txn_go cho state hiện tại chưa

    always @(posedge pi_clk or negedge pi_rst_n) begin : main_fsm
        if (!pi_rst_n) begin
            mstate    <= S_IDLE;
            po_busy   <= 1'b0;
            po_done   <= 1'b0;
            txn_go    <= 1'b0;
            txn_is_rd <= 1'b0;
            txn_addr  <= 8'd0;
            txn_wdata <= 32'd0;
            issued    <= 1'b0;
            do_s2mm_l <= 1'b0;
            mm2s_addr_l <= 32'd0; s2mm_addr_l <= 32'd0;
            mm2s_len_l  <= 26'd0; s2mm_len_l  <= 26'd0;
        end else begin
            txn_go  <= 1'b0;
            po_done <= 1'b0;
            case (mstate)
            S_IDLE: begin
                po_busy <= 1'b0;
                issued  <= 1'b0;
                if (pi_start) begin
                    po_busy     <= 1'b1;
                    do_s2mm_l   <= pi_do_s2mm;
                    mm2s_addr_l <= pi_mm2s_addr;
                    mm2s_len_l  <= pi_mm2s_len;
                    s2mm_addr_l <= pi_s2mm_addr;
                    s2mm_len_l  <= pi_s2mm_len;
                    issued      <= 1'b0;
                    mstate      <= pi_do_s2mm ? S_S2_CR : S_MM_CR;
                end
            end
            // ── Mỗi state: phát 1 txn rồi chờ txn_done → sang state kế ──
            S_S2_CR:  do_write(S2MM_DMACR,  DMACR_RUN,            S_S2_DA);
            S_S2_DA:  do_write(S2MM_DA,     s2mm_addr_l,          S_S2_LEN);
            S_S2_LEN: do_write(S2MM_LENGTH, {6'd0, s2mm_len_l},   S_MM_CR);
            S_MM_CR:  do_write(MM2S_DMACR,  DMACR_RUN,            S_MM_SA);
            S_MM_SA:  do_write(MM2S_SA,     mm2s_addr_l,          S_MM_LEN);
            S_MM_LEN: do_write(MM2S_LENGTH, {6'd0, mm2s_len_l},   S_POLL_MM);
            S_POLL_MM: do_poll(MM2S_DMASR, do_s2mm_l ? S_POLL_S2 : S_DONE);
            S_POLL_S2: do_poll(S2MM_DMASR, S_DONE);
            S_DONE: begin
                po_done <= 1'b1;
                po_busy <= 1'b0;
                mstate  <= S_IDLE;
            end
            default: mstate <= S_IDLE;
            endcase
        end
    end

    // task: phát 1 write rồi sang nxt khi xong
    task do_write(input [7:0] a, input [31:0] d, input [3:0] nxt);
        begin
            if (!issued) begin
                txn_is_rd <= 1'b0;
                txn_addr  <= a;
                txn_wdata <= d;
                txn_go    <= 1'b1;
                issued    <= 1'b1;
            end else if (txn_done) begin
                issued <= 1'b0;
                mstate <= nxt;
            end
        end
    endtask

    // task: đọc DMASR lặp tới khi IDLE bit set, rồi sang nxt
    task do_poll(input [7:0] a, input [3:0] nxt);
        begin
            if (!issued) begin
                txn_is_rd <= 1'b1;
                txn_addr  <= a;
                txn_go    <= 1'b1;
                issued    <= 1'b1;
            end else if (txn_done) begin
                issued <= 1'b0;
                if (txn_rdata[SR_IDLE_BIT])  // IDLE → xong
                    mstate <= nxt;
                // else: issued=0 → đọc lại (poll)
            end
        end
    endtask

endmodule
