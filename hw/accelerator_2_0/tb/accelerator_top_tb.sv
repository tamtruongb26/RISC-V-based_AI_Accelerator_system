`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Testbench: accelerator_top_tb — end-to-end integration TB cho accelerator
//
// Kịch bản: hw/accelerator_2_0/tb/accelerator_top_tb_scenarios.md
//
// Drive 3 AXI interface qua TB-written drivers (no Vivado VIP):
//   - axi_lite_write/read   (config + status)
//   - axis_push             (data load qua AXIS slave)
//   - always-tready capture (output từ AXIS master)
//
// 4 case:
//   1. Sanity 2x2x2 bypass (hardcoded)
//   2. 3 act mode trên cùng input 4x4x4
//   3. Sweep 50 random tile (bypass)
//   4. Back-to-back 2 tile (no DUT reset giữa)
//
// Pass: "=== ALL ACCELERATOR TOP TESTS PASSED ===".
//////////////////////////////////////////////////////////////////////////////////

module accelerator_top_tb;

    // -------- Parameters --------
    localparam integer SA_N       = 8;
    localparam integer DW         = 16;
    localparam integer AW         = 40;
    localparam integer CLK_PERIOD = 10;       // 100 MHz
    localparam string  DATA_DIR   = "/home/tam/Documents/RAAS/hw/accelerator_2_0/tb/data/";

    // -------- Clock & reset --------
    reg clk = 1'b0;
    reg rst_n;
    always #(CLK_PERIOD/2) clk = ~clk;

    // -------- AXI-Lite signals --------
    reg  [4:0]  s00_axi_awaddr;
    reg  [2:0]  s00_axi_awprot;
    reg         s00_axi_awvalid;
    wire        s00_axi_awready;
    reg  [31:0] s00_axi_wdata;
    reg  [3:0]  s00_axi_wstrb;
    reg         s00_axi_wvalid;
    wire        s00_axi_wready;
    wire [1:0]  s00_axi_bresp;
    wire        s00_axi_bvalid;
    reg         s00_axi_bready;
    reg  [4:0]  s00_axi_araddr;
    reg  [2:0]  s00_axi_arprot;
    reg         s00_axi_arvalid;
    wire        s00_axi_arready;
    wire [31:0] s00_axi_rdata;
    wire [1:0]  s00_axi_rresp;
    wire        s00_axi_rvalid;
    reg         s00_axi_rready;

    // -------- AXIS slave signals (TB drives, DUT receives) --------
    reg         s00_axis_tvalid;
    reg  [31:0] s00_axis_tdata;
    reg  [3:0]  s00_axis_tstrb;
    reg         s00_axis_tlast;
    wire        s00_axis_tready;

    // -------- AXIS master signals (DUT drives, TB captures) --------
    wire        m00_axis_tvalid;
    wire [31:0] m00_axis_tdata;
    wire [3:0]  m00_axis_tstrb;
    wire        m00_axis_tlast;
    reg         m00_axis_tready;

    // -------- DUT --------
    accelerator dut (
        .s00_axi_aclk    (clk),
        .s00_axi_aresetn (rst_n),
        .s00_axi_awaddr  (s00_axi_awaddr),
        .s00_axi_awprot  (s00_axi_awprot),
        .s00_axi_awvalid (s00_axi_awvalid),
        .s00_axi_awready (s00_axi_awready),
        .s00_axi_wdata   (s00_axi_wdata),
        .s00_axi_wstrb   (s00_axi_wstrb),
        .s00_axi_wvalid  (s00_axi_wvalid),
        .s00_axi_wready  (s00_axi_wready),
        .s00_axi_bresp   (s00_axi_bresp),
        .s00_axi_bvalid  (s00_axi_bvalid),
        .s00_axi_bready  (s00_axi_bready),
        .s00_axi_araddr  (s00_axi_araddr),
        .s00_axi_arprot  (s00_axi_arprot),
        .s00_axi_arvalid (s00_axi_arvalid),
        .s00_axi_arready (s00_axi_arready),
        .s00_axi_rdata   (s00_axi_rdata),
        .s00_axi_rresp   (s00_axi_rresp),
        .s00_axi_rvalid  (s00_axi_rvalid),
        .s00_axi_rready  (s00_axi_rready),
        .s00_axis_aclk    (clk),
        .s00_axis_aresetn (rst_n),
        .s00_axis_tvalid  (s00_axis_tvalid),
        .s00_axis_tdata   (s00_axis_tdata),
        .s00_axis_tstrb   (s00_axis_tstrb),
        .s00_axis_tlast   (s00_axis_tlast),
        .s00_axis_tready  (s00_axis_tready),
        .m00_axis_aclk    (clk),
        .m00_axis_aresetn (rst_n),
        .m00_axis_tvalid  (m00_axis_tvalid),
        .m00_axis_tdata   (m00_axis_tdata),
        .m00_axis_tstrb   (m00_axis_tstrb),
        .m00_axis_tlast   (m00_axis_tlast),
        .m00_axis_tready  (m00_axis_tready)
    );

    // -------- Capture buffer (always tready, latch words on handshake) --------
    reg  [31:0] capture_buf [0:255];
    integer     capture_count;
    reg         capture_enable;
    reg         capture_reset;       // sync reset cho counter (giữa tile, no DUT reset)

    always @(posedge clk) begin
        if (!rst_n || capture_reset) begin
            capture_count <= 0;
        end else if (capture_enable && m00_axis_tvalid && m00_axis_tready) begin
            capture_buf[capture_count] <= m00_axis_tdata;
            capture_count <= capture_count + 1;
        end
    end

    // -------- Test buffers (loaded từ hex files) --------
    reg [DW-1:0] A_mem    [0:63];     // M*K elements (max 64)
    reg [DW-1:0] W_mem    [0:63];     // SA_N*SA_N padded
    reg [DW-1:0] bias_mem [0:7];      // SA_N elements
    reg [DW-1:0] C_mem    [0:63];     // M*N expected

    // -------- Counters --------
    integer total_tiles  = 0;
    integer total_checks = 0;
    integer errs         = 0;

    // ─────────────────────────────────────────────────────────────
    // AXI-Lite master driver
    // ─────────────────────────────────────────────────────────────
    task automatic axi_lite_write(input [4:0] addr, input [31:0] data);
        @(negedge clk);
        s00_axi_awaddr  = addr;
        s00_axi_awprot  = 3'b0;
        s00_axi_awvalid = 1'b1;
        s00_axi_wdata   = data;
        s00_axi_wstrb   = 4'hF;
        s00_axi_wvalid  = 1'b1;
        s00_axi_bready  = 1'b1;
        // Wait both AWREADY and WREADY
        do @(posedge clk);
        while (!(s00_axi_awready && s00_axi_wready));
        @(negedge clk);
        s00_axi_awvalid = 1'b0;
        s00_axi_wvalid  = 1'b0;
        // Wait BVALID then ack
        do @(posedge clk);
        while (!s00_axi_bvalid);
        @(negedge clk);
        s00_axi_bready  = 1'b0;
    endtask

    task automatic axi_lite_read(input [4:0] addr, output [31:0] data);
        @(negedge clk);
        s00_axi_araddr  = addr;
        s00_axi_arprot  = 3'b0;
        s00_axi_arvalid = 1'b1;
        s00_axi_rready  = 1'b1;
        do @(posedge clk);
        while (!s00_axi_arready);
        @(negedge clk);
        s00_axi_arvalid = 1'b0;
        do @(posedge clk);
        while (!s00_axi_rvalid);
        data = s00_axi_rdata;
        @(negedge clk);
        s00_axi_rready  = 1'b0;
    endtask

    // ─────────────────────────────────────────────────────────────
    // AXIS slave driver (push 1 word)
    // ─────────────────────────────────────────────────────────────
    task automatic axis_push(input [31:0] word);
        @(negedge clk);
        s00_axis_tvalid = 1'b1;
        s00_axis_tdata  = word;
        s00_axis_tstrb  = 4'hF;
        s00_axis_tlast  = 1'b0;
        do @(posedge clk);
        while (!s00_axis_tready);
        @(negedge clk);
        s00_axis_tvalid = 1'b0;
    endtask

    // ─────────────────────────────────────────────────────────────
    // Helper: load tile data từ hex files
    // ─────────────────────────────────────────────────────────────
    task automatic load_case(input string name);
        integer i;
        // Clear buffers
        for (i = 0; i < 64; i = i + 1) A_mem[i] = 16'h0;
        for (i = 0; i < 64; i = i + 1) W_mem[i] = 16'h0;
        for (i = 0; i < 8;  i = i + 1) bias_mem[i] = 16'h0;
        for (i = 0; i < 64; i = i + 1) C_mem[i] = 16'h0;
        $readmemh({DATA_DIR, name, "_A.hex"},    A_mem);
        $readmemh({DATA_DIR, name, "_W.hex"},    W_mem);
        $readmemh({DATA_DIR, name, "_bias.hex"}, bias_mem);
        $readmemh({DATA_DIR, name, "_C.hex"},    C_mem);
    endtask

    // ─────────────────────────────────────────────────────────────
    // Helper: drive 1 tile (load → config → stream → capture → compare)
    // ─────────────────────────────────────────────────────────────
    task automatic run_one_tile(input string name,
                                input integer M_used,
                                input integer K_used,
                                input integer N_used,
                                input integer act_mode);
        integer r, c, p, m, n;
        integer K_pairs, N_pairs;
        integer expected_words;
        integer local_errs;
        reg [15:0] elem_lo, elem_hi;
        reg [15:0] cap_lo, cap_hi;
        reg [15:0] exp_v, got_v;
        reg [31:0] status;
        integer    timeout;

        load_case(name);

        // ── Reset capture for this tile (proper sync reset) ──
        @(negedge clk);
        capture_enable = 1'b0;
        capture_reset  = 1'b1;
        @(posedge clk);
        @(negedge clk);
        capture_reset  = 1'b0;
        capture_enable = 1'b1;

        // ── 1+2. AXI-Lite config + start, packed CONFIG (Phase 0 layout) ──
        //   0x00 CFG: [3:0]=M [7:4]=K [11:8]=N [13:12]=ACT [14]=START(one-shot)
        axi_lite_write(5'h00, (M_used    & 32'hF)
                            | ((K_used   & 32'hF) << 4)
                            | ((N_used   & 32'hF) << 8)
                            | ((act_mode & 32'h3) << 12)
                            | (32'h1 << 14));

        // ── 3. Drive AXIS slave: weights 32 word + bias 4 word + input ──
        // Weights: 8 rows × 4 word/row, even/odd packing
        for (r = 0; r < SA_N; r = r + 1) begin
            for (p = 0; p < 4; p = p + 1) begin
                axis_push({W_mem[r*8 + p*2 + 1], W_mem[r*8 + p*2]});
            end
        end
        // Bias: 4 word
        for (p = 0; p < 4; p = p + 1) begin
            axis_push({bias_mem[p*2 + 1], bias_mem[p*2]});
        end
        // Input: M × ⌈K/2⌉ word
        K_pairs = (K_used + 1) >> 1;
        for (m = 0; m < M_used; m = m + 1) begin
            for (p = 0; p < K_pairs; p = p + 1) begin
                elem_lo = A_mem[m*K_used + 2*p];
                elem_hi = (2*p + 1 < K_used) ? A_mem[m*K_used + 2*p + 1] : 16'h0;
                axis_push({elem_hi, elem_lo});
            end
        end

        // ── 4. Wait DONE bit in STATUS ──
        timeout = 0;
        status  = 32'h0;
        while (!status[1] && timeout < 2000) begin
            axi_lite_read(5'h0C, status);   // STATUS dời 0x10 -> 0x0C (Phase 0 pack)
            timeout = timeout + 1;
        end
        if (timeout >= 2000) begin
            $display("[FAIL] %s: TIMEOUT waiting DONE", name);
            errs = errs + 1;
            return;
        end

        // Stop capture
        @(posedge clk);
        capture_enable = 1'b0;

        // ── 5. Verify capture count ──
        N_pairs = (N_used + 1) >> 1;
        expected_words = M_used * N_pairs;
        if (capture_count !== expected_words) begin
            $display("[FAIL] %s: captured %0d words, expected %0d",
                     name, capture_count, expected_words);
            errs = errs + 1;
            return;
        end

        // ── 6. Compare unpacked output cells với C_mem ──
        local_errs = 0;
        for (m = 0; m < M_used; m = m + 1) begin
            for (p = 0; p < N_pairs; p = p + 1) begin
                cap_lo = capture_buf[m*N_pairs + p][15:0];
                cap_hi = capture_buf[m*N_pairs + p][31:16];

                // Even index 2p
                if (2*p < N_used) begin
                    exp_v = C_mem[m*N_used + 2*p];
                    got_v = cap_lo;
                    if (got_v !== exp_v) begin
                        if (local_errs < 3)
                            $display("[FAIL] %s C[%0d][%0d]: got=0x%h (%0d) exp=0x%h (%0d)",
                                     name, m, 2*p, got_v, $signed(got_v),
                                     exp_v, $signed(exp_v));
                        local_errs = local_errs + 1;
                    end
                    total_checks = total_checks + 1;
                end

                // Odd index 2p+1
                if (2*p + 1 < N_used) begin
                    exp_v = C_mem[m*N_used + 2*p + 1];
                    got_v = cap_hi;
                    if (got_v !== exp_v) begin
                        if (local_errs < 3)
                            $display("[FAIL] %s C[%0d][%0d]: got=0x%h (%0d) exp=0x%h (%0d)",
                                     name, m, 2*p+1, got_v, $signed(got_v),
                                     exp_v, $signed(exp_v));
                        local_errs = local_errs + 1;
                    end
                    total_checks = total_checks + 1;
                end
            end
        end

        if (local_errs == 0) begin
            $display("[ OK ] %s (M=%0d K=%0d N=%0d act=%0d)",
                     name, M_used, K_used, N_used, act_mode);
        end else begin
            $display("[FAIL] %s: %0d cells mismatch", name, local_errs);
        end
        errs = errs + local_errs;
        total_tiles = total_tiles + 1;
    endtask

    // ─────────────────────────────────────────────────────────────
    // DUT reset (between tiles)
    // ─────────────────────────────────────────────────────────────
    task automatic reset_dut();
        @(negedge clk);
        rst_n = 1'b0;
        repeat (5) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        @(posedge clk);
    endtask

    // ─────────────────────────────────────────────────────────────
    // Phase 1a-i helpers: push tile data + wait DONE
    // ─────────────────────────────────────────────────────────────
    task automatic push_tile(input integer M, input integer K);
        integer r, p, m, Kp;
        reg [15:0] lo, hi;
        for (r = 0; r < SA_N; r = r + 1)
            for (p = 0; p < 4; p = p + 1)
                axis_push({W_mem[r*8 + p*2 + 1], W_mem[r*8 + p*2]});
        for (p = 0; p < 4; p = p + 1)
            axis_push({bias_mem[p*2 + 1], bias_mem[p*2]});
        Kp = (K + 1) >> 1;
        for (m = 0; m < M; m = m + 1)
            for (p = 0; p < Kp; p = p + 1) begin
                lo = A_mem[m*K + 2*p];
                hi = (2*p + 1 < K) ? A_mem[m*K + 2*p + 1] : 16'h0;
                axis_push({hi, lo});
            end
    endtask

    task automatic wait_done(input string tag);
        reg [31:0] status;
        integer timeout;
        timeout = 0; status = 32'h0;
        while (!status[1] && timeout < 2000) begin
            axi_lite_read(5'h0C, status);
            timeout = timeout + 1;
        end
        if (timeout >= 2000) begin
            $display("[FAIL] %s: TIMEOUT waiting DONE", tag);
            errs = errs + 1;
        end
    endtask

    // ─────────────────────────────────────────────────────────────
    // Case 5: HW K-accumulation (Phase 1a-i)
    //   Tính chất tự kiểm: K-acc(P + P) == single-tile(2P).
    //   K0: overwrite (acc_accum=0), post_skip=1 → chỉ cộng dồn, không output.
    //   K1: accumulate (acc_accum=1), post_skip=0 → output = post_proc(P+P).
    //   Ref: single tile với 2×A → psum = 2P → output = post_proc(2P).
    //   2 đường phải khớp từng word.
    // ─────────────────────────────────────────────────────────────
    task automatic run_kaccum_check();
        integer m, k, n, i, nw, local_errs;
        reg [31:0] out_kacc [0:63];
        reg [31:0] cfg;

        // Data M=4,K=8,N=4, bias=0, act=bypass — giá trị nhỏ (2× không tràn)
        for (i = 0; i < 64; i = i + 1) begin A_mem[i] = 16'h0; W_mem[i] = 16'h0; end
        for (i = 0; i < 8;  i = i + 1) bias_mem[i] = 16'h0;
        for (m = 0; m < 4; m = m + 1)
            for (k = 0; k < 8; k = k + 1)
                A_mem[m*8 + k] = 16'h0080 + m*16'h0010 + k;
        for (k = 0; k < 8; k = k + 1)
            for (n = 0; n < 4; n = n + 1)
                W_mem[k*8 + n] = 16'h0040 + k*16'h0008 + n;
        nw  = 4 * ((4 + 1) >> 1);                       // M × ⌈N/2⌉ = 8 word
        cfg = (4 & 32'hF) | ((8 & 32'hF) << 4) | ((4 & 32'hF) << 8);   // M=4,K=8,N=4,bypass

        // ── K-acc run (KHÔNG reset giữa K0 và K1 → psum_buf persist) ──
        reset_dut();
        @(negedge clk); capture_enable = 1'b0; capture_reset = 1'b1;
        @(posedge clk); @(negedge clk); capture_reset = 1'b0; capture_enable = 1'b1;

        // K0: START | post_skip(bit16); acc_accum=0 (overwrite)
        axi_lite_write(5'h00, cfg | (32'h1 << 14) | (32'h1 << 16));
        push_tile(4, 8);
        wait_done("kacc.K0");

        // K1: START | acc_accum(bit15); post_skip=0 (output)
        axi_lite_write(5'h00, cfg | (32'h1 << 14) | (32'h1 << 15));
        push_tile(4, 8);
        wait_done("kacc.K1");

        @(posedge clk); capture_enable = 1'b0;
        for (i = 0; i < nw; i = i + 1) out_kacc[i] = capture_buf[i];

        // ── Reference: single tile với 2×A → 2P ──
        for (m = 0; m < 4; m = m + 1)
            for (k = 0; k < 8; k = k + 1)
                A_mem[m*8 + k] = (16'h0080 + m*16'h0010 + k) << 1;
        reset_dut();
        @(negedge clk); capture_enable = 1'b0; capture_reset = 1'b1;
        @(posedge clk); @(negedge clk); capture_reset = 1'b0; capture_enable = 1'b1;
        axi_lite_write(5'h00, cfg | (32'h1 << 14));     // overwrite + post (mặc định)
        push_tile(4, 8);
        wait_done("kacc.ref");
        @(posedge clk); capture_enable = 1'b0;

        // ── So sánh ──
        local_errs = 0;
        if (capture_count !== nw) begin
            $display("[FAIL] kaccum ref: captured %0d words, expected %0d", capture_count, nw);
            local_errs = local_errs + 1;
        end
        for (i = 0; i < nw; i = i + 1)
            if (out_kacc[i] !== capture_buf[i]) begin
                $display("[FAIL] kaccum word %0d: kacc=0x%h ref=0x%h",
                         i, out_kacc[i], capture_buf[i]);
                local_errs = local_errs + 1;
            end
        if (local_errs == 0)
            $display("[ OK ] kaccum: K0+K1 (P+P) == single 2P (%0d words)", nw);
        errs = errs + local_errs;
    endtask

    task automatic push_bias_input(input integer M, input integer K);
        integer p, m, Kp;
        reg [15:0] lo, hi;
        for (p = 0; p < 4; p = p + 1)
            axis_push({bias_mem[p*2 + 1], bias_mem[p*2]});
        Kp = (K + 1) >> 1;
        for (m = 0; m < M; m = m + 1)
            for (p = 0; p < Kp; p = p + 1) begin
                lo = A_mem[m*K + 2*p];
                hi = (2*p + 1 < K) ? A_mem[m*K + 2*p + 1] : 16'h0;
                axis_push({hi, lo});
            end
    endtask

    // ─────────────────────────────────────────────────────────────
    // Case 6: weight reuse via SKIP_W_LOAD (Phase 1a-ii-A)
    //   Run1: load W + input A1 (compute, để W lại trong array).
    //   Run2: SKIP_W_LOAD + input A2 (KHÔNG push weight) → C2_reuse.
    //         KHÔNG reset giữa Run1/Run2 → kiểm residual psum.
    //   Run3 (ref): reset, fresh load W + input A2 → C2_ref.
    //   C2_reuse phải == C2_ref.
    // ─────────────────────────────────────────────────────────────
    task automatic run_skipw_check();
        integer m, k, n, i, nw, local_errs;
        reg [31:0] out_reuse [0:63];
        reg [31:0] cfg;

        for (i = 0; i < 64; i = i + 1) begin A_mem[i] = 16'h0; W_mem[i] = 16'h0; end
        for (i = 0; i < 8;  i = i + 1) bias_mem[i] = 16'h0;
        for (k = 0; k < 8; k = k + 1)
            for (n = 0; n < 4; n = n + 1)
                W_mem[k*8 + n] = 16'h0040 + k*16'h0008 + n;
        nw  = 4 * ((4 + 1) >> 1);
        cfg = (4 & 32'hF) | ((8 & 32'hF) << 4) | ((4 & 32'hF) << 8);   // 4x8x4 bypass

        reset_dut();

        // ── Run1: fresh load W + input A1 (không capture) ──
        for (m = 0; m < 4; m = m + 1)
            for (k = 0; k < 8; k = k + 1)
                A_mem[m*8 + k] = 16'h0100 + m*16'h0010 + k;
        @(negedge clk); capture_enable = 1'b0; capture_reset = 1'b1;
        @(posedge clk); @(negedge clk); capture_reset = 1'b0;
        axi_lite_write(5'h00, cfg | (32'h1 << 14));      // normal load+post
        push_tile(4, 8);
        wait_done("skipw.run1");

        // ── Run2: SKIP_W_LOAD + input A2 (reuse W, không push weight) ──
        for (m = 0; m < 4; m = m + 1)
            for (k = 0; k < 8; k = k + 1)
                A_mem[m*8 + k] = 16'h0080 + m*16'h0008 + k;
        @(negedge clk); capture_reset = 1'b1;
        @(posedge clk); @(negedge clk); capture_reset = 1'b0; capture_enable = 1'b1;
        axi_lite_write(5'h00, cfg | (32'h1 << 14) | (32'h1 << 17));   // SKIP_W_LOAD
        push_bias_input(4, 8);
        wait_done("skipw.run2");
        @(posedge clk); capture_enable = 1'b0;
        for (i = 0; i < nw; i = i + 1) out_reuse[i] = capture_buf[i];

        // ── Run3 (ref): reset + fresh load W + input A2 ──
        reset_dut();
        @(negedge clk); capture_enable = 1'b0; capture_reset = 1'b1;
        @(posedge clk); @(negedge clk); capture_reset = 1'b0; capture_enable = 1'b1;
        axi_lite_write(5'h00, cfg | (32'h1 << 14));
        push_tile(4, 8);
        wait_done("skipw.ref");
        @(posedge clk); capture_enable = 1'b0;

        local_errs = 0;
        for (i = 0; i < nw; i = i + 1)
            if (out_reuse[i] !== capture_buf[i]) begin
                $display("[FAIL] skipw word %0d: reuse=0x%h ref=0x%h",
                         i, out_reuse[i], capture_buf[i]);
                local_errs = local_errs + 1;
            end
        if (local_errs == 0)
            $display("[ OK ] skipw: reuse-W == fresh-load (%0d words)", nw);
        errs = errs + local_errs;
    endtask

    // ─────────────────────────────────────────────────────────────
    // Case 7: accumulator slot independence (Phase 1a-ii-B)
    //   W nạp 1 lần, reuse (skip_w) cho mọi compute.
    //   slot0 ← A1 (overwrite, post_skip), slot1 ← A2 (overwrite, post_skip) → giữ.
    //   Xuất slot: compute zero-input + accumulate (cộng 0 → slot không đổi) +
    //   post → output slot. So với fresh A×W. Verify 2 slot độc lập + post đúng slot.
    // ─────────────────────────────────────────────────────────────
    task automatic run_slot_check();
        integer m, k, n, i, nw, local_errs;
        reg [31:0] c0_blk [0:63];
        reg [31:0] c1_blk [0:63];
        reg [31:0] cfg;

        for (i = 0; i < 64; i = i + 1) W_mem[i] = 16'h0;
        for (i = 0; i < 8;  i = i + 1) bias_mem[i] = 16'h0;
        for (k = 0; k < 8; k = k + 1)
            for (n = 0; n < 4; n = n + 1)
                W_mem[k*8 + n] = 16'h0040 + k*16'h0008 + n;
        nw  = 4 * ((4 + 1) >> 1);
        cfg = (4 & 32'hF) | ((8 & 32'hF) << 4) | ((4 & 32'hF) << 8);

        reset_dut();
        @(negedge clk); capture_enable = 1'b0; capture_reset = 1'b1;
        @(posedge clk); @(negedge clk); capture_reset = 1'b0;

        // slot0 ← A1 (load W, overwrite, post_skip)
        for (m = 0; m < 4; m = m + 1) for (k = 0; k < 8; k = k + 1)
            A_mem[m*8 + k] = 16'h0100 + m*16'h0010 + k;
        axi_lite_write(5'h00, cfg | (32'h1<<14) | (32'h1<<16) | (32'd0<<18));
        push_tile(4, 8);
        wait_done("slot.w0");

        // slot1 ← A2 (skip_w, overwrite, post_skip)
        for (m = 0; m < 4; m = m + 1) for (k = 0; k < 8; k = k + 1)
            A_mem[m*8 + k] = 16'h0080 + m*16'h0008 + k;
        axi_lite_write(5'h00, cfg | (32'h1<<14) | (32'h1<<16) | (32'h1<<17) | (32'd1<<18));
        push_bias_input(4, 8);
        wait_done("slot.w1");

        // Xuất slot0: zero-input + accumulate + post (slot không đổi)
        for (i = 0; i < 64; i = i + 1) A_mem[i] = 16'h0;
        @(negedge clk); capture_reset = 1'b1;
        @(posedge clk); @(negedge clk); capture_reset = 1'b0; capture_enable = 1'b1;
        axi_lite_write(5'h00, cfg | (32'h1<<14) | (32'h1<<15) | (32'h1<<17) | (32'd0<<18));
        push_bias_input(4, 8);
        wait_done("slot.r0");
        @(posedge clk); capture_enable = 1'b0;
        for (i = 0; i < nw; i = i + 1) c0_blk[i] = capture_buf[i];

        // Xuất slot1
        @(negedge clk); capture_reset = 1'b1;
        @(posedge clk); @(negedge clk); capture_reset = 1'b0; capture_enable = 1'b1;
        axi_lite_write(5'h00, cfg | (32'h1<<14) | (32'h1<<15) | (32'h1<<17) | (32'd1<<18));
        push_bias_input(4, 8);
        wait_done("slot.r1");
        @(posedge clk); capture_enable = 1'b0;
        for (i = 0; i < nw; i = i + 1) c1_blk[i] = capture_buf[i];

        // Ref slot0: fresh A1×W
        local_errs = 0;
        reset_dut();
        for (m = 0; m < 4; m = m + 1) for (k = 0; k < 8; k = k + 1)
            A_mem[m*8 + k] = 16'h0100 + m*16'h0010 + k;
        @(negedge clk); capture_reset = 1'b1;
        @(posedge clk); @(negedge clk); capture_reset = 1'b0; capture_enable = 1'b1;
        axi_lite_write(5'h00, cfg | (32'h1<<14));
        push_tile(4, 8);
        wait_done("slot.ref0");
        @(posedge clk); capture_enable = 1'b0;
        for (i = 0; i < nw; i = i + 1)
            if (c0_blk[i] !== capture_buf[i]) begin
                $display("[FAIL] slot0 word %0d: blk=0x%h ref=0x%h", i, c0_blk[i], capture_buf[i]);
                local_errs = local_errs + 1;
            end

        // Ref slot1: fresh A2×W
        reset_dut();
        for (m = 0; m < 4; m = m + 1) for (k = 0; k < 8; k = k + 1)
            A_mem[m*8 + k] = 16'h0080 + m*16'h0008 + k;
        @(negedge clk); capture_reset = 1'b1;
        @(posedge clk); @(negedge clk); capture_reset = 1'b0; capture_enable = 1'b1;
        axi_lite_write(5'h00, cfg | (32'h1<<14));
        push_tile(4, 8);
        wait_done("slot.ref1");
        @(posedge clk); capture_enable = 1'b0;
        for (i = 0; i < nw; i = i + 1)
            if (c1_blk[i] !== capture_buf[i]) begin
                $display("[FAIL] slot1 word %0d: blk=0x%h ref=0x%h", i, c1_blk[i], capture_buf[i]);
                local_errs = local_errs + 1;
            end

        if (local_errs == 0)
            $display("[ OK ] slot: 2 slot độc lập, post đúng slot (%0d words each)", nw);
        errs = errs + local_errs;
    endtask

    task automatic push_weight_bias();
        integer r, p;
        for (r = 0; r < SA_N; r = r + 1)
            for (p = 0; p < 4; p = p + 1)
                axis_push({W_mem[r*8 + p*2 + 1], W_mem[r*8 + p*2]});
        for (p = 0; p < 4; p = p + 1)
            axis_push({bias_mem[p*2 + 1], bias_mem[p*2]});
    endtask

    // ─────────────────────────────────────────────────────────────
    // Case 9: input reuse via SKIP_IN_LOAD (Phase 1a-ii-D)
    //   Run1: load W1 + input A0 (để A0 lại trong input_buf).
    //   Run2: SKIP_IN_LOAD + W2 (KHÔNG push input) → C2_reuse = A0×W2.
    //   Run3 (ref): reset, fresh W2 + A0 → C2_ref. Phải khớp.
    // ─────────────────────────────────────────────────────────────
    task automatic run_skipin_check();
        integer m, k, n, i, nw, local_errs;
        reg [31:0] out_reuse [0:63];
        reg [31:0] cfg;

        for (i = 0; i < 64; i = i + 1) begin A_mem[i] = 16'h0; W_mem[i] = 16'h0; end
        for (i = 0; i < 8;  i = i + 1) bias_mem[i] = 16'h0;
        for (m = 0; m < 4; m = m + 1) for (k = 0; k < 8; k = k + 1)
            A_mem[m*8 + k] = 16'h0100 + m*16'h0010 + k;         // input A0
        for (k = 0; k < 8; k = k + 1) for (n = 0; n < 4; n = n + 1)
            W_mem[k*8 + n] = 16'h0040 + k*16'h0008 + n;          // W1
        nw  = 4 * ((4 + 1) >> 1);
        cfg = (4 & 32'hF) | ((8 & 32'hF) << 4) | ((4 & 32'hF) << 8);

        reset_dut();
        // Run1: load W1 + A0 (no capture)
        @(negedge clk); capture_enable = 1'b0; capture_reset = 1'b1;
        @(posedge clk); @(negedge clk); capture_reset = 1'b0;
        axi_lite_write(5'h00, cfg | (32'h1 << 14));
        push_tile(4, 8);
        wait_done("skipin.run1");

        // Run2: SKIP_IN_LOAD + W2 (reuse A0, no input push)
        for (k = 0; k < 8; k = k + 1) for (n = 0; n < 4; n = n + 1)
            W_mem[k*8 + n] = 16'h0030 + k*16'h0004 + n;          // W2
        @(negedge clk); capture_reset = 1'b1;
        @(posedge clk); @(negedge clk); capture_reset = 1'b0; capture_enable = 1'b1;
        axi_lite_write(5'h00, cfg | (32'h1 << 14) | (32'h1 << 20));   // SKIP_IN_LOAD
        push_weight_bias();
        wait_done("skipin.run2");
        @(posedge clk); capture_enable = 1'b0;
        for (i = 0; i < nw; i = i + 1) out_reuse[i] = capture_buf[i];

        // Run3 ref: fresh W2 + A0
        reset_dut();
        @(negedge clk); capture_reset = 1'b1;
        @(posedge clk); @(negedge clk); capture_reset = 1'b0; capture_enable = 1'b1;
        axi_lite_write(5'h00, cfg | (32'h1 << 14));
        push_tile(4, 8);
        wait_done("skipin.ref");
        @(posedge clk); capture_enable = 1'b0;

        local_errs = 0;
        for (i = 0; i < nw; i = i + 1)
            if (out_reuse[i] !== capture_buf[i]) begin
                $display("[FAIL] skipin word %0d: reuse=0x%h ref=0x%h",
                         i, out_reuse[i], capture_buf[i]);
                local_errs = local_errs + 1;
            end
        if (local_errs == 0)
            $display("[ OK ] skipin: reuse-input == fresh-load (%0d words)", nw);
        errs = errs + local_errs;
    endtask

    // ─────────────────────────────────────────────────────────────
    // Case 8: full blocking (Phase 1a-ii-C) — blocking == simple K-acc
    //   GEMM 2 M-tile × K=16 (2 K-tile) × N=8. 2 đường tính cùng kết quả:
    //   (1) blocking: W reuse qua 2 slot, K-acc vào từng slot, output cuối K.
    //   (2) simple: từng M-tile, K-acc slot0, no reuse (đã verify ở Case 5).
    //   Tổ hợp K-acc + slot + skip_w cùng lúc = phần chưa test chung.
    // ─────────────────────────────────────────────────────────────
    reg [15:0] Wfull  [0:127];   // 16 K × 8 N  (k*8 + n)
    reg [15:0] Afull0 [0:127];   // slot0: 8 M × 16 K (m*16 + k)
    reg [15:0] Afull1 [0:127];

    task automatic ld_W(input integer k0);          // W_mem ← Wfull[k0..k0+7]
        integer k, n;
        for (k = 0; k < 8; k = k + 1)
            for (n = 0; n < 8; n = n + 1)
                W_mem[k*8 + n] = Wfull[(k0 + k)*8 + n];
    endtask
    task automatic ld_A(input integer sel, input integer k0);  // A_mem ← Afull[sel] cols k0..k0+7
        integer m, k;
        for (m = 0; m < 8; m = m + 1)
            for (k = 0; k < 8; k = k + 1)
                A_mem[m*8 + k] = (sel == 0) ? Afull0[m*16 + k0 + k]
                                            : Afull1[m*16 + k0 + k];
    endtask

    task automatic run_block_check();
        integer m, k, n, i, nw, local_errs;
        reg [31:0] c0_blk [0:63];
        reg [31:0] c1_blk [0:63];
        reg [31:0] cfg;

        for (i = 0; i < 8; i = i + 1) bias_mem[i] = 16'h0;
        for (k = 0; k < 16; k = k + 1) for (n = 0; n < 8; n = n + 1)
            Wfull[k*8 + n] = 16'h0020 + k*16'h0004 + n;
        for (m = 0; m < 8; m = m + 1) for (k = 0; k < 16; k = k + 1) begin
            Afull0[m*16 + k] = 16'h0040 + m*16'h0008 + k;
            Afull1[m*16 + k] = 16'h0030 + m*16'h0004 + k;
        end
        nw  = 8 * ((8 + 1) >> 1);            // 8 × 4 = 32 word
        cfg = (8 & 32'hF) | ((8 & 32'hF) << 4) | ((8 & 32'hF) << 8);

        // ── Đường 1: BLOCKING (2 slot, reuse W) ──
        reset_dut();
        @(negedge clk); capture_enable = 1'b0; capture_reset = 1'b1;
        @(posedge clk); @(negedge clk); capture_reset = 1'b0;
        // k0=0: slot0 load W, slot1 reuse W (both overwrite, post_skip)
        ld_W(0);  ld_A(0, 0);
        axi_lite_write(5'h00, cfg | (32'h1<<14) | (32'h1<<16) | (32'd0<<18));
        push_tile(8, 8); wait_done("blk.k0s0");
        ld_A(1, 0);
        axi_lite_write(5'h00, cfg | (32'h1<<14) | (32'h1<<16) | (32'h1<<17) | (32'd1<<18));
        push_bias_input(8, 8); wait_done("blk.k0s1");
        // k0=8 (last): slot0 load W[8] accum+post→out; slot1 reuse accum+post→out
        ld_W(8);  ld_A(0, 8);
        @(negedge clk); capture_reset = 1'b1; @(posedge clk); @(negedge clk);
        capture_reset = 1'b0; capture_enable = 1'b1;
        axi_lite_write(5'h00, cfg | (32'h1<<14) | (32'h1<<15) | (32'd0<<18));
        push_tile(8, 8); wait_done("blk.k1s0");
        @(posedge clk); capture_enable = 1'b0;
        for (i = 0; i < nw; i = i + 1) c0_blk[i] = capture_buf[i];
        ld_A(1, 8);
        @(negedge clk); capture_reset = 1'b1; @(posedge clk); @(negedge clk);
        capture_reset = 1'b0; capture_enable = 1'b1;
        axi_lite_write(5'h00, cfg | (32'h1<<14) | (32'h1<<15) | (32'h1<<17) | (32'd1<<18));
        push_bias_input(8, 8); wait_done("blk.k1s1");
        @(posedge clk); capture_enable = 1'b0;
        for (i = 0; i < nw; i = i + 1) c1_blk[i] = capture_buf[i];

        // ── Đường 2: SIMPLE K-acc (slot0, no reuse), so sánh ──
        local_errs = 0;
        // slot0 data → c0_smp
        reset_dut();
        ld_W(0); ld_A(0, 0);
        axi_lite_write(5'h00, cfg | (32'h1<<14) | (32'h1<<16));
        push_tile(8, 8); wait_done("smp.k0");
        ld_W(8); ld_A(0, 8);
        @(negedge clk); capture_reset = 1'b1; @(posedge clk); @(negedge clk);
        capture_reset = 1'b0; capture_enable = 1'b1;
        axi_lite_write(5'h00, cfg | (32'h1<<14) | (32'h1<<15));
        push_tile(8, 8); wait_done("smp.k1");
        @(posedge clk); capture_enable = 1'b0;
        for (i = 0; i < nw; i = i + 1)
            if (c0_blk[i] !== capture_buf[i]) begin
                $display("[FAIL] block slot0 word %0d: blk=0x%h smp=0x%h", i, c0_blk[i], capture_buf[i]);
                local_errs = local_errs + 1;
            end
        // slot1 data → c1_smp
        reset_dut();
        ld_W(0); ld_A(1, 0);
        axi_lite_write(5'h00, cfg | (32'h1<<14) | (32'h1<<16));
        push_tile(8, 8); wait_done("smp.k0b");
        ld_W(8); ld_A(1, 8);
        @(negedge clk); capture_reset = 1'b1; @(posedge clk); @(negedge clk);
        capture_reset = 1'b0; capture_enable = 1'b1;
        axi_lite_write(5'h00, cfg | (32'h1<<14) | (32'h1<<15));
        push_tile(8, 8); wait_done("smp.k1b");
        @(posedge clk); capture_enable = 1'b0;
        for (i = 0; i < nw; i = i + 1)
            if (c1_blk[i] !== capture_buf[i]) begin
                $display("[FAIL] block slot1 word %0d: blk=0x%h smp=0x%h", i, c1_blk[i], capture_buf[i]);
                local_errs = local_errs + 1;
            end

        if (local_errs == 0)
            $display("[ OK ] blocking: 2-slot W-reuse K-acc == simple K-acc (%0d words×2)", nw);
        errs = errs + local_errs;
    endtask

    // ─────────────────────────────────────────────────────────────
    // Case 6: HW im2col mode (Phase 2a integration)
    //   Cấu hình im2col, stream feature map vào, im2col chạy trong accelerator,
    //   verify ma trận A trong scratchpad (hierarchical peek) khớp golden.
    // ─────────────────────────────────────────────────────────────
    task automatic run_im2col_check();
        integer Hh, Ww, Cc, KHh, KWw, strr, padd, Hout, Wout, K, M;
        integer i, ho, wo, c, ik, iw, hin, win, row, col, nwords, local_errs;
        reg [15:0] fm   [0:255];
        reg [15:0] gold [0:511];
        reg [31:0] cfg0, cfg1;
        reg [15:0] got, exp;

        Hh=4; Ww=4; Cc=1; KHh=2; KWw=2; strr=1; padd=0; Hout=3; Wout=3;
        K = Cc*KHh*KWw; M = Hout*Wout;

        for (i=0;i<Cc*Hh*Ww;i=i+1) fm[i] = 16'h0100 + i;

        // golden im2col
        row=0;
        for (ho=0;ho<Hout;ho=ho+1)
        for (wo=0;wo<Wout;wo=wo+1) begin
            col=0;
            for (c=0;c<Cc;c=c+1)
            for (ik=0;ik<KHh;ik=ik+1)
            for (iw=0;iw<KWw;iw=iw+1) begin
                hin = ho*strr + ik - padd;
                win = wo*strr + iw - padd;
                if (hin>=0 && hin<Hh && win>=0 && win<Ww)
                    gold[row*K+col] = fm[c*Hh*Ww + hin*Ww + win];
                else gold[row*K+col] = 16'h0;
                col=col+1;
            end
            row=row+1;
        end

        cfg0 = (KWw<<28)|(KHh<<24)|(Cc<<16)|(Ww<<8)|Hh;
        cfg1 = (padd<<20)|(strr<<16)|(Wout<<8)|Hout;

        @(negedge clk);
        axi_lite_write(5'h14, cfg0);
        axi_lite_write(5'h18, cfg1);
        // CFG: IM2COL_MODE (bit21) + START (bit14)
        axi_lite_write(5'h00, (32'h1<<21) | (32'h1<<14));

        nwords = (Cc*Hh*Ww + 1) >> 1;
        for (i=0;i<nwords;i=i+1)
            axis_push({fm[2*i+1], fm[2*i]});

        wait_done("im2col");

        // Peek A region trong scratchpad (bank_a, base 1024)
        local_errs=0;
        for (i=0;i<M*K;i=i+1) begin
            got = dut.u_ctrl.u_sp.bank_a[11'd1024 + i];
            exp = gold[i];
            if (got !== exp) begin
                if (local_errs<6)
                    $display("[FAIL] im2col A[%0d]: got=0x%h exp=0x%h", i, got, exp);
                local_errs=local_errs+1;
            end
        end
        if (local_errs==0)
            $display("[ OK ] im2col-mode: A[%0d×%0d] khớp golden trong scratchpad", M, K);
        errs = errs + local_errs;
    endtask

    // ─────────────────────────────────────────────────────────────
    // Main stimulus
    // ─────────────────────────────────────────────────────────────
    initial begin
        $dumpfile("accelerator_top_tb.vcd");
        $dumpvars(0, accelerator_top_tb);

        // Init signals
        rst_n           = 1'b0;
        s00_axi_awaddr  = 5'h0;  s00_axi_awprot  = 3'b0;  s00_axi_awvalid = 1'b0;
        s00_axi_wdata   = 32'h0; s00_axi_wstrb   = 4'h0;  s00_axi_wvalid  = 1'b0;
        s00_axi_bready  = 1'b0;
        s00_axi_araddr  = 5'h0;  s00_axi_arprot  = 3'b0;  s00_axi_arvalid = 1'b0;
        s00_axi_rready  = 1'b0;
        s00_axis_tvalid = 1'b0;  s00_axis_tdata  = 32'h0;
        s00_axis_tstrb  = 4'h0;  s00_axis_tlast  = 1'b0;
        m00_axis_tready = 1'b1;          // always ready, no backpressure
        capture_enable  = 1'b0;
        capture_reset   = 1'b0;

        // Reset
        repeat (3) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        // ─────────── Case 1: Sanity 2x2x2 bypass ───────────
        $display("");
        $display("==== Case 1: Sanity 2x2x2 bypass ====");
        run_one_tile("top_case1", 2, 2, 2, 0);

        // ─────────── Case 2: 3 act mode trên cùng 4x4x4 ───────────
        $display("");
        $display("==== Case 2: 3 act mode (4x4x4) ====");
        reset_dut();
        run_one_tile("top_case2_bypass",  4, 4, 4, 0);
        reset_dut();
        run_one_tile("top_case2_relu",    4, 4, 4, 1);
        reset_dut();
        run_one_tile("top_case2_sigmoid", 4, 4, 4, 2);

        // ─────────── Case 3: Sweep 50 random tile ───────────
        $display("");
        $display("==== Case 3: Sweep 50 random tile ====");
        run_sweep_50();

        // ─────────── Case 4: Back-to-back 2 tile (no reset giữa) ───────────
        $display("");
        $display("==== Case 4: Back-to-back 2 tile (no reset giữa) ====");
        reset_dut();
        run_one_tile("top_case4a", 8, 8, 8, 0);
        // KHÔNG reset → verify tile B vẫn đúng
        run_one_tile("top_case4b", 8, 8, 8, 0);

        // ─────────── Case 5: HW K-accumulation (Phase 1a-i) ───────────
        $display("");
        $display("==== Case 5: HW K-accumulation (P+P == 2P) ====");
        run_kaccum_check();

        // ─────────── Case 6: weight reuse SKIP_W_LOAD (Phase 1a-ii-A) ───────────
        $display("");
        $display("==== Case 6: weight reuse (SKIP_W_LOAD) ====");
        run_skipw_check();

        // ─────────── Case 7: accumulator slot (Phase 1a-ii-B) ───────────
        $display("");
        $display("==== Case 7: accumulator slot independence ====");
        run_slot_check();

        // ─────────── Case 8: full blocking (Phase 1a-ii-C) ───────────
        $display("");
        $display("==== Case 8: blocking (W-reuse + K-acc + slots) ====");
        run_block_check();

        // ─────────── Case 9: input reuse SKIP_IN_LOAD (Phase 1a-ii-D) ───────────
        $display("");
        $display("==== Case 9: input reuse (SKIP_IN_LOAD) ====");
        run_skipin_check();

        // ─────────── Case 10: HW im2col mode (Phase 2a) ───────────
        $display("");
        $display("==== Case 10: HW im2col mode ====");
        reset_dut();
        run_im2col_check();

        // ─────────── Summary ───────────
        $display("");
        $display("Total tiles run:   %0d", total_tiles);
        $display("Total cell checks: %0d", total_checks);
        if (errs == 0)
            $display("=== ALL ACCELERATOR TOP TESTS PASSED ===");
        else
            $display("=== %0d ACCELERATOR TOP TEST FAILURES ===", errs);
        $finish;
    end

    // ─────────────────────────────────────────────────────────────
    // Sweep helper (50 tile từ manifest hardcoded)
    // ─────────────────────────────────────────────────────────────
    // Manifest format khớp tools/gen_top_sweep.py output (seed=42).
    task automatic run_sweep_50();
        integer Ms [0:49];
        integer Ks [0:49];
        integer Ns [0:49];
        string  name;
        integer i;

        // Manifest copy từ sweep_manifest.txt (seed=42)
        Ms = '{1,7,6,4,4,7,1,6,2,1, 5,8,6,7,6,7,5,2,7,4, 5,3,2,8,7,6,4,7,5,4,
               4,2,1,5,8,1,7,7,3,6, 2,7,6,3,1,8,4,8,6,7};
        Ks = '{7,2,3,4,4,1,5,2,6,6, 8,6,3,8,4,3,8,3,1,4, 7,2,4,2,6,4,3,2,5,6,
               8,4,2,7,6,6,1,3,7,7, 4,7,7,4,8,3,2,6,6,2};
        Ns = '{7,2,7,1,7,7,7,6,4,6, 3,7,5,4,5,5,1,2,2,1, 4,6,6,4,7,5,1,7,5,6,
               5,5,1,5,7,3,5,1,3,4, 8,2,3,4,8,7,1,2,7,1};

        for (i = 0; i < 50; i = i + 1) begin
            name = $sformatf("sweep_%02d", i);
            reset_dut();
            run_one_tile(name, Ms[i], Ks[i], Ns[i], 0);
        end
    endtask

    // -------- Timeout watchdog --------
    initial begin
        #2000000;       // 2 ms
        $display("[TIMEOUT] simulation exceeded 2 ms");
        $finish;
    end

endmodule
