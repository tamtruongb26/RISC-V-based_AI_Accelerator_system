`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Testbench: data_path_tb — verifies systolic 2x2 GEMM end-to-end.
//
// Uses SA_N=2 to keep cycle counts manageable. GEMM:
//
//   A = [[1, 2],     W = [[5, 6],     C = A·W = [[19, 22],
//        [3, 4]]          [7, 8]]                [43, 50]]
//
// Steps:
//   1. Load W into PE grid (1 row per cycle via weight_row_sel).
//   2. Feed A skewed at left edge: row r delayed by r cycles.
//   3. Capture po_psum_bottom[c] when po_valid_bottom[c] is high; expected
//      cycle for C[m][c] is t = m + c + K + 1 (relative to first input cycle,
//      counting the registered output delay).
//
// All values are plain integers (no fixed-point scaling) for unit-test clarity.
//////////////////////////////////////////////////////////////////////////////////

module data_path_tb;
    localparam integer SA_N = 2;
    localparam integer DW   = 16;
    localparam integer AW   = 40;
    localparam integer M = 2, K = 2, N = 2;

    reg clk = 0; always #5 clk = ~clk;
    reg rst_n = 0;

    reg                          weight_load;
    reg  [0:0]                   weight_row_sel;
    reg  [SA_N*DW-1:0]           weight_data;
    reg  [SA_N*DW-1:0]           a_left;
    reg  [SA_N-1:0]              valid_left;
    wire [SA_N*AW-1:0]           psum_bottom;
    wire [SA_N-1:0]              valid_bottom;

    data_path #(
        .SA_N(SA_N), .DATA_WIDTH(DW), .ACC_WIDTH(AW)
    ) dut (
        .pi_clk            (clk),
        .pi_rst_n          (rst_n),
        .pi_weight_load    (weight_load),
        .pi_weight_row_sel (weight_row_sel),
        .pi_weight_data    (weight_data),
        .pi_a_left         (a_left),
        .pi_valid_left     (valid_left),
        .po_psum_bottom    (psum_bottom),
        .po_valid_bottom   (valid_bottom)
    );

    // Test matrices
    reg signed [DW-1:0] A [0:M-1][0:K-1];
    reg signed [DW-1:0] W [0:K-1][0:N-1];
    reg signed [AW-1:0] C_exp [0:M-1][0:N-1];
    reg signed [AW-1:0] C_got [0:M-1][0:N-1];
    integer errs = 0;
    integer t;
    integer rr, nn;

    initial begin
        $dumpfile("data_path_tb.vcd"); $dumpvars(0, data_path_tb);

        // Init test data
        A[0][0]= 1; A[0][1]= 2;
        A[1][0]= 3; A[1][1]= 4;
        W[0][0]= 5; W[0][1]= 6;
        W[1][0]= 7; W[1][1]= 8;
        C_exp[0][0]= 1*5 + 2*7;  // 19
        C_exp[0][1]= 1*6 + 2*8;  // 22
        C_exp[1][0]= 3*5 + 4*7;  // 43
        C_exp[1][1]= 3*6 + 4*8;  // 50

        for (rr=0; rr<M; rr=rr+1) for (nn=0; nn<N; nn=nn+1) C_got[rr][nn] = 'x;

        weight_load = 0; weight_row_sel = 0; weight_data = 0;
        a_left = 0; valid_left = 0;
        #20 rst_n = 1; @(posedge clk);

        // Load weights row by row
        // Row 0 = {W[0][1], W[0][0]} = {6, 5}
        @(negedge clk);
        weight_row_sel = 0;
        weight_data = {W[0][1], W[0][0]};
        weight_load = 1;
        @(posedge clk);
        @(negedge clk);
        weight_row_sel = 1;
        weight_data = {W[1][1], W[1][0]};
        @(posedge clk);
        @(negedge clk);
        weight_load = 0;
        weight_data = 0;

        // Compute phase: skewed feed
        // cycle t (cmp_t): row r feeds A[t-r][r] when 0<=t-r<M
        for (t = 0; t < M+K-1; t = t+1) begin
            @(negedge clk);
            a_left = 0; valid_left = 0;
            for (rr = 0; rr < SA_N; rr = rr+1) begin
                if (rr < K) begin
                    if (t-rr >= 0 && t-rr < M) begin
                        a_left[rr*DW +: DW] = A[t-rr][rr];
                        valid_left[rr] = 1'b1;
                    end
                end
            end
        end
        // After last input, drain N+K extra cycles to catch all outputs
        // Outputs C[m][n] arrive when cmp_t (RHS at posedge) = m+n+K
        // For 2x2: cmp_t in [2,3,4] for C[m][n]: (0,0)=2, (1,0)/(0,1)=3, (1,1)=4
        // Then registered output emerges 1 cycle later, so capture range = [3..5].
        @(negedge clk); a_left = 0; valid_left = 0;

        // Capture loop: monitor valid_bottom
        for (t = 0; t < 8; t = t+1) begin
            @(posedge clk);
            #1;
            for (nn = 0; nn < N; nn = nn+1) begin
                if (valid_bottom[nn]) begin
                    // Compute m index from cycle. We know first capture is for
                    // some C[?][nn]; record into next free m slot for that nn.
                    automatic integer m;
                    m = 0;
                    while (m<M && C_got[m][nn] !== 'x) m = m+1;
                    if (m < M) begin
                        C_got[m][nn] = $signed(psum_bottom[nn*AW +: AW]);
                        $display("[t=%0d] capture C[%0d][%0d] = %0d (exp %0d)",
                                 t, m, nn, C_got[m][nn], C_exp[m][nn]);
                    end
                end
            end
        end

        // Verify
        for (rr = 0; rr < M; rr = rr+1)
            for (nn = 0; nn < N; nn = nn+1)
                if (C_got[rr][nn] !== C_exp[rr][nn]) begin
                    $display("[FAIL] C[%0d][%0d] got=%0d exp=%0d",
                             rr, nn, C_got[rr][nn], C_exp[rr][nn]);
                    errs = errs+1;
                end

        if (errs == 0) $display("=== ALL DATA_PATH TESTS PASSED ===");
        else            $display("=== %0d FAILURES ===", errs);
        $finish;
    end

    initial begin
        #5000 $display("TIMEOUT"); $finish;
    end
endmodule
