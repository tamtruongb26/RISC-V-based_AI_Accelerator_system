`timescale 1ns / 1ps

// ===========================================================================
// maxpool2x2.v — Hardware max-pool 2×2 stride 2 (Phase 2b, Vấn đề 3c)
//
// Bỏ maxpool SW. Đọc feature map [C×H×W] (CHW) từ memory, mỗi output = max của
// khối 2×2 → ghi [C × H/2 × W/2]. FSM address-based (như im2col): mỗi output đọc
// 4 phần tử (2 cycle latency mỗi đọc) → so sánh signed → ghi.
//
// H, W giả định chẵn (LeNet: 24→12, 8→4). Q1.4.11 signed.
// ===========================================================================
module maxpool2x2 #(
    parameter integer DATA_WIDTH = 16,
    parameter integer ADDR_WIDTH = 16,
    parameter integer DIM_WIDTH  = 8
)(
    input  wire                    pi_clk,
    input  wire                    pi_rst_n,
    input  wire                    pi_start,
    output reg                     po_busy,
    output reg                     po_done,

    // ── Config (latch lúc start) — input CHW; output C×(H/2)×(W/2) ──
    input  wire [DIM_WIDTH-1:0]    pi_H,
    input  wire [DIM_WIDTH-1:0]    pi_W,
    input  wire [DIM_WIDTH-1:0]    pi_C,

    // ── FM read port (CHW): addr = c*H*W + h*W + w, data 1-cycle sau ──
    output reg                     po_fm_rd_en,
    output reg [ADDR_WIDTH-1:0]    po_fm_rd_addr,
    input  wire signed [DATA_WIDTH-1:0] pi_fm_rd_data,

    // ── Output write (linear) ──
    output reg                     po_out_wr_en,
    output reg [ADDR_WIDTH-1:0]    po_out_wr_addr,
    output reg signed [DATA_WIDTH-1:0] po_out_wr_data
);

    localparam [2:0] S_IDLE = 3'd0, S_P0 = 3'd1, S_P1 = 3'd2,
                     S_P2 = 3'd3, S_P3 = 3'd4, S_P4 = 3'd5, S_DONE = 3'd6;
    reg [2:0] state;

    // Config
    reg [DIM_WIDTH-1:0]  H, W, C, Hout, Wout;
    reg [ADDR_WIDTH-1:0] HW;

    // Counters
    reg [DIM_WIDTH-1:0]  cc, ho, wo;
    reg [ADDR_WIDTH-1:0] out_idx;
    reg signed [DATA_WIDTH-1:0] rmax;     // running max

    // 4 địa chỉ của khối 2×2 (CHW): base + (2ho+dh)*W + (2wo+dw)
    wire [ADDR_WIDTH-1:0] base   = cc * HW;
    wire [ADDR_WIDTH-1:0] row0   = base + (ho << 1) * W;
    wire [ADDR_WIDTH-1:0] row1   = base + ((ho << 1) + {{(DIM_WIDTH-1){1'b0}},1'b1}) * W;
    wire [ADDR_WIDTH-1:0] a0 = row0 + (wo << 1);
    wire [ADDR_WIDTH-1:0] a1 = row0 + (wo << 1) + {{(ADDR_WIDTH-1){1'b0}},1'b1};
    wire [ADDR_WIDTH-1:0] a2 = row1 + (wo << 1);
    wire [ADDR_WIDTH-1:0] a3 = row1 + (wo << 1) + {{(ADDR_WIDTH-1){1'b0}},1'b1};

    // FM read addr combinational theo state (1-cycle latency của memory).
    always @(*) begin
        po_fm_rd_en   = (state == S_P0) || (state == S_P1) ||
                        (state == S_P2) || (state == S_P3);
        case (state)
            S_P0:    po_fm_rd_addr = a0;
            S_P1:    po_fm_rd_addr = a1;
            S_P2:    po_fm_rd_addr = a2;
            S_P3:    po_fm_rd_addr = a3;
            default: po_fm_rd_addr = {ADDR_WIDTH{1'b0}};
        endcase
    end

    // max signed của running max và data hiện tại.
    wire signed [DATA_WIDTH-1:0] max_cur =
        (rmax > pi_fm_rd_data) ? rmax : pi_fm_rd_data;

    wire last_out = (wo == Wout - {{(DIM_WIDTH-1){1'b0}},1'b1}) &&
                    (ho == Hout - {{(DIM_WIDTH-1){1'b0}},1'b1}) &&
                    (cc == C - {{(DIM_WIDTH-1){1'b0}},1'b1});

    always @(posedge pi_clk or negedge pi_rst_n) begin
        if (!pi_rst_n) begin
            state <= S_IDLE; po_busy <= 1'b0; po_done <= 1'b0;
            po_out_wr_en <= 1'b0; po_out_wr_addr <= 0; po_out_wr_data <= 0;
            cc <= 0; ho <= 0; wo <= 0; out_idx <= 0; rmax <= 0;
        end else begin
            po_out_wr_en <= 1'b0;
            po_done      <= 1'b0;
            case (state)
            S_IDLE: begin
                po_busy <= 1'b0;
                if (pi_start) begin
                    H <= pi_H; W <= pi_W; C <= pi_C;
                    Hout <= pi_H >> 1; Wout <= pi_W >> 1;
                    HW <= pi_H * pi_W;
                    cc <= 0; ho <= 0; wo <= 0; out_idx <= 0;
                    po_busy <= 1'b1;
                    state <= S_P0;
                end
            end
            // Đọc 4 phần tử (P0 issue a0, P1 cap a0+issue a1, ...).
            S_P0: state <= S_P1;
            S_P1: begin rmax <= pi_fm_rd_data; state <= S_P2; end          // e0
            S_P2: begin rmax <= max_cur;       state <= S_P3; end          // e1
            S_P3: begin rmax <= max_cur;       state <= S_P4; end          // e2
            S_P4: begin                                                     // e3 + write
                po_out_wr_en   <= 1'b1;
                po_out_wr_addr <= out_idx;
                po_out_wr_data <= max_cur;       // max(rmax, e3)
                out_idx <= out_idx + {{(ADDR_WIDTH-1){1'b0}},1'b1};
                if (last_out) begin
                    state <= S_DONE;
                end else begin
                    // advance wo → ho → cc
                    if (wo == Wout - {{(DIM_WIDTH-1){1'b0}},1'b1}) begin
                        wo <= 0;
                        if (ho == Hout - {{(DIM_WIDTH-1){1'b0}},1'b1}) begin
                            ho <= 0; cc <= cc + {{(DIM_WIDTH-1){1'b0}},1'b1};
                        end else ho <= ho + {{(DIM_WIDTH-1){1'b0}},1'b1};
                    end else wo <= wo + {{(DIM_WIDTH-1){1'b0}},1'b1};
                    state <= S_P0;
                end
            end
            S_DONE: begin po_done <= 1'b1; po_busy <= 1'b0; state <= S_IDLE; end
            default: state <= S_IDLE;
            endcase
        end
    end

endmodule
