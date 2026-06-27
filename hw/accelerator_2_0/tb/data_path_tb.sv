`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Testbench: data_path_tb — verifies TPU canonical 8x8 systolic GEMM
//
// Kịch bản chi tiết: hw/accelerator_2_0/tb/data_path_tb_scenarios.md
//
// 3 case (256 check tổng):
//   Case 1: 2x2x2 sanity lồng trong 8x8 (hardcoded A=[[1,2],[3,4]], W=[[5,6],[7,8]])
//   Case 2: 8x8x8 random (seed 42, range ±1.0)
//   Case 3: back-to-back 2 tile (case3a + case3b, weight_load giữa 2 tile)
//
// Test data: hw/accelerator_2_0/tb/data/<name>_{A,W,C}.hex
//
// Pass: in "=== ALL DATA_PATH TESTS PASSED ===". Fail: in "=== <N> FAILURES ===".
//////////////////////////////////////////////////////////////////////////////////

module data_path_tb;

    // -------- Tham số --------
    localparam integer SA_N        = 8;
    localparam integer DW          = 16;
    localparam integer AW          = 40;
    localparam integer ROW_SEL_W   = 3;
    localparam integer CLK_PERIOD  = 10;   // 100 MHz
    localparam string  DATA_DIR    = "/home/tam/Documents/RAAS/hw/accelerator_2_0/tb/data/";

    // -------- DUT signals --------
    reg                          clk = 1'b0;
    reg                          rst_n;
    reg                          weight_load;
    reg  [ROW_SEL_W-1:0]         weight_row_sel;
    reg  [SA_N*DW-1:0]           weight_data;
    reg  [SA_N*DW-1:0]           a_left;
    reg  [SA_N-1:0]              valid_left;
    wire [SA_N*AW-1:0]           psum_bottom;
    wire [SA_N-1:0]              valid_bottom;

    integer errs = 0;
    integer total_cells_checked = 0;

    // -------- Clock --------
    always #(CLK_PERIOD/2) clk = ~clk;

    // -------- DUT instance --------
    reg os_mode = 1'b0, os_init = 1'b0, os_valid = 1'b0;
    wire [SA_N*AW-1:0] os_c;

    data_path #(.SA_N(SA_N), .DATA_WIDTH(DW), .ACC_WIDTH(AW)) dut (
        .pi_clk             (clk),
        .pi_rst_n           (rst_n),
        .pi_weight_load     (weight_load),
        .pi_weight_row_sel  (weight_row_sel),
        .pi_weight_data     (weight_data),
        .pi_a_left          (a_left),
        .pi_valid_left      (valid_left),
        .po_psum_bottom     (psum_bottom),
        .po_valid_bottom    (valid_bottom),
        .pi_os_mode         (os_mode),
        .pi_os_init         (os_init),
        .pi_os_valid        (os_valid),
        .po_os_c            (os_c)
    );

    // -------- Test data buffers (loaded từ hex files) --------
    reg [DW-1:0] A_q   [0:SA_N*SA_N-1];   // row-major: A_q[m*SA_N+k]
    reg [DW-1:0] W_q   [0:SA_N*SA_N-1];   // row-major: W_q[r*SA_N+c]
    reg [AW-1:0] C_exp [0:SA_N*SA_N-1];   // row-major: C_exp[m*SA_N+n]
    reg [AW-1:0] C_got [0:SA_N*SA_N-1];   // captured

    // -------- Helper: load 1 case từ hex files --------
    task automatic load_case(input string name);
        $readmemh({DATA_DIR, name, "_A.hex"}, A_q);
        $readmemh({DATA_DIR, name, "_W.hex"}, W_q);
        $readmemh({DATA_DIR, name, "_C.hex"}, C_exp);
        $display("[INFO] Loaded case '%s' from %s", name, DATA_DIR);
    endtask

    // -------- Helper: load tất cả 8 weight rows vào DUT --------
    task automatic load_weights();
        integer r, c;
        reg [SA_N*DW-1:0] row_pack;
        for (r = 0; r < SA_N; r = r + 1) begin
            // Pack W_q[r][:] vào weight_data (col 0 = LSB)
            row_pack = '0;
            for (c = 0; c < SA_N; c = c + 1)
                row_pack[c*DW +: DW] = W_q[r*SA_N + c];

            @(negedge clk);
            weight_load    = 1'b1;
            weight_row_sel = r[ROW_SEL_W-1:0];
            weight_data    = row_pack;
            a_left         = '0;
            valid_left     = '0;
            @(posedge clk);
        end
        // Cycle dứt weight_load để clear cleanup
        @(negedge clk);
        weight_load    = 1'b0;
        weight_row_sel = '0;
        weight_data    = '0;
        @(posedge clk);
    endtask

    // -------- Helper: drive skewed input + capture output cho 1 tile --------
    // M_used, K_used, N_used: kích thước tile thực tế (≤ SA_N).
    task automatic drive_and_capture(input integer M_used,
                                     input integer K_used,
                                     input integer N_used);
        integer cmp_t;
        integer total_cycles;
        integer r, n;
        integer m_cap;
        reg [DW-1:0] a_val;

        // Init C_got = 0
        for (r = 0; r < SA_N*SA_N; r = r + 1)
            C_got[r] = '0;

        // Total cycles cần drive: M+N+SA_N-1 + 2 cycle margin
        total_cycles = M_used + N_used + SA_N - 1 + 2;

        for (cmp_t = 0; cmp_t < total_cycles; cmp_t = cmp_t + 1) begin
            // ---- Drive skewed inputs at negedge ----
            @(negedge clk);
            for (r = 0; r < SA_N; r = r + 1) begin
                if (r < K_used && cmp_t >= r && (cmp_t - r) < M_used) begin
                    a_val = A_q[(cmp_t - r) * SA_N + r];
                    a_left[r*DW +: DW] = a_val;
                end else begin
                    a_left[r*DW +: DW] = '0;
                end
                // CRITICAL: valid_left = 1 cho TẤT CẢ row (kể cả r >= K_used)
                // để valid chain propagate tới row đáy SA_N-1.
                valid_left[r] = 1'b1;
            end

            // ---- Wait posedge then capture ----
            @(posedge clk);
            #1;
            for (n = 0; n < SA_N; n = n + 1) begin
                if (valid_bottom[n]) begin
                    // Formula: m_cap = cmp_t - n - (SA_N - 1)
                    m_cap = cmp_t - n - (SA_N - 1);
                    if (m_cap >= 0 && m_cap < M_used && n < N_used) begin
                        C_got[m_cap*SA_N + n] = psum_bottom[n*AW +: AW];
                    end
                end
            end
        end

        // Ngừng drive
        @(negedge clk);
        a_left     = '0;
        valid_left = '0;
        @(posedge clk);
    endtask

    // -------- Helper: so sánh C_got với C_exp --------
    task automatic compare_results(input string name,
                                   input integer M_used,
                                   input integer N_used);
        integer m, n, idx;
        integer local_errs = 0;
        for (m = 0; m < SA_N; m = m + 1) begin
            for (n = 0; n < SA_N; n = n + 1) begin
                idx = m * SA_N + n;
                if ($signed(C_got[idx]) !== $signed(C_exp[idx])) begin
                    if (local_errs < 5) begin   // chỉ in 5 fail đầu để gọn log
                        $display("[FAIL] %s C[%0d][%0d]: got=%0d (0x%h)  exp=%0d (0x%h)",
                                 name, m, n,
                                 $signed(C_got[idx]), C_got[idx],
                                 $signed(C_exp[idx]), C_exp[idx]);
                    end
                    local_errs = local_errs + 1;
                end
                total_cells_checked = total_cells_checked + 1;
            end
        end
        if (local_errs == 0)
            $display("[ OK ] %s: all %0d cells match (used %0dx%0d)",
                     name, SA_N*SA_N, M_used, N_used);
        else
            $display("[FAIL] %s: %0d cell(s) mismatch", name, local_errs);
        errs = errs + local_errs;
    endtask

    // -------- Helper: chạy 1 tile end-to-end --------
    task automatic run_tile(input string name,
                            input integer M_used,
                            input integer K_used,
                            input integer N_used);
        $display("");
        $display("==== Tile %s (M=%0d K=%0d N=%0d) ====", name, M_used, K_used, N_used);
        load_case(name);
        load_weights();
        drive_and_capture(M_used, K_used, N_used);
        compare_results(name, M_used, N_used);
    endtask

    // -------- Phase 3a-merge: OS qua array == Σ a·w (verify dual-mode PE) --------
    task automatic run_os_check(input string tag, input integer ntile);
        integer r, c, k, n, t, le;
        reg [SA_N*DW-1:0] row_pack, a_pack;
        reg signed [AW-1:0] gold [0:SA_N-1];
        reg signed [AW-1:0] got, exp;
        // golden reset
        for (n = 0; n < SA_N; n = n + 1) gold[n] = '0;
        os_mode = 1'b0; os_init = 1'b0; os_valid = 1'b0;

        for (t = 0; t < ntile; t = t + 1) begin
            // data K-tile t (signed, distinct)
            for (r = 0; r < SA_N; r = r + 1)
                for (c = 0; c < SA_N; c = c + 1)
                    W_q[r*SA_N + c] = (t*4 + r*3 + c) % 17 - 8;
            for (k = 0; k < SA_N; k = k + 1)
                A_q[k] = (t*7 + k*5) % 13 - 6;
            for (n = 0; n < SA_N; n = n + 1)
                for (k = 0; k < SA_N; k = k + 1)
                    gold[n] = gold[n] + $signed(A_q[k]) * $signed(W_q[k*SA_N + n]);

            // load W tile vào array (os_mode=0 ở tile đầu để clear; giữ ở tile sau)
            os_mode = (t != 0);
            load_weights();
            // compute 1 K-tile: broadcast a, os_init chỉ tile đầu
            os_mode = 1'b1;
            a_pack = '0;
            for (k = 0; k < SA_N; k = k + 1) a_pack[k*DW +: DW] = A_q[k];
            @(negedge clk); a_left = a_pack; os_valid = 1'b1; os_init = (t == 0);
            @(negedge clk); os_valid = 1'b0; os_init = 1'b0; a_left = '0;
            @(negedge clk);
        end
        #1;
        le = 0;
        for (n = 0; n < SA_N; n = n + 1) begin
            got = os_c[n*AW +: AW]; exp = gold[n];
            if (got !== exp) begin
                if (le < 4) $display("[FAIL] %s os_c[%0d]: got=%0d exp=%0d", tag, n, $signed(got), $signed(exp));
                le = le + 1;
            end
        end
        if (le == 0) $display("[ OK ] %s OS-via-array == Σ a·w (%0d K-tile, 8 col)", tag, ntile);
        errs = errs + le;
        os_mode = 1'b0;
    endtask

    // -------- Main stimulus --------
    initial begin
        $dumpfile("data_path_tb.vcd");
        $dumpvars(0, data_path_tb);

        // Init
        rst_n          = 1'b0;
        weight_load    = 1'b0;
        weight_row_sel = '0;
        weight_data    = '0;
        a_left         = '0;
        valid_left     = '0;

        // Reset
        repeat(3) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        // ========== Case 1: 2x2x2 sanity ==========
        run_tile("case1", 2, 2, 2);

        // ========== Case 2: 8x8x8 random ==========
        run_tile("case2", 8, 8, 8);

        // ========== Case 3: back-to-back 2 tiles ==========
        // KHÔNG reset DUT giữa 2 tile — verify weight_load tự clear pipeline.
        run_tile("case3a", 8, 8, 8);
        run_tile("case3b", 8, 8, 8);

        // ========== Case 4: OS dual-mode (gộp WS+OS) ==========
        run_os_check("os.1tile", 1);
        run_os_check("os.3tile", 3);

        // ========== Tổng kết ==========
        $display("");
        $display("Total cells checked: %0d", total_cells_checked);
        if (errs == 0)
            $display("=== ALL DATA_PATH TESTS PASSED ===");
        else
            $display("=== %0d DATA_PATH TEST FAILURES ===", errs);
        $finish;
    end

    // -------- Timeout watchdog --------
    initial begin
        #20000;
        $display("[TIMEOUT] simulation exceeded 20000 ns");
        $finish;
    end

endmodule
