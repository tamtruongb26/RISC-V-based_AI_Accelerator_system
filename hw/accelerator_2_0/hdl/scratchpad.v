`timescale 1ns / 1ps

// ===========================================================================
// scratchpad.v — On-chip SRAM buffer cho weight + input
//
// 2 bank ping-pong, mỗi bank dual-port (1 write port, 1 read port độc lập).
// Trong double-buffering: Load FSM ghi 1 bank trong khi Exec FSM
// đọc bank kia → 2 port chọn bank riêng (pi_wr_bank / pi_rd_bank).
//
// Việc TOGGLE bank (ping-pong) nằm ở control_unit, KHÔNG ở đây — module này
// chỉ là storage có địa chỉ bank. Giữ đơn giản + dễ test.
//
// Mặc định: DATA_WIDTH=128 (= 8 phần tử × 16-bit, 1 hàng feed array 8-wide),
//           DEPTH=512/bank → 512×128 = 8KB/bank × 2 = 16KB = 4 BRAM36 tile.
// Read có 1 cycle latency (registered output → suy ra BRAM).
// Không reset mảng nhớ (để tool infer BRAM).
// ===========================================================================
module scratchpad #(
    parameter integer DATA_WIDTH = 128,
    parameter integer DEPTH      = 512,
    parameter integer ADDR_WIDTH = (DEPTH <= 1) ? 1 : $clog2(DEPTH)
)(
    input  wire                    pi_clk,

    // ── Write port (vd: DMA load DDR → scratchpad) ──
    //   pi_wr_bank: 0 = bank A, 1 = bank B
    input  wire                    pi_wr_en,
    input  wire                    pi_wr_bank,
    input  wire [ADDR_WIDTH-1:0]   pi_wr_addr,
    input  wire [DATA_WIDTH-1:0]   pi_wr_data,

    // ── Read port (vd: Exec đọc scratchpad → array) ──
    //   pi_rd_bank: 0 = bank A, 1 = bank B
    //   po_rd_data hợp lệ 1 cycle SAU khi pi_rd_en + pi_rd_addr được drive.
    input  wire                    pi_rd_en,
    input  wire                    pi_rd_bank,
    input  wire [ADDR_WIDTH-1:0]   pi_rd_addr,
    output reg  [DATA_WIDTH-1:0]   po_rd_data
);

    // ── 2 bank độc lập ──
    reg [DATA_WIDTH-1:0] bank_a [0:DEPTH-1];
    reg [DATA_WIDTH-1:0] bank_b [0:DEPTH-1];

    // ── Write: chỉ bank được chọn mới ghi ──
    always @(posedge pi_clk) begin
        if (pi_wr_en) begin
            if (pi_wr_bank == 1'b0)
                bank_a[pi_wr_addr] <= pi_wr_data;
            else
                bank_b[pi_wr_addr] <= pi_wr_data;
        end
    end

    // ── Read: registered output (1 cycle latency, BRAM-style) ──
    always @(posedge pi_clk) begin
        if (pi_rd_en) begin
            if (pi_rd_bank == 1'b0)
                po_rd_data <= bank_a[pi_rd_addr];
            else
                po_rd_data <= bank_b[pi_rd_addr];
        end
    end

endmodule
