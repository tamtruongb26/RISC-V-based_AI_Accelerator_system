`timescale 1ns / 1ps

// ===========================================================================
// im2col.v — Bộ chuyển đổi im2col bằng phần cứng (giải Vấn đề 3b)
//
// Biến feature map [H×W×C] (CHW) thành ma trận GEMM A[M×K]:
//   M = H_out × W_out   (số vị trí output)
//   K = C × kH × kW     (kích thước patch trải phẳng, thứ tự C-kh-kw)
//
// FSM sliding-window: với mỗi (h_out,w_out) → 1 hàng A; trong hàng, duyệt
// (c, kh, kw) → các cột. Pixel ngoài biên (padding) ghi 0.
//
// 2 bước/phần tử: READ (issue fm read) → WRITE (ghi A). FM read 1-cycle latency.
// Địa chỉ ghi A là LINEAR (row-major, ++mỗi phần tử) → không cần nhân.
// Địa chỉ đọc FM = c*H*W + h_in*W + w_in (CHW).
//
// H_out/W_out nhận từ ngoài (firmware tính sẵn) → tránh chia trong HW.
// ===========================================================================
module im2col #(
    parameter integer DATA_WIDTH = 16,
    parameter integer ADDR_WIDTH = 16,
    parameter integer DIM_WIDTH  = 8
)(
    input  wire                    pi_clk,
    input  wire                    pi_rst_n,
    input  wire                    pi_start,
    output reg                     po_busy,
    output reg                     po_done,

    // ── Config (latch lúc start) ──
    input  wire [DIM_WIDTH-1:0]    pi_H,
    input  wire [DIM_WIDTH-1:0]    pi_W,
    input  wire [DIM_WIDTH-1:0]    pi_C,
    input  wire [3:0]              pi_KH,
    input  wire [3:0]              pi_KW,
    input  wire [3:0]              pi_stride,
    input  wire [3:0]              pi_pad,
    // Blocking: chỉ sinh các output-row ho trong [ho_start, ho_start+ho_count).
    // im2col đầy đủ = ho_start 0, ho_count Hout. A write addr linear từ 0 mỗi lần.
    input  wire [DIM_WIDTH-1:0]    pi_ho_start,
    input  wire [DIM_WIDTH-1:0]    pi_ho_count,
    input  wire [DIM_WIDTH-1:0]    pi_W_out,

    // ── FM read port (CHW): addr = c*H*W + h*W + w, data 1-cycle sau ──
    output reg                     po_fm_rd_en,
    output reg [ADDR_WIDTH-1:0]    po_fm_rd_addr,
    input  wire [DATA_WIDTH-1:0]   pi_fm_rd_data,

    // ── A write port (row-major linear) ──
    output reg                     po_a_wr_en,
    output reg [ADDR_WIDTH-1:0]    po_a_wr_addr,
    output reg [DATA_WIDTH-1:0]    po_a_wr_data
);

    localparam [1:0] S_IDLE  = 2'd0,
                     S_READ  = 2'd1,
                     S_WRITE = 2'd2,
                     S_DONE  = 2'd3;
    reg [1:0] state;

    // ── Config đã latch ──
    reg [DIM_WIDTH-1:0]  H, W, C, Wout;
    reg [DIM_WIDTH-1:0]  ho_last;     // = ho_start + ho_count - 1
    reg [3:0]            KH, KW, STR, PAD;
    reg [ADDR_WIDTH-1:0] HW;          // = H*W

    // ── Counters của 5 vòng lặp ──
    reg [DIM_WIDTH-1:0]  ho, wo, cc;
    reg [3:0]            kh, kw;
    reg [ADDR_WIDTH-1:0] wr_addr;     // địa chỉ ghi A linear

    // ── Tính vị trí pixel input (unsigned, tránh signed) ──
    //   h_pos = ho*STR + kh ; valid khi h_pos>=PAD và h_pos-PAD < H
    wire [ADDR_WIDTH-1:0] h_pos = ho * STR + kh;
    wire [ADDR_WIDTH-1:0] w_pos = wo * STR + kw;
    wire valid_h = (h_pos >= PAD) && ((h_pos - PAD) < H);
    wire valid_w = (w_pos >= PAD) && ((w_pos - PAD) < W);
    wire in_bounds = valid_h && valid_w;
    wire [ADDR_WIDTH-1:0] h_in = h_pos - PAD;
    wire [ADDR_WIDTH-1:0] w_in = w_pos - PAD;
    wire [ADDR_WIDTH-1:0] fm_addr = cc * HW + h_in * W + w_in;

    // FM read là COMBINATIONAL (active trong S_READ) → khớp 1-cycle latency
    // của memory: addr ở cycle N → data valid cycle N+1 (S_WRITE).
    always @(*) begin
        po_fm_rd_en   = (state == S_READ) && in_bounds;
        po_fm_rd_addr = fm_addr;
    end

    // ── Phần tử cuối? ──
    wire last_elem = (kw == KW - 4'd1) && (kh == KH - 4'd1) &&
                     (cc == C - {{(DIM_WIDTH-1){1'b0}},1'b1}) &&
                     (wo == Wout - {{(DIM_WIDTH-1){1'b0}},1'b1}) &&
                     (ho == ho_last);

    always @(posedge pi_clk or negedge pi_rst_n) begin
        if (!pi_rst_n) begin
            state         <= S_IDLE;
            po_busy       <= 1'b0;
            po_done       <= 1'b0;
            po_a_wr_en    <= 1'b0;
            po_a_wr_addr  <= {ADDR_WIDTH{1'b0}};
            po_a_wr_data  <= {DATA_WIDTH{1'b0}};
            ho <= 0; wo <= 0; cc <= 0; kh <= 0; kw <= 0;
            wr_addr <= {ADDR_WIDTH{1'b0}};
        end else begin
            po_a_wr_en  <= 1'b0;
            po_done     <= 1'b0;

            case (state)
            S_IDLE: begin
                po_busy <= 1'b0;
                if (pi_start) begin
                    H    <= pi_H;   W    <= pi_W;   C   <= pi_C;
                    KH   <= pi_KH;  KW   <= pi_KW;  STR <= pi_stride; PAD <= pi_pad;
                    Wout <= pi_W_out;
                    ho_last <= pi_ho_start + pi_ho_count - {{(DIM_WIDTH-1){1'b0}},1'b1};
                    HW   <= pi_H * pi_W;
                    ho <= pi_ho_start; wo <= 0; cc <= 0; kh <= 0; kw <= 0;
                    wr_addr <= {ADDR_WIDTH{1'b0}};
                    po_busy <= 1'b1;
                    state   <= S_READ;
                end
            end

            // FM read đã issue combinational (xem always @* trên). Chờ 1 cycle.
            S_READ: begin
                state <= S_WRITE;
            end

            // Ghi 1 phần tử A; advance counters.
            S_WRITE: begin
                po_a_wr_en   <= 1'b1;
                po_a_wr_addr <= wr_addr;
                po_a_wr_data <= in_bounds ? pi_fm_rd_data : {DATA_WIDTH{1'b0}};
                wr_addr      <= wr_addr + {{(ADDR_WIDTH-1){1'b0}},1'b1};

                if (last_elem) begin
                    state <= S_DONE;
                end else begin
                    // Advance (kw → kh → c → wo → ho)
                    if (kw == KW - 4'd1) begin
                        kw <= 4'd0;
                        if (kh == KH - 4'd1) begin
                            kh <= 4'd0;
                            if (cc == C - {{(DIM_WIDTH-1){1'b0}},1'b1}) begin
                                cc <= 0;
                                if (wo == Wout - {{(DIM_WIDTH-1){1'b0}},1'b1}) begin
                                    wo <= 0;
                                    ho <= ho + {{(DIM_WIDTH-1){1'b0}},1'b1};
                                end else wo <= wo + {{(DIM_WIDTH-1){1'b0}},1'b1};
                            end else cc <= cc + {{(DIM_WIDTH-1){1'b0}},1'b1};
                        end else kh <= kh + 4'd1;
                    end else kw <= kw + 4'd1;
                    state <= S_READ;
                end
            end

            S_DONE: begin
                po_done <= 1'b1;
                po_busy <= 1'b0;
                state   <= S_IDLE;
            end

            default: state <= S_IDLE;
            endcase
        end
    end

endmodule
