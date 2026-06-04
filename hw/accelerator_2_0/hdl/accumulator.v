`timescale 1ns / 1ps

// ===========================================================================
// accumulator.v — Psum SRAM với in-place add (Phase 1a)
//
// Giải Vấn đề 3a (SW K-accumulation): HW tự cộng dồn psum qua các K-tile.
//   pi_overwrite = 1 : acc[addr] = data_in            (K-tile 0, khởi tạo)
//   pi_overwrite = 0 : acc[addr] = acc[addr] + data_in (K-tile > 0, cộng dồn)
//
// psum 40-bit (signed): = 32-bit tích Q2.8.22 + 8-bit headroom cho K_max=256
// → không tràn ở mọi layer LeNet.
// DEPTH = 1024 cell = 16 output tile (8×8) → đặt block size M (xem design note §3).
//
// Lưu ý synthesis: read-modify-write (acc += data) ở đây mô tả hành vi đúng cho
// sim. Khi map BRAM thật có thể cần read-first mode / forwarding pipeline cho
// back-to-back same-addr — xác nhận ở synthesis (design note §10).
// ===========================================================================
module accumulator #(
    parameter integer DATA_WIDTH = 40,
    parameter integer DEPTH      = 1024,
    parameter integer ADDR_WIDTH = (DEPTH <= 1) ? 1 : $clog2(DEPTH)
)(
    input  wire                          pi_clk,

    // ── Write port (psum từ array) ──
    input  wire                          pi_wr_en,
    input  wire                          pi_overwrite,   // 1=ghi đè, 0=cộng dồn
    input  wire [ADDR_WIDTH-1:0]         pi_wr_addr,
    input  wire signed [DATA_WIDTH-1:0]  pi_wr_data,

    // ── Read port (→ post_proc / DMA) ──
    input  wire                          pi_rd_en,
    input  wire [ADDR_WIDTH-1:0]         pi_rd_addr,
    output reg  signed [DATA_WIDTH-1:0]  po_rd_data
);

    reg signed [DATA_WIDTH-1:0] mem [0:DEPTH-1];

    // ── Write: ghi đè hoặc cộng dồn (adder column) ──
    always @(posedge pi_clk) begin
        if (pi_wr_en) begin
            if (pi_overwrite)
                mem[pi_wr_addr] <= pi_wr_data;
            else
                mem[pi_wr_addr] <= mem[pi_wr_addr] + pi_wr_data;
        end
    end

    // ── Read: registered output (1 cycle latency) ──
    always @(posedge pi_clk) begin
        if (pi_rd_en)
            po_rd_data <= mem[pi_rd_addr];
    end

endmodule
