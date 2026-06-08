`timescale 1ns / 1ps

// ===========================================================================
// tmr_voter.v — Triple Modular Redundancy majority voter
//
// Vấn đề 7b: FSM state (hoặc register quan trọng) là single point of failure với
// SEU. Triple hóa state thành a/b/c, voter chọn majority bit-wise → 1 bit flip
// trong 1 bản bị "outvote" → state đúng vẫn được giữ. mismatch=1 khi 3 bản
// không đồng nhất (đã có lỗi được sửa) → đếm để đo SEU rate.
//
// Combinational, ~0 latency, overhead ~3× register (nhỏ so với tổng).
// ===========================================================================
module tmr_voter #(
    parameter integer WIDTH = 4
)(
    input  wire [WIDTH-1:0] pi_a,
    input  wire [WIDTH-1:0] pi_b,
    input  wire [WIDTH-1:0] pi_c,
    output wire [WIDTH-1:0] po_voted,
    output wire             po_mismatch   // 1 = 3 bản không đồng nhất
);

    // Majority bit-wise: voted[i] = 1 khi ≥2 trong a/b/c có bit i = 1.
    assign po_voted = (pi_a & pi_b) | (pi_a & pi_c) | (pi_b & pi_c);

    // Mismatch khi không phải cả 3 giống nhau.
    assign po_mismatch = (pi_a != pi_b) || (pi_b != pi_c) || (pi_a != pi_c);

endmodule
